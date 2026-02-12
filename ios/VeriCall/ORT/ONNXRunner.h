#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ONNXRunnerResult : NSObject
@property (nonatomic, assign) float fakeProb;
@property (nonatomic, assign) float realProb;
@property (nonatomic, assign) float fakLogit;
@property (nonatomic, assign) float realLogit;
@end

@interface ONNXRunner : NSObject

- (nullable instancetype)initWithModelPath:(NSString *)modelPath error:(NSError **)error;
- (nullable ONNXRunnerResult *)runWithAudioSamples:(const float *)samples
                                       sampleCount:(int)count
                                             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
