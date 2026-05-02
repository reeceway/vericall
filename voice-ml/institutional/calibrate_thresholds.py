#!/usr/bin/env python3
"""Calibrate VeriCall verification thresholds from labeled production captures."""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Dict, Iterable, List, Optional, Tuple

import numpy as np


def parse_optional_float(value: str) -> Optional[float]:
    if value is None:
        return None
    v = str(value).strip()
    if not v:
        return None
    try:
        return float(v)
    except ValueError:
        return None


def parse_optional_int(value: str) -> Optional[int]:
    if value is None:
        return None
    v = str(value).strip()
    if not v:
        return None
    try:
        return int(v)
    except ValueError:
        return None


@dataclass
class DeepfakeRow:
    label_human: int
    l2_human_confidence: float
    l1_pass: int
    speech_activity_ratio: Optional[float]
    speech_continuous_seconds: Optional[float]


@dataclass
class IdentityRow:
    label_identity_match: int
    l2_human_confidence: float
    l3_similarity_smoothed: float
    speech_activity_ratio: float
    speech_continuous_seconds: float


def confusion_binary(labels: np.ndarray, preds: np.ndarray) -> Dict[str, int]:
    tp = int(np.sum((labels == 1) & (preds == 1)))
    tn = int(np.sum((labels == 0) & (preds == 0)))
    fp = int(np.sum((labels == 0) & (preds == 1)))
    fn = int(np.sum((labels == 1) & (preds == 0)))
    return {"tp": tp, "tn": tn, "fp": fp, "fn": fn}


def rates(conf: Dict[str, int]) -> Dict[str, float]:
    tp, tn, fp, fn = conf["tp"], conf["tn"], conf["fp"], conf["fn"]
    tpr = tp / max(1, tp + fn)
    tnr = tn / max(1, tn + fp)
    far = fp / max(1, fp + tn)
    frr = fn / max(1, fn + tp)
    acc = (tp + tn) / max(1, tp + tn + fp + fn)
    bal_acc = (tpr + tnr) / 2.0
    return {"tpr": tpr, "tnr": tnr, "far": far, "frr": frr, "acc": acc, "balanced_acc": bal_acc}


def load_rows(manifest_csv: Path) -> Tuple[List[DeepfakeRow], List[IdentityRow]]:
    deepfake_rows: List[DeepfakeRow] = []
    identity_rows: List[IdentityRow] = []

    with manifest_csv.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            l2 = parse_optional_float(row.get("l2_human_confidence", ""))
            l1 = parse_optional_int(row.get("debug_l1_pass", ""))
            speech_ratio = parse_optional_float(row.get("speech_activity_ratio", ""))
            speech_cont = parse_optional_float(row.get("speech_continuous_seconds", ""))
            if l2 is None:
                continue

            label_human = parse_optional_int(row.get("label_human", ""))
            if label_human in (0, 1):
                deepfake_rows.append(
                    DeepfakeRow(
                        label_human=label_human,
                        l2_human_confidence=l2,
                        l1_pass=1 if l1 == 1 else 0,
                        speech_activity_ratio=speech_ratio,
                        speech_continuous_seconds=speech_cont,
                    )
                )

            label_identity = parse_optional_int(row.get("label_identity_match", ""))
            l3 = parse_optional_float(row.get("l3_similarity_smoothed", ""))
            if label_identity in (0, 1) and l3 is not None and speech_ratio is not None and speech_cont is not None:
                identity_rows.append(
                    IdentityRow(
                        label_identity_match=label_identity,
                        l2_human_confidence=l2,
                        l3_similarity_smoothed=l3,
                        speech_activity_ratio=speech_ratio,
                        speech_continuous_seconds=speech_cont,
                    )
                )

    return deepfake_rows, identity_rows


def optimize_deepfake(rows: List[DeepfakeRow], target_far: float) -> Dict[str, float]:
    labels = np.array([r.label_human for r in rows], dtype=np.int32)
    l2 = np.array([r.l2_human_confidence for r in rows], dtype=np.float64)
    l1 = np.array([r.l1_pass for r in rows], dtype=np.int32)

    best: Optional[Tuple[float, float, Dict[str, float], Dict[str, int]]] = None
    best_score = -1.0

    primary_values = np.arange(0.20, 0.81, 0.01)
    secondary_values = np.arange(0.20, 0.91, 0.01)

    for primary in primary_values:
        for secondary in secondary_values:
            if secondary < primary:
                continue
            preds = ((l2 >= primary) & ((l1 == 1) | (l2 >= secondary))).astype(np.int32)
            conf = confusion_binary(labels, preds)
            m = rates(conf)
            # Prefer configurations meeting FAR target. Heavily penalize high FAR.
            penalty = 0.0 if m["far"] <= target_far else (m["far"] - target_far) * 4.0
            score = m["tpr"] - penalty - (0.20 * m["frr"])
            if score > best_score:
                best_score = score
                best = (primary, secondary, m, conf)

    if best is None:
        raise RuntimeError("Failed to optimize deepfake thresholds")

    primary, secondary, metrics, conf = best

    human_rows = [r for r in rows if r.label_human == 1]
    speech_activity = [r.speech_activity_ratio for r in human_rows if r.speech_activity_ratio is not None]
    speech_continuous = [r.speech_continuous_seconds for r in human_rows if r.speech_continuous_seconds is not None]

    speech_ratio_threshold = 0.18
    speech_cont_threshold = 0.40
    if speech_activity:
        speech_ratio_threshold = float(np.clip(np.quantile(speech_activity, 0.10), 0.10, 0.35))
    if speech_continuous:
        speech_cont_threshold = float(np.clip(np.quantile(speech_continuous, 0.10), 0.20, 1.20))

    return {
        "l2_human_primary_threshold": float(round(primary, 4)),
        "l2_human_secondary_threshold": float(round(secondary, 4)),
        "deepfake_human_score_threshold": float(round(primary, 4)),
        "deepfake_required_speech_activity_ratio": float(round(speech_ratio_threshold, 4)),
        "deepfake_required_continuous_speech_seconds": float(round(speech_cont_threshold, 4)),
        "deepfake_metrics": metrics,
        "deepfake_confusion": conf,
    }


def optimize_identity(rows: List[IdentityRow], target_far: float) -> Dict[str, float]:
    labels = np.array([r.label_identity_match for r in rows], dtype=np.int32)
    l2 = np.array([r.l2_human_confidence for r in rows], dtype=np.float64)
    l3 = np.array([r.l3_similarity_smoothed for r in rows], dtype=np.float64)
    speech_ratio = np.array([r.speech_activity_ratio for r in rows], dtype=np.float64)
    speech_cont = np.array([r.speech_continuous_seconds for r in rows], dtype=np.float64)

    best = None
    best_score = -1.0

    sim_values = np.arange(0.70, 0.991, 0.01)
    human_values = np.arange(0.20, 0.801, 0.02)
    speech_ratio_values = np.arange(0.10, 0.401, 0.02)
    speech_cont_values = np.arange(0.20, 1.21, 0.10)

    for sim_thr in sim_values:
        for human_thr in human_values:
            for speech_thr in speech_ratio_values:
                for cont_thr in speech_cont_values:
                    preds = (
                        (l2 >= human_thr) &
                        (l3 >= sim_thr) &
                        (speech_ratio >= speech_thr) &
                        (speech_cont >= cont_thr)
                    ).astype(np.int32)
                    conf = confusion_binary(labels, preds)
                    m = rates(conf)
                    penalty = 0.0 if m["far"] <= target_far else (m["far"] - target_far) * 5.0
                    score = m["tpr"] - penalty - (0.15 * m["frr"])
                    if score > best_score:
                        best_score = score
                        best = (sim_thr, human_thr, speech_thr, cont_thr, m, conf)

    if best is None:
        raise RuntimeError("Failed to optimize identity thresholds")

    sim_thr, human_thr, speech_thr, cont_thr, metrics, conf = best

    return {
        "l3_similarity_threshold": float(round(sim_thr, 4)),
        "identity_strict_similarity_threshold": float(round(sim_thr, 4)),
        "identity_min_human_confidence": float(round(human_thr, 4)),
        "identity_required_speech_activity_ratio": float(round(speech_thr, 4)),
        "identity_required_continuous_speech_seconds": float(round(cont_thr, 4)),
        "identity_quality_bonus_similarity_delta": 0.01,
        # Slightly stricter service-level defaults for non-call verification.
        "service_strict_similarity_threshold": float(round(max(0.75, sim_thr - 0.02), 4)),
        "service_min_human_confidence": float(round(max(0.50, human_thr + 0.05), 4)),
        "identity_metrics": metrics,
        "identity_confusion": conf,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Calibrate VeriCall thresholds from labeled manifest")
    parser.add_argument("--manifest", required=True, help="Labeled manifest CSV")
    parser.add_argument("--output", required=True, help="Output JSON path")
    parser.add_argument("--target-deepfake-far", type=float, default=0.01, help="Max deepfake FAR target")
    parser.add_argument("--target-identity-far", type=float, default=0.01, help="Max identity FAR target")
    args = parser.parse_args()

    manifest = Path(args.manifest).expanduser().resolve()
    output = Path(args.output).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    deepfake_rows, identity_rows = load_rows(manifest)
    if len(deepfake_rows) < 30:
        raise SystemExit(f"Not enough deepfake-labeled rows ({len(deepfake_rows)}). Need >= 30.")
    if len(identity_rows) < 30:
        raise SystemExit(f"Not enough identity-labeled rows ({len(identity_rows)}). Need >= 30.")

    deepfake = optimize_deepfake(deepfake_rows, target_far=args.target_deepfake_far)
    identity = optimize_identity(identity_rows, target_far=args.target_identity_far)

    tuning = {
        "l1_rms_min": 0.0035,
        "l1_mean_abs_min": 0.0024,
        "l1_clipped_ratio_max": 0.72,
        "l2_human_primary_threshold": deepfake["l2_human_primary_threshold"],
        "l2_human_secondary_threshold": deepfake["l2_human_secondary_threshold"],
        "l3_similarity_threshold": identity["l3_similarity_threshold"],
        "deepfake_human_score_threshold": deepfake["deepfake_human_score_threshold"],
        "deepfake_required_speech_activity_ratio": deepfake["deepfake_required_speech_activity_ratio"],
        "deepfake_required_continuous_speech_seconds": deepfake["deepfake_required_continuous_speech_seconds"],
        "identity_strict_similarity_threshold": identity["identity_strict_similarity_threshold"],
        "identity_min_human_confidence": identity["identity_min_human_confidence"],
        "identity_required_speech_activity_ratio": identity["identity_required_speech_activity_ratio"],
        "identity_required_continuous_speech_seconds": identity["identity_required_continuous_speech_seconds"],
        "identity_quality_bonus_similarity_delta": identity["identity_quality_bonus_similarity_delta"],
        "service_strict_similarity_threshold": identity["service_strict_similarity_threshold"],
        "service_min_human_confidence": identity["service_min_human_confidence"],
    }

    now = datetime.now(tz=timezone.utc)
    payload = {
        "version": now.strftime("%Y%m%d%H%M"),
        "ttl_seconds": 300,
        "generated_at_utc": now.isoformat(),
        "source_manifest": str(manifest),
        "counts": {
            "deepfake_rows": len(deepfake_rows),
            "identity_rows": len(identity_rows),
        },
        "metrics": {
            "deepfake": {
                "rates": deepfake["deepfake_metrics"],
                "confusion": deepfake["deepfake_confusion"],
            },
            "identity": {
                "rates": identity["identity_metrics"],
                "confusion": identity["identity_confusion"],
            },
        },
        "tuning": tuning,
    }

    output.write_text(json.dumps(payload, indent=2))
    print(f"Wrote tuning recommendation to {output}")
    print(f"Deepfake FAR={deepfake['deepfake_metrics']['far']:.4f} TPR={deepfake['deepfake_metrics']['tpr']:.4f}")
    print(f"Identity FAR={identity['identity_metrics']['far']:.4f} TPR={identity['identity_metrics']['tpr']:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
