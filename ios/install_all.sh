#!/bin/bash
set -e

# Detect devices
echo "🔍 Detecting connected devices..."
# Get devices list: ID and Name
raw_devices=$(ios-deploy -c | grep "Found" || true)

if [ -z "$raw_devices" ]; then
    echo "❌ No physical devices found. Please connect an iPhone."
    exit 1
fi

echo "$raw_devices"
echo ""

# Parse unique device IDs
device_ids=$(echo "$raw_devices" | grep -o "[0-9A-Fa-f-]*" | grep -E "^[0-9A-F-]{20,}$" | sort | uniq)

if [ -z "$device_ids" ]; then
    echo "❌ Could not parse device IDs."
    exit 1
fi

# Build once for generic iOS device (arm64)
echo "🚀 Building VeriCall for iOS..."
xcodebuild -project VeriCall.xcodeproj \
    -scheme VeriCall \
    -configuration Debug \
    -sdk iphoneos \
    -derivedDataPath build \
    clean build \
    CODE_SIGN_IDENTITY="Apple Development" \
    CODE_SIGNING_REQUIRED=YES \
    CODE_SIGNING_ALLOWED=YES

if [ $? -eq 0 ]; then
    echo "✅ Build success"
else
    echo "❌ Build failed"
    exit 1
fi

APP_PATH="build/Build/Products/Debug-iphoneos/VeriCall.app"

if [ ! -d "$APP_PATH" ]; then
    echo "❌ App bundle not found at $APP_PATH"
    exit 1
fi

echo ""
echo "📱 Installing to connected devices..."

for id in $device_ids; do
    echo "---------------------------------------------------"
    echo "📲 Deploying to device ID: $id"
    # ios-deploy flags: 
    # -i <id>: specify device
    # -b <path>: bundle path
    # --justlaunch: launch and exit debugger (optional, but good for "install & run")
    # --debug: launch in debug mode (optional)
    
    ios-deploy --id "$id" --bundle "$APP_PATH" --justlaunch --no-wifi
    echo "✅ Installed on $id"
done

echo ""
echo "🎉 Deployment complete for all devices!"
