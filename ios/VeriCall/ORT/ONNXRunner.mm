#import "ONNXRunner.h"
#include "onnxruntime_cxx_api.h"
#include <vector>
#include <cmath>

@implementation ONNXRunnerResult
@end

@interface ONNXRunner () {
    Ort::Env _env;
    Ort::Session *_session;
}
@end

@implementation ONNXRunner

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error {
    self = [super init];
    if (!self) return nil;

    try {
        _env = Ort::Env(ORT_LOGGING_LEVEL_WARNING, "VeriCall");
        Ort::SessionOptions opts;
        opts.SetIntraOpNumThreads(2);
        opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);

        _session = new Ort::Session(_env, modelPath.UTF8String, opts);

        // Log model info
        Ort::AllocatorWithDefaultOptions alloc;
        size_t numInputs = _session->GetInputCount();
        size_t numOutputs = _session->GetOutputCount();
        NSLog(@"[ONNXRunner] Model loaded: %zu inputs, %zu outputs", numInputs, numOutputs);

        for (size_t i = 0; i < numInputs; i++) {
            auto name = _session->GetInputNameAllocated(i, alloc);
            auto info = _session->GetInputTypeInfo(i);
            auto shape = info.GetTensorTypeAndShapeInfo().GetShape();
            NSMutableString *shapeStr = [NSMutableString string];
            for (auto d : shape) [shapeStr appendFormat:@"%lld,", d];
            NSLog(@"[ONNXRunner] Input[%zu]: '%s' shape=[%@]", i, name.get(), shapeStr);
        }
        for (size_t i = 0; i < numOutputs; i++) {
            auto name = _session->GetOutputNameAllocated(i, alloc);
            NSLog(@"[ONNXRunner] Output[%zu]: '%s'", i, name.get());
        }

    } catch (const Ort::Exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"ONNXRunner"
                                         code:-1
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"ONNX init failed: %s", e.what()]}];
        }
        return nil;
    }
    return self;
}

- (nullable ONNXRunnerResult *)runWithAudioSamples:(const float *)samples
                                       sampleCount:(int)count
                                             error:(NSError **)error {
    try {
        // Input: "audio" shape [1, count]
        std::vector<int64_t> inputShape = {1, (int64_t)count};
        auto memInfo = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);

        Ort::Value inputTensor = Ort::Value::CreateTensor<float>(
            memInfo, (float *)samples, count, inputShape.data(), inputShape.size());

        const char *inputNames[] = {"audio"};
        const char *outputNames[] = {"logits"};

        auto outputs = _session->Run(Ort::RunOptions{nullptr},
                                      inputNames, &inputTensor, 1,
                                      outputNames, 1);

        // Output: logits shape [1, 2]
        float *logits = outputs[0].GetTensorMutableData<float>();
        float fakeLogit = logits[0];  // index 0 = fake
        float realLogit = logits[1];  // index 1 = real

        // Softmax
        float maxLogit = fmax(fakeLogit, realLogit);
        float expFake = expf(fakeLogit - maxLogit);
        float expReal = expf(realLogit - maxLogit);
        float sumExp = expFake + expReal;

        ONNXRunnerResult *result = [[ONNXRunnerResult alloc] init];
        result.fakeProb = expFake / sumExp;
        result.realProb = expReal / sumExp;
        result.fakLogit = fakeLogit;
        result.realLogit = realLogit;
        return result;

    } catch (const Ort::Exception &e) {
        if (error) {
            *error = [NSError errorWithDomain:@"ONNXRunner"
                                         code:-2
                                     userInfo:@{NSLocalizedDescriptionKey:
                                         [NSString stringWithFormat:@"ONNX run failed: %s", e.what()]}];
        }
        return nil;
    }
}

- (void)dealloc {
    delete _session;
}

@end
