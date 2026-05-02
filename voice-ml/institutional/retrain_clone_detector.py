#!/usr/bin/env python3
"""Retrain CloneDetector (Layer 2) from pipeline-shaped audio manifests."""

from __future__ import annotations

import argparse
import csv
import json
import math
from dataclasses import dataclass
from pathlib import Path
from typing import Dict, Iterable, List, Sequence, Tuple

import coremltools as ct
import numpy as np
import soundfile as sf
import xgboost as xgb
from scipy import signal


SR = 16_000
FRAME_LEN = 400
HOP = 160
EPS = 1e-8

FEATURE_NAMES: List[str] = [
    "pauses_per_second",
    "mean_pause_duration",
    "std_pause_duration",
    "max_pause_duration",
    "pause_ratio",
    "mean_amplitude",
    "std_amplitude",
    "amplitude_range",
    "amplitude_smoothness",
    "spectral_centroid_mean",
    "spectral_centroid_std",
    "spectral_bandwidth_mean",
    "spectral_bandwidth_std",
    "spectral_rolloff_mean",
    "spectral_rolloff_std",
    "spectral_contrast_0_mean",
    "spectral_contrast_1_mean",
    "spectral_contrast_2_mean",
    "spectral_contrast_3_mean",
    "spectral_contrast_4_mean",
    "spectral_contrast_5_mean",
    "spectral_contrast_6_mean",
    "spectral_flatness_mean",
    "spectral_flatness_std",
    "spectral_flatness_max",
    "subband_0_ratio",
    "subband_1_ratio",
    "subband_2_ratio",
    "subband_3_ratio",
    "mean_f0",
    "std_f0",
    "f0_range",
    "jitter",
    "shimmer",
    "syllables_per_second",
    "voiced_ratio",
    "hnr_mean",
    "hnr_std",
    "hnr_max",
    "energy_variance",
    "energy_kurtosis",
    "energy_autocorr_lag1",
    "modulation_3_5hz_ratio",
    "modulation_peak_freq",
]


@dataclass
class SampleRow:
    audio_path: Path
    split: str
    # label_spoof: 1=fake/spoof, 0=real human
    label_spoof: int


def load_manifest_rows(manifest_paths: Sequence[Path]) -> List[SampleRow]:
    rows: List[SampleRow] = []
    for manifest in manifest_paths:
        with manifest.open() as f:
            reader = csv.DictReader(f)
            for row in reader:
                audio = (row.get("audio_path") or row.get("chunk_wav") or "").strip()
                if not audio:
                    continue
                label = (row.get("label") or "").strip().lower()
                if label in {"fake", "spoof", "1"}:
                    y = 1
                elif label in {"real", "human", "0"}:
                    y = 0
                else:
                    continue
                split = (row.get("split") or "train").strip().lower()
                if split not in {"train", "val", "test"}:
                    split = "train"
                rows.append(
                    SampleRow(
                        audio_path=Path(audio).expanduser(),
                        split=split,
                        label_spoof=y,
                    )
                )
    return rows


def load_mono_16k(path: Path) -> np.ndarray | None:
    try:
        audio, sr = sf.read(path.as_posix(), dtype="float32", always_2d=False)
    except Exception:
        return None
    if isinstance(audio, np.ndarray) and audio.ndim == 2:
        audio = np.mean(audio, axis=1)
    if not isinstance(audio, np.ndarray) or audio.size == 0:
        return None
    if sr != SR:
        gcd = math.gcd(int(sr), SR)
        audio = signal.resample_poly(audio, up=SR // gcd, down=int(sr) // gcd).astype(np.float32)
    audio = np.nan_to_num(audio.astype(np.float32), nan=0.0, posinf=0.0, neginf=0.0)
    # Match iOS pre-processing.
    audio = audio - float(np.mean(audio))
    peak = float(np.max(np.abs(audio)))
    if peak > 1e-6:
        audio = audio * (0.95 / peak)
    return audio


def frame_signal(samples: np.ndarray) -> Tuple[np.ndarray, np.ndarray]:
    if samples.size < FRAME_LEN:
        pad = np.zeros(FRAME_LEN - samples.size, dtype=np.float32)
        samples = np.concatenate([samples, pad])
    n_frames = max(1, 1 + (samples.size - FRAME_LEN) // HOP)
    idx = np.arange(FRAME_LEN)[None, :] + (np.arange(n_frames)[:, None] * HOP)
    frames = samples[idx]
    rms = np.sqrt(np.mean(frames * frames, axis=1) + EPS)
    return frames, rms


def distribution_stats(x: np.ndarray) -> Tuple[float, float, float, float]:
    if x.size == 0:
        return 0.0, 0.0, 0.0, 0.0
    m = float(np.mean(x))
    s = float(np.std(x))
    if s < 1e-8:
        return m, 0.0, 0.0, 0.0
    z = (x - m) / s
    skew = float(np.mean(z**3))
    kurt = float(np.mean(z**4) - 3.0)
    return m, s, skew, kurt


def correlation_lag1(x: np.ndarray) -> float:
    if x.size < 3:
        return 0.0
    left = x[:-1]
    right = x[1:]
    lstd = float(np.std(left))
    rstd = float(np.std(right))
    if lstd < EPS or rstd < EPS:
        return 0.0
    cov = float(np.mean((left - np.mean(left)) * (right - np.mean(right))))
    return cov / max(EPS, lstd * rstd)


def estimate_f0_per_frame(frame: np.ndarray, fmin: float = 75.0, fmax: float = 500.0) -> Tuple[float, float]:
    # Returns (f0, confidence)
    if frame.size < FRAME_LEN:
        return 0.0, 0.0
    min_lag = max(1, int(SR / fmax))
    max_lag = min(frame.size - 2, int(SR / fmin))
    if max_lag <= min_lag:
        return 0.0, 0.0
    energy = float(np.sum(frame * frame))
    if energy < EPS:
        return 0.0, 0.0
    best_lag = min_lag
    best_val = -1.0
    for lag in range(min_lag, max_lag + 1):
        corr = float(np.sum(frame[:-lag] * frame[lag:]) / energy)
        if corr > best_val:
            best_val = corr
            best_lag = lag
    f0 = float(SR / best_lag) if best_val > 0 else 0.0
    return f0, max(0.0, best_val)


def estimate_hnr(frame: np.ndarray) -> float:
    if frame.size < 64:
        return 0.0
    ac = signal.correlate(frame, frame, mode="full")
    ac = ac[ac.size // 2 :]
    if ac.size < 8:
        return 0.0
    zero_lag = float(ac[0])
    if zero_lag < EPS:
        return 0.0
    peak = float(np.max(ac[1:]))
    if peak < EPS:
        return 0.0
    noise = max(EPS, zero_lag - peak)
    return float(10.0 * math.log10(max(EPS, peak / noise)))


def modulation_features(samples: np.ndarray) -> Tuple[float, float]:
    if samples.size == 0:
        return 0.0, 0.0
    envelope = np.abs(samples)
    dec = max(1, int(SR / 100))
    down = envelope[::dec]
    if down.size < 8:
        return 0.0, 0.0
    down = down - np.mean(down)
    n = 1 << int(np.ceil(np.log2(max(8, down.size))))
    fft = np.fft.rfft(np.pad(down, (0, n - down.size)))
    power = np.abs(fft) ** 2
    freqs = np.fft.rfftfreq(n, d=(dec / SR))
    total = float(np.sum(power[1:])) + EPS
    band = (freqs >= 3.0) & (freqs <= 5.0)
    ratio = float(np.sum(power[band]) / total)
    peak_idx = int(np.argmax(power[1:]) + 1)
    peak_freq = float(freqs[peak_idx]) if peak_idx < freqs.size else 0.0
    return ratio, peak_freq


def extract_features(samples: np.ndarray) -> Dict[str, float]:
    feats: Dict[str, float] = {}
    frames, rms = frame_signal(samples)
    total_duration = float(samples.size / SR)
    frame_duration = float(HOP / SR)

    # VAD from relative dB threshold (same idea as iOS)
    rms_db = 20.0 * np.log10(np.maximum(rms, EPS))
    peak_db = float(np.max(rms_db))
    vad = rms_db > (peak_db - 40.0)

    # Pause features
    pauses: List[float] = []
    in_pause = False
    pause_start = 0
    for i, is_speech in enumerate(vad):
        if (not is_speech) and (not in_pause):
            in_pause = True
            pause_start = i
        elif is_speech and in_pause:
            dur = (i - pause_start) * frame_duration
            if dur > 0.05:
                pauses.append(float(dur))
            in_pause = False
    if in_pause:
        dur = (vad.size - pause_start) * frame_duration
        if dur > 0.05:
            pauses.append(float(dur))
    speech_duration = float(np.sum(vad) * frame_duration)
    p = np.asarray(pauses, dtype=np.float32)
    p_mean, p_std, _, _ = distribution_stats(p)
    feats["pauses_per_second"] = float(len(pauses) / max(total_duration, EPS))
    feats["mean_pause_duration"] = p_mean
    feats["std_pause_duration"] = p_std
    feats["max_pause_duration"] = float(np.max(p) if p.size else 0.0)
    feats["pause_ratio"] = float(max(0.0, 1.0 - speech_duration / max(total_duration, EPS)))

    # Amplitude features
    speech_rms = rms[vad] if np.any(vad) else rms
    peak_rms = float(max(np.max(speech_rms), EPS))
    norm_rms = speech_rms / peak_rms
    a_mean, a_std, _, _ = distribution_stats(norm_rms)
    if norm_rms.size > 1:
        amp_d = np.diff(norm_rms)
        amp_smooth = float(np.std(amp_d))
    else:
        amp_smooth = 0.0
    feats["mean_amplitude"] = a_mean
    feats["std_amplitude"] = a_std
    feats["amplitude_range"] = float(np.max(norm_rms) - np.min(norm_rms))
    feats["amplitude_smoothness"] = amp_smooth

    # STFT-based spectral features
    f, t, Z = signal.stft(samples, fs=SR, nperseg=FRAME_LEN, noverlap=FRAME_LEN - HOP, nfft=512, boundary=None)
    mag = np.abs(Z) + EPS
    power = mag**2
    sum_mag = np.sum(mag, axis=0) + EPS
    centroid = np.sum((f[:, None] * mag), axis=0) / sum_mag
    bw = np.sqrt(np.sum(((f[:, None] - centroid[None, :]) ** 2) * mag, axis=0) / sum_mag)
    cumulative = np.cumsum(power, axis=0)
    rolloff_target = 0.85 * cumulative[-1, :]
    rolloff = np.zeros_like(rolloff_target)
    for i in range(cumulative.shape[1]):
        idx = np.searchsorted(cumulative[:, i], rolloff_target[i], side="left")
        idx = int(min(max(idx, 0), f.size - 1))
        rolloff[i] = f[idx]
    c_mean, c_std, _, _ = distribution_stats(centroid.astype(np.float32))
    b_mean, b_std, _, _ = distribution_stats(bw.astype(np.float32))
    r_mean, r_std, _, _ = distribution_stats(rolloff.astype(np.float32))
    feats["spectral_centroid_mean"] = c_mean
    feats["spectral_centroid_std"] = c_std
    feats["spectral_bandwidth_mean"] = b_mean
    feats["spectral_bandwidth_std"] = b_std
    feats["spectral_rolloff_mean"] = r_mean
    feats["spectral_rolloff_std"] = r_std

    # Spectral contrast bands (7)
    edges = np.geomspace(50, SR / 2, num=8)
    for b in range(7):
        lo, hi = edges[b], edges[b + 1]
        idx = (f >= lo) & (f <= hi)
        if not np.any(idx):
            feats[f"spectral_contrast_{b}_mean"] = 0.0
            continue
        band_mag = mag[idx, :]
        sorted_band = np.sort(band_mag, axis=0)
        q = max(1, sorted_band.shape[0] // 5)
        low = np.mean(sorted_band[:q, :], axis=0)
        high = np.mean(sorted_band[-q:, :], axis=0)
        contrast = 20.0 * np.log10((high + EPS) / (low + EPS))
        feats[f"spectral_contrast_{b}_mean"] = float(np.mean(contrast))

    flatness = np.exp(np.mean(np.log(power + EPS), axis=0)) / (np.mean(power, axis=0) + EPS)
    fl_mean, fl_std, _, _ = distribution_stats(flatness.astype(np.float32))
    feats["spectral_flatness_mean"] = fl_mean
    feats["spectral_flatness_std"] = fl_std
    feats["spectral_flatness_max"] = float(np.max(flatness))

    # Subband ratios (4)
    ny = f.size
    width = max(1, ny // 4)
    sub = np.zeros(4, dtype=np.float64)
    for b in range(4):
        st = b * width
        en = ny - 1 if b == 3 else min(ny - 1, ((b + 1) * width) - 1)
        if en >= st:
            sub[b] = float(np.sum(power[st : en + 1, :]))
    sub_total = float(np.sum(sub)) + EPS
    for b in range(4):
        feats[f"subband_{b}_ratio"] = float(sub[b] / sub_total)

    # Pitch/voicing
    f0_vals: List[float] = []
    voiced_rms: List[float] = []
    voiced_flags = np.zeros(frames.shape[0], dtype=bool)
    for i in range(frames.shape[0]):
        if rms[i] < 0.005:
            continue
        f0, conf = estimate_f0_per_frame(frames[i])
        if conf >= 0.30 and 75.0 <= f0 <= 500.0:
            voiced_flags[i] = True
            f0_vals.append(f0)
            voiced_rms.append(float(rms[i]))
    f0_arr = np.asarray(f0_vals, dtype=np.float32)
    f0_mean, f0_std, _, _ = distribution_stats(f0_arr)
    feats["mean_f0"] = f0_mean
    feats["std_f0"] = f0_std
    feats["f0_range"] = float(np.max(f0_arr) - np.min(f0_arr)) if f0_arr.size else 0.0
    if f0_arr.size > 1 and f0_mean > EPS:
        feats["jitter"] = float(np.mean(np.abs(np.diff(f0_arr))) / max(f0_mean, EPS))
    else:
        feats["jitter"] = 0.0
    vr = np.asarray(voiced_rms, dtype=np.float32)
    if vr.size > 1:
        feats["shimmer"] = float(np.mean(np.abs(np.diff(vr))) / max(float(np.mean(vr)), EPS))
    else:
        feats["shimmer"] = 0.0

    # Speaking rate proxy
    smooth = signal.convolve(rms, np.ones(5, dtype=np.float32) / 5.0, mode="same")
    thr = float(np.mean(smooth))
    peaks = signal.find_peaks(smooth, height=thr, distance=5)[0]
    feats["syllables_per_second"] = float(len(peaks) / max(total_duration, EPS))
    feats["voiced_ratio"] = float(np.sum(voiced_flags) / max(1, voiced_flags.size))

    # HNR
    hnr_vals = [estimate_hnr(frames[i]) for i in range(0, frames.shape[0], 2)]
    h = np.asarray(hnr_vals, dtype=np.float32)
    h_mean, h_std, _, _ = distribution_stats(h)
    feats["hnr_mean"] = h_mean
    feats["hnr_std"] = h_std
    feats["hnr_max"] = float(np.max(h)) if h.size else 0.0

    # Energy dynamics
    mean_rms = float(np.mean(rms))
    norm_energy = rms / max(mean_rms, EPS)
    e_mean, e_std, _, e_kurt = distribution_stats(norm_energy.astype(np.float32))
    feats["energy_variance"] = float(e_std * e_std)
    feats["energy_kurtosis"] = e_kurt
    feats["energy_autocorr_lag1"] = correlation_lag1(rms.astype(np.float32))

    # Modulation
    mod_ratio, mod_peak = modulation_features(samples)
    feats["modulation_3_5hz_ratio"] = mod_ratio
    feats["modulation_peak_freq"] = mod_peak

    # sanitize
    out: Dict[str, float] = {}
    for k in FEATURE_NAMES:
        v = float(feats.get(k, 0.0))
        if not np.isfinite(v):
            v = 0.0
        out[k] = v
    return out


def build_dataset(rows: Sequence[SampleRow], max_rows: int, seed: int) -> Tuple[np.ndarray, np.ndarray, np.ndarray]:
    rng = np.random.default_rng(seed)
    rows = list(rows)
    if max_rows > 0 and len(rows) > max_rows:
        idx = rng.choice(len(rows), size=max_rows, replace=False)
        rows = [rows[int(i)] for i in idx]

    x: List[List[float]] = []
    y: List[int] = []
    split_ids: List[int] = []
    split_map = {"train": 0, "val": 1, "test": 2}
    bad = 0
    for row in rows:
        audio = load_mono_16k(row.audio_path)
        if audio is None or audio.size < 100:
            bad += 1
            continue
        feats = extract_features(audio)
        x.append([feats[name] for name in FEATURE_NAMES])
        y.append(int(row.label_spoof))
        split_ids.append(split_map[row.split])
    if not x:
        raise SystemExit("No valid training samples after feature extraction")
    if bad > 0:
        print(f"Skipped {bad} unreadable samples")
    return np.asarray(x, dtype=np.float32), np.asarray(y, dtype=np.int32), np.asarray(split_ids, dtype=np.int32)


def sigmoid(x: np.ndarray) -> np.ndarray:
    return 1.0 / (1.0 + np.exp(-x))


def confusion(labels: np.ndarray, preds: np.ndarray) -> Dict[str, int]:
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
    return {"tpr": tpr, "tnr": tnr, "far": far, "frr": frr, "acc": acc}


def select_threshold(labels: np.ndarray, spoof_probs: np.ndarray, target_far: float) -> float:
    # Decision: spoof if spoof_prob >= threshold
    best_thr = 0.5
    best_tpr = -1.0
    for thr in np.linspace(0.05, 0.95, 181):
        preds = (spoof_probs >= thr).astype(np.int32)
        c = confusion(labels, preds)
        m = rates(c)
        # For spoof detector, FAR means real misclassified as spoof? Here we want low false alarms on real.
        # Use false-positive rate on real class as "human false alarm", i.e., fp/(fp+tn).
        human_false_alarm = m["far"]
        if human_false_alarm <= target_far and m["tpr"] > best_tpr:
            best_tpr = m["tpr"]
            best_thr = float(thr)
    return best_thr


def metrics_at_threshold(labels: np.ndarray, probs: np.ndarray, thr: float) -> Dict[str, Dict[str, float]]:
    preds = (probs >= thr).astype(np.int32)
    c = confusion(labels, preds)
    m = rates(c)
    return {"confusion": c, "rates": m}


def main() -> int:
    parser = argparse.ArgumentParser(description="Retrain CloneDetector.mlmodel from pipeline-shaped corpus")
    parser.add_argument("--manifest", action="append", required=True, help="Manifest CSV path (can pass multiple)")
    parser.add_argument("--output-mlmodel", required=True, help="Output .mlmodel path")
    parser.add_argument("--output-report", required=True, help="Output training report JSON")
    parser.add_argument("--max-rows", type=int, default=60_000, help="Max rows for feature extraction/training")
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--target-human-far", type=float, default=0.02, help="Target false alarm rate on real speech")
    args = parser.parse_args()

    manifests = [Path(p).expanduser().resolve() for p in args.manifest]
    for p in manifests:
        if not p.exists():
            raise SystemExit(f"Manifest not found: {p}")

    rows = load_manifest_rows(manifests)
    if not rows:
        raise SystemExit("No usable rows found in manifests")
    print(f"Loaded manifest rows: {len(rows)}")

    x, y, split_ids = build_dataset(rows, max_rows=args.max_rows, seed=args.seed)
    print(f"Feature matrix: {x.shape}")

    train_mask = split_ids == 0
    val_mask = split_ids == 1
    test_mask = split_ids == 2
    if np.sum(train_mask) < 1000:
        raise SystemExit("Too few training rows after extraction")
    if np.sum(val_mask) < 100:
        # fallback: split from train
        rng = np.random.default_rng(args.seed)
        idx = np.where(train_mask)[0]
        pick = rng.choice(idx, size=max(100, int(0.1 * idx.size)), replace=False)
        val_mask = np.zeros_like(train_mask)
        val_mask[pick] = True
        train_mask[pick] = False
    if np.sum(test_mask) < 100:
        test_mask = val_mask.copy()

    dtrain = xgb.DMatrix(x[train_mask], label=y[train_mask], feature_names=FEATURE_NAMES)
    dval = xgb.DMatrix(x[val_mask], label=y[val_mask], feature_names=FEATURE_NAMES)
    dtest = xgb.DMatrix(x[test_mask], label=y[test_mask], feature_names=FEATURE_NAMES)

    params = {
        "objective": "binary:logitraw",
        "eval_metric": ["logloss", "auc"],
        "max_depth": 6,
        "eta": 0.05,
        "subsample": 0.85,
        "colsample_bytree": 0.85,
        "min_child_weight": 4.0,
        "lambda": 2.0,
        "alpha": 0.0,
        "seed": args.seed,
    }

    booster = xgb.train(
        params=params,
        dtrain=dtrain,
        num_boost_round=800,
        evals=[(dtrain, "train"), (dval, "val")],
        early_stopping_rounds=30,
        verbose_eval=50,
    )

    val_margin = booster.predict(dval, output_margin=True)
    val_prob = sigmoid(val_margin)
    chosen_thr = select_threshold(y[val_mask], val_prob, target_far=args.target_human_far)

    train_prob = sigmoid(booster.predict(dtrain, output_margin=True))
    test_prob = sigmoid(booster.predict(dtest, output_margin=True))

    train_metrics = metrics_at_threshold(y[train_mask], train_prob, chosen_thr)
    val_metrics = metrics_at_threshold(y[val_mask], val_prob, chosen_thr)
    test_metrics = metrics_at_threshold(y[test_mask], test_prob, chosen_thr)

    output_mlmodel = Path(args.output_mlmodel).expanduser().resolve()
    output_mlmodel.parent.mkdir(parents=True, exist_ok=True)
    mlmodel = ct.converters.xgboost.convert(
        booster,
        feature_names=FEATURE_NAMES,
        target="target",
    )
    mlmodel.save(output_mlmodel.as_posix())
    print(f"Saved CoreML model: {output_mlmodel}")

    report = {
        "manifests": [p.as_posix() for p in manifests],
        "rows_loaded": len(rows),
        "rows_used": int(x.shape[0]),
        "feature_names": FEATURE_NAMES,
        "x_shape": list(x.shape),
        "split_counts": {
            "train": int(np.sum(train_mask)),
            "val": int(np.sum(val_mask)),
            "test": int(np.sum(test_mask)),
        },
        "xgboost_params": params,
        "best_iteration": int(getattr(booster, "best_iteration", -1)),
        "chosen_spoof_threshold": float(chosen_thr),
        "target_human_far": float(args.target_human_far),
        "metrics": {
            "train": train_metrics,
            "val": val_metrics,
            "test": test_metrics,
        },
        "notes": {
            "label_definition": "spoof=1 (fake/clone), human=0 (real)",
            "ios_interpretation": "LocalVoiceVerifier computes spoofProbability=sigmoid(target), human=1-spoof",
        },
    }

    output_report = Path(args.output_report).expanduser().resolve()
    output_report.parent.mkdir(parents=True, exist_ok=True)
    output_report.write_text(json.dumps(report, indent=2))
    print(f"Saved report: {output_report}")

    # Convenience threshold suggestion for runtime tuning.
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
