#!/usr/bin/env python3
"""Build a labeling manifest from iOS VerificationDataset captures."""

from __future__ import annotations

import argparse
import csv
import json
from pathlib import Path
from typing import Any, Dict, List


def to_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def to_int(value: Any) -> int | None:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def to_bool(value: Any) -> int | None:
    if isinstance(value, bool):
        return 1 if value else 0
    if isinstance(value, (int, float)):
        return 1 if value else 0
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered in {"1", "true", "yes", "y"}:
            return 1
        if lowered in {"0", "false", "no", "n"}:
            return 0
    return None


def flatten_row(json_path: Path, payload: Dict[str, Any]) -> Dict[str, Any]:
    debug = payload.get("debugSnapshot") or {}
    l2_features = debug.get("l2Features") if isinstance(debug, dict) else {}
    if not isinstance(l2_features, dict):
        l2_features = {}

    wav_path = json_path.with_suffix(".wav")
    row: Dict[str, Any] = {
        "session_dir": json_path.parent.as_posix(),
        "chunk_json": json_path.as_posix(),
        "chunk_wav": wav_path.as_posix(),
        "recorded_at": payload.get("recordedAt", ""),
        "call_id": payload.get("callId", ""),
        "remote_user_id": payload.get("remoteUserId", ""),
        "remote_voiceprint_tag": payload.get("remoteVoiceprintTag", ""),
        "tuning_version": payload.get("tuningVersion", ""),
        "chunk_index": to_int(payload.get("chunkIndex")),
        "sample_rate": to_float(payload.get("sampleRate")),
        "sample_count": to_int(payload.get("sampleCount")),
        "speech_activity_ratio": to_float(payload.get("speechActivityRatio")),
        "speech_continuous_seconds": to_float(payload.get("speechContinuousSeconds")),
        "model_human_pass": to_bool(payload.get("modelHumanPass")),
        "l2_human_confidence": to_float(payload.get("l2HumanConfidence")),
        "l3_similarity_raw": to_float(payload.get("l3SimilarityRaw")),
        "l3_similarity_smoothed": to_float(payload.get("l3SimilaritySmoothed")),
        "adaptive_similarity_threshold": to_float(payload.get("adaptiveSimilarityThreshold")),
        "stable_identity_match": to_bool(payload.get("stableIdentityMatch")),
        "debug_l1_pass": to_bool(debug.get("l1Pass") if isinstance(debug, dict) else None),
        "debug_deepfake_pass": to_bool(debug.get("deepfakePass") if isinstance(debug, dict) else None),
        "debug_identity_pass": to_bool(debug.get("identityPass") if isinstance(debug, dict) else None),
        "debug_final_confidence": to_float(debug.get("finalConfidence") if isinstance(debug, dict) else None),
        "debug_l2_features_json": json.dumps(l2_features, sort_keys=True),
        # Manual labels:
        "label_human": "",
        "label_identity_match": "",
        "label_notes": "",
    }
    return row


def build_manifest(dataset_root: Path) -> List[Dict[str, Any]]:
    rows: List[Dict[str, Any]] = []
    for json_path in sorted(dataset_root.rglob("chunk_*.json")):
        try:
            payload = json.loads(json_path.read_text())
        except Exception:
            continue
        if not isinstance(payload, dict):
            continue
        rows.append(flatten_row(json_path, payload))
    return rows


def main() -> int:
    parser = argparse.ArgumentParser(description="Build labeling manifest from VerificationDataset folders")
    parser.add_argument("--dataset-root", required=True, help="Root folder containing VerificationDataset exports")
    parser.add_argument("--output", required=True, help="Output CSV path")
    args = parser.parse_args()

    dataset_root = Path(args.dataset_root).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    if not dataset_root.exists():
        raise SystemExit(f"Dataset root not found: {dataset_root}")

    rows = build_manifest(dataset_root)
    if not rows:
        raise SystemExit("No chunk_*.json files found under dataset root")

    fieldnames = list(rows[0].keys())
    with output.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
