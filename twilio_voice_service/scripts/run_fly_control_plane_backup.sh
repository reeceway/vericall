#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLY_APP="${VICALL_FLY_APP:-vericall-twilio-voice}"
FLY_VOLUME_ID="${VICALL_FLY_VOLUME_ID:-vol_vjyk8mqw92m5g99v}"
REMOTE_APP_DIR="${VICALL_REMOTE_APP_DIR:-/app}"
REMOTE_PYTHON="${VICALL_REMOTE_PYTHON:-python3}"
SKIP_FLY_SNAPSHOT="${VICALL_SKIP_FLY_SNAPSHOT:-0}"

if ! command -v fly >/dev/null 2>&1; then
  echo "flyctl is required for this helper script." >&2
  exit 1
fi

if [[ "$SKIP_FLY_SNAPSHOT" != "1" ]]; then
  echo "[1/3] Creating Fly volume snapshot for ${FLY_VOLUME_ID}..."
  fly volumes snapshots create "$FLY_VOLUME_ID" --app "$FLY_APP"
else
  echo "[1/3] Skipping Fly volume snapshot because VICALL_SKIP_FLY_SNAPSHOT=1"
fi

echo "[2/3] Running remote control-plane backup inside ${FLY_APP}..."
BACKUP_JSON="$(
  fly ssh console -q -a "$FLY_APP" -C \
    "cd '$REMOTE_APP_DIR' && $REMOTE_PYTHON scripts/backup_control_plane_db.py"
)"
printf '%s\n' "$BACKUP_JSON"

BACKUP_PATH="$(
  printf '%s' "$BACKUP_JSON" | "$REMOTE_PYTHON" -c 'import json, sys; print(json.load(sys.stdin)["compressed_backup_path"])'
)"

echo "[3/3] Validating ${BACKUP_PATH} on the Fly machine..."
fly ssh console -q -a "$FLY_APP" -C \
  "cd '$REMOTE_APP_DIR' && $REMOTE_PYTHON scripts/validate_control_plane_backup.py '$BACKUP_PATH' --pretty"
