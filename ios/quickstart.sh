#!/bin/bash
# Quick start script for VeriCall

echo "🚀 VERICALL - QUICK START"
echo "=========================="
echo ""

# Check if running on macOS
if [[ "$OSTYPE" != "darwin"* ]]; then
    echo "❌ This script must be run on macOS with Xcode installed"
    exit 1
fi

# Check if Xcode is installed
if ! command -v xcodebuild &> /dev/null; then
    echo "❌ Xcode not found. Please install Xcode from the App Store"
    exit 1
fi

echo "✅ Xcode found"

# Open project
echo ""
echo "📱 Opening VeriCall.xcodeproj..."
open "$(dirname "$0")/VeriCall.xcodeproj"

echo ""
echo "📋 NEXT STEPS:"
echo "=============="
echo ""
echo "1. SELECT YOUR TEAM"
echo "   - In Xcode, click on 'VeriCall' in the left sidebar"
echo "   - Go to 'Signing & Capabilities' tab"
echo "   - Set 'Team' to your Apple Developer account"
echo ""
echo "2. CONNECT YOUR IPHONE"
echo "   - Connect first iPhone via USB"
echo "   - Select it from the device dropdown (top of Xcode window)"
echo ""
echo "3. BUILD & RUN"
echo "   - Press Cmd+R to build and run"
echo "   - The app will install on your iPhone"
echo ""
echo "4. REPEAT ON SECOND IPHONE"
echo "   - Connect second iPhone"
echo "   - Select it and press Cmd+R again"
echo ""
echo "5. TEST THE DEMO"
echo "   - Open DEPLOY_AND_TEST.md for full testing guide"
echo ""
