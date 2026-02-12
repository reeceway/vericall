#!/usr/bin/env python3
import torch
import coremltools as ct
from transformers import AutoModelForImageClassification

print('Loading ConvNeXt-Tiny...')
model = AutoModelForImageClassification.from_pretrained('kubinooo/convnext-tiny-224-audio-deepfake-classification')
model.eval()

# Wrap to return logits only
class Wrapper(torch.nn.Module):
    def __init__(self, m):
        super().__init__()
        self.m = m
    def forward(self, x):
        return self.m(x).logits

wrapped = Wrapper(model)
dummy = torch.randn(1, 3, 224, 224)

print('Tracing...')
traced = torch.jit.trace(wrapped, dummy, strict=False)

print('Converting to CoreML...')
mlmodel = ct.convert(
    traced,
    inputs=[ct.ImageType(name='spectrogram', shape=(1, 3, 224, 224), color_layout=ct.colorlayout.RGB)],
    classifier_config=ct.ClassifierConfig(class_labels=['real', 'fake']),
    minimum_deployment_target=ct.target.iOS17
)

print('Applying FP16 quantization...')
import coremltools.optimize.coreml as cto
mlmodel = cto.linear_quantize_weights(mlmodel, config=cto.OptimizationConfig())

print('Saving...')
mlmodel.save('ConvNeXt_Tiny_Deepfake_FP16.mlpackage')
print('Done!')
