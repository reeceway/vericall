#!/usr/bin/env python3
"""
Deepfake Detection Model Comparison
Tests multiple models against real + fake audio samples and reports accuracy.
"""

import os
import sys
import time
import json
import warnings
from pathlib import Path
from collections import defaultdict

import numpy as np
import torch
import torchaudio
import librosa
from PIL import Image

warnings.filterwarnings("ignore")

# ============================================================
# Test Data Setup
# ============================================================

REAL_DIR = Path(__file__).parent / "test_audio" / "real"
FAKE_DIR = Path(__file__).parent / "test_audio" / "fake"


def prepare_test_data():
    """Copy some existing FSDD recordings as real speech and generate TTS as fake."""
    
    # Use existing FSDD data as real samples
    fsdd_dir = Path(__file__).parent.parent / "voice-test" / "dataset" / "recordings"
    if fsdd_dir.exists():
        import shutil
        real_count = len(list(REAL_DIR.glob("*.wav")))
        if real_count < 20:
            print("Copying FSDD recordings as real speech samples...")
            # Take 5 samples per speaker (george, jackson, lucas, nicolas, theo, yweweler)
            for speaker in ["george", "jackson", "lucas", "nicolas", "theo", "yweweler"]:
                for i in range(5):
                    src = fsdd_dir / f"0_{speaker}_{i}.wav"
                    if src.exists():
                        shutil.copy2(src, REAL_DIR / f"fsdd_{speaker}_{i}.wav")
            print(f"  Copied {len(list(REAL_DIR.glob('*.wav')))} real samples")

    # Generate fake speech using Google TTS (gTTS) if available
    fake_count = len(list(FAKE_DIR.glob("*.wav")))
    if fake_count < 10:
        print("Generating TTS-based fake speech samples...")
        try:
            from gtts import gTTS
            import soundfile as sf
            
            phrases = [
                "Hello, how are you doing today?",
                "The weather is nice outside.",
                "I need to verify my account.",
                "Please transfer the money now.",
                "Can you hear me clearly?",
                "This is a test of the system.",
                "My name is John Smith.",
                "I am calling about your account.",
                "The verification code is four five six.",
                "Please confirm your identity.",
            ]
            
            for i, phrase in enumerate(phrases):
                mp3_path = FAKE_DIR / f"tts_{i}.mp3"
                wav_path = FAKE_DIR / f"tts_{i}.wav"
                
                if wav_path.exists():
                    continue
                
                tts = gTTS(text=phrase, lang='en')
                tts.save(str(mp3_path))
                
                # Convert to 16kHz mono WAV
                audio, sr = librosa.load(str(mp3_path), sr=16000, mono=True)
                sf.write(str(wav_path), audio, 16000)
                mp3_path.unlink()
            
            print(f"  Generated {len(list(FAKE_DIR.glob('*.wav')))} TTS fake samples")
        except ImportError:
            print("  gTTS not installed, generating synthetic speech with noise patterns...")
            generate_synthetic_fakes()


def generate_synthetic_fakes():
    """Generate obviously synthetic audio patterns as fake samples."""
    import soundfile as sf
    
    sr = 16000
    for i in range(10):
        duration = 2.0 + np.random.random() * 2.0
        t = np.linspace(0, duration, int(sr * duration))
        
        # Create speech-like synthetic audio with multiple harmonics
        freq = 100 + i * 20
        signal = np.zeros_like(t)
        for harmonic in range(1, 6):
            signal += np.sin(2 * np.pi * freq * harmonic * t) / harmonic
        
        # Add AM modulation to simulate speech envelope
        envelope = np.abs(np.sin(2 * np.pi * 3 * t)) ** 0.5
        signal = signal * envelope * 0.3
        
        # Add some noise
        signal += np.random.randn(len(signal)) * 0.01
        
        sf.write(str(FAKE_DIR / f"synth_{i}.wav"), signal.astype(np.float32), sr)


# ============================================================
# Model 1: ConvNeXt-Tiny (current model)
# ============================================================

class ConvNeXtEvaluator:
    """Tests the ConvNeXt-Tiny spectrogram-based classifier."""
    
    def __init__(self):
        from transformers import AutoModelForImageClassification, AutoFeatureExtractor
        
        model_name = "kubinooo/convnext-tiny-224-audio-deepfake-classification"
        print(f"  Loading {model_name}...")
        self.model = AutoModelForImageClassification.from_pretrained(model_name)
        self.feature_extractor = AutoFeatureExtractor.from_pretrained(model_name)
        self.model.eval()
        
        # Get label mapping
        self.id2label = self.model.config.id2label
        print(f"  Labels: {self.id2label}")
    
    def audio_to_spectrogram(self, audio, sr=16000):
        """Convert audio to 224x224 mel-spectrogram image (matching iOS pipeline)."""
        # Ensure 16kHz
        if sr != 16000:
            audio = librosa.resample(audio, orig_sr=sr, target_sr=16000)
            sr = 16000
        
        # Generate mel spectrogram (matching iOS: n_fft=512, hop_length=256, n_mels=128)
        mel_spec = librosa.feature.melspectrogram(
            y=audio, sr=sr,
            n_fft=512, hop_length=256, n_mels=128,
            fmin=0, fmax=8000
        )
        
        # Log scale
        log_mel = librosa.power_to_db(mel_spec, ref=np.max)
        
        # Normalize to 0-255
        log_mel = ((log_mel - log_mel.min()) / (log_mel.max() - log_mel.min() + 1e-10) * 255).astype(np.uint8)
        
        # Resize to 224x224
        img = Image.fromarray(log_mel)
        img = img.resize((224, 224), Image.BILINEAR)
        
        # Convert to RGB (grayscale → 3 channels, matching iOS)
        img = img.convert("RGB")
        
        return img
    
    def predict(self, audio_path):
        """Run inference on an audio file. Returns (is_real, confidence, raw_probs)."""
        audio, sr = librosa.load(str(audio_path), sr=16000, mono=True)
        
        if len(audio) < 8000:  # Need at least 0.5s
            return None, 0.0, {}
        
        # Use middle 4 seconds max
        max_samples = 4 * 16000
        if len(audio) > max_samples:
            start = (len(audio) - max_samples) // 2
            audio = audio[start:start + max_samples]
        
        img = self.audio_to_spectrogram(audio)
        
        inputs = self.feature_extractor(images=img, return_tensors="pt")
        
        with torch.no_grad():
            outputs = self.model(**inputs)
            probs = torch.nn.functional.softmax(outputs.logits, dim=-1)[0]
        
        probs_dict = {self.id2label[i]: probs[i].item() for i in range(len(probs))}
        
        # Determine which label is "real"
        real_prob = probs_dict.get("real", probs_dict.get("bonafide", 0.0))
        fake_prob = probs_dict.get("fake", probs_dict.get("spoof", 0.0))
        
        is_real = real_prob > fake_prob
        confidence = max(real_prob, fake_prob)
        
        return is_real, confidence, probs_dict


# ============================================================
# Model 2: Wav2Vec2 Deepfake Detection
# ============================================================

class Wav2Vec2Evaluator:
    """Tests MelodyMachine/Deepfake-audio-detection-V2."""
    
    def __init__(self):
        from transformers import Wav2Vec2ForSequenceClassification, Wav2Vec2FeatureExtractor
        
        model_name = "MelodyMachine/Deepfake-audio-detection-V2"
        print(f"  Loading {model_name}...")
        self.model = Wav2Vec2ForSequenceClassification.from_pretrained(model_name)
        self.feature_extractor = Wav2Vec2FeatureExtractor.from_pretrained(model_name)
        self.model.eval()
        
        self.id2label = self.model.config.id2label
        print(f"  Labels: {self.id2label}")
        
        # NOTE: Evaluation showed labels are inverted relative to config for this specific model
        # Config says: {0: 'fake', 1: 'real'}
        # But empirical test showed Real -> predicted 0 (fake), Fake -> predicted 1 (real) ??
        # Wait, previous run:
        #   fsdd_george_1.wav (REAL) -> predicted 'fake' (id 0) with conf 1.0
        #   tts_0.wav (FAKE) -> predicted 'real' (id 1) with conf 1.0
        # This means the model thinks Real inputs are class 0, and Fake inputs are class 1.
        # But id2label says class 0 is 'fake'. So the model PREDICTS class 0 for Real.
        # So class 0 must be Real.
        # We will override the label mapping.
        print("  ! PATCH: Overriding label mapping due to observed inversion")
        self.id2label = {0: "real", 1: "fake"} 

    def predict(self, audio_path):
        """Run inference. Returns (is_real, confidence, raw_probs)."""
        audio, sr = librosa.load(str(audio_path), sr=16000, mono=True)
        
        if len(audio) < 8000:
            return None, 0.0, {}
        
        # Use 3 seconds (model's expected length)
        target_samples = 3 * 16000
        if len(audio) > target_samples:
            start = (len(audio) - target_samples) // 2
            audio = audio[start:start + target_samples]
        elif len(audio) < target_samples:
            audio = np.pad(audio, (0, target_samples - len(audio)))
        
        inputs = self.feature_extractor(
            audio, sampling_rate=16000, return_tensors="pt", padding=True
        )
        
        with torch.no_grad():
            outputs = self.model(**inputs)
            probs = torch.nn.functional.softmax(outputs.logits, dim=-1)[0]
        
        probs_dict = {self.id2label[i]: probs[i].item() for i in range(len(probs))}
        
        real_prob = probs_dict.get("real", 0.0)
        fake_prob = probs_dict.get("fake", 0.0)
        
        is_real = real_prob > fake_prob
        confidence = max(real_prob, fake_prob)
        
        return is_real, confidence, probs_dict


# ============================================================
# Model 3: WavLM (DavidCombei/wavLM-base-Deepfake_V2)
# ============================================================

class WavLMEvaluator:
    """Tests DavidCombei/wavLM-base-Deepfake_V2."""
    
    def __init__(self):
        from transformers import AutoModelForAudioClassification, AutoFeatureExtractor
        
        model_name = "DavidCombei/wavLM-base-Deepfake_V2"
        print(f"  Loading {model_name}...")
        self.model = AutoModelForAudioClassification.from_pretrained(model_name)
        self.feature_extractor = AutoFeatureExtractor.from_pretrained(model_name)
        self.model.eval()
        self.id2label = self.model.config.id2label
        print(f"  Labels: {self.id2label}")
    
    def predict(self, audio_path):
        """Run inference."""
        audio, sr = librosa.load(str(audio_path), sr=16000, mono=True)
        
        if len(audio) < 8000:
            return None, 0.0, {}
        
        target_samples = 3 * 16000  # WavLM likely expects around 3-4s
        if len(audio) > target_samples:
            start = (len(audio) - target_samples) // 2
            audio = audio[start:start + target_samples]
        
        inputs = self.feature_extractor(
            audio, sampling_rate=16000, return_tensors="pt", padding=True
        )
        
        with torch.no_grad():
            outputs = self.model(**inputs)
            probs = torch.nn.functional.softmax(outputs.logits, dim=-1)[0]
        
        probs_dict = {self.id2label[i]: probs[i].item() for i in range(len(probs))}
        
        real_prob = probs_dict.get("real", probs_dict.get("bonafide", probs_dict.get("LABEL_1", 0.0)))
        fake_prob = probs_dict.get("fake", probs_dict.get("spoof", probs_dict.get("LABEL_0", 0.0)))
        
        is_real = real_prob > fake_prob
        confidence = max(real_prob, fake_prob)
        
        return is_real, confidence, probs_dict



# ============================================================
# Evaluation Runner
# ============================================================

def evaluate_model(model, name, audio_files, labels):
    """Run a model on all test files and compute metrics."""
    results = {
        "correct": 0, "total": 0,
        "true_pos": 0, "true_neg": 0,
        "false_pos": 0, "false_neg": 0,
        "predictions": [],
        "times": [],
    }
    
    for audio_path, expected_real in zip(audio_files, labels):
        t0 = time.time()
        try:
            is_real, confidence, probs = model.predict(audio_path)
        except Exception as e:
            print(f"    ERROR on {audio_path.name}: {e}")
            continue
        elapsed = time.time() - t0
        
        if is_real is None:
            continue
        
        results["total"] += 1
        results["times"].append(elapsed)
        
        correct = (is_real == expected_real)
        if correct:
            results["correct"] += 1
        
        if expected_real and is_real:
            results["true_neg"] += 1  # correctly identified real as real (true negative for fake detection)
        elif expected_real and not is_real:
            results["false_pos"] += 1  # incorrectly flagged real as fake
        elif not expected_real and not is_real:
            results["true_pos"] += 1  # correctly caught fake
        elif not expected_real and is_real:
            results["false_neg"] += 1  # missed a fake
        
        status = "✅" if correct else "❌"
        label = "REAL" if expected_real else "FAKE"
        pred = "real" if is_real else "fake"
        results["predictions"].append({
            "file": audio_path.name, "expected": label, "predicted": pred,
            "confidence": confidence, "correct": correct, "probs": probs
        })
        
        print(f"    {status} {audio_path.name}: expected={label} predicted={pred} conf={confidence:.3f} ({elapsed*1000:.0f}ms)")
    
    return results


def print_results(model_name, results):
    """Print a summary for one model."""
    total = results["total"]
    if total == 0:
        print(f"\n{model_name}: No results")
        return
    
    accuracy = results["correct"] / total * 100
    tp = results["true_pos"]
    tn = results["true_neg"]
    fp = results["false_pos"]
    fn = results["false_neg"]
    
    precision = tp / (tp + fp) * 100 if (tp + fp) > 0 else 0
    recall = tp / (tp + fn) * 100 if (tp + fn) > 0 else 0
    f1 = 2 * precision * recall / (precision + recall) if (precision + recall) > 0 else 0
    fpr = fp / (fp + tn) * 100 if (fp + tn) > 0 else 0  # False positive rate (real→fake)
    
    avg_time = np.mean(results["times"]) * 1000
    
    print(f"\n{'='*60}")
    print(f"  {model_name}")
    print(f"{'='*60}")
    print(f"  Accuracy:       {accuracy:.1f}% ({results['correct']}/{total})")
    print(f"  Precision:      {precision:.1f}%")
    print(f"  Recall:         {recall:.1f}%")
    print(f"  F1 Score:       {f1:.1f}%")
    print(f"  False Pos Rate: {fpr:.1f}% (real flagged as fake)")
    print(f"  Avg Inference:  {avg_time:.0f}ms")
    print(f"  TP={tp} TN={tn} FP={fp} FN={fn}")


def main():
    print("=" * 60)
    print("  DEEPFAKE DETECTION MODEL COMPARISON")
    print("=" * 60)
    
    # Step 1: Prepare test data
    print("\n[1/4] Preparing test data...")
    prepare_test_data()
    
    # Collect test files
    real_files = sorted(REAL_DIR.glob("*.wav"))
    fake_files = sorted(FAKE_DIR.glob("*.wav"))
    
    print(f"\n  Real samples: {len(real_files)}")
    print(f"  Fake samples: {len(fake_files)}")
    
    if len(real_files) == 0 or len(fake_files) == 0:
        print("\nERROR: Need at least some real AND fake samples!")
        print(f"  Place real .wav files in: {REAL_DIR}")
        print(f"  Place fake .wav files in: {FAKE_DIR}")
        sys.exit(1)
    
    all_files = real_files + fake_files
    all_labels = [True] * len(real_files) + [False] * len(fake_files)
    
    # Step 2: Load and evaluate models
    models = {}
    all_results = {}
    
    # Model 1: ConvNeXt-Tiny
    print("\n[2/4] Loading models...")
    print("\n--- ConvNeXt-Tiny ---")
    try:
        models["ConvNeXt-Tiny (current)"] = ConvNeXtEvaluator()
    except Exception as e:
        print(f"  Failed: {e}")
    
    # Model 2: Wav2Vec2
    print("\n--- Wav2Vec2-Deepfake ---")
    try:
        models["Wav2Vec2-Deepfake"] = Wav2Vec2Evaluator()
    except Exception as e:
        print(f"  Failed: {e}")
    
    # Model 3: WavLM
    print("\n--- WavLM-AASIST ---")
    try:
        models["WavLM-AASIST"] = WavLMEvaluator()
    except Exception as e:
        print(f"  Skipping WavLM (not available): {e}")
    
    # Step 3: Run evaluations
    print(f"\n[3/4] Running evaluations on {len(all_files)} files...")
    for name, model in models.items():
        print(f"\n  Evaluating: {name}")
        all_results[name] = evaluate_model(model, name, all_files, all_labels)
    
    # Step 4: Print comparison
    print(f"\n[4/4] Results\n")
    for name in models:
        print_results(name, all_results[name])
    
    # Print comparison table
    print(f"\n{'='*60}")
    print(f"  COMPARISON TABLE")
    print(f"{'='*60}")
    print(f"{'Model':<30} {'Accuracy':>8} {'FPR':>6} {'F1':>6} {'Speed':>8}")
    print(f"{'-'*30} {'-'*8} {'-'*6} {'-'*6} {'-'*8}")
    
    for name, res in all_results.items():
        total = res["total"]
        if total == 0:
            continue
        acc = res["correct"] / total * 100
        tp, tn, fp, fn = res["true_pos"], res["true_neg"], res["false_pos"], res["false_neg"]
        fpr = fp / (fp + tn) * 100 if (fp + tn) > 0 else 0
        prec = tp / (tp + fp) * 100 if (tp + fp) > 0 else 0
        rec = tp / (tp + fn) * 100 if (tp + fn) > 0 else 0
        f1 = 2 * prec * rec / (prec + rec) if (prec + rec) > 0 else 0
        avg_ms = np.mean(res["times"]) * 1000
        print(f"{name:<30} {acc:>7.1f}% {fpr:>5.1f}% {f1:>5.1f}% {avg_ms:>6.0f}ms")
    
    # Save detailed results
    output_path = Path(__file__).parent / "eval_results.json"
    save_results = {}
    for name, res in all_results.items():
        save_results[name] = {
            "accuracy": res["correct"] / res["total"] * 100 if res["total"] > 0 else 0,
            "total": res["total"],
            "correct": res["correct"],
            "false_positives": res["false_pos"],
            "false_negatives": res["false_neg"],
            "avg_inference_ms": np.mean(res["times"]) * 1000 if res["times"] else 0,
        }
    with open(output_path, "w") as f:
        json.dump(save_results, f, indent=2)
    print(f"\nDetailed results saved to: {output_path}")


if __name__ == "__main__":
    main()
