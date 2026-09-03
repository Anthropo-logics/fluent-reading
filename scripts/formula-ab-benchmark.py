#!/usr/bin/env python3
"""Prepare and run the formula-classification A/B without writing to the internal disk."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from pathlib import Path

from PIL import Image, ImageDraw


def read_json(path: Path):
    return json.loads(path.read_text(encoding="utf-8"))


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")


def parse_model_json(raw: str):
    start = raw.find("{")
    if start < 0:
        return None
    try:
        value, _ = json.JSONDecoder().raw_decode(raw[start:])
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def resolve_pdf(corpus: Path, name: str) -> Path:
    matches = list(corpus.rglob(name))
    if len(matches) != 1:
        raise RuntimeError(f"expected one PDF named {name}, found {len(matches)}")
    return matches[0]


def page_size(pdf: Path, page: int) -> tuple[float, float]:
    result = subprocess.run(
        ["pdfinfo", "-f", str(page), "-l", str(page), str(pdf)],
        check=True,
        capture_output=True,
        text=True,
    )
    match = re.search(rf"Page\s+{page}\s+size:\s+([\d.]+)\s+x\s+([\d.]+)\s+pts", result.stdout)
    if not match:
        match = re.search(r"Page size:\s+([\d.]+)\s+x\s+([\d.]+)\s+pts", result.stdout)
    if not match:
        raise RuntimeError(f"could not read page size for {pdf} page {page}")
    return float(match.group(1)), float(match.group(2))


def render_page(pdf: Path, page: int, output: Path, dpi: int) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    png = output.with_suffix(".png")
    if not png.exists():
        subprocess.run(
            [
                "pdftoppm",
                "-f",
                str(page),
                "-l",
                str(page),
                "-r",
                str(dpi),
                "-png",
                "-singlefile",
                str(pdf),
                str(output),
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    return png


def union_rect(rects: list[list[float]]) -> list[float]:
    left = min(rect[0] for rect in rects)
    bottom = min(rect[1] for rect in rects)
    right = max(rect[0] + rect[2] for rect in rects)
    top = max(rect[1] + rect[3] for rect in rects)
    return [left, bottom, right - left, top - bottom]


def group_formula_blocks(blocks: list[dict]) -> list[list[dict]]:
    groups: list[list[dict]] = []
    for block in sorted(blocks, key=lambda item: (-item["rect"][1], item["rect"][0])):
        x, y, width, height = block["rect"]
        center_y = y + height / 2
        for group in groups:
            gx, gy, gw, gh = union_rect([item["rect"] for item in group])
            vertical_match = abs(center_y - (gy + gh / 2)) <= max(18.0, height, gh)
            horizontal_gap = max(gx - (x + width), x - (gx + gw), 0.0)
            stacked_match = horizontal_gap <= 18.0 and abs(center_y - (gy + gh / 2)) <= 42.0
            if (vertical_match and horizontal_gap <= 42.0) or stacked_match:
                group.append(block)
                break
        else:
            groups.append([block])
    return groups


def crop_candidate(
    page_png: Path,
    page_height: float,
    rect: list[float],
    output: Path,
    dpi: int,
) -> None:
    scale = dpi / 72.0
    x, y, width, height = rect
    image = Image.open(page_png).convert("RGB")
    candidate = (
        x * scale,
        (page_height - y - height) * scale,
        (x + width) * scale,
        (page_height - y) * scale,
    )
    margin_x = max(90.0 * scale, width * scale * 0.35)
    margin_y = max(24.0 * scale, height * scale * 1.25)
    crop_box = (
        max(0, int(candidate[0] - margin_x)),
        max(0, int(candidate[1] - margin_y)),
        min(image.width, int(candidate[2] + margin_x)),
        min(image.height, int(candidate[3] + margin_y)),
    )
    cropped = image.crop(crop_box)
    draw = ImageDraw.Draw(cropped)
    outlined = tuple(int(value) for value in (
        candidate[0] - crop_box[0],
        candidate[1] - crop_box[1],
        candidate[2] - crop_box[0],
        candidate[3] - crop_box[1],
    ))
    draw.rectangle(outlined, outline=(220, 0, 0), width=max(3, round(scale * 2)))
    output.parent.mkdir(parents=True, exist_ok=True)
    cropped.save(output, optimize=True)


def crop_tight(
    page_png: Path,
    page_height: float,
    rect: list[float],
    output: Path,
    dpi: int,
) -> None:
    scale = dpi / 72.0
    x, y, width, height = rect
    image = Image.open(page_png).convert("RGB")
    margin = 4.0 * scale
    box = (
        max(0, int(x * scale - margin)),
        max(0, int((page_height - y - height) * scale - margin)),
        min(image.width, int((x + width) * scale + margin)),
        min(image.height, int((page_height - y) * scale + margin)),
    )
    output.parent.mkdir(parents=True, exist_ok=True)
    image.crop(box).save(output, optimize=True)


def prepare(args) -> None:
    corpus = Path(args.corpus)
    output = Path(args.output)
    pages_dir = output / "pages"
    crops_dir = output / "crops"
    manifest: list[dict] = []

    control = read_json(Path(args.control))
    for index, hit in enumerate(control["formula_hits"]):
        pdf = resolve_pdf(corpus, hit["document"])
        page = int(hit["page"])
        _, height = page_size(pdf, page)
        page_png = render_page(pdf, page, pages_dir / f"control-{index:03d}", args.dpi)
        for region_index, formula in enumerate(hit["formulas"]):
            candidate_id = f"neg-layout-{index:03d}-{region_index:02d}"
            crop = crops_dir / f"{candidate_id}.png"
            tight = crops_dir / f"{candidate_id}-tight.png"
            crop_candidate(page_png, height, formula["rect"], crop, args.dpi)
            crop_tight(page_png, height, formula["rect"], tight, args.dpi)
            manifest.append(
                {
                    "id": candidate_id,
                    "expected": "not_formula",
                    "source": "control_layout_false_positive",
                    "document": hit["document"],
                    "page": page,
                    "rect": formula["rect"],
                    "layout_confidence": formula["confidence"],
                    "crop": str(crop),
                    "tight_crop": str(tight),
                }
            )

    sample = read_json(Path(args.sample))
    positive_pages = [
        item
        for item in sample
        if item.get("formula_blocks") and item.get("normalized_formula_unit_count", 0) > 0
    ]
    selected = positive_pages[: args.positive_pages]
    sp_ss = next(
        (item for item in sample if "PTSD BY COUNTRY" in json.dumps(item)),
        None,
    )
    if sp_ss and sp_ss not in selected:
        selected.append(sp_ss)

    for page_index, item in enumerate(selected):
        match = re.search(r"^mtqn-formula-\d+-(.+\.pdf)-p(\d+)$", item["id"])
        if not match:
            raise RuntimeError(f"cannot parse sample id {item['id']}")
        document, page_text = match.groups()
        page = int(page_text)
        pdf = resolve_pdf(corpus, document)
        _, height = page_size(pdf, page)
        page_png = render_page(pdf, page, pages_dir / f"sample-{page_index:03d}", args.dpi)
        groups = group_formula_blocks(item["formula_blocks"])
        for group_index, group in enumerate(groups[: args.groups_per_page]):
            joined = " ".join(block.get("text", "") for block in group).strip()
            expected = "not_formula" if "PTSD BY COUNTRY" in joined or "MISSING ANALYSIS" in joined else "review"
            candidate_id = f"sample-{page_index:03d}-{group_index:02d}"
            crop = crops_dir / f"{candidate_id}.png"
            tight = crops_dir / f"{candidate_id}-tight.png"
            rect = union_rect([block["rect"] for block in group])
            crop_candidate(page_png, height, rect, crop, args.dpi)
            crop_tight(page_png, height, rect, tight, args.dpi)
            manifest.append(
                {
                    "id": candidate_id,
                    "expected": expected,
                    "source": "mtqn_stratified",
                    "document": document,
                    "page": page,
                    "rect": rect,
                    "layout_text": joined,
                    "crop": str(crop),
                    "tight_crop": str(tight),
                }
            )

    write_json(output / "manifest.json", manifest)
    print(json.dumps({"candidates": len(manifest), "manifest": str(output / "manifest.json")}))


def classify(args) -> None:
    from mlx_vlm import load, stream_generate
    from mlx_vlm.prompt_utils import apply_chat_template
    from mlx_vlm.utils import load_config
    from transformers.image_utils import load_image

    manifest = read_json(Path(args.manifest))[args.offset :]
    if args.limit:
        manifest = manifest[: args.limit]
    model_path = args.model
    started = time.perf_counter()
    model, processor = load(model_path)
    loaded = time.perf_counter()
    config = load_config(model_path)
    target_description = (
        "Classify only the document content enclosed by the red rectangle. Surrounding content is context."
        if args.image_field == "crop"
        else "Classify all content in this tightly cropped document region."
    )
    prompt_text = (
        target_description
        + " Return exactly one compact JSON object and no markdown. The kind value must be "
        "exactly one of these seven strings: formula, text, url, code, table, note, abstain. Never "
        "copy this list into the value. For non-formula content, for example, return "
        '{"kind":"text","latex":null}. For a formula return, for example, '
        '{"kind":"formula","latex":"x^2 + y^2"}. '
        "Use formula only for a genuine mathematical expression, never for a citation number, "
        "URL/query string, software command, prose, table value, or isolated punctuation. If and "
        "only if kind is formula, replace null with an exact LaTeX transcription of the complete "
        "expression in the rectangle. When uncertain use abstain."
    )
    results = []
    for item in manifest:
        prompt = apply_chat_template(processor, config, prompt_text, num_images=1)
        image = load_image(item[args.image_field])
        generated = ""
        item_started = time.perf_counter()
        for token in stream_generate(
            model,
            processor,
            prompt,
            [image],
            max_tokens=args.max_tokens,
            temperature=0.0,
            verbose=False,
        ):
            generated += token.text
            if any(stop in generated for stop in ("<|end_of_text|>", "<end_of_utterance>")):
                break
        elapsed = time.perf_counter() - item_started
        parsed = parse_model_json(generated)
        results.append(
            {
                "id": item["id"],
                "expected": item["expected"],
                "kind": parsed.get("kind") if isinstance(parsed, dict) else "invalid",
                "latex": parsed.get("latex") if isinstance(parsed, dict) else None,
                "elapsed_seconds": round(elapsed, 3),
                "raw": generated,
            }
        )
        print(json.dumps(results[-1], ensure_ascii=False), flush=True)
    write_json(
        Path(args.output),
        {
            "model": model_path,
            "model_load_seconds": round(loaded - started, 3),
            "total_seconds": round(time.perf_counter() - started, 3),
            "results": results,
        },
    )


def score(args) -> None:
    payload = read_json(Path(args.results))
    annotations = read_json(Path(args.annotations))
    manifest = {item["id"]: item for item in read_json(Path(args.manifest))}
    counts = {"tp": 0, "tn": 0, "fp": 0, "fn": 0, "abstain": 0, "excluded": 0}
    details = []
    allowed = {"formula", "text", "url", "code", "table", "note", "abstain"}
    for result in payload["results"]:
        item = manifest[result["id"]]
        annotation = annotations.get(result["id"], {})
        expected = annotation.get("expected", item["expected"])
        if expected == "review":
            raise RuntimeError(f"missing annotation for {result['id']}")
        if expected == "ambiguous":
            counts["excluded"] += 1
            continue
        parsed = parse_model_json(result["raw"])
        kind = parsed.get("kind") if parsed else "invalid"
        latex = parsed.get("latex") if parsed else None
        predicted_formula = kind == "formula" and isinstance(latex, str) and bool(latex.strip())
        valid_kind = kind in allowed
        if not valid_kind or kind == "abstain":
            counts["abstain"] += 1
        if expected == "formula" and predicted_formula:
            outcome = "tp"
        elif expected == "formula":
            outcome = "fn"
        elif predicted_formula:
            outcome = "fp"
        else:
            outcome = "tn"
        counts[outcome] += 1
        details.append(
            {
                "id": result["id"],
                "expected": expected,
                "predicted_kind": kind,
                "outcome": outcome,
                "region_quality": annotation.get("region_quality", item["source"]),
                "latex": latex,
            }
        )
    precision_denominator = counts["tp"] + counts["fp"]
    recall_denominator = counts["tp"] + counts["fn"]
    summary = {
        **counts,
        "precision": counts["tp"] / precision_denominator if precision_denominator else None,
        "recall": counts["tp"] / recall_denominator if recall_denominator else None,
        "false_positives": [item for item in details if item["outcome"] == "fp"],
        "false_negatives": [item for item in details if item["outcome"] == "fn"],
        "details": details,
    }
    write_json(Path(args.output), summary)
    print(json.dumps({key: value for key, value in summary.items() if key != "details"}, ensure_ascii=False))


def contact_sheets(args) -> None:
    manifest = read_json(Path(args.manifest))
    output = Path(args.output)
    output.mkdir(parents=True, exist_ok=True)
    cell_width, cell_height = 520, 230
    for sheet_index, start in enumerate(range(0, len(manifest), args.per_sheet)):
        items = manifest[start : start + args.per_sheet]
        rows = (len(items) + args.columns - 1) // args.columns
        sheet = Image.new("RGB", (cell_width * args.columns, cell_height * rows), "white")
        draw = ImageDraw.Draw(sheet)
        for offset, item in enumerate(items):
            column, row = offset % args.columns, offset // args.columns
            left, top = column * cell_width, row * cell_height
            image = Image.open(item["crop"]).convert("RGB")
            image.thumbnail((cell_width - 20, cell_height - 55))
            sheet.paste(image, (left + 10, top + 45))
            title = f"{item['id']} [{item['expected']}] p{item['page']}"
            detail = item.get("layout_text", "")[:74]
            draw.text((left + 10, top + 8), title, fill="black")
            draw.text((left + 10, top + 24), detail, fill="black")
            draw.rectangle((left, top, left + cell_width - 1, top + cell_height - 1), outline="gray")
        sheet.save(output / f"sheet-{sheet_index:02d}.jpg", quality=88)
    print(json.dumps({"sheets": sheet_index + 1 if manifest else 0, "output": str(output)}))


def main() -> None:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)
    prep = subparsers.add_parser("prepare")
    prep.add_argument("--corpus", required=True)
    prep.add_argument("--control", required=True)
    prep.add_argument("--sample", required=True)
    prep.add_argument("--output", required=True)
    prep.add_argument("--dpi", type=int, default=144)
    prep.add_argument("--positive-pages", type=int, default=24)
    prep.add_argument("--groups-per-page", type=int, default=2)
    prep.set_defaults(function=prepare)

    run = subparsers.add_parser("classify")
    run.add_argument("--manifest", required=True)
    run.add_argument("--model", required=True)
    run.add_argument("--output", required=True)
    run.add_argument("--max-tokens", type=int, default=160)
    run.add_argument("--offset", type=int, default=0)
    run.add_argument("--limit", type=int)
    run.add_argument("--image-field", choices=("crop", "tight_crop"), default="crop")
    run.set_defaults(function=classify)

    contact = subparsers.add_parser("contact")
    contact.add_argument("--manifest", required=True)
    contact.add_argument("--output", required=True)
    contact.add_argument("--columns", type=int, default=3)
    contact.add_argument("--per-sheet", type=int, default=12)
    contact.set_defaults(function=contact_sheets)

    scoring = subparsers.add_parser("score")
    scoring.add_argument("--manifest", required=True)
    scoring.add_argument("--annotations", required=True)
    scoring.add_argument("--results", required=True)
    scoring.add_argument("--output", required=True)
    scoring.set_defaults(function=score)
    args = parser.parse_args()
    args.function(args)


if __name__ == "__main__":
    main()
