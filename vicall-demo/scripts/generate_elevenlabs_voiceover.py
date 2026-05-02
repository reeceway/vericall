#!/usr/bin/env python3

import json
import os
import shutil
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path
from typing import Optional


ROOT = Path("/Users/reeceway/Desktop/vericall voiceprints/vericall/vicall-demo")
PUBLIC_DIR = ROOT / "public"
BUILD_DIR = PUBLIC_DIR / "voiceover_build"
OUTPUT_MP3 = PUBLIC_DIR / "voiceover.mp3"
ENV_FILE = Path(
    "/Users/reeceway/Desktop/vericall voiceprints/commercial_safe_cleanroom/projects/vicall_ecapa_runpod/.env"
)

# Default voice: Roger. Override with ELEVENLABS_VOICE_ID for alternates.
DEFAULT_VOICE_ID = "CwhRBWXzGAHq8TQ4Fs17"
DEFAULT_MODEL_ID = "eleven_multilingual_v2"
OUTPUT_FORMAT = "mp3_44100_128"
DEFAULT_BRAND_SPELLING = "Vicall"
DEFAULT_CHANNEL_VARIANT = "esafe"

SCENES = [
    {
        "id": "scene01",
        "duration": 5.60,
        "text": "AI can already fake a voice well enough to sound real on a live call.",
    },
    {
        "id": "scene02",
        "duration": 7.37,
        "text": "One thousand three hundred percent growth. Three seconds of audio. Forty billion dollars in projected losses. Voice fraud is scaling fast.",
    },
    {
        "id": "scene03",
        "duration": 5.47,
        "text": "Email is protected. Endpoints are protected. Voice calls still slip through.",
    },
    {
        "id": "scene04",
        "duration": 8.73,
        "text": "Vicall adds a secure calling layer without asking your team to work differently. Your IT team deploys it once, and detection runs continuously during the call.",
    },
    {
        "id": "scene05",
        "duration": 6.67,
        "text": "If the app is open, Vicall shows the trust signal right in the call screen.",
    },
    {
        "id": "scene06",
        "duration": 8.93,
        "text": "If the app is closed, the call still comes through normal iPhone CallKit. If the voice sounds safe, nothing extra gets in the way.",
    },
    {
        "id": "scene07",
        "duration": 10.60,
        "text": "If a voice clone is detected, the in-app screen turns red first. If the app is closed, the device follows with a notification and vibration.",
    },
    {
        "id": "scene08",
        "duration": 6.37,
        "text": "The alert decision runs on the device. No cloud inference for the alert. No stored call recordings.",
    },
    {
        "id": "scene09",
        "duration": 10.27,
        "text": "One voice clone incident can average a five hundred thousand dollar loss. Protection starts at thirty-five dollars per seat per month. That's one dollar and twelve cents a day. Less than your daily coffee.",
    },
    {
        "id": "scene10",
        "duration": 5.00,
        "text": "Available now through E-Safe. Powered by Vicall.",
    },
]


def read_api_key() -> str:
    for line in ENV_FILE.read_text().splitlines():
        if line.startswith("ELEVENLABS_API_KEY="):
            return line.split("=", 1)[1].strip()
    raise RuntimeError(f"ELEVENLABS_API_KEY not found in {ENV_FILE}")


def read_voice_id() -> str:
    return os.environ.get("ELEVENLABS_VOICE_ID", DEFAULT_VOICE_ID).strip()


def read_model_id() -> str:
    return os.environ.get("ELEVENLABS_MODEL_ID", DEFAULT_MODEL_ID).strip()


def read_channel_variant() -> str:
    variant = os.environ.get("VICALL_CHANNEL_VARIANT", DEFAULT_CHANNEL_VARIANT).strip().lower()
    return "general" if variant == "general" else "esafe"


def read_brand_alias() -> Optional[str]:
    alias = os.environ.get("ELEVENLABS_BRAND_ALIAS", "").strip()
    return alias or None


def read_brand_phoneme() -> Optional[dict]:
    phoneme = os.environ.get("ELEVENLABS_BRAND_PHONEME", "").strip()
    if not phoneme:
        return None
    alphabet = os.environ.get("ELEVENLABS_BRAND_ALPHABET", "ipa").strip() or "ipa"
    return {
        "type": "phoneme",
        "alphabet": alphabet,
        "phoneme": phoneme,
    }


def create_pronunciation_dictionary(api_key: str, rule: dict, label: str) -> dict:
    payload = {
        "name": f"Vicall brand rule {label}",
        "description": f"Temporary brand pronunciation rule for Vicall as {label}",
        "rules": [
            {
                "string_to_replace": DEFAULT_BRAND_SPELLING,
                "case_sensitive": True,
                "word_boundaries": True,
                **rule,
            }
        ],
    }
    request = urllib.request.Request(
        "https://api.elevenlabs.io/v1/pronunciation-dictionaries/add-from-rules",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read().decode("utf-8"))


def ffprobe_duration(path: Path) -> float:
    cmd = [
        "ffprobe",
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        str(path),
    ]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)
    return float(result.stdout.strip())


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def build_atempo_chain(speed_factor: float) -> str:
    factors = []
    remaining = speed_factor
    while remaining > 2.0:
        factors.append(2.0)
        remaining /= 2.0
    while remaining < 0.5:
        factors.append(0.5)
        remaining /= 0.5
    factors.append(remaining)
    return ",".join(f"atempo={factor:.6f}" for factor in factors)


def synthesize_scene(api_key: str, scene: dict, output_path: Path) -> None:
    voice_id = read_voice_id()
    model_id = read_model_id()
    brand_alias = read_brand_alias()
    brand_phoneme = read_brand_phoneme()
    payload = {
        "text": scene["text"],
        "model_id": model_id,
        "language_code": "en",
        "voice_settings": {
        "stability": 0.31,
        "similarity_boost": 0.84,
        "style": 0.06,
        "use_speaker_boost": True,
        "speed": 0.98,
        },
    }
    if brand_alias or brand_phoneme:
        if brand_phoneme:
            rule = brand_phoneme
            label = f"{brand_phoneme['alphabet']}:{brand_phoneme['phoneme']}"
        else:
            rule = {"type": "alias", "alias": brand_alias}
            label = brand_alias
        dictionary = create_pronunciation_dictionary(api_key, rule, label)
        payload["pronunciation_dictionary_locators"] = [
            {
                "pronunciation_dictionary_id": dictionary["id"],
                "version_id": dictionary["version_id"],
            }
        ]
    request = urllib.request.Request(
        f"https://api.elevenlabs.io/v1/text-to-speech/{voice_id}?output_format={OUTPUT_FORMAT}",
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "xi-api-key": api_key,
            "Content-Type": "application/json",
            "Accept": "audio/mpeg",
        },
        method="POST",
    )
    with urllib.request.urlopen(request) as response:
        output_path.write_bytes(response.read())


def create_silence(path: Path, seconds: float) -> None:
    run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "lavfi",
            "-i",
            "anullsrc=r=44100:cl=mono",
            "-t",
            f"{seconds:.3f}",
            "-c:a",
            "pcm_s16le",
            str(path),
        ]
    )


def main() -> int:
    api_key = read_api_key()
    channel_variant = read_channel_variant()
    BUILD_DIR.mkdir(parents=True, exist_ok=True)

    concat_entries: list[Path] = []
    manifest_rows = []

    scenes = []
    for scene in SCENES:
        scene_copy = dict(scene)
        if scene_copy["id"] == "scene10":
            scene_copy["text"] = (
                "Available now through your MSP. Powered by Vicall."
                if channel_variant == "general"
                else "Available now through E-Safe, powered by Vicall."
            )
        scenes.append(scene_copy)

    for scene in scenes:
        raw_mp3 = BUILD_DIR / f"{scene['id']}-raw.mp3"
        processed_wav = BUILD_DIR / f"{scene['id']}.wav"
        synthesize_scene(api_key, scene, raw_mp3)
        raw_duration = ffprobe_duration(raw_mp3)

        available_duration = max(scene["duration"] - 0.18, 0.5)
        speed_factor = raw_duration / available_duration if raw_duration > available_duration else 1.0

        audio_filter = build_atempo_chain(speed_factor) if speed_factor > 1.005 else None
        cmd = ["ffmpeg", "-y", "-i", str(raw_mp3)]
        if audio_filter:
            cmd.extend(["-filter:a", audio_filter])
        cmd.extend(["-ar", "44100", "-ac", "1", "-c:a", "pcm_s16le", str(processed_wav)])
        run(cmd)

        final_duration = ffprobe_duration(processed_wav)
        silence_needed = max(scene["duration"] - final_duration, 0.0)
        concat_entries.append(processed_wav)

        if silence_needed >= 0.04:
            silence_wav = BUILD_DIR / f"{scene['id']}-silence.wav"
            create_silence(silence_wav, silence_needed)
            concat_entries.append(silence_wav)

        manifest_rows.append(
            {
                "scene": scene["id"],
                "target_duration": scene["duration"],
                "raw_duration": round(raw_duration, 3),
                "final_voice_duration": round(final_duration, 3),
                "silence_added": round(silence_needed, 3),
                "speed_factor": round(speed_factor, 4),
            }
        )

    concat_list = BUILD_DIR / "concat.txt"
    concat_list.write_text("".join(f"file '{path}'\n" for path in concat_entries))

    if OUTPUT_MP3.exists():
        backup = BUILD_DIR / "voiceover-prev.mp3"
        shutil.copy2(OUTPUT_MP3, backup)

    run(
        [
            "ffmpeg",
            "-y",
            "-f",
            "concat",
            "-safe",
            "0",
            "-i",
            str(concat_list),
            "-c:a",
            "libmp3lame",
            "-b:a",
            "128k",
            str(OUTPUT_MP3),
        ]
    )

    (BUILD_DIR / "manifest.json").write_text(json.dumps(manifest_rows, indent=2))
    total_duration = ffprobe_duration(OUTPUT_MP3)
    print(json.dumps({"voiceover": str(OUTPUT_MP3), "duration": total_duration, "manifest": str(BUILD_DIR / 'manifest.json')}, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
