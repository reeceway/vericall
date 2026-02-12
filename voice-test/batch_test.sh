#!/bin/bash
# Batch test: concatenate FSDD recordings per speaker, then run all-vs-all comparison
# Each speaker gets 2 groups of recordings to test same-speaker AND cross-speaker

set -e
cd "$(dirname "$0")"

DATASET_DIR="dataset/recordings"
TEST_DIR="test_audio"
mkdir -p "$TEST_DIR"

SPEAKERS=(george jackson lucas nicolas theo yweweler)

echo "=== Building concatenated audio files per speaker ==="
for speaker in "${SPEAKERS[@]}"; do
    # Group A: digits 0-4 (instances 0-9 each = 50 files)
    echo "  Building ${speaker}_A.wav ..."
    files_a=()
    for digit in 0 1 2 3 4; do
        for inst in $(seq 0 9); do
            f="${DATASET_DIR}/${digit}_${speaker}_${inst}.wav"
            if [ -f "$f" ]; then files_a+=("$f"); fi
        done
    done
    # Use sox or ffmpeg to concatenate - try sox first, fallback to ffmpeg
    if command -v sox &>/dev/null; then
        sox "${files_a[@]}" "$TEST_DIR/${speaker}_A.wav" 2>/dev/null
    else
        # ffmpeg concat
        list_file=$(mktemp)
        for f in "${files_a[@]}"; do echo "file '$(pwd)/$f'" >> "$list_file"; done
        ffmpeg -y -f concat -safe 0 -i "$list_file" "$TEST_DIR/${speaker}_A.wav" -loglevel error 2>/dev/null
        rm "$list_file"
    fi

    # Group B: digits 5-9 (instances 0-9 each = 50 files)  
    echo "  Building ${speaker}_B.wav ..."
    files_b=()
    for digit in 5 6 7 8 9; do
        for inst in $(seq 0 9); do
            f="${DATASET_DIR}/${digit}_${speaker}_${inst}.wav"
            if [ -f "$f" ]; then files_b+=("$f"); fi
        done
    done
    if command -v sox &>/dev/null; then
        sox "${files_b[@]}" "$TEST_DIR/${speaker}_B.wav" 2>/dev/null
    else
        list_file=$(mktemp)
        for f in "${files_b[@]}"; do echo "file '$(pwd)/$f'" >> "$list_file"; done
        ffmpeg -y -f concat -safe 0 -i "$list_file" "$TEST_DIR/${speaker}_B.wav" -loglevel error 2>/dev/null
        rm "$list_file"
    fi
done

echo ""
echo "=== SAME-SPEAKER tests (should be MATCH, >72%) ==="
for speaker in "${SPEAKERS[@]}"; do
    swift run VoiceTest filevs "$TEST_DIR/${speaker}_A.wav" "$TEST_DIR/${speaker}_B.wav" 2>&1 | grep -E "Similarity|Result|FILE"
    echo ""
done

echo "=== CROSS-SPEAKER tests (should be NO MATCH, <72%) ==="
for i in "${!SPEAKERS[@]}"; do
    for j in "${!SPEAKERS[@]}"; do
        if [ "$j" -gt "$i" ]; then
            swift run VoiceTest filevs "$TEST_DIR/${SPEAKERS[$i]}_A.wav" "$TEST_DIR/${SPEAKERS[$j]}_A.wav" 2>&1 | grep -E "Similarity|Result|FILE"
            echo ""
        fi
    done
done
