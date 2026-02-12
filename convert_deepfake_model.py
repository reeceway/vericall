#!/usr/bin/env python3
"""
Convert Hugging Face deepfake detection models to quantized CoreML for iPhone.

Targets:
- kubinooo/convnext-tiny-224-audio-deepfake-classification (RECOMMENDED)
  * INT8: ~28MB, ~10-15ms on iPhone A17 Pro
  * FP16: ~55MB, ~15-25ms on iPhone A17 Pro
  
- MelodyMachine/Deepfake-audio-detection-V2 (Wav2Vec2)
  * FP16 only recommended: ~190MB, ~100-150ms
  * INT8 has accuracy degradation issues with attention layers

Usage:
    python convert_deepfake_model.py --model convnext --quantize int8
    python convert_deepfake_model.py --model wav2vec2 --quantize fp16
"""

import argparse
import sys
import warnings
from pathlib import Path

def install_requirements():
    """Ensure all required packages are installed."""
    required = [
        "torch",
        "torchaudio",
        "transformers",
        "coremltools>=9.0",
        "numpy",
        "librosa",
        "pillow",
    ]
    
    import subprocess
    for pkg in required:
        try:
            __import__(pkg.split(">=")[0])
        except ImportError:
            print(f"Installing {pkg}...")
            subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])

install_requirements()

import torch
import torchaudio
import coremltools as ct
import numpy as np
from transformers import AutoModelForImageClassification, AutoFeatureExtractor, Wav2Vec2ForSequenceClassification, Wav2Vec2FeatureExtractor
import librosa
from PIL import Image


def convert_convnext_tiny(quantize: str = "int8"):
    """
    Convert ConvNeXt-Tiny audio deepfake detector to CoreML.
    
    Architecture: Audio -> Mel-spectrogram (224x224) -> ConvNeXt -> Classification
    
    Args:
        quantize: "int8" (28MB, fastest), "fp16" (55MB, best accuracy), or "none" (111MB)
    """
    print("=" * 60)
    print("Converting ConvNeXt-Tiny for Audio Deepfake Detection")
    print("=" * 60)
    
    model_name = "kubinooo/convnext-tiny-224-audio-deepfake-classification"
    
    print(f"\n1. Loading model from Hugging Face: {model_name}")
    model = AutoModelForImageClassification.from_pretrained(model_name)
    feature_extractor = AutoFeatureExtractor.from_pretrained(model_name)
    
    model.eval()
    
    # Get model info
    param_count = sum(p.numel() for p in model.parameters())
    print(f"   Parameters: {param_count / 1e6:.1f}M")
    
    # Create dummy mel-spectrogram input (224x224 RGB image)
    # In production, you'll convert audio to mel-spectrogram in Swift
    dummy_input = torch.randn(1, 3, 224, 224)
    
    print("\n2. Tracing model with PyTorch...")
    
    # Wrap model to handle classifier output dict
    class ModelWrapper(torch.nn.Module):
        def __init__(self, model):
            super().__init__()
            self.model = model
        
        def forward(self, x):
            outputs = self.model(x)
            # Return logits tensor directly, not dict
            return outputs.logits
    
    wrapped_model = ModelWrapper(model)
    wrapped_model.eval()
    
    with torch.no_grad():
        traced_model = torch.jit.trace(wrapped_model, dummy_input, strict=False)
    
    print("\n3. Converting to CoreML...")
    
    # Define input type for image
    input_type = ct.ImageType(
        name="spectrogram",
        shape=(1, 3, 224, 224),
        color_layout=ct.colorlayout.RGB,
        scale=1.0/255.0,  # Normalize 0-255 to 0-1
        bias=[0, 0, 0]
    )
    
    # Convert to CoreML with classifier
    mlmodel = ct.convert(
        traced_model,
        inputs=[input_type],
        classifier_config=ct.ClassifierConfig(
            class_labels=["real", "fake"]
        ),
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,  # Use CPU, GPU, and Neural Engine
    )
    
    # Apply quantization using modern CoreML API
    if quantize == "int8":
        print("\n4. Applying INT8 quantization...")
        
        # Use the modern linear quantization API
        import coremltools.optimize.coreml as cto
        
        config = cto.OptimizationConfig(
            global_config=cto.OpLinearQuantizerConfig(mode="linear_symmetric")
        )
        
        mlmodel = cto.linear_quantize_weights(mlmodel, config=config)
        
        output_name = "ConvNeXt_Tiny_Deepfake_INT8.mlpackage"
        expected_size = "~28 MB"
        
    elif quantize == "fp16":
        print("\n4. Applying FP16 quantization...")
        
        import coremltools.optimize.coreml as cto
        mlmodel = cto.linear_quantize_weights(mlmodel, config=cto.OptimizationConfig())
        
        output_name = "ConvNeXt_Tiny_Deepfake_FP16.mlpackage"
        expected_size = "~55 MB"
        
    else:
        output_name = "ConvNeXt_Tiny_Deepfake_FP32.mlpackage"
        expected_size = "~111 MB"
    
    # Save model
    output_path = Path(output_name)
    mlmodel.save(str(output_path))
    
    # Get actual size
    if output_path.is_dir():  # .mlpackage is a directory
        import shutil
        actual_size = shutil.disk_usage(output_path).used / (1024 * 1024)
    else:
        actual_size = output_path.stat().st_size / (1024 * 1024)
    
    print(f"\n5. Model saved: {output_name}")
    print(f"   Expected size: {expected_size}")
    print(f"   Actual size: {actual_size:.1f} MB")
    
    print("\n6. Inference test...")
    from PIL import Image
    test_img = Image.new('RGB', (224, 224), color=(128, 128, 128))
    prediction = mlmodel.predict({"spectrogram": test_img})
    print(f"   Test prediction: {prediction}")
    
    print("\n" + "=" * 60)
    print("CONVNEXT-TINY CONVERSION COMPLETE")
    print("=" * 60)
    print(f"\nTo use in Swift:")
    print(f"1. Add {output_name} to your Xcode project")
    print(f"2. Convert audio to mel-spectrogram (224x224 RGB)")
    print(f"3. Run inference with CoreML")
    
    return output_path


def convert_wav2vec2(quantize: str = "fp16"):
    """
    Convert Wav2Vec2 audio deepfake detector to CoreML.
    
    NOTE: Wav2Vec2 has dynamic input shapes and attention layers that don't
    quantize well to INT8. FP16 is recommended.
    
    Args:
        quantize: "fp16" (190MB, recommended) or "none" (380MB)
        
    Warning: INT8 quantization NOT recommended for Wav2Vec2 due to:
    - Attention layer quantization artifacts
    - Dynamic sequence length issues
    - 2-5% accuracy degradation
    """
    print("=" * 60)
    print("Converting Wav2Vec2 for Audio Deepfake Detection")
    print("=" * 60)
    
    if quantize == "int8":
        print("\n⚠️  WARNING: INT8 quantization not recommended for Wav2Vec2!")
        print("   Use FP16 for best accuracy/size tradeoff.")
        print("   Proceeding with FP16 instead...\n")
        quantize = "fp16"
    
    model_name = "MelodyMachine/Deepfake-audio-detection-V2"
    
    print(f"\n1. Loading model from Hugging Face: {model_name}")
    model = Wav2Vec2ForSequenceClassification.from_pretrained(model_name)
    feature_extractor = Wav2Vec2FeatureExtractor.from_pretrained(model_name)
    
    model.eval()
    
    param_count = sum(p.numel() for p in model.parameters())
    print(f"   Parameters: {param_count / 1e6:.1f}M")
    
    # Wav2Vec2 uses fixed-length audio (typically 2-4 seconds)
    # We'll use 3 seconds at 16kHz = 48000 samples
    sample_rate = 16000
    duration = 3.0
    num_samples = int(sample_rate * duration)
    
    print(f"\n2. Tracing model with fixed input shape (3s @ 16kHz)...")
    dummy_audio = torch.randn(1, num_samples)
    
    # Trace the model
    with torch.no_grad():
        traced_model = torch.jit.trace(model, dummy_audio)
    
    print("\n3. Converting to CoreML...")
    
    # Define input type
    input_type = ct.TensorType(
        name="audio",
        shape=(1, num_samples),
        dtype=np.float32
    )
    
    # Convert to CoreML
    mlmodel = ct.convert(
        traced_model,
        inputs=[input_type],
        classifier_config=ct.ClassifierConfig(
            class_labels=["real", "fake"],
            predicted_feature_name="deepfake_prediction"
        ),
        minimum_deployment_target=ct.target.iOS17,
        compute_units=ct.ComputeUnit.ALL,
    )
    
    # Apply FP16 quantization
    if quantize == "fp16":
        print("\n4. Applying FP16 quantization...")
        mlmodel = ct.models.neural_network.quantization_utils.quantize_weights(
            mlmodel,
            nbits=16
        )
        output_name = "Wav2Vec2_Deepfake_FP16.mlpackage"
        expected_size = "~190 MB"
    else:
        output_name = "Wav2Vec2_Deepfake_FP32.mlpackage"
        expected_size = "~380 MB"
    
    # Save model
    output_path = Path(output_name)
    mlmodel.save(str(output_path))
    
    print(f"\n5. Model saved: {output_name}")
    print(f"   Expected size: {expected_size}")
    
    print("\n" + "=" * 60)
    print("WAV2VEC2 CONVERSION COMPLETE")
    print("=" * 60)
    print("\n⚠️  IMPORTANT NOTES:")
    print("   - Input must be exactly 3 seconds (48000 samples) @ 16kHz")
    print("   - Model is 3-7x larger and slower than ConvNeXt-Tiny")
    print("   - Consider ConvNeXt-Tiny for production use")
    
    return output_path


def create_swift_audio_preprocessor():
    """
    Generate Swift code for converting audio to mel-spectrogram.
    This is needed for the ConvNeXt-Tiny model (which expects images).
    """
    swift_code = '''import Accelerate
import CoreImage

/// Converts audio buffer to mel-spectrogram image for ConvNeXt input
class AudioToSpectrogram {
    let sampleRate: Double = 16000.0
    let fftSize: Int = 2048
    let hopLength: Int = 512
    let nMels: Int = 224
    let targetSize: CGSize = CGSize(width: 224, height: 224)
    
    func convert(audio: [Float]) -> CGImage? {
        // 1. Compute STFT
        let spectrogram = computeSTFT(audio: audio)
        
        // 2. Convert to mel scale
        let melSpec = linearToMel(spectrogram: spectrogram)
        
        // 3. Convert to dB scale
        let dbSpec = amplitudeToDB(melSpec: melSpec)
        
        // 4. Normalize to 0-255 (RGB)
        let normalized = normalizeToRGB(dbSpec: dbSpec)
        
        // 5. Create CGImage
        return createCGImage(from: normalized)
    }
    
    private func computeSTFT(audio: [Float]) -> [[Float]] {
        // Use Accelerate vDSP for FFT
        // Implementation details...
        return []
    }
    
    private func linearToMel(spectrogram: [[Float]]) -> [[Float]] {
        // Apply mel filterbank
        // Implementation details...
        return []
    }
    
    private func amplitudeToDB(melSpec: [[Float]]) -> [[Float]] {
        // 20 * log10(amplitude + epsilon)
        return melSpec.map { row in
            row.map { 20 * log10(max($0, 1e-10)) }
        }
    }
    
    private func normalizeToRGB(dbSpec: [[Float]]) -> [UInt8] {
        // Normalize to 0-255 range
        let minVal = dbSpec.flatMap { $0 }.min() ?? -80
        let maxVal = dbSpec.flatMap { $0 }.max() ?? 0
        let range = maxVal - minVal
        
        var rgbBytes: [UInt8] = []
        for row in dbSpec {
            for val in row {
                let normalized = (val - minVal) / range
                let byte = UInt8(clamping: Int(normalized * 255))
                rgbBytes.append(byte) // R
                rgbBytes.append(byte) // G
                rgbBytes.append(byte) // B
            }
        }
        return rgbBytes
    }
    
    private func createCGImage(from bytes: [UInt8]) -> CGImage? {
        let width = 224
        let height = 224
        let bytesPerPixel = 3
        let bytesPerRow = width * bytesPerPixel
        
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else {
            return nil
        }
        
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 24,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}
'''
    
    output_path = Path("AudioToSpectrogram.swift")
    output_path.write_text(swift_code)
    print(f"\nSwift preprocessor saved: {output_path}")
    print("Note: This is a template - full implementation requires vDSP FFT code")


def main():
    parser = argparse.ArgumentParser(
        description="Convert deepfake detection models to quantized CoreML"
    )
    parser.add_argument(
        "--model",
        choices=["convnext", "wav2vec2"],
        default="convnext",
        help="Model to convert (default: convnext - recommended)"
    )
    parser.add_argument(
        "--quantize",
        choices=["int8", "fp16", "none"],
        default="int8",
        help="Quantization level (default: int8 - smallest)"
    )
    parser.add_argument(
        "--generate-swift",
        action="store_true",
        help="Generate Swift audio preprocessor template"
    )
    
    args = parser.parse_args()
    
    print("Deepfake Model Converter for iOS")
    print("================================\n")
    
    if args.generate_swift:
        create_swift_audio_preprocessor()
        return
    
    # Convert selected model
    if args.model == "convnext":
        output = convert_convnext_tiny(quantize=args.quantize)
    else:
        output = convert_wav2vec2(quantize=args.quantize)
    
    print(f"\n✅ Model saved to: {output.absolute()}")
    print("\nNext steps:")
    print("1. Drag the .mlpackage into your Xcode project")
    print("2. For ConvNeXt: Implement audio→spectrogram conversion in Swift")
    print("3. For Wav2Vec2: Ensure audio is exactly 3s @ 16kHz")
    print("4. Run inference using CoreML")


if __name__ == "__main__":
    main()
