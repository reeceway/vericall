#!/usr/bin/env python3
"""Render a safe fly.io secrets command from a tuning config JSON."""

from __future__ import annotations

import argparse
import json
import shlex
from pathlib import Path
from typing import Any, Dict, Tuple


def load_payload(config_path: Path) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    payload = json.loads(config_path.read_text())
    if not isinstance(payload, dict):
        raise SystemExit("Config JSON must be an object")

    if isinstance(payload.get("tuning"), dict):
        tuning = payload["tuning"]
    else:
        tuning = payload

    if not isinstance(tuning, dict):
        raise SystemExit("Could not find a tuning object in config JSON")
    return payload, tuning


def compact_json_object(obj: Dict[str, Any]) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True)


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate fly secrets command for verification tuning")
    parser.add_argument("--config", required=True, help="Path to tuning_recommendation.json")
    parser.add_argument("--app", help="Optional Fly app name")
    parser.add_argument("--version", help="Override VOICE_VERIFICATION_CONFIG_VERSION")
    parser.add_argument("--ttl-seconds", type=int, help="Override VOICE_VERIFICATION_CONFIG_TTL_SECONDS")
    parser.add_argument("--output", help="Optional output file to write command")
    args = parser.parse_args()

    config_path = Path(args.config).expanduser().resolve()
    if not config_path.exists():
        raise SystemExit(f"Config not found: {config_path}")

    payload, tuning = load_payload(config_path)
    version = str(
        args.version
        if args.version is not None
        else payload.get("version", "1")
    ).strip() or "1"
    ttl_seconds = int(
        args.ttl_seconds
        if args.ttl_seconds is not None
        else payload.get("ttl_seconds", 300)
    )
    ttl_seconds = max(60, min(86_400, ttl_seconds))

    tuning_json = compact_json_object(tuning)
    assignments = [
        f"VOICE_VERIFICATION_TUNING_JSON={tuning_json}",
        f"VOICE_VERIFICATION_CONFIG_VERSION={version}",
        f"VOICE_VERIFICATION_CONFIG_TTL_SECONDS={ttl_seconds}",
    ]

    tokens = ["fly", "secrets", "set", *assignments]
    if args.app:
        tokens.extend(["-a", args.app])
    command = " ".join(shlex.quote(token) for token in tokens)

    if args.output:
        output = Path(args.output).expanduser().resolve()
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(command + "\n")
        print(f"Wrote command to {output}")

    print(command)
    print("")
    print("# Equivalent .env values")
    print(f"VOICE_VERIFICATION_TUNING_JSON='{tuning_json}'")
    print(f"VOICE_VERIFICATION_CONFIG_VERSION={version}")
    print(f"VOICE_VERIFICATION_CONFIG_TTL_SECONDS={ttl_seconds}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
