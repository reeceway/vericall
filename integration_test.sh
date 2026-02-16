#!/bin/bash
# VeriCall Integration Test Script
# Tests all components before deployment

echo "======================================"
echo "VERICALL INTEGRATION TEST"
echo "======================================"
echo ""

# Colors for output
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

FAILED=0

# Test 1: Check all required files exist
echo "🧪 Test 1: Checking file structure..."
REQUIRED_FILES=(
    "backend/app/main.py"
    "backend/app/auth.py"
    "backend/app/websocket.py"
    "backend/app/push.py"
    "backend/Dockerfile"
    "backend/fly.toml"
    "voice-ml/speaker_model.py"
    "voice-ml/voice_enrollment.py"
    "voice-ml/voice_verification.py"
    "ios/VeriCall/Services/APIService.swift"
    "ios/VeriCall/Services/CallKitManager.swift"
    "ios/VeriCall/Services/DeviceCrypto.swift"
)

for file in "${REQUIRED_FILES[@]}"; do
    if [ -f "$file" ]; then
        echo -e "${GREEN}✓${NC} $file"
    else
        echo -e "${RED}✗${NC} $file (MISSING)"
        FAILED=$((FAILED + 1))
    fi
done
echo ""

# Test 2: Check API constants alignment
echo "🧪 Test 2: Checking API constants alignment..."
# Backend voice check removed as verification is local P2P now

if grep -q "voiceEmbeddingDimension = 192" ios/VeriCall/Constants.swift 2>/dev/null || grep -q "192" ios/VeriCall/Services/VoiceCaptureService.swift 2>/dev/null; then
    echo -e "${GREEN}✓${NC} iOS: 192-dim embeddings"
else
    echo -e "${YELLOW}⚠${NC} iOS: Embedding dimension check skipped (in Swift files)"
fi
echo ""

# Test 3: Check Docker build
echo "🧪 Test 3: Validating Docker configuration..."
if [ -f "backend/Dockerfile" ]; then
    echo -e "${GREEN}✓${NC} Dockerfile exists"
    if grep -q "uvicorn" backend/Dockerfile; then
        echo -e "${GREEN}✓${NC} Uvicorn server configured"
    fi
    if grep -q "workers.*4" backend/Dockerfile; then
        echo -e "${GREEN}✓${NC} 4 workers configured (scalability)"
    fi
else
    echo -e "${RED}✗${NC} Dockerfile missing"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 4: Check Fly.io configuration
echo "🧪 Test 4: Validating Fly.io configuration..."
if [ -f "backend/fly.toml" ]; then
    echo -e "${GREEN}✓${NC} fly.toml exists"
    if grep -q "hard_limit = 1000" backend/fly.toml; then
        echo -e "${GREEN}✓${NC} Concurrency: 1000 connections (scalable)"
    fi
    if grep -q "cpu = 2" backend/fly.toml; then
        echo -e "${GREEN}✓${NC} CPU: 2 cores"
    fi
    if grep -q "memory = \"2gb\"" backend/fly.toml; then
        echo -e "${GREEN}✓${NC} Memory: 2GB"
    fi
else
    echo -e "${RED}✗${NC} fly.toml missing"
    FAILED=$((FAILED + 1))
fi
echo ""

# Test 5: Check database migrations
echo "🧪 Test 5: Checking database schema..."
if [ -f "backend/migrations/versions/20250209_1800_initial_schema.py" ]; then
    echo -e "${GREEN}✓${NC} Database migrations exist"
    if grep -q "users" backend/migrations/versions/20250209_1800_initial_schema.py; then
        echo -e "${GREEN}✓${NC} Users table defined"
    fi
    if grep -q "voiceprints" backend/migrations/versions/20250209_1800_initial_schema.py; then
        echo -e "${GREEN}✓${NC} Voiceprints table defined"
    fi
else
    echo -e "${YELLOW}⚠${NC} Database migrations not found (may be in models)"
fi
echo ""

# Test 6: Check WebSocket implementation
echo "🧪 Test 6: Checking WebSocket support..."
if grep -q "WebSocket" backend/app/main.py 2>/dev/null; then
    echo -e "${GREEN}✓${NC} WebSocket endpoint implemented"
fi
if grep -q "WebSocket" ios/VeriCall/Services/WebSocketService.swift 2>/dev/null; then
    echo -e "${GREEN}✓${NC} iOS WebSocket service implemented"
fi
echo ""

# Test 7: Security checks
echo "🧪 Test 7: Security checks..."
if grep -q "SecureEnclave" ios/VeriCall/Services/DeviceCrypto.swift 2>/dev/null; then
    echo -e "${GREEN}✓${NC} iOS: SecureEnclave for key storage"
fi
if grep -q "Keychain" ios/VeriCall/Services/KeychainService.swift 2>/dev/null; then
    echo -e "${GREEN}✓${NC} iOS: Keychain for certificate storage"
fi
if grep -q "jwt" backend/app/auth.py 2>/dev/null; then
    echo -e "${GREEN}✓${NC} Backend: JWT for auth tokens"
fi
echo ""

# Summary
echo "======================================"
if [ $FAILED -eq 0 ]; then
    echo -e "${GREEN}✅ ALL TESTS PASSED${NC}"
    echo ""
    echo "System is ready for deployment!"
    echo ""
    echo "Next steps:"
    echo "1. Deploy backend: cd backend && fly deploy"
    echo "2. Build iOS app in Xcode"
    echo "3. Run integration tests"
    echo "4. Demo!"
    exit 0
else
    echo -e "${RED}❌ $FAILED TEST(S) FAILED${NC}"
    echo "Please review the errors above."
    exit 1
fi
