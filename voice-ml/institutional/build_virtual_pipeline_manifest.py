#!/usr/bin/env python3
"""Build a massive virtual manifest for on-the-fly pipeline audio shaping."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence, Tuple


SUPPORTED_EXTS = {".wav", ".flac", ".aiff", ".aif", ".m4a", ".mp3"}
PROFILES = [
    "clean",
    "telephony",
    "telephony_noise",
    "packet_loss",
    "mulaw",
    "speed_perturb",
    "clipped",
]


def iter_audio_files(roots: Sequence[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists():
            continue
        for p in root.rglob("*"):
            if p.is_file() and p.suffix.lower() in SUPPORTED_EXTS:
                yield p


def deterministic_shuffle(paths: List[Path], seed: int, salt: str) -> List[Path]:
    def key_fn(p: Path) -> str:
        return hashlib.sha1(f"{seed}:{salt}:{p.as_posix()}".encode("utf-8")).hexdigest()

    return sorted(paths, key=key_fn)


def source_group(path: Path) -> str:
    stem = path.stem
    m = re.match(r"^\d+_([A-Za-z]+)_\d+$", stem)
    if m:
        return f"fsdd_{m.group(1).lower()}"

    parts = list(path.parts)
    if "LibriSpeech" in parts:
        idx = parts.index("LibriSpeech")
        if idx + 2 < len(parts):
            return f"ls_{parts[idx + 2]}"

    parent = path.parent.name.lower()
    prefix = re.split(r"[_\-]", stem.lower())[0]
    return f"{parent}_{prefix}"


def split_for_group(group: str, seed: int, train_ratio: float, val_ratio: float) -> str:
    h = hashlib.sha1(f"{seed}:{group}".encode("utf-8")).hexdigest()[:8]
    bucket = int(h, 16) / float(0xFFFFFFFF)
    if bucket < train_ratio:
        return "train"
    if bucket < train_ratio + val_ratio:
        return "val"
    return "test"


def select_balanced(real_paths: List[Path], fake_paths: List[Path], seed: int, target_per_class: int) -> Tuple[List[Path], List[Path]]:
    real_sorted = deterministic_shuffle(real_paths, seed=seed, salt="real")
    fake_sorted = deterministic_shuffle(fake_paths, seed=seed, salt="fake")
    n = min(len(real_sorted), len(fake_sorted))
    if target_per_class > 0:
        n = min(n, target_per_class)
    return real_sorted[:n], fake_sorted[:n]


def main() -> int:
    parser = argparse.ArgumentParser(description="Build virtual manifest for large-scale on-the-fly augmentation")
    parser.add_argument("--real-dir", action="append", required=True)
    parser.add_argument("--fake-dir", action="append", required=True)
    parser.add_argument("--output", required=True, help="Output CSV path")
    parser.add_argument("--summary", help="Optional summary JSON path")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--target-sources-per-class", type=int, default=3000)
    parser.add_argument("--virtual-samples-per-source", type=int, default=80)
    parser.add_argument("--target-seconds", type=float, default=2.5)
    parser.add_argument("--train-ratio", type=float, default=0.8)
    parser.add_argument("--val-ratio", type=float, default=0.1)
    args = parser.parse_args()

    if args.virtual_samples_per_source <= 0:
        raise SystemExit("--virtual-samples-per-source must be > 0")
    if args.target_seconds <= 0:
        raise SystemExit("--target-seconds must be > 0")
    if args.train_ratio <= 0 or args.val_ratio < 0 or args.train_ratio + args.val_ratio >= 1:
        raise SystemExit("train_ratio + val_ratio must be < 1 and train_ratio > 0")

    real_roots = [Path(p).expanduser().resolve() for p in args.real_dir]
    fake_roots = [Path(p).expanduser().resolve() for p in args.fake_dir]
    real_paths = list(iter_audio_files(real_roots))
    fake_paths = list(iter_audio_files(fake_roots))
    if not real_paths:
        raise SystemExit("No real audio files found")
    if not fake_paths:
        raise SystemExit("No fake audio files found")

    real_sel, fake_sel = select_balanced(
        real_paths,
        fake_paths,
        seed=args.seed,
        target_per_class=max(0, args.target_sources_per_class),
    )

    rows: List[Dict[str, Any]] = []
    for label, paths in [("real", real_sel), ("fake", fake_sel)]:
        for source_idx, source_path in enumerate(paths):
            group = source_group(source_path)
            split = split_for_group(
                group=group,
                seed=args.seed,
                train_ratio=args.train_ratio,
                val_ratio=args.val_ratio,
            )
            for sample_idx in range(args.virtual_samples_per_source):
                profile = PROFILES[sample_idx % len(PROFILES)]
                segment_idx = sample_idx
                aug_seed_hex = hashlib.sha1(
                    f"{args.seed}:{source_path.as_posix()}:{sample_idx}:{profile}".encode("utf-8")
                ).hexdigest()[:12]
                aug_seed = int(aug_seed_hex, 16)
                sample_id = hashlib.sha1(
                    f"{label}:{source_path.as_posix()}:{sample_idx}".encode("utf-8")
                ).hexdigest()[:18]
                rows.append(
                    {
                        "sample_id": sample_id,
                        "label": label,
                        "split": split,
                        "source_group": group,
                        "source_path": source_path.as_posix(),
                        "target_seconds": f"{args.target_seconds:.3f}",
                        "virtual_segment_index": segment_idx,
                        "augmentation_profile": profile,
                        "augmentation_seed": aug_seed,
                    }
                )

            if (source_idx + 1) % 500 == 0:
                print(f"[{label}] source {source_idx + 1}/{len(paths)} processed")

    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        writer.writeheader()
        writer.writerows(rows)

    by_label: Dict[str, int] = {"real": 0, "fake": 0}
    by_split: Dict[str, int] = {"train": 0, "val": 0, "test": 0}
    for row in rows:
        by_label[row["label"]] = by_label.get(row["label"], 0) + 1
        by_split[row["split"]] = by_split.get(row["split"], 0) + 1

    summary = {
        "seed": args.seed,
        "target_sources_per_class": args.target_sources_per_class,
        "virtual_samples_per_source": args.virtual_samples_per_source,
        "target_seconds": args.target_seconds,
        "selected_sources": {
            "real": len(real_sel),
            "fake": len(fake_sel),
        },
        "rows_total": len(rows),
        "rows_by_label": by_label,
        "rows_by_split": by_split,
        "output": output.as_posix(),
    }

    summary_path = Path(args.summary).expanduser().resolve() if args.summary else output.with_suffix(".summary.json")
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"Wrote virtual manifest: {output}")
    print(f"Wrote summary: {summary_path}")
    print(f"Total rows: {len(rows)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
