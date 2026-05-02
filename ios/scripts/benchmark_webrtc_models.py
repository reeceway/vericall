#!/usr/bin/env python3
from __future__ import annotations

import argparse
import csv
import math
from collections import defaultdict
from pathlib import Path

import coremltools as ct
import numpy as np
import soundfile as sf

np.seterr(all="ignore")


ANALYSIS_WINDOW_SAMPLES = 48_000
SPEAKER_THRESHOLD = 0.90
SPOOF_THRESHOLD = 0.665
TARGET_SPOOF_RMS = 0.03
MAX_SPOOF_GAIN = 10.0


def read_csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="") as fh:
        return list(csv.DictReader(fh))


def load_wav_16k_mono(path: str, target_samples: int = ANALYSIS_WINDOW_SAMPLES) -> np.ndarray:
    samples, sr = sf.read(path, dtype="float32", always_2d=False)
    if samples.ndim > 1:
        samples = samples.mean(axis=1)
    samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    samples = np.clip(samples, -1.0, 1.0)
    if sr != 16_000:
        raise RuntimeError(f"Unexpected sample rate {sr} for {path}")
    if samples.shape[0] > target_samples:
        samples = samples[-target_samples:]
    elif samples.shape[0] < target_samples:
        samples = np.pad(samples, (0, target_samples - samples.shape[0]))
    return samples.astype(np.float32)


def build_mel_filterbank(num_filters: int = 80, fft_size: int = 400, sample_rate: float = 16_000.0) -> np.ndarray:
    half = fft_size // 2 + 1

    def hz_to_mel(hz: float) -> float:
        return 2595.0 * math.log10(1.0 + hz / 700.0)

    def mel_to_hz(mel: float) -> float:
        return 700.0 * (10.0 ** (mel / 2595.0) - 1.0)

    mel_min = hz_to_mel(0.0)
    mel_max = hz_to_mel(sample_rate / 2.0)
    mel_points = [
        mel_to_hz(mel_min + i * (mel_max - mel_min) / (num_filters + 1))
        for i in range(num_filters + 2)
    ]
    bins = [int((hz / sample_rate) * fft_size + 0.5) for hz in mel_points]

    fb = np.zeros((num_filters, half), dtype=np.float32)
    for m in range(num_filters):
        left, center, right = bins[m], bins[m + 1], bins[m + 2]
        if center > left:
            for k in range(left, min(center, half)):
                fb[m, k] = (k - left) / (center - left)
        if right > center:
            for k in range(center, min(right, half)):
                fb[m, k] = (right - k) / (right - center)
    return fb


MEL_FILTERS = build_mel_filterbank()
HAMMING = np.hamming(400).astype(np.float32)


def compute_fbank(samples: np.ndarray) -> np.ndarray:
    x = samples.astype(np.float32)
    x = np.nan_to_num(x, nan=0.0, posinf=0.0, neginf=0.0)
    x = np.clip(x, -1.0, 1.0)
    emphasized = np.empty_like(x)
    emphasized[0] = x[0]
    emphasized[1:] = x[1:] - 0.97 * x[:-1]

    frames: list[np.ndarray] = []
    for frame_idx in range(300):
        start = frame_idx * 160
        chunk = emphasized[start : start + 400]
        if chunk.shape[0] < 400:
            chunk = np.pad(chunk, (0, 400 - chunk.shape[0]))
        spec = np.fft.rfft(chunk * HAMMING)
        power = (np.real(spec) ** 2 + np.imag(spec) ** 2).astype(np.float32)
        power = np.nan_to_num(power, nan=0.0, posinf=1e10, neginf=0.0)
        energy = MEL_FILTERS @ power
        energy = np.maximum(energy, 1e-10)
        frames.append(np.log(energy))

    fbank = np.stack(frames, axis=0).astype(np.float32)
    mean = float(np.mean(fbank))
    return fbank - mean


class SpeakerBench:
    def __init__(self, model_path: Path):
        self.model = ct.models.MLModel(str(model_path), compute_units=ct.ComputeUnit.CPU_ONLY)

    def embed(self, samples: np.ndarray) -> np.ndarray:
        fbank = compute_fbank(samples)
        out = self.model.predict({"fbank_features": fbank[np.newaxis, :, :]})
        emb = np.array(out["embedding"], dtype=np.float32).reshape(-1)
        return emb

    @staticmethod
    def cosine(a: np.ndarray, b: np.ndarray) -> float:
        denom = float(np.linalg.norm(a) * np.linalg.norm(b))
        if denom <= 1e-8:
            return 0.0
        return max(0.0, min(1.0, float(np.dot(a, b) / denom)))


class SpoofBench:
    def __init__(self, model_path: Path):
        self.model = ct.models.MLModel(str(model_path), compute_units=ct.ComputeUnit.CPU_ONLY)

    def predict_clone_probability(self, samples: np.ndarray) -> float:
        rms = float(np.sqrt(np.mean(samples * samples)))
        gain = min(MAX_SPOOF_GAIN, TARGET_SPOOF_RMS / max(rms, 1e-6))
        prepared = np.clip(samples * gain, -1.0, 1.0).astype(np.float32)
        out = self.model.predict({"waveform": prepared[np.newaxis, :]})
        val = out["clone_probability"]
        if isinstance(val, np.ndarray):
            return float(val.reshape(-1)[0])
        return float(val)


def run_speaker_benchmark(manifest_path: Path, model_path: Path, max_speakers: int) -> dict[str, float]:
    rows = read_csv_rows(manifest_path)
    rows = [r for r in rows if r["label"] == "real" and r["split"] in {"val", "test"}]
    by_speaker: dict[str, list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        by_speaker[row["speaker_id"]].append(row)

    selected = [speaker for speaker, items in sorted(by_speaker.items()) if len(items) >= 2][:max_speakers]
    bench = SpeakerBench(model_path)

    enroll_embeddings: dict[str, np.ndarray] = {}
    pos_scores: list[float] = []
    neg_scores: list[float] = []

    for speaker in selected:
        print(f"speaker_progress={speaker}", flush=True)
        enroll = load_wav_16k_mono(by_speaker[speaker][0]["audio_path"])
        probe = load_wav_16k_mono(by_speaker[speaker][1]["audio_path"])
        enroll_emb = bench.embed(enroll)
        probe_emb = bench.embed(probe)
        enroll_embeddings[speaker] = enroll_emb
        pos_scores.append(bench.cosine(enroll_emb, probe_emb))

    for idx, speaker in enumerate(selected):
        other = selected[(idx + 1) % len(selected)]
        if other == speaker:
            continue
        probe = load_wav_16k_mono(by_speaker[other][0]["audio_path"])
        probe_emb = bench.embed(probe)
        neg_scores.append(bench.cosine(enroll_embeddings[speaker], probe_emb))

    total = len(pos_scores) + len(neg_scores)
    correct = sum(score >= SPEAKER_THRESHOLD for score in pos_scores) + sum(
        score < SPEAKER_THRESHOLD for score in neg_scores
    )
    return {
        "selected_speakers": float(len(selected)),
        "positive_pairs": float(len(pos_scores)),
        "negative_pairs": float(len(neg_scores)),
        "speaker_accuracy": correct / max(total, 1),
        "positive_mean_similarity": float(np.mean(pos_scores)) if pos_scores else 0.0,
        "negative_mean_similarity": float(np.mean(neg_scores)) if neg_scores else 0.0,
    }


def run_spoof_benchmark(manifest_path: Path, model_path: Path, max_per_class: int) -> dict[str, float]:
    rows = read_csv_rows(manifest_path)
    rows = [r for r in rows if r["split"] in {"val", "test"}]
    real_rows = [r for r in rows if r["label"] == "real"][:max_per_class]
    fake_rows = [r for r in rows if r["label"] == "fake"][:max_per_class]
    bench = SpoofBench(model_path)

    real_scores: list[float] = []
    fake_scores: list[float] = []

    for row in real_rows:
        print(f"spoof_progress=real:{Path(row['audio_path']).name}", flush=True)
        real_scores.append(bench.predict_clone_probability(load_wav_16k_mono(row["audio_path"])))
    for row in fake_rows:
        print(f"spoof_progress=fake:{Path(row['audio_path']).name}", flush=True)
        fake_scores.append(bench.predict_clone_probability(load_wav_16k_mono(row["audio_path"])))

    total = len(real_scores) + len(fake_scores)
    correct = sum(score < SPOOF_THRESHOLD for score in real_scores) + sum(
        score >= SPOOF_THRESHOLD for score in fake_scores
    )
    return {
        "real_rows": float(len(real_scores)),
        "fake_rows": float(len(fake_scores)),
        "spoof_accuracy": correct / max(total, 1),
        "real_mean_clone_probability": float(np.mean(real_scores)) if real_scores else 0.0,
        "fake_mean_clone_probability": float(np.mean(fake_scores)) if fake_scores else 0.0,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--speaker-manifest", type=Path, default=Path("/Users/reeceway/Desktop/vericall voiceprints/commercial_safe_cleanroom/data/manifests/institutional_release_20260309_spoof/layer3_sv_manifest.csv"))
    parser.add_argument("--spoof-manifest", type=Path, default=Path("/Users/reeceway/Desktop/vericall voiceprints/commercial_safe_cleanroom/data/manifests/institutional_release_20260309_spoof/layer2_spoof_manifest.csv"))
    parser.add_argument("--speaker-model", type=Path, default=Path("/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/VoiceEmbedder.mlpackage"))
    parser.add_argument("--spoof-model", type=Path, default=Path("/Users/reeceway/Desktop/vericall voiceprints/vericall/ios/VeriCall/Models/VeriCallSpoofDetector.mlpackage"))
    parser.add_argument("--max-speakers", type=int, default=25)
    parser.add_argument("--max-spoof-per-class", type=int, default=50)
    args = parser.parse_args()

    print(f"speaker_manifest={args.speaker_manifest}")
    print(f"spoof_manifest={args.spoof_manifest}")
    print(f"speaker_model={args.speaker_model}")
    print(f"spoof_model={args.spoof_model}")

    speaker_metrics = run_speaker_benchmark(args.speaker_manifest, args.speaker_model, args.max_speakers)
    print("SPEAKER_BENCH")
    for key, value in speaker_metrics.items():
        print(f"{key}={value:.4f}")

    spoof_metrics = run_spoof_benchmark(args.spoof_manifest, args.spoof_model, args.max_spoof_per_class)
    print("SPOOF_BENCH")
    for key, value in spoof_metrics.items():
        print(f"{key}={value:.4f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
