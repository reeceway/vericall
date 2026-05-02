#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="/Users/reeceway/Desktop/vericall voiceprints/vericall"
VIDEO_ROOT="$PROJECT_ROOT/vicall-demo"
IOS_ROOT="$PROJECT_ROOT/ios"
WORKSPACE="$IOS_ROOT/VeriCall.xcworkspace"
SCHEME="VeriCall"
SIMULATOR_NAME="${SIMULATOR_NAME:-iPhone 17 Pro}"
DERIVED_DATA="$VIDEO_ROOT/build/DerivedData"
OUTPUT_DIR="$VIDEO_ROOT/public/clips"
APP_BUNDLE_ID="com.reeceway.vericall.dev"

mkdir -p "$OUTPUT_DIR"

echo "==> Locating simulator: $SIMULATOR_NAME"
SIMULATOR_ID="$(xcrun simctl list devices available | awk -F '[()]' -v name="$SIMULATOR_NAME" '$1 ~ name {print $2; exit}')"

if [[ -z "${SIMULATOR_ID:-}" ]]; then
  echo "Simulator not found: $SIMULATOR_NAME" >&2
  exit 1
fi

echo "==> Booting simulator $SIMULATOR_NAME ($SIMULATOR_ID)"
xcrun simctl boot "$SIMULATOR_ID" >/dev/null 2>&1 || true
xcrun simctl bootstatus "$SIMULATOR_ID" -b
open -a Simulator --args -CurrentDeviceUDID "$SIMULATOR_ID" >/dev/null 2>&1 || true

echo "==> Standardizing status bar"
xcrun simctl status_bar "$SIMULATOR_ID" clear >/dev/null 2>&1 || true
xcrun simctl status_bar "$SIMULATOR_ID" override \
  --time "9:41" \
  --dataNetwork wifi \
  --wifiMode active \
  --wifiBars 3 \
  --cellularMode active \
  --cellularBars 4 \
  --operatorName "" \
  --batteryState charged \
  --batteryLevel 100 >/dev/null 2>&1 || true

echo "==> Building Vicall for simulator"
cd "$IOS_ROOT"
xcodebuild \
  -workspace "$WORKSPACE" \
  -scheme "$SCHEME" \
  -configuration Debug \
  -sdk iphonesimulator \
  -destination "id=$SIMULATOR_ID" \
  -derivedDataPath "$DERIVED_DATA" \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/vicall-demo-xcodebuild.log

APP_PATH="$(find "$DERIVED_DATA/Build/Products" -path '*iphonesimulator*/VeriCall.app' | head -n 1)"

if [[ -z "${APP_PATH:-}" ]]; then
  echo "Could not find built app in $DERIVED_DATA" >&2
  exit 1
fi

echo "==> Resetting installed app"
xcrun simctl terminate "$SIMULATOR_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl uninstall "$SIMULATOR_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_ID" "$APP_PATH" >/dev/null

record_kind() {
  local kind="$1"
  local filename="$2"
  local duration="${3:-7}"
  local warmup="${4:-1.0}"
  local raw="$OUTPUT_DIR/raw-$filename"
  local out="$OUTPUT_DIR/$filename"

  echo "==> Recording $kind -> $out"
  xcrun simctl terminate "$SIMULATOR_ID" "$APP_BUNDLE_ID" >/dev/null 2>&1 || true

  SIMCTL_CHILD_VICALL_VIDEO_DEMO_KIND="$kind" \
    xcrun simctl launch --terminate-running-process "$SIMULATOR_ID" "$APP_BUNDLE_ID" >/tmp/vicall-demo-launch.log

  sleep "$warmup"

  xcrun simctl io "$SIMULATOR_ID" recordVideo --codec h264 "$raw" >/tmp/vicall-demo-record.log 2>&1 &
  local recorder_pid=$!
  sleep "$duration"
  kill -INT "$recorder_pid" >/dev/null 2>&1 || true
  wait "$recorder_pid" >/dev/null 2>&1 || true

  ffmpeg -y -i "$raw" -vf "format=yuv420p" -movflags +faststart "$out" >/tmp/vicall-demo-ffmpeg.log 2>&1
  rm -f "$raw"
}

record_kind "install" "install.mp4" 7 0.6
record_kind "make-call" "make-call.mp4" 8 0.6
record_kind "callkit-incoming" "callkit-incoming.mp4" 7 0.6
record_kind "answer-green-notification" "answer-green-notification.mp4" 8 0.6
record_kind "call-ui-green-chip" "call-ui-green-chip.mp4" 6 0.6
record_kind "call-ui-red-chip" "call-ui-red-chip.mp4" 6 0.6
record_kind "clone-notification-red" "clone-notification-red.mp4" 7 0.6

echo "==> Done. Video demo clips are in $OUTPUT_DIR"
