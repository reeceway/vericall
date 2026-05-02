#!/usr/bin/env python3
"""Prepare deterministic train/val/test manifests from labeled pipeline captures."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional


def parse_optional_float(value: Any) -> Optional[float]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return float(text)
    except ValueError:
        return None


def parse_optional_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    text = str(value).strip()
    if not text:
        return None
    try:
        return int(text)
    except ValueError:
        lowered = text.lower()
        if lowered in {"true", "yes", "y"}:
            return 1
        if lowered in {"false", "no", "n"}:
            return 0
        return None


def stable_split(group_id: str, seed: str, train_ratio: float, val_ratio: float) -> str:
    payload = f"{seed}:{group_id}".encode("utf-8")
    digest = hashlib.sha1(payload).hexdigest()[:8]
    bucket = int(digest, 16) / float(0xFFFFFFFF)
    if bucket < train_ratio:
        return "train"
    if bucket < (train_ratio + val_ratio):
        return "val"
    return "test"


def read_rows(manifest_csv: Path) -> Iterable[Dict[str, str]]:
    with manifest_csv.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            yield row


def ensure_parent(path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)


def write_csv(path: Path, fieldnames: List[str], rows: List[Dict[str, Any]]) -> None:
    ensure_parent(path)
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def default_group_key(row: Dict[str, str]) -> str:
    for candidate in (
        row.get("call_id"),
        row.get("session_dir"),
        row.get("remote_user_id"),
        row.get("remote_voiceprint_tag"),
        row.get("chunk_wav"),
    ):
        if candidate and str(candidate).strip():
            return str(candidate).strip()
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description="Prepare retraining manifests from labeled captures")
    parser.add_argument("--manifest", required=True, help="Labeled manifest CSV")
    parser.add_argument("--output-dir", required=True, help="Output directory")
    parser.add_argument("--train-ratio", type=float, default=0.70)
    parser.add_argument("--val-ratio", type=float, default=0.15)
    parser.add_argument("--seed", default="vericall-pipeline-v1", help="Deterministic split seed")
    parser.add_argument(
        "--require-audio-files",
        action="store_true",
        help="Drop rows where chunk_wav path does not exist",
    )
    args = parser.parse_args()

    train_ratio = float(args.train_ratio)
    val_ratio = float(args.val_ratio)
    if train_ratio <= 0 or val_ratio < 0 or train_ratio + val_ratio >= 1:
        raise SystemExit("Expected ratios with train>0, val>=0, and train+val<1")

    manifest = Path(args.manifest).expanduser().resolve()
    if not manifest.exists():
        raise SystemExit(f"Manifest not found: {manifest}")
    output_dir = Path(args.output_dir).expanduser().resolve()
    output_dir.mkdir(parents=True, exist_ok=True)

    deepfake_rows: List[Dict[str, Any]] = []
    identity_rows: List[Dict[str, Any]] = []
    skipped_missing_audio = 0

    for row in read_rows(manifest):
        chunk_wav = (row.get("chunk_wav") or "").strip()
        if not chunk_wav:
            continue
        chunk_wav_path = Path(chunk_wav)
        if args.require_audio_files and not chunk_wav_path.exists():
            skipped_missing_audio += 1
            continue

        group_key = default_group_key(row)
        split = stable_split(group_key, args.seed, train_ratio, val_ratio)
        shared = {
            "split": split,
            "group_key": group_key,
            "call_id": row.get("call_id", ""),
            "remote_user_id": row.get("remote_user_id", ""),
            "remote_voiceprint_tag": row.get("remote_voiceprint_tag", ""),
            "chunk_wav": chunk_wav,
            "chunk_json": row.get("chunk_json", ""),
            "recorded_at": row.get("recorded_at", ""),
            "speech_activity_ratio": row.get("speech_activity_ratio", ""),
            "speech_continuous_seconds": row.get("speech_continuous_seconds", ""),
            "l2_human_confidence": row.get("l2_human_confidence", ""),
            "debug_l2_features_json": row.get("debug_l2_features_json", ""),
        }

        label_human = parse_optional_int(row.get("label_human"))
        if label_human in (0, 1):
            deepfake_rows.append(
                {
                    **shared,
                    "label_human": int(label_human),
                }
            )

        label_identity = parse_optional_int(row.get("label_identity_match"))
        l3_similarity = parse_optional_float(row.get("l3_similarity_smoothed"))
        if label_identity in (0, 1) and l3_similarity is not None:
            identity_rows.append(
                {
                    **shared,
                    "label_identity_match": int(label_identity),
                    "l3_similarity_smoothed": l3_similarity,
                }
            )

    deepfake_path = output_dir / "deepfake_retrain_manifest.csv"
    identity_path = output_dir / "identity_retrain_manifest.csv"

    deepfake_fields = [
        "split",
        "group_key",
        "label_human",
        "call_id",
        "remote_user_id",
        "remote_voiceprint_tag",
        "chunk_wav",
        "chunk_json",
        "recorded_at",
        "speech_activity_ratio",
        "speech_continuous_seconds",
        "l2_human_confidence",
        "debug_l2_features_json",
    ]
    identity_fields = [
        "split",
        "group_key",
        "label_identity_match",
        "call_id",
        "remote_user_id",
        "remote_voiceprint_tag",
        "chunk_wav",
        "chunk_json",
        "recorded_at",
        "speech_activity_ratio",
        "speech_continuous_seconds",
        "l2_human_confidence",
        "l3_similarity_smoothed",
        "debug_l2_features_json",
    ]

    write_csv(deepfake_path, deepfake_fields, deepfake_rows)
    write_csv(identity_path, identity_fields, identity_rows)

    def split_counts(rows: List[Dict[str, Any]], label_key: str) -> Dict[str, Dict[str, int]]:
        counts: Dict[str, Dict[str, int]] = {}
        for item in rows:
            split = item["split"]
            label = str(item[label_key])
            split_stats = counts.setdefault(split, {})
            split_stats[label] = split_stats.get(label, 0) + 1
        return counts

    summary = {
        "source_manifest": str(manifest),
        "output_dir": str(output_dir),
        "train_ratio": train_ratio,
        "val_ratio": val_ratio,
        "test_ratio": 1.0 - train_ratio - val_ratio,
        "seed": args.seed,
        "skipped_missing_audio": skipped_missing_audio,
        "deepfake": {
            "rows": len(deepfake_rows),
            "by_split_and_label": split_counts(deepfake_rows, "label_human"),
            "manifest": str(deepfake_path),
        },
        "identity": {
            "rows": len(identity_rows),
            "by_split_and_label": split_counts(identity_rows, "label_identity_match"),
            "manifest": str(identity_path),
        },
    }

    summary_path = output_dir / "retrain_summary.json"
    summary_path.write_text(json.dumps(summary, indent=2))

    print(f"Wrote {deepfake_path} ({len(deepfake_rows)} rows)")
    print(f"Wrote {identity_path} ({len(identity_rows)} rows)")
    print(f"Wrote {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
