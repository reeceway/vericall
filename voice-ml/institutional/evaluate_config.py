#!/usr/bin/env python3
"""Evaluate a verification tuning config against a labeled manifest."""

from __future__ import annotations

import argparse
import csv
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple


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


@dataclass
class DeepfakeEvalRow:
    call_id: str
    remote_voiceprint_tag: str
    label_human: int
    l1_pass: int
    l2_human_confidence: float


@dataclass
class IdentityEvalRow:
    call_id: str
    remote_voiceprint_tag: str
    label_identity_match: int
    l1_pass: int
    l2_human_confidence: float
    l3_similarity_smoothed: float
    speech_activity_ratio: float
    speech_continuous_seconds: float


def confusion_binary(labels: List[int], preds: List[int]) -> Dict[str, int]:
    tp = tn = fp = fn = 0
    for label, pred in zip(labels, preds):
        if label == 1 and pred == 1:
            tp += 1
        elif label == 0 and pred == 0:
            tn += 1
        elif label == 0 and pred == 1:
            fp += 1
        elif label == 1 and pred == 0:
            fn += 1
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


def default_tuning() -> Dict[str, float]:
    return {
        "l1_rms_min": 0.0035,
        "l1_mean_abs_min": 0.0024,
        "l1_clipped_ratio_max": 0.72,
        "l2_human_primary_threshold": 0.36,
        "l2_human_secondary_threshold": 0.48,
        "l3_similarity_threshold": 0.90,
        "deepfake_human_score_threshold": 0.36,
        "deepfake_required_speech_activity_ratio": 0.18,
        "deepfake_required_continuous_speech_seconds": 0.40,
        "identity_strict_similarity_threshold": 0.92,
        "identity_min_human_confidence": 0.42,
        "identity_required_speech_activity_ratio": 0.18,
        "identity_required_continuous_speech_seconds": 0.40,
        "identity_quality_bonus_similarity_delta": 0.01,
        "service_strict_similarity_threshold": 0.90,
        "service_min_human_confidence": 0.62,
    }


def load_tuning(config_path: Path) -> Tuple[Dict[str, float], str, int]:
    defaults = default_tuning()
    payload = json.loads(config_path.read_text())
    if not isinstance(payload, dict):
        raise SystemExit("Config JSON must be an object")

    source = payload
    if isinstance(payload.get("tuning"), dict):
        source = payload["tuning"]

    merged = dict(defaults)
    for key, value in source.items():
        if key not in merged:
            continue
        if isinstance(value, (int, float)):
            merged[key] = float(value)

    version = str(payload.get("version", "adhoc")).strip() or "adhoc"
    ttl = parse_optional_int(payload.get("ttl_seconds"))
    if ttl is None:
        ttl = 300
    return merged, version, ttl


def load_eval_rows(manifest_csv: Path) -> Tuple[List[DeepfakeEvalRow], List[IdentityEvalRow]]:
    deepfake_rows: List[DeepfakeEvalRow] = []
    identity_rows: List[IdentityEvalRow] = []

    with manifest_csv.open() as f:
        reader = csv.DictReader(f)
        for row in reader:
            call_id = (row.get("call_id") or "").strip() or "unknown"
            tag = (row.get("remote_voiceprint_tag") or "").strip() or "unknown"
            l2 = parse_optional_float(row.get("l2_human_confidence"))
            l1 = parse_optional_int(row.get("debug_l1_pass"))
            if l1 is None:
                l1 = parse_optional_int(row.get("model_human_pass"))

            label_human = parse_optional_int(row.get("label_human"))
            if label_human in (0, 1) and l2 is not None and l1 is not None:
                deepfake_rows.append(
                    DeepfakeEvalRow(
                        call_id=call_id,
                        remote_voiceprint_tag=tag,
                        label_human=label_human,
                        l1_pass=1 if l1 == 1 else 0,
                        l2_human_confidence=l2,
                    )
                )

            label_identity = parse_optional_int(row.get("label_identity_match"))
            l3 = parse_optional_float(row.get("l3_similarity_smoothed"))
            speech_ratio = parse_optional_float(row.get("speech_activity_ratio"))
            speech_cont = parse_optional_float(row.get("speech_continuous_seconds"))
            if (
                label_identity in (0, 1)
                and l1 is not None
                and l2 is not None
                and l3 is not None
                and speech_ratio is not None
                and speech_cont is not None
            ):
                identity_rows.append(
                    IdentityEvalRow(
                        call_id=call_id,
                        remote_voiceprint_tag=tag,
                        label_identity_match=label_identity,
                        l1_pass=1 if l1 == 1 else 0,
                        l2_human_confidence=l2,
                        l3_similarity_smoothed=l3,
                        speech_activity_ratio=speech_ratio,
                        speech_continuous_seconds=speech_cont,
                    )
                )

    return deepfake_rows, identity_rows


def deepfake_pred(row: DeepfakeEvalRow, tuning: Dict[str, float]) -> int:
    primary = tuning["l2_human_primary_threshold"]
    secondary = tuning["l2_human_secondary_threshold"]
    passed = (
        row.l2_human_confidence >= primary
        and (row.l1_pass == 1 or row.l2_human_confidence >= secondary)
    )
    return 1 if passed else 0


def identity_pred(row: IdentityEvalRow, tuning: Dict[str, float]) -> int:
    # Keep decision logic aligned with VoIPCallService tick path.
    deepfake_ok = deepfake_pred(
        DeepfakeEvalRow(
            call_id=row.call_id,
            remote_voiceprint_tag=row.remote_voiceprint_tag,
            label_human=1,
            l1_pass=row.l1_pass,
            l2_human_confidence=row.l2_human_confidence,
        ),
        tuning,
    )
    if deepfake_ok == 0:
        return 0

    if row.l2_human_confidence < tuning["identity_min_human_confidence"]:
        return 0
    if row.speech_activity_ratio < tuning["identity_required_speech_activity_ratio"]:
        return 0
    if row.speech_continuous_seconds < tuning["identity_required_continuous_speech_seconds"]:
        return 0

    adaptive_similarity_threshold = tuning["identity_strict_similarity_threshold"]
    if row.l2_human_confidence >= 0.75 and row.speech_continuous_seconds >= 1.0:
        adaptive_similarity_threshold -= tuning["identity_quality_bonus_similarity_delta"]

    return 1 if row.l3_similarity_smoothed >= adaptive_similarity_threshold else 0


def service_identity_pred(row: IdentityEvalRow, tuning: Dict[str, float]) -> int:
    return 1 if (
        row.l2_human_confidence >= tuning["service_min_human_confidence"]
        and row.l3_similarity_smoothed >= tuning["service_strict_similarity_threshold"]
    ) else 0


def top_error_groups(
    rows: List[Any],
    labels: List[int],
    preds: List[int],
    group_attr: str,
    top_n: int,
) -> List[Dict[str, Any]]:
    grouped: Dict[str, Dict[str, int]] = {}
    for row, label, pred in zip(rows, labels, preds):
        group = str(getattr(row, group_attr, "")) or "unknown"
        stats = grouped.setdefault(
            group,
            {"rows": 0, "errors": 0, "false_accepts": 0, "false_rejects": 0},
        )
        stats["rows"] += 1
        if pred != label:
            stats["errors"] += 1
            if label == 0 and pred == 1:
                stats["false_accepts"] += 1
            elif label == 1 and pred == 0:
                stats["false_rejects"] += 1

    ranked = sorted(
        grouped.items(),
        key=lambda kv: (kv[1]["errors"], kv[1]["rows"]),
        reverse=True,
    )
    return [{"group": key, **stats} for key, stats in ranked[:top_n] if stats["errors"] > 0]


def evaluate(
    deepfake_rows: List[DeepfakeEvalRow],
    identity_rows: List[IdentityEvalRow],
    tuning: Dict[str, float],
    top_n: int,
) -> Dict[str, Any]:
    result: Dict[str, Any] = {"counts": {}, "metrics": {}, "top_errors": {}}

    if deepfake_rows:
        deepfake_labels = [r.label_human for r in deepfake_rows]
        deepfake_preds = [deepfake_pred(r, tuning) for r in deepfake_rows]
        deepfake_conf = confusion_binary(deepfake_labels, deepfake_preds)
        result["counts"]["deepfake_rows"] = len(deepfake_rows)
        result["metrics"]["deepfake"] = {
            "confusion": deepfake_conf,
            "rates": rates(deepfake_conf),
        }
        result["top_errors"]["deepfake_by_call_id"] = top_error_groups(
            deepfake_rows,
            deepfake_labels,
            deepfake_preds,
            group_attr="call_id",
            top_n=top_n,
        )
    else:
        result["counts"]["deepfake_rows"] = 0

    if identity_rows:
        identity_labels = [r.label_identity_match for r in identity_rows]
        identity_preds = [identity_pred(r, tuning) for r in identity_rows]
        identity_conf = confusion_binary(identity_labels, identity_preds)
        result["counts"]["identity_rows"] = len(identity_rows)
        result["metrics"]["identity_call_path"] = {
            "confusion": identity_conf,
            "rates": rates(identity_conf),
        }
        result["top_errors"]["identity_by_call_id"] = top_error_groups(
            identity_rows,
            identity_labels,
            identity_preds,
            group_attr="call_id",
            top_n=top_n,
        )

        service_preds = [service_identity_pred(r, tuning) for r in identity_rows]
        service_conf = confusion_binary(identity_labels, service_preds)
        result["metrics"]["identity_service_path"] = {
            "confusion": service_conf,
            "rates": rates(service_conf),
        }
    else:
        result["counts"]["identity_rows"] = 0

    return result


def main() -> int:
    parser = argparse.ArgumentParser(description="Evaluate tuning config against labeled manifest")
    parser.add_argument("--manifest", required=True, help="Labeled manifest CSV path")
    parser.add_argument("--config", required=True, help="Tuning JSON path (payload or tuning object)")
    parser.add_argument("--output", help="Optional output JSON path")
    parser.add_argument("--top-groups", type=int, default=10, help="How many top error groups to include")
    args = parser.parse_args()

    manifest = Path(args.manifest).expanduser().resolve()
    config_path = Path(args.config).expanduser().resolve()
    if not manifest.exists():
        raise SystemExit(f"Manifest not found: {manifest}")
    if not config_path.exists():
        raise SystemExit(f"Config not found: {config_path}")

    tuning, version, ttl = load_tuning(config_path)
    deepfake_rows, identity_rows = load_eval_rows(manifest)
    report = evaluate(deepfake_rows, identity_rows, tuning, top_n=max(1, args.top_groups))
    report["config"] = {
        "version": version,
        "ttl_seconds": ttl,
        "source_path": str(config_path),
    }
    report["manifest"] = str(manifest)
    report["tuning"] = tuning

    if args.output:
        output = Path(args.output).expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(json.dumps(report, indent=2))
        print(f"Wrote evaluation report to {output}")

    deepfake_metrics = report["metrics"].get("deepfake", {}).get("rates")
    if deepfake_metrics:
        print(
            "Deepfake rows={rows} FAR={far:.4f} FRR={frr:.4f} TPR={tpr:.4f}".format(
                rows=report["counts"]["deepfake_rows"],
                far=deepfake_metrics["far"],
                frr=deepfake_metrics["frr"],
                tpr=deepfake_metrics["tpr"],
            )
        )
    else:
        print("Deepfake rows=0 (no labels found)")

    identity_metrics = report["metrics"].get("identity_call_path", {}).get("rates")
    if identity_metrics:
        print(
            "Identity(call) rows={rows} FAR={far:.4f} FRR={frr:.4f} TPR={tpr:.4f}".format(
                rows=report["counts"]["identity_rows"],
                far=identity_metrics["far"],
                frr=identity_metrics["frr"],
                tpr=identity_metrics["tpr"],
            )
        )
    else:
        print("Identity rows=0 (no labels found)")

    service_metrics = report["metrics"].get("identity_service_path", {}).get("rates")
    if service_metrics:
        print(
            "Identity(service) FAR={far:.4f} FRR={frr:.4f} TPR={tpr:.4f}".format(
                far=service_metrics["far"],
                frr=service_metrics["frr"],
                tpr=service_metrics["tpr"],
            )
        )

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
