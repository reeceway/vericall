import torch
import torch.nn as nn
import coremltools as ct
from transformers import AutoModelForAudioClassification
import numpy as np

# Wrapper to ensure output is a Tensor (logits), not a dict
class WavLMTracer(nn.Module):
    def __init__(self, model):
        super().__init__()
        self.model = model
    
    def forward(self, x):
        # WavLM expects input_values=x
        return self.model(x).logits

def convert_wavlm_to_coreml(model_id="DavidCombei/wavLM-base-Deepfake_V2", output_path="WavLMDeepfake.mlpackage"):
    print(f"Loading model: {model_id}...")
    original_model = AutoModelForAudioClassification.from_pretrained(model_id)
    original_model.eval()
    
    # Wrap the model
    model = WavLMTracer(original_model)
    model.eval()
    
    # Trace the model
    # wavLM-base expects 16kHz audio. 
    # Input shape: [1, sequence_length]
    # We'll fix the input length to 3 seconds for CoreML @ 16kHz = 48000 samples
    sample_rate = 16000
    seconds = 3
    input_len = sample_rate * seconds
    
    example_input = torch.randn(1, input_len)
    
    print(f"Tracing model with input shape {example_input.shape}...")
    try:
        traced_model = torch.jit.trace(model, example_input)
    except Exception as e:
        print(f"Tracing failed: {e}")
        return

    print("Converting to CoreML (FP16)...")
    try:
        mlmodel = ct.convert(
            traced_model,
            inputs=[ct.TensorType(name="audio", shape=(1, input_len))],
            classifier_config=ct.ClassifierConfig(
                # Label mapping based on evaluation findings: 0=fake, 1=real
                class_labels=["fake", "real"], 
                predicted_feature_name="label"
            ),
            minimum_deployment_target=ct.target.iOS17,
            compute_units=ct.ComputeUnit.CPU_ONLY,
            compute_precision=ct.precision.FLOAT16
        )
        
        mlmodel.save(output_path)
        print(f"✅ Saved CoreML model to {output_path}")
        
    except Exception as e:
        print(f"Conversion failed: {e}")

if __name__ == "__main__":
    convert_wavlm_to_coreml()
