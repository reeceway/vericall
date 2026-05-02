#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path


BUNDLE_ID = "com.reeceway.vericall.dev"

EVAL_CLIPS = [
    {
        "id": "enroll_reference",
        "filename": "enroll_reference.wav",
        "category": "same-speaker enroll",
        "useAsEnrollment": True,
        "expectedSpeakerMatch": None,
        "expectedHuman": True,
        "source": "/Volumes/My Passport for Mac/voiceprint_data/degraded/my_voice_vericall_degraded/train/real/New Recording 12_0000000.wav",
    },
    {
        "id": "same_clear",
        "filename": "same_clear.wav",
        "category": "same-speaker clear",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": True,
        "expectedHuman": True,
        "source": "/Volumes/My Passport for Mac/voiceprint_data/degraded/my_voice_vericall_degraded/train/real/New Recording 13_0000001.wav",
    },
    {
        "id": "same_degraded",
        "filename": "same_degraded.wav",
        "category": "same-speaker degraded call",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": True,
        "expectedHuman": True,
        "source": "/Volumes/My Passport for Mac/voiceprint_data/degraded/my_voice_vericall_degraded/train/real/New Recording 12_0000000.wav",
    },
    {
        "id": "same_degraded_2",
        "filename": "same_degraded_2.wav",
        "category": "same-speaker degraded call",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": True,
        "expectedHuman": True,
        "source": "/Volumes/My Passport for Mac/voiceprint_data/degraded/my_voice_vericall_degraded/train/real/New Recording 13_0000001.wav",
    },
    {
        "id": "impostor_real",
        "filename": "impostor_real.wav",
        "category": "real impostor",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": False,
        "expectedHuman": True,
        "source": "/Users/reeceway/Desktop/vericall voiceprints/vericall/datasets/pipeline_supervised_corpus_v2/audio/real/fd6de6061dc8d6b0_telephony_r00.wav",
    },
    {
        "id": "clone_telephony",
        "filename": "clone_telephony.wav",
        "category": "known clone",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": False,
        "expectedHuman": False,
        "source": "/Users/reeceway/Desktop/vericall voiceprints/vericall/datasets/pipeline_supervised_corpus_v2/audio/fake/75abdcffe54d18f2_telephony_r00.wav",
    },
    {
        "id": "clone_noise",
        "filename": "clone_noise.wav",
        "category": "known clone degraded",
        "useAsEnrollment": False,
        "expectedSpeakerMatch": False,
        "expectedHuman": False,
        "source": "/Users/reeceway/Desktop/vericall voiceprints/vericall/datasets/pipeline_supervised_corpus_v2/audio/fake/e7ea83cf6c0d1f47_telephony_noise_r00.wav",
    },
]


def run(cmd: list[str]) -> None:
    subprocess.run(cmd, check=True)


def copy_file(source: Path, destination: Path) -> None:
    run(["/usr/bin/ditto", source.as_posix(), destination.as_posix()])


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: stage_on_device_eval_set.py <device-id> [<device-id> ...]")
        return 1

    staging_root = Path("/tmp/vericall_on_device_eval")
    if staging_root.exists():
        shutil.rmtree(staging_root)
    staging_root.mkdir(parents=True)

    manifest = {"clips": []}
    for clip in EVAL_CLIPS:
        source = Path(clip["source"])
        if not source.exists():
            raise FileNotFoundError(source)
        destination = staging_root / clip["filename"]
        copy_file(source, destination)
        manifest["clips"].append(
            {
                "id": clip["id"],
                "filename": clip["filename"],
                "category": clip["category"],
                "useAsEnrollment": clip["useAsEnrollment"],
                "expectedSpeakerMatch": clip["expectedSpeakerMatch"],
                "expectedHuman": clip["expectedHuman"],
            }
        )

    (staging_root / "manifest.json").write_text(json.dumps(manifest, indent=2))

    for device in sys.argv[1:]:
        run(
            [
                "xcrun",
                "devicectl",
                "device",
                "copy",
                "to",
                "--device",
                device,
                "--domain-type",
                "appDataContainer",
                "--domain-identifier",
                BUNDLE_ID,
                "--destination",
                "Documents/OnDeviceEval",
                "--source",
                str(staging_root),
                "--remove-existing-content",
                "true",
            ]
        )

    print(f"staged eval set to {', '.join(sys.argv[1:])}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
