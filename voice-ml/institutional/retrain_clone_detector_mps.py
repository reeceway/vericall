#!/usr/bin/env python3
"""Retrain CloneDetector on Apple GPU (MPS) and export to CoreML."""

from __future__ import annotations

import argparse
import json
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, List, Tuple

import coremltools as ct
import numpy as np
import torch
import torch.nn as nn
from sklearn.metrics import roc_auc_score

from retrain_clone_detector import (
    FEATURE_NAMES,
    build_dataset,
    load_manifest_rows,
    metrics_at_threshold,
    select_threshold,
)


@dataclass
class SplitSet:
    x: np.ndarray
    y: np.ndarray


class CloneMLP(nn.Module):
    def __init__(self, in_dim: int, mean: np.ndarray, std: np.ndarray):
        super().__init__()
        self.register_buffer("feat_mean", torch.tensor(mean, dtype=torch.float32))
        self.register_buffer("feat_std", torch.tensor(std, dtype=torch.float32))
        self.net = nn.Sequential(
            nn.Linear(in_dim, 128),
            nn.ReLU(),
            nn.Dropout(0.20),
            nn.Linear(128, 64),
            nn.ReLU(),
            nn.Dropout(0.20),
            nn.Linear(64, 1),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        if x.dim() == 1:
            x = x.unsqueeze(0)
        x = (x - self.feat_mean) / self.feat_std
        out = self.net(x).squeeze(-1)
        return out


def choose_device(require_mps: bool) -> torch.device:
    if torch.backends.mps.is_available():
        return torch.device("mps")
    if require_mps:
        raise SystemExit("MPS is not available. Re-run in host context with GPU access.")
    return torch.device("cpu")


def split_data(x: np.ndarray, y: np.ndarray, split_ids: np.ndarray, seed: int) -> Tuple[SplitSet, SplitSet, SplitSet]:
    train_mask = split_ids == 0
    val_mask = split_ids == 1
    test_mask = split_ids == 2

    if int(np.sum(train_mask)) < 200:
        raise SystemExit("Too few train rows")

    if int(np.sum(val_mask)) < 50:
        rng = np.random.default_rng(seed)
        idx = np.where(train_mask)[0]
        pick = rng.choice(idx, size=max(50, int(0.1 * idx.size)), replace=False)
        val_mask = np.zeros_like(train_mask)
        val_mask[pick] = True
        train_mask[pick] = False

    if int(np.sum(test_mask)) < 50:
        test_mask = val_mask.copy()

    train = SplitSet(x=x[train_mask], y=y[train_mask])
    val = SplitSet(x=x[val_mask], y=y[val_mask])
    test = SplitSet(x=x[test_mask], y=y[test_mask])
    return train, val, test


def make_loader(split: SplitSet, batch_size: int, shuffle: bool) -> torch.utils.data.DataLoader:
    tx = torch.from_numpy(split.x).float()
    ty = torch.from_numpy(split.y).float()
    ds = torch.utils.data.TensorDataset(tx, ty)
    return torch.utils.data.DataLoader(ds, batch_size=batch_size, shuffle=shuffle)


def run_eval(model: nn.Module, split: SplitSet, device: torch.device, batch_size: int = 512) -> Tuple[np.ndarray, float]:
    model.eval()
    probs: List[np.ndarray] = []
    losses: List[float] = []
    criterion = nn.BCEWithLogitsLoss()
    loader = make_loader(split, batch_size=batch_size, shuffle=False)
    with torch.no_grad():
        for xb, yb in loader:
            xb = xb.to(device)
            yb = yb.to(device)
            logits = model(xb)
            loss = criterion(logits, yb)
            losses.append(float(loss.item()))
            p = torch.sigmoid(logits).detach().cpu().numpy()
            probs.append(p)
    all_probs = np.concatenate(probs, axis=0) if probs else np.empty((0,), dtype=np.float32)
    avg_loss = float(np.mean(losses)) if losses else 0.0
    return all_probs, avg_loss


def main() -> int:
    parser = argparse.ArgumentParser(description="GPU retrain CloneDetector on MPS and export CoreML")
    parser.add_argument("--manifest", action="append", required=True, help="Manifest CSV path (repeatable)")
    parser.add_argument("--output-mlmodel", required=True, help="Output CoreML path")
    parser.add_argument("--output-report", required=True, help="Output JSON report path")
    parser.add_argument("--max-rows", type=int, default=12_000)
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--batch-size", type=int, default=256)
    parser.add_argument("--lr", type=float, default=2e-3)
    parser.add_argument("--patience", type=int, default=7)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--target-human-far", type=float, default=0.02)
    parser.add_argument("--allow-cpu", action="store_true")
    args = parser.parse_args()

    torch.manual_seed(args.seed)
    np.random.seed(args.seed)

    manifests = [Path(p).expanduser().resolve() for p in args.manifest]
    for p in manifests:
        if not p.exists():
            raise SystemExit(f"Manifest not found: {p}")

    rows = load_manifest_rows(manifests)
    if not rows:
        raise SystemExit("No usable rows in manifests")
    print(f"Loaded rows: {len(rows)}")

    x, y, split_ids = build_dataset(rows, max_rows=args.max_rows, seed=args.seed)
    print(f"Feature matrix: {x.shape}")

    train, val, test = split_data(x, y, split_ids, seed=args.seed)
    print(f"Split counts train={len(train.y)} val={len(val.y)} test={len(test.y)}")

    mean = np.mean(train.x, axis=0).astype(np.float32)
    std = np.std(train.x, axis=0).astype(np.float32)
    std = np.where(std < 1e-5, 1.0, std).astype(np.float32)

    device = choose_device(require_mps=not args.allow_cpu)
    print(f"Training device: {device}")

    model = CloneMLP(in_dim=train.x.shape[1], mean=mean, std=std).to(device)
    pos = max(1.0, float(np.sum(train.y == 1)))
    neg = max(1.0, float(np.sum(train.y == 0)))
    pos_weight = torch.tensor([neg / pos], dtype=torch.float32, device=device)
    criterion = nn.BCEWithLogitsLoss(pos_weight=pos_weight)
    optimizer = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)

    train_loader = make_loader(train, batch_size=args.batch_size, shuffle=True)
    best_state = None
    best_val_auc = -1.0
    best_epoch = -1
    stale = 0
    history: List[Dict[str, float]] = []

    for epoch in range(args.epochs):
        model.train()
        losses: List[float] = []
        for xb, yb in train_loader:
            xb = xb.to(device)
            yb = yb.to(device)
            optimizer.zero_grad(set_to_none=True)
            logits = model(xb)
            loss = criterion(logits, yb)
            loss.backward()
            optimizer.step()
            losses.append(float(loss.item()))

        train_probs, train_eval_loss = run_eval(model, train, device=device)
        val_probs, val_eval_loss = run_eval(model, val, device=device)
        train_auc = float(roc_auc_score(train.y, train_probs)) if len(np.unique(train.y)) > 1 else 0.5
        val_auc = float(roc_auc_score(val.y, val_probs)) if len(np.unique(val.y)) > 1 else 0.5
        row = {
            "epoch": float(epoch),
            "train_loss_batch_avg": float(np.mean(losses) if losses else 0.0),
            "train_loss_eval": train_eval_loss,
            "val_loss_eval": val_eval_loss,
            "train_auc": train_auc,
            "val_auc": val_auc,
        }
        history.append(row)
        print(
            f"[epoch {epoch:02d}] "
            f"train_auc={train_auc:.4f} val_auc={val_auc:.4f} "
            f"train_loss={train_eval_loss:.4f} val_loss={val_eval_loss:.4f}"
        )

        if val_auc > best_val_auc:
            best_val_auc = val_auc
            best_epoch = epoch
            best_state = {k: v.detach().cpu().clone() for k, v in model.state_dict().items()}
            stale = 0
        else:
            stale += 1
            if stale >= args.patience:
                print(f"Early stopping at epoch {epoch}")
                break

    if best_state is None:
        raise SystemExit("Training failed to produce a best checkpoint")

    model.load_state_dict(best_state)
    model = model.to(device)

    train_probs, _ = run_eval(model, train, device=device)
    val_probs, _ = run_eval(model, val, device=device)
    test_probs, _ = run_eval(model, test, device=device)

    chosen_thr = select_threshold(val.y.astype(np.int32), val_probs.astype(np.float64), target_far=args.target_human_far)
    train_metrics = metrics_at_threshold(train.y.astype(np.int32), train_probs.astype(np.float64), chosen_thr)
    val_metrics = metrics_at_threshold(val.y.astype(np.int32), val_probs.astype(np.float64), chosen_thr)
    test_metrics = metrics_at_threshold(test.y.astype(np.int32), test_probs.astype(np.float64), chosen_thr)

    # Export to CoreML (keep .mlmodel for current Xcode project wiring).
    model_cpu = model.to("cpu").eval()
    example = torch.randn(1, train.x.shape[1], dtype=torch.float32)
    traced = torch.jit.trace(model_cpu, example)

    output_mlmodel = Path(args.output_mlmodel).expanduser().resolve()
    output_mlmodel.parent.mkdir(parents=True, exist_ok=True)
    mlmodel = ct.convert(
        traced,
        convert_to="neuralnetwork",
        inputs=[ct.TensorType(name="input_features", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="target", dtype=np.float32)],
    )
    mlmodel.user_defined_metadata["feature_order"] = json.dumps(FEATURE_NAMES)
    mlmodel.user_defined_metadata["input_name"] = "input_features"
    mlmodel.user_defined_metadata["input_shape"] = f"1x{train.x.shape[1]}"
    mlmodel.user_defined_metadata["training_device"] = str(device)
    mlmodel.user_defined_metadata["notes"] = "target is spoof logit; human_prob = 1 - sigmoid(target)"
    mlmodel.save(output_mlmodel.as_posix())
    print(f"Saved CoreML model: {output_mlmodel}")

    report = {
        "manifests": [p.as_posix() for p in manifests],
        "rows_loaded": len(rows),
        "rows_used": int(x.shape[0]),
        "feature_names": FEATURE_NAMES,
        "x_shape": list(x.shape),
        "split_counts": {
            "train": int(len(train.y)),
            "val": int(len(val.y)),
            "test": int(len(test.y)),
        },
        "training": {
            "device": str(device),
            "epochs_requested": args.epochs,
            "batch_size": args.batch_size,
            "lr": args.lr,
            "patience": args.patience,
            "best_epoch": best_epoch,
            "best_val_auc": best_val_auc,
            "history": history,
        },
        "chosen_spoof_threshold": float(chosen_thr),
        "target_human_far": float(args.target_human_far),
        "metrics": {
            "train": train_metrics,
            "val": val_metrics,
            "test": test_metrics,
        },
    }
    output_report = Path(args.output_report).expanduser().resolve()
    output_report.parent.mkdir(parents=True, exist_ok=True)
    output_report.write_text(json.dumps(report, indent=2))
    print(f"Saved report: {output_report}")

    human_accept_threshold = max(0.05, min(0.95, 1.0 - chosen_thr))
    suggested = {
        "l2_human_primary_threshold": round(float(human_accept_threshold), 4),
        "l2_human_secondary_threshold": round(float(min(0.95, human_accept_threshold + 0.08)), 4),
        "deepfake_human_score_threshold": round(float(human_accept_threshold), 4),
    }
    print(f"Suggested L2 thresholds: {json.dumps(suggested)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
