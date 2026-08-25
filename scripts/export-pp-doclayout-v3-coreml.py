#!/usr/bin/env python3
"""Export the fixed PP-DocLayoutV3 graph to a native Core ML package.

Python is a build-time tool only. The produced model accepts one normalized
800x800 RGB tensor and returns the tensors needed by the Swift postprocessor.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import time
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
import torch.nn.functional as F
from transformers import AutoModelForObjectDetection


INPUT_SHAPE = (1, 3, 800, 800)
OUTPUT_NAMES = ("class_logits", "boxes_cxcywh", "order_logits")


class LayoutOutputs(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.model = model

    def forward(self, pixel_values: torch.Tensor) -> tuple[torch.Tensor, ...]:
        output = self.model(pixel_values=pixel_values, return_dict=True)
        return output.logits, output.pred_boxes, output.order_logits


class FixedPositionEmbedding(torch.nn.Module):
    """Static equivalent of the official embedding for the fixed 800px input."""

    def __init__(self, value: torch.Tensor) -> None:
        super().__init__()
        self.register_buffer("value", value)

    def forward(self, width: int, height: int, device: object, dtype: object) -> torch.Tensor:
        return self.value


class FixedMultiscaleAttention(torch.nn.Module):
    """Equivalent deformable attention with all model-fixed shapes explicit."""

    def __init__(self, shapes: tuple[tuple[int, int], ...]) -> None:
        super().__init__()
        self.shapes = shapes

    def forward(
        self,
        value: torch.Tensor,
        spatial_shapes: torch.Tensor,
        spatial_shapes_list: object,
        level_start_index: torch.Tensor,
        sampling_locations: torch.Tensor,
        attention_weights: torch.Tensor,
        im2col_step: int,
    ) -> torch.Tensor:
        value_levels = value.split([height * width for height, width in self.shapes], dim=1)
        sampling_grids = 2 * sampling_locations - 1
        sampled = []
        for level, (height, width) in enumerate(self.shapes):
            level_value = (
                value_levels[level]
                .flatten(2)
                .transpose(1, 2)
                .reshape(8, 32, height, width)
            )
            point_start = level * 4
            level_grid = (
                sampling_grids[:, :, :, point_start : point_start + 4]
                .transpose(1, 2)
                .flatten(0, 1)
            )
            sampled.append(
                F.grid_sample(
                    level_value,
                    level_grid,
                    mode="bilinear",
                    padding_mode="zeros",
                    align_corners=False,
                )
            )
        weights = attention_weights.transpose(1, 2).reshape(8, 1, 300, 12)
        output = (
            (torch.stack(sampled, dim=-2).flatten(-2) * weights)
            .sum(-1)
            .view(1, 256, 300)
        )
        return output.transpose(1, 2).contiguous()


class FixedEncoderAttention(torch.nn.Module):
    """The official cross-attention with level x point flattened to rank five."""

    def __init__(
        self, source: torch.nn.Module, shapes: tuple[tuple[int, int], ...]
    ) -> None:
        super().__init__()
        self.sampling_offsets = source.sampling_offsets
        self.attention_weights = source.attention_weights
        self.value_proj = source.value_proj
        self.output_proj = source.output_proj
        self.attn = FixedMultiscaleAttention(shapes)

    def forward(
        self,
        hidden_states: torch.Tensor,
        attention_mask: torch.Tensor | None = None,
        encoder_hidden_states: torch.Tensor | None = None,
        encoder_attention_mask: torch.Tensor | None = None,
        position_embeddings: torch.Tensor | None = None,
        reference_points: torch.Tensor | None = None,
        spatial_shapes: torch.Tensor | None = None,
        spatial_shapes_list: object = None,
        level_start_index: torch.Tensor | None = None,
        **kwargs: object,
    ) -> tuple[torch.Tensor, torch.Tensor]:
        if position_embeddings is not None:
            hidden_states = hidden_states + position_embeddings
        value = self.value_proj(encoder_hidden_states).view(1, 13125, 8, 32)
        offsets = self.sampling_offsets(hidden_states).view(1, 300, 8, 12, 2)
        weights = self.attention_weights(hidden_states).view(1, 300, 8, 12)
        weights = F.softmax(weights, dim=-1)

        centers = reference_points[..., :2].repeat_interleave(12, dim=2).unsqueeze(2)
        sizes = reference_points[..., 2:].repeat_interleave(12, dim=2).unsqueeze(2)
        locations = centers + offsets / 4 * sizes * 0.5
        output = self.attn(
            value,
            spatial_shapes,
            spatial_shapes_list,
            level_start_index,
            locations,
            weights,
            64,
        )
        return self.output_proj(output), weights


def freeze_position_embeddings(model: torch.nn.Module) -> None:
    encoder = model.model.encoder
    for index, feature_index in enumerate(encoder.encode_proj_layers):
        stride = encoder.feat_strides[feature_index]
        height = INPUT_SHAPE[-2] // stride
        width = INPUT_SHAPE[-1] // stride
        aifi = encoder.aifi[index]
        value = aifi.position_embedding(
            width=width, height=height, device="cpu", dtype=torch.float32
        ).detach()
        aifi.position_embedding = FixedPositionEmbedding(value)


def freeze_anchors(model: torch.nn.Module) -> None:
    detector = model.model
    spatial_shapes = tuple(
        (INPUT_SHAPE[-2] // stride, INPUT_SHAPE[-1] // stride)
        for stride in detector.config.feat_strides
    )
    anchors, valid_mask = detector.generate_anchors(
        spatial_shapes=spatial_shapes, device="cpu", dtype=torch.float32
    )
    detector.register_buffer("anchors", anchors)
    detector.register_buffer("valid_mask", valid_mask)
    detector.config.anchor_image_size = INPUT_SHAPE[-1]


def freeze_multiscale_attention(model: torch.nn.Module) -> None:
    detector = model.model
    shapes = tuple(
        (INPUT_SHAPE[-2] // stride, INPUT_SHAPE[-1] // stride)
        for stride in detector.config.feat_strides
    )
    for layer in detector.decoder.layers:
        layer.encoder_attn = FixedEncoderAttention(layer.encoder_attn, shapes)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--torchscript", type=Path)
    parser.add_argument("--trace-only", action="store_true")
    parser.add_argument("--precision", choices=("fp16", "fp32"), default="fp32")
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    weights = args.model / "model.safetensors"
    if not weights.is_file():
        raise SystemExit(f"missing model weights: {weights}")
    if args.output.exists():
        raise SystemExit(f"refusing to overwrite: {args.output}")

    started = time.perf_counter()
    model = AutoModelForObjectDetection.from_pretrained(
        args.model, local_files_only=True
    ).eval()
    wrapped = LayoutOutputs(model).eval()
    example = torch.zeros(INPUT_SHAPE, dtype=torch.float32)

    with torch.inference_mode():
        baseline = wrapped(example)
        freeze_position_embeddings(model)
        freeze_anchors(model)
        freeze_multiscale_attention(model)
        reference = wrapped(example)
        for name, expected, actual in zip(OUTPUT_NAMES, baseline, reference):
            if not torch.equal(expected, actual):
                raise RuntimeError(f"static position embedding changed {name}")
        traced = torch.jit.trace(wrapped, example, strict=False, check_trace=False)
        traced_outputs = traced(example)
    for name, expected, actual in zip(OUTPUT_NAMES, reference, traced_outputs):
        if not torch.allclose(expected, actual, rtol=1e-4, atol=1e-5):
            raise RuntimeError(f"TorchScript trace changed {name}")

    if args.torchscript:
        if args.torchscript.exists():
            raise SystemExit(f"refusing to overwrite: {args.torchscript}")
        traced.save(str(args.torchscript))

    if not args.trace_only:
        precision = (
            ct.precision.FLOAT16 if args.precision == "fp16" else ct.precision.FLOAT32
        )
        converted = ct.convert(
            traced,
            convert_to="mlprogram",
            minimum_deployment_target=ct.target.macOS15,
            compute_precision=precision,
            inputs=[
                ct.TensorType(
                    name="pixel_values", shape=INPUT_SHAPE, dtype=np.float32
                )
            ],
            outputs=[ct.TensorType(name=name) for name in OUTPUT_NAMES],
        )
        converted.short_description = "PP-DocLayoutV3 native layout detector"
        converted.author = "PaddlePaddle; Core ML conversion by Lectura Fluida"
        converted.license = "Apache-2.0"
        converted.user_defined_metadata["source_revision"] = args.model.name
        converted.user_defined_metadata["weights_sha256"] = sha256(weights)
        converted.user_defined_metadata["compute_precision"] = args.precision
        converted.save(str(args.output))

    print(
        json.dumps(
            {
                "model": str(args.model),
                "weights_sha256": sha256(weights),
                "input_shape": INPUT_SHAPE,
                "outputs": {
                    name: list(value.shape)
                    for name, value in zip(OUTPUT_NAMES, reference)
                },
                "torchscript": str(args.torchscript) if args.torchscript else None,
                "coreml": None if args.trace_only else str(args.output),
                "precision": args.precision,
                "elapsed_seconds": round(time.perf_counter() - started, 3),
            },
            indent=2,
        )
    )


if __name__ == "__main__":
    main()
