#!/usr/bin/env python3
"""Compare native Core ML PP-DocLayoutV3 with its PyTorch source graph."""

from __future__ import annotations

import argparse
import importlib.util
import json
import math
import subprocess
import tempfile
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image
from transformers import (
    AutoModelForObjectDetection,
    PPDocLayoutV3ImageProcessor,
)


def load_exporter():
    path = Path(__file__).with_name("export-pp-doclayout-v3-coreml.py")
    spec = importlib.util.spec_from_file_location("pp_doclayout_exporter", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load exporter: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--coreml", required=True, type=Path)
    parser.add_argument("--cases", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--work-dir", required=True, type=Path)
    parser.add_argument("--threshold", type=float, default=0.3)
    return parser.parse_args()


def render_page(source: Path, page: int, directory: Path) -> Image.Image:
    prefix = directory / f"page-{page}"
    subprocess.run(
        [
            "pdftoppm",
            "-f",
            str(page),
            "-l",
            str(page),
            "-singlefile",
            "-r",
            "200",
            "-png",
            str(source),
            str(prefix),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    with Image.open(prefix.with_suffix(".png")) as image:
        return image.convert("RGB")


def sigmoid(value: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-np.clip(value, -80, 80)))


def detections(
    logits: np.ndarray,
    boxes: np.ndarray,
    order_logits: np.ndarray,
    labels: dict[int, str],
    threshold: float,
) -> list[dict[str, object]]:
    order_scores = sigmoid(order_logits[0])
    votes = np.triu(order_scores, k=1).sum(axis=0)
    votes += np.tril(1.0 - order_scores.T, k=-1).sum(axis=0)
    pointers = np.argsort(votes)
    order = np.empty_like(pointers)
    order[pointers] = np.arange(len(pointers))

    probabilities = sigmoid(logits[0]).reshape(-1)
    flat_indices = np.argsort(probabilities)[::-1][: logits.shape[1]]
    scores = probabilities[flat_indices]
    class_indices = flat_indices % logits.shape[2]
    query_indices = flat_indices // logits.shape[2]
    selected_boxes = boxes[0, query_indices]
    centers = selected_boxes[:, :2]
    dimensions = selected_boxes[:, 2:]
    xyxy = np.concatenate(
        [centers - 0.5 * dimensions, centers + 0.5 * dimensions], axis=1
    )

    keep = scores >= threshold
    rows = list(
        zip(
            scores[keep],
            class_indices[keep],
            xyxy[keep],
            order[query_indices][keep],
        )
    )
    rows.sort(key=lambda row: int(row[3]))
    return [
        {
            "label": labels[int(label)],
            "score": float(score),
            "box": [float(value) for value in box],
            "order": int(rank),
        }
        for score, label, box, rank in rows
    ]


def iou(left: list[float], right: list[float]) -> float:
    x1 = max(left[0], right[0])
    y1 = max(left[1], right[1])
    x2 = min(left[2], right[2])
    y2 = min(left[3], right[3])
    intersection = max(0.0, x2 - x1) * max(0.0, y2 - y1)
    left_area = max(0.0, left[2] - left[0]) * max(0.0, left[3] - left[1])
    right_area = max(0.0, right[2] - right[0]) * max(0.0, right[3] - right[1])
    union = left_area + right_area - intersection
    return intersection / union if union else 0.0


def match(reference: list[dict], candidate: list[dict]) -> dict[str, object]:
    available = set(range(len(candidate)))
    overlaps = []
    score_deltas = []
    for expected in reference:
        options = [
            (iou(expected["box"], candidate[index]["box"]), index)
            for index in available
            if candidate[index]["label"] == expected["label"]
        ]
        if not options:
            continue
        overlap, index = max(options)
        if overlap < 0.5:
            continue
        available.remove(index)
        overlaps.append(overlap)
        score_deltas.append(abs(expected["score"] - candidate[index]["score"]))
    return {
        "reference_count": len(reference),
        "candidate_count": len(candidate),
        "matched_count": len(overlaps),
        "recall": len(overlaps) / len(reference) if reference else 1.0,
        "mean_iou": float(np.mean(overlaps)) if overlaps else 0.0,
        "minimum_iou": min(overlaps, default=0.0),
        "maximum_score_delta": max(score_deltas, default=0.0),
        "ordered_labels_equal": [row["label"] for row in reference]
        == [row["label"] for row in candidate],
    }


def main() -> None:
    args = parse_args()
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite: {args.output}")
    args.work_dir.mkdir(parents=True, exist_ok=True)
    cases = json.loads(args.cases.read_text())["results"]
    exporter = load_exporter()
    processor = PPDocLayoutV3ImageProcessor.from_pretrained(
        args.model, local_files_only=True
    )
    model = AutoModelForObjectDetection.from_pretrained(
        args.model, local_files_only=True
    ).eval()
    labels = {int(key): value for key, value in model.config.id2label.items()}

    samples = []
    with tempfile.TemporaryDirectory(dir=args.work_dir, prefix="renders-") as temporary:
        temporary_path = Path(temporary)
        for case in cases:
            image = render_page(Path(case["source"]), int(case["page"]), temporary_path)
            tensor = processor(images=image, return_tensors="pt")["pixel_values"]
            samples.append((case, tuple(reversed(image.size)), tensor))

    references = []
    with torch.inference_mode():
        for _, _, tensor in samples:
            output = model(pixel_values=tensor, return_dict=True)
            references.append(
                tuple(
                    value.detach().cpu().numpy()
                    for value in (output.logits, output.pred_boxes, output.order_logits)
                )
            )
        exporter.freeze_position_embeddings(model)
        exporter.freeze_anchors(model)
        exporter.freeze_multiscale_attention(model)
        for index, (_, _, tensor) in enumerate(samples):
            output = model(pixel_values=tensor, return_dict=True)
            patched = (output.logits, output.pred_boxes, output.order_logits)
            for name, expected, actual in zip(
                exporter.OUTPUT_NAMES, references[index], patched
            ):
                if not np.array_equal(expected, actual.detach().cpu().numpy()):
                    raise RuntimeError(
                        f"static graph changed {samples[index][0]['id']} {name}"
                    )

    load_started = time.perf_counter()
    coreml = ct.models.MLModel(str(args.coreml), compute_units=ct.ComputeUnit.ALL)
    load_seconds = time.perf_counter() - load_started
    results = []
    for (case, pixels, tensor), reference in zip(samples, references):
        started = time.perf_counter()
        native = coreml.predict({"pixel_values": tensor.numpy()})
        elapsed = time.perf_counter() - started
        native_tuple = tuple(native[name] for name in exporter.OUTPUT_NAMES)
        raw = {}
        for name, expected, actual in zip(
            exporter.OUTPUT_NAMES, reference, native_tuple
        ):
            delta = np.abs(expected - actual)
            raw[name] = {
                "maximum_absolute_error": float(delta.max()),
                "mean_absolute_error": float(delta.mean()),
                "finite": bool(np.isfinite(actual).all()),
            }
        reference_detections = detections(
            *reference, labels=labels, threshold=args.threshold
        )
        native_detections = detections(
            *native_tuple, labels=labels, threshold=args.threshold
        )
        results.append(
            {
                "id": case["id"],
                "source": case["source"],
                "page": case["page"],
                "pixels": pixels,
                "coreml_seconds": elapsed,
                "raw": raw,
                "detections": match(reference_detections, native_detections),
                "reference_labels": [row["label"] for row in reference_detections],
                "coreml_labels": [row["label"] for row in native_detections],
            }
        )

    recalls = [row["detections"]["recall"] for row in results]
    median_seconds = float(np.median([row["coreml_seconds"] for row in results]))
    report = {
        "model": str(args.model),
        "coreml": str(args.coreml),
        "threshold": args.threshold,
        "coreml_load_seconds": load_seconds,
        "coreml_median_seconds": median_seconds,
        "minimum_detection_recall": min(recalls),
        "all_outputs_finite": all(
            metric["finite"]
            for row in results
            for metric in row["raw"].values()
        ),
        "results": results,
    }
    if not math.isfinite(median_seconds):
        raise RuntimeError("invalid Core ML timing")
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
