#!/bin/bash
# Final checklist before demo

echo "🎯 VERICALL - PRE-DEMO CHECKLIST"
echo "==================================="
echo ""

PROJECT_DIR="/opt/moltbot/.openclaw/workspace/projects/vericall"

echo "📁 Project Structure Check:"
echo "----------------------------"

# Check backend files
if [ -f "$PROJECT_DIR/backend/app/main.py" ]; then
    echo "✅ Backend main.py exists"
else
    echo "❌ Backend main.py missing"
fi

if [ -f "$PROJECT_DIR/backend/fly.toml" ]; then
    echo "✅ fly.toml exists"
else
    echo "❌ fly.toml missing"
fi

if [ -f "$PROJECT_DIR/backend/deploy.sh" ]; then
    echo "✅ deploy.sh exists"
else
    echo "❌ deploy.sh missing"
fi

# Check iOS files
if [ -d "$PROJECT_DIR/ios/VeriCall.xcodeproj" ]; then
    echo "✅ Xcode project exists"
else
    echo "❌ Xcode project missing"
fi

if [ -f "$PROJECT_DIR/ios/VeriCall/App/Constants.swift" ]; then
    echo "✅ iOS Constants.swift exists"
else
    echo "❌ iOS Constants.swift missing"
fi

if [ -f "$PROJECT_DIR/ios/VeriCall/Services/DeviceCrypto.swift" ]; then
    echo "✅ DeviceCrypto.swift exists"
else
    echo "❌ DeviceCrypto.swift missing"
fi

# Check docs
if [ -f "$PROJECT_DIR/TECH_SPEC.md" ]; then
    echo "✅ TECH_SPEC.md exists"
else
    echo "❌ TECH_SPEC.md missing"
fi

if [ -f "$PROJECT_DIR/DEPLOY_AND_TEST.md" ]; then
    echo "✅ DEPLOY_AND_TEST.md exists"
else
    echo "❌ DEPLOY_AND_TEST.md missing"
fi

echo ""
echo "📊 Code Stats:"
echo "--------------"
echo "Swift files: $(find $PROJECT_DIR/ios -name '*.swift' 2>/dev/null | wc -l)"
echo "Python files: $(find $PROJECT_DIR/backend -name '*.py' 2>/dev/null | wc -l)"

echo ""
echo "🚀 NEXT ACTIONS:"
echo "----------------"
echo "1. Deploy backend:"
echo "   cd $PROJECT_DIR/backend && ./deploy.sh"
echo ""
echo "2. Build iOS app:"
echo "   open $PROJECT_DIR/ios/VeriCall.xcodeproj"
echo ""
echo "3. Test with 2 phones"
echo ""
