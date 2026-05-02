#!/usr/bin/env python3
"""Generate a large synthetic-fake speech corpus using macOS `say` voices."""

from __future__ import annotations

import argparse
import csv
import hashlib
import random
import re
import subprocess
from pathlib import Path
from typing import List, Tuple

import soundfile as sf


VOICE_LINE_RE = re.compile(r"^(?P<name>.+?)\s+(?P<locale>[a-z]{2}_[A-Z]{2})\s+#")


def parse_voices(english_only: bool) -> List[Tuple[str, str]]:
    result = subprocess.run(
        ["say", "-v", "?"],
        capture_output=True,
        text=True,
        check=True,
    )
    voices: List[Tuple[str, str]] = []
    for line in result.stdout.splitlines():
        m = VOICE_LINE_RE.match(line.strip())
        if not m:
            continue
        name = m.group("name").strip()
        locale = m.group("locale").strip()
        if english_only and not locale.startswith("en_"):
            continue
        voices.append((name, locale))
    return voices


def phrase_pool() -> List[str]:
    base = [
        "Hello, this is a secure verification call.",
        "Please confirm your identity using your voice.",
        "I am calling to verify account ownership.",
        "Can you hear me clearly right now?",
        "This call is protected by voice authentication.",
        "I authorize this transfer request right now.",
        "Please repeat your full name after the tone.",
        "The verification code is {code}.",
        "The amount requested is {amount} dollars.",
        "I am at home and this is my real voice.",
        "Please do not share this passcode with anyone.",
        "I did not request any password reset today.",
        "Confirm that you are speaking with {name}.",
        "This is an urgent request for account recovery.",
        "I approve this identity confirmation workflow.",
        "Can we continue this verification in a few seconds?",
        "Please answer yes if you are the account holder.",
        "I am speaking from a mobile phone connection.",
        "The call quality may change during this test.",
        "VeriCall is checking for deepfake impersonation now.",
    ]
    names = [
        "Alex Morgan",
        "Jordan Lee",
        "Taylor Brooks",
        "Sam Carter",
        "Casey Adams",
        "Riley Parker",
        "Avery Collins",
        "Drew Bennett",
    ]
    codes = ["four two nine eight", "one seven zero five", "nine one three four", "six six one two"]
    amounts = ["120", "350", "980", "2500", "4200", "75"]

    phrases: List[str] = []
    for template in base:
        if "{name}" in template:
            for name in names:
                phrases.append(template.format(name=name))
        elif "{code}" in template:
            for code in codes:
                phrases.append(template.format(code=code))
        elif "{amount}" in template:
            for amount in amounts:
                phrases.append(template.format(amount=amount))
        else:
            phrases.append(template)
    return phrases


def stable_id(voice: str, text: str) -> str:
    h = hashlib.sha1(f"{voice}|{text}".encode("utf-8")).hexdigest()
    return h[:16]


def synth_one(voice: str, text: str, wav_path: Path) -> None:
    aiff_path = wav_path.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff_path), text], check=True)
    subprocess.run(
        [
            "afconvert",
            "-f",
            "WAVE",
            "-d",
            "LEI16@16000",
            "-c",
            "1",
            str(aiff_path),
            str(wav_path),
        ],
        check=True,
    )
    aiff_path.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate synthetic fake speech with macOS TTS voices")
    parser.add_argument("--output-dir", required=True, help="Where to write generated wav files")
    parser.add_argument("--count", type=int, default=800, help="Number of clips to generate")
    parser.add_argument("--seed", type=int, default=42, help="Random seed")
    parser.add_argument("--english-only", action="store_true", help="Use only en_* voices")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing files")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    output_dir = Path(args.output_dir).expanduser().resolve()
    audio_dir = output_dir / "audio"
    audio_dir.mkdir(parents=True, exist_ok=True)
    manifest_path = output_dir / "manifest.csv"

    voices = parse_voices(english_only=args.english_only)
    if not voices:
        raise SystemExit("No usable voices found from `say -v ?`")
    phrases = phrase_pool()
    if not phrases:
        raise SystemExit("Phrase pool is empty")

    rows = []
    generated = 0

    for idx in range(args.count):
        voice, locale = rng.choice(voices)
        text = rng.choice(phrases)
        clip_id = stable_id(voice, f"{text}|{idx}|{args.seed}")
        wav_path = audio_dir / f"{clip_id}.wav"

        if wav_path.exists() and args.overwrite:
            wav_path.unlink(missing_ok=True)

        try:
            synth_one(voice=voice, text=text, wav_path=wav_path)
            audio, sr = sf.read(str(wav_path))
            duration = float(len(audio) / sr) if sr > 0 else 0.0
            if duration < 0.20:
                wav_path.unlink(missing_ok=True)
                continue
            rows.append(
                {
                    "clip_id": clip_id,
                    "label": "fake",
                    "voice": voice,
                    "locale": locale,
                    "text": text,
                    "wav_path": str(wav_path),
                    "duration_seconds": f"{duration:.4f}",
                }
            )
            generated = idx + 1
            if generated % 50 == 0:
                print(f"Generated {generated}/{args.count} clips...")
        except Exception as exc:
            wav_path.unlink(missing_ok=True)
            print(f"Failed clip ({voice}): {exc}")

    if generated < args.count:
        print(f"Warning: requested {args.count}, generated {generated}.")

    with manifest_path.open("w", newline="") as f:
        writer = csv.DictWriter(
            f,
            fieldnames=[
                "clip_id",
                "label",
                "voice",
                "locale",
                "text",
                "wav_path",
                "duration_seconds",
            ],
        )
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {generated} clips to {audio_dir}")
    print(f"Wrote manifest: {manifest_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
