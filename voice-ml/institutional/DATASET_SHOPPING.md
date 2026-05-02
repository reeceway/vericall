# Dataset Shopping: Clone Detection + Speaker Verification

Goal: maximize **speaker diversity** and **clone diversity**, then convert all audio into VeriCall pipeline acoustics.

## Best Sources (Primary)

### Speaker verification / real-human speech

1. LibriSpeech (OpenSLR 12)
   - https://www.openslr.org/12
   - Large speaker diversity and clean transcripts.
2. VoxCeleb 1/2 (official)
   - https://www.robots.ox.ac.uk/~vgg/data/voxceleb/
   - In-the-wild speech with channel variability.
3. Mozilla Common Voice
   - https://commonvoice.mozilla.org/en/datasets
   - Broad accents and real-world recording conditions.
4. VCTK Corpus
   - https://datashare.ed.ac.uk/handle/10283/3443
   - Multi-speaker English with consistent metadata.

### Voice-clone / deepfake detection

1. ASVspoof Challenges (official)
   - https://www.asvspoof.org/
   - Core benchmark for spoofed and synthesized speech.
2. WaveFake (official release)
   - https://zenodo.org/records/5643015
   - Large synthetic/deepfake speech collection.
3. FakeAVCeleb
   - https://github.com/DASH-Lab/FakeAVCeleb
   - Audio/video deepfake corpus with spoof labels.

## Data Closest to Your Runtime Conditions

Prioritize these first for better production transfer:

1. ASVspoof 2021/2024 tracks (codec/channel effects).
2. VoxCeleb (in-the-wild channel variability).
3. Your own VeriCall captures (`VerificationDataset`) from mixed networks.

Then run all through pipeline shaping (telephony band-limit, noise, packet-loss, companding) using:

- `voice-ml/institutional/build_supervised_audio_corpus.py`

## Download-ready commands already used

```bash
git clone --depth 1 https://github.com/Jakobovski/free-spoken-digit-dataset.git datasets/raw/fsdd

curl -L -o datasets/raw/test-clean.tar.gz https://www.openslr.org/resources/12/test-clean.tar.gz
tar -xzf datasets/raw/test-clean.tar.gz -C datasets/raw

curl -L -o datasets/raw/train-clean-100.tar.gz https://www.openslr.org/resources/12/train-clean-100.tar.gz
tar -xzf datasets/raw/train-clean-100.tar.gz -C datasets/raw

# Public clone-detection corpus (Hugging Face)
GIT_LFS_SKIP_SMUDGE=1 git clone https://huggingface.co/datasets/garystafford/deepfake-audio-detection datasets/raw/hf-deepfake-audio
cd datasets/raw/hf-deepfake-audio
git lfs pull --include 'fake/*,real/*'
```

## Practical scaling strategy

1. Real-human pool: LibriSpeech + VoxCeleb + Common Voice + VeriCall captures.
2. Clone pool: ASVspoof + WaveFake + FakeAVCeleb + local TTS generation.
3. Pipeline-shape all sources to your production transport profile.
4. Keep train/val/test split by speaker/session group to avoid leakage.
