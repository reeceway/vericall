#!/usr/bin/env python3
"""Build a balanced supervised audio corpus with pipeline-style augmentations."""

from __future__ import annotations

import argparse
import csv
import hashlib
import math
import random
import re
from pathlib import Path
from typing import Any, Dict, Iterable, List, Sequence, Tuple

import numpy as np
import soundfile as sf
from scipy import signal


SUPPORTED_EXTS = {".wav", ".flac", ".aiff", ".aif", ".m4a", ".mp3"}


def iter_audio_files(roots: Sequence[Path]) -> Iterable[Path]:
    for root in roots:
        if not root.exists():
            continue
        for path in root.rglob("*"):
            if path.is_file() and path.suffix.lower() in SUPPORTED_EXTS:
                yield path


def deterministic_shuffle(items: List[Path], seed: int, salt: str) -> List[Path]:
    def key_fn(path: Path) -> str:
        raw = f"{seed}:{salt}:{path.as_posix()}".encode("utf-8")
        return hashlib.sha1(raw).hexdigest()

    return sorted(items, key=key_fn)


def load_mono_16k(path: Path) -> np.ndarray | None:
    try:
        audio, sr = sf.read(path.as_posix(), dtype="float32", always_2d=False)
    except Exception:
        return None

    if isinstance(audio, np.ndarray) and audio.ndim == 2:
        audio = np.mean(audio, axis=1)
    if not isinstance(audio, np.ndarray):
        return None
    if sr != 16_000:
        gcd = math.gcd(int(sr), 16_000)
        up = 16_000 // gcd
        down = int(sr) // gcd
        audio = signal.resample_poly(audio, up=up, down=down).astype(np.float32)
    if audio is None or len(audio) == 0:
        return None
    audio = np.nan_to_num(audio.astype(np.float32), nan=0.0, posinf=0.0, neginf=0.0)
    peak = float(np.max(np.abs(audio)))
    if peak > 1e-6:
        audio = audio / max(1.0, peak)
    return audio


def tile_to_length(audio: np.ndarray, target_len: int) -> np.ndarray:
    if len(audio) >= target_len:
        return audio[:target_len]
    reps = int(math.ceil(target_len / max(1, len(audio))))
    tiled = np.tile(audio, reps)
    return tiled[:target_len]


def crop_segments(audio: np.ndarray, target_len: int, max_segments: int) -> List[np.ndarray]:
    if len(audio) < target_len:
        return [tile_to_length(audio, target_len)]

    if len(audio) <= int(target_len * 1.5) or max_segments <= 1:
        start = (len(audio) - target_len) // 2
        return [audio[start : start + target_len]]

    max_segments = max(1, max_segments)
    max_start = len(audio) - target_len
    starts = np.linspace(0, max_start, num=max_segments, dtype=np.int64).tolist()
    segments = [audio[int(s) : int(s) + target_len] for s in starts]
    return segments


def normalize_rms(audio: np.ndarray, target_rms: float = 0.08) -> np.ndarray:
    rms = float(np.sqrt(np.mean(np.square(audio)) + 1e-9))
    if rms < 1e-6:
        return audio.copy()
    out = audio * (target_rms / rms)
    return np.clip(out, -1.0, 1.0)


def bandpass_telephony(audio: np.ndarray, sr: int = 16_000) -> np.ndarray:
    b, a = signal.butter(4, [300 / (sr / 2), 3400 / (sr / 2)], btype="band")
    out = signal.lfilter(b, a, audio).astype(np.float32)
    return np.clip(out, -1.0, 1.0)


def add_noise(audio: np.ndarray, rng: random.Random, snr_db_min: float, snr_db_max: float) -> np.ndarray:
    snr_db = rng.uniform(snr_db_min, snr_db_max)
    sig_power = float(np.mean(np.square(audio)) + 1e-9)
    noise_power = sig_power / (10 ** (snr_db / 10))
    noise = np.random.normal(0.0, np.sqrt(noise_power), size=audio.shape).astype(np.float32)
    out = audio + noise
    return np.clip(out, -1.0, 1.0)


def packet_loss(audio: np.ndarray, rng: random.Random, frame: int = 320) -> np.ndarray:
    p = rng.uniform(0.01, 0.06)
    out = audio.copy()
    n = len(out)
    for i in range(0, n, frame):
        if rng.random() < p:
            out[i : i + frame] = 0.0
    return out


def mu_law_roundtrip(audio: np.ndarray, mu: int = 255) -> np.ndarray:
    x = np.clip(audio, -1.0, 1.0)
    fx = np.sign(x) * np.log1p(mu * np.abs(x)) / np.log1p(mu)
    q = np.round((fx + 1) * 127.5) / 127.5 - 1
    y = np.sign(q) * (1.0 / mu) * ((1 + mu) ** np.abs(q) - 1)
    return np.clip(y.astype(np.float32), -1.0, 1.0)


def clipped(audio: np.ndarray, rng: random.Random) -> np.ndarray:
    clip_value = rng.uniform(0.55, 0.80)
    out = np.clip(audio, -clip_value, clip_value)
    peak = float(np.max(np.abs(out)))
    if peak > 1e-6:
        out = out / peak * 0.95
    return out.astype(np.float32)


def speed_perturb(audio: np.ndarray, rng: random.Random, target_len: int) -> np.ndarray:
    rate = rng.uniform(0.94, 1.06)
    new_len = max(1, int(round(len(audio) / rate)))
    y = signal.resample(audio.astype(np.float32), new_len).astype(np.float32)
    return tile_to_length(y, target_len)


def make_variants(base_audio: np.ndarray, rng: random.Random, target_len: int) -> Dict[str, np.ndarray]:
    clean = normalize_rms(base_audio)
    tel = bandpass_telephony(clean)
    tel_noise = add_noise(tel, rng=rng, snr_db_min=12, snr_db_max=28)
    pkt = packet_loss(tel_noise, rng=rng)
    mulaw = mu_law_roundtrip(tel)
    spd = speed_perturb(tel_noise, rng=rng, target_len=target_len)
    clip = clipped(tel_noise, rng=rng)

    variants = {
        "clean": clean,
        "telephony": tel,
        "telephony_noise": tel_noise,
        "packet_loss": pkt,
        "mulaw": mulaw,
        "speed_perturb": spd,
        "clipped": clip,
    }
    return variants


def source_group(path: Path) -> str:
    stem = path.stem
    m = re.match(r"^\d+_([A-Za-z]+)_\d+$", stem)
    if m:
        return f"fsdd_{m.group(1).lower()}"

    parts = [p for p in path.parts]
    if "LibriSpeech" in parts:
        idx = parts.index("LibriSpeech")
        if idx + 2 < len(parts):
            speaker = parts[idx + 2]
            return f"ls_{speaker}"

    parent = path.parent.name.lower()
    stem_prefix = re.split(r"[_\-]", stem.lower())[0]
    return f"{parent}_{stem_prefix}"


def split_for_group(group: str, seed: int, train_ratio: float, val_ratio: float) -> str:
    h = hashlib.sha1(f"{seed}:{group}".encode("utf-8")).hexdigest()[:8]
    bucket = int(h, 16) / float(0xFFFFFFFF)
    if bucket < train_ratio:
        return "train"
    if bucket < (train_ratio + val_ratio):
        return "val"
    return "test"


def write_manifest(path: Path, rows: List[Dict[str, Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if not rows:
        path.write_text("")
        return
    fieldnames = list(rows[0].keys())
    with path.open("w", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def ensure_balanced(
    real_paths: List[Path],
    fake_paths: List[Path],
    seed: int,
    target_per_class: int,
) -> Tuple[List[Path], List[Path]]:
    real_sorted = deterministic_shuffle(real_paths, seed=seed, salt="real")
    fake_sorted = deterministic_shuffle(fake_paths, seed=seed, salt="fake")
    n = min(len(real_sorted), len(fake_sorted))
    if target_per_class > 0:
        n = min(n, target_per_class)
    return real_sorted[:n], fake_sorted[:n]


def take_limit(paths: List[Path], limit: int, seed: int, salt: str) -> List[Path]:
    if limit <= 0 or len(paths) <= limit:
        return deterministic_shuffle(paths, seed=seed, salt=salt)
    return deterministic_shuffle(paths, seed=seed, salt=salt)[:limit]


def main() -> int:
    parser = argparse.ArgumentParser(description="Build balanced supervised corpus with call-pipeline augmentations")
    parser.add_argument("--real-dir", action="append", required=True, help="Directory of real-human audio")
    parser.add_argument("--fake-dir", action="append", required=True, help="Directory of fake/clone audio")
    parser.add_argument("--output-dir", required=True, help="Output corpus directory")
    parser.add_argument("--target-seconds", type=float, default=2.5)
    parser.add_argument("--max-segments-per-source", type=int, default=2)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--train-ratio", type=float, default=0.80)
    parser.add_argument("--val-ratio", type=float, default=0.10)
    parser.add_argument("--max-real-sources", type=int, default=0, help="0 means no cap")
    parser.add_argument("--max-fake-sources", type=int, default=0, help="0 means no cap")
    parser.add_argument("--target-sources-per-class", type=int, default=0, help="Optional balanced cap after class balancing")
    parser.add_argument("--augmentation-rounds", type=int, default=1, help="How many randomized augmentation passes per segment")
    parser.add_argument("--no-balance-classes", action="store_true", help="Disable class balancing by source count")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    np.random.seed(args.seed)

    if args.target_seconds <= 0:
        raise SystemExit("--target-seconds must be > 0")
    if args.train_ratio <= 0 or args.val_ratio < 0 or args.train_ratio + args.val_ratio >= 1:
        raise SystemExit("Expected train_ratio > 0, val_ratio >= 0, and train_ratio + val_ratio < 1")

    real_roots = [Path(p).expanduser().resolve() for p in args.real_dir]
    fake_roots = [Path(p).expanduser().resolve() for p in args.fake_dir]
    output_dir = Path(args.output_dir).expanduser().resolve()
    audio_root = output_dir / "audio"
    audio_root.mkdir(parents=True, exist_ok=True)

    real_paths = list(iter_audio_files(real_roots))
    fake_paths = list(iter_audio_files(fake_roots))
    if not real_paths:
        raise SystemExit("No real audio files found")
    if not fake_paths:
        raise SystemExit("No fake audio files found")

    if args.max_real_sources > 0:
        real_paths = take_limit(real_paths, args.max_real_sources, seed=args.seed, salt="cap-real")
    if args.max_fake_sources > 0:
        fake_paths = take_limit(fake_paths, args.max_fake_sources, seed=args.seed, salt="cap-fake")

    if not args.no_balance_classes:
        real_paths, fake_paths = ensure_balanced(
            real_paths,
            fake_paths,
            seed=args.seed,
            target_per_class=max(0, args.target_sources_per_class),
        )

    target_len = int(round(args.target_seconds * 16_000))
    rows: List[Dict[str, Any]] = []
    class_counts = {"real": 0, "fake": 0}
    written = 0
    skipped = 0

    for label, paths in [("real", real_paths), ("fake", fake_paths)]:
        for idx, source_path in enumerate(paths):
            audio = load_mono_16k(source_path)
            if audio is None or len(audio) < 50:
                skipped += 1
                continue

            segments = crop_segments(audio, target_len=target_len, max_segments=max(1, args.max_segments_per_source))
            for seg_idx, seg in enumerate(segments):
                seg = tile_to_length(seg, target_len)
                for aug_round in range(args.augmentation_rounds):
                    variants = make_variants(seg, rng=rng, target_len=target_len)
                    for variant_name, variant_audio in variants.items():
                        variant_key = f"{variant_name}_r{aug_round:02d}"
                        source_id = hashlib.sha1(
                            f"{source_path.as_posix()}:{seg_idx}:{variant_key}".encode("utf-8")
                        ).hexdigest()[:16]
                        rel_audio = Path(label) / f"{source_id}_{variant_key}.wav"
                        out_path = audio_root / rel_audio
                        out_path.parent.mkdir(parents=True, exist_ok=True)
                        sf.write(out_path.as_posix(), variant_audio, 16_000, subtype="PCM_16")

                        group = source_group(source_path)
                        split = split_for_group(
                            group=group,
                            seed=args.seed,
                            train_ratio=args.train_ratio,
                            val_ratio=args.val_ratio,
                        )
                        row = {
                            "id": source_id,
                            "label": label,
                            "split": split,
                            "variant": variant_key,
                            "source_group": group,
                            "source_path": source_path.as_posix(),
                            "audio_path": out_path.as_posix(),
                            "sample_rate": 16_000,
                            "duration_seconds": f"{(len(variant_audio) / 16_000):.4f}",
                        }
                        rows.append(row)
                        class_counts[label] += 1
                        written += 1

            if (idx + 1) % 200 == 0:
                print(f"[{label}] processed {idx + 1}/{len(paths)} sources; written={written}")

    all_manifest = output_dir / "manifest_all.csv"
    write_manifest(all_manifest, rows)
    for split in ("train", "val", "test"):
        split_rows = [r for r in rows if r["split"] == split]
        write_manifest(output_dir / f"manifest_{split}.csv", split_rows)

    summary = {
        "seed": args.seed,
        "target_seconds": args.target_seconds,
        "max_segments_per_source": args.max_segments_per_source,
        "real_sources": len(real_paths),
        "fake_sources": len(fake_paths),
        "augmentation_rounds": args.augmentation_rounds,
        "written_total": written,
        "written_real": class_counts["real"],
        "written_fake": class_counts["fake"],
        "skipped_sources": skipped,
        "output_dir": output_dir.as_posix(),
    }
    summary_path = output_dir / "summary.json"
    summary_path.write_text(str(summary).replace("'", '"') + "\n")

    print(f"Wrote corpus to {output_dir}")
    print(f"Real clips: {class_counts['real']}")
    print(f"Fake clips: {class_counts['fake']}")
    print(f"Skipped sources: {skipped}")
    print(f"Manifest: {all_manifest}")
    print(f"Summary: {summary_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
    if args.augmentation_rounds <= 0:
        raise SystemExit("--augmentation-rounds must be >= 1")
