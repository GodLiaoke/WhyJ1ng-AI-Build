//
//  YODetector.m
//  YOOverlay
//

#import "YODetector.h"
#import "YOCommon.h"

#import <CoreML/CoreML.h>
#import <math.h>
#import <stdlib.h>
#import <string.h>

// MARK: - MLMultiArray access
//
// The model's output layout differs between exporters (channels-major
// `[1, C, N]` versus anchors-major `[1, N, C]`), and the raw element type differs
// between Core ML tool versions. Both are resolved at runtime from the
// description and the strides rather than assumed.

typedef struct {
    /// Unretained on purpose: this struct is zeroed with memset and never owns
    /// the array, which is kept alive by the prediction results in the caller.
    MLMultiArray *__unsafe_unretained array;
    const void *pointer;
    /// 0 = float32, 1 = float64, 2 = int32, 3 = object subscript (slow fallback)
    int kind;
    NSInteger rank;
    NSInteger strides[4];
} YOArrayRef;

static BOOL YOArrayPrepare(YOArrayRef *out, MLMultiArray *array) {
    if (![array isKindOfClass:[MLMultiArray class]]) {
        return NO;
    }
    memset(out, 0, sizeof(*out));
    out->array = array;
    out->rank = (NSInteger)array.shape.count;
    if (out->rank < 2 || out->rank > 4) {
        return NO;
    }
    for (NSInteger i = 0; i < out->rank; i++) {
        out->strides[i] = [array.strides[i] integerValue];
    }
    switch (array.dataType) {
        case MLMultiArrayDataTypeFloat32:
            out->kind = 0;
            break;
        case MLMultiArrayDataTypeDouble:
            out->kind = 1;
            break;
        case MLMultiArrayDataTypeInt32:
            out->kind = 2;
            break;
        default:
            out->kind = 3;
            break;
    }
    if (out->kind != 3) {
        out->pointer = array.dataPointer;
        if (out->pointer == NULL) {
            out->kind = 3;
        }
    }
    return YES;
}

static double YOArrayValue(const YOArrayRef *array, NSInteger index) {
    switch (array->kind) {
        case 0:
            return (double)((const float *)array->pointer)[index];
        case 1:
            return ((const double *)array->pointer)[index];
        case 2:
            return (double)((const int32_t *)array->pointer)[index];
        default:
            return [[array->array objectAtIndexedSubscript:index] doubleValue];
    }
}

// MARK: - Detection

typedef struct {
    CGRect box;
    double score;
    int classIndex;
} YOCandidate;

static double YOIntersectionOverUnion(CGRect a, CGRect b) {
    CGFloat x0 = MAX(a.origin.x, b.origin.x);
    CGFloat y0 = MAX(a.origin.y, b.origin.y);
    CGFloat x1 = MIN(a.origin.x + a.size.width, b.origin.x + b.size.width);
    CGFloat y1 = MIN(a.origin.y + a.size.height, b.origin.y + b.size.height);
    CGFloat width = x1 - x0;
    CGFloat height = y1 - y0;
    if (width <= 0 || height <= 0) {
        return 0;
    }
    double intersection = (double)width * (double)height;
    double areaA = (double)a.size.width * (double)a.size.height;
    double areaB = (double)b.size.width * (double)b.size.height;
    double unionArea = areaA + areaB - intersection;
    return unionArea > 1e-9 ? intersection / unionArea : 0;
}

@interface YODetector () {
    MLModel *_model;
    NSString *_inputName;
    CGFloat _inputSize;
    NSString *_status;
    BOOL _ready;
}
@end

@implementation YODetector

- (instancetype)initWithModelPath:(NSString *)modelPath {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _inputSize = 640;
    _status = @"未加载";
    [self loadModelAtPath:modelPath];
    return self;
}

- (void)loadModelAtPath:(NSString *)modelPath {
    if (modelPath.length == 0) {
        _status = @"配置里没有 modelPath";
        YOLog(@"detector: %@", _status);
        return;
    }
    NSURL *url = [NSURL fileURLWithPath:modelPath];
    if (![[NSFileManager defaultManager] fileExistsAtPath:modelPath]) {
        _status = [NSString stringWithFormat:@"模型不存在：%@", modelPath];
        YOLog(@"detector: %@", _status);
        return;
    }

    MLModelConfiguration *configuration = [[MLModelConfiguration alloc] init];
    configuration.computeUnits = MLComputeUnitsAll;

    NSError *error = nil;
    MLModel *model = nil;
    @try {
        model = [MLModel modelWithContentsOfURL:url configuration:configuration error:&error];
    } @catch (NSException *exception) {
        _status = [NSString stringWithFormat:@"模型加载异常：%@", exception.reason ?: @"unknown"];
        YOLog(@"detector: %@", _status);
        return;
    }
    if (model == nil) {
        _status = [NSString stringWithFormat:@"模型加载失败：%@",
                   error.localizedDescription ?: @"unknown"];
        YOLog(@"detector: %@", _status);
        return;
    }

    // The image input carries the expected side length; it is what raw pixel
    // coordinates in the output have to be divided by.
    NSString *imageInput = nil;
    for (NSString *name in model.modelDescription.inputDescriptionsByName) {
        MLFeatureDescription *description =
            model.modelDescription.inputDescriptionsByName[name];
        if (description.type != MLFeatureTypeImage) {
            continue;
        }
        imageInput = name;
        MLImageConstraint *constraint = description.imageConstraint;
        if (constraint != nil && constraint.pixelsWide > 0) {
            _inputSize = (CGFloat)constraint.pixelsWide;
        }
        break;
    }
    if (imageInput == nil) {
        _status = @"模型没有图像输入（需要 Core ML 图像分类/检测模型）";
        YOLog(@"detector: %@", _status);
        return;
    }

    _model = model;
    _inputName = [imageInput copy];
    _ready = YES;
    _status = [NSString stringWithFormat:@"已加载 · 输入 %@ · %dx%d",
               imageInput, (int)_inputSize, (int)_inputSize];
    YOLog(@"detector: %@ (%@)", _status, modelPath);
}

- (BOOL)ready {
    return _ready;
}

- (NSString *)status {
    return _status ?: @"";
}

- (CGFloat)inputSize {
    return _inputSize;
}

- (NSArray<NSValue *> *)detectInPixelBuffer:(CVPixelBufferRef)buffer
                                 confidence:(double)minimumConfidence
                                 onlyPerson:(BOOL)onlyPerson
                                   maxBoxes:(int)maxBoxes {
    if (!_ready || buffer == NULL || _model == nil) {
        return @[];
    }

    MLFeatureValue *imageValue = [MLFeatureValue featureValueWithPixelBuffer:buffer];
    if (imageValue == nil) {
        return @[];
    }
    NSError *error = nil;
    MLDictionaryFeatureProvider *provider =
        [[MLDictionaryFeatureProvider alloc] initWithDictionary:@{ _inputName: imageValue }
                                                          error:&error];
    if (provider == nil) {
        YOLog(@"detector: 构造输入失败 %@", error.localizedDescription);
        return @[];
    }

    id<MLFeatureProvider> output = nil;
    @try {
        output = [_model predictionFromFeatures:provider
                                        options:[[MLPredictionOptions alloc] init]
                                          error:&error];
    } @catch (NSException *exception) {
        YOLog(@"detector: 推理异常 %@", exception.reason ?: @"unknown");
        return @[];
    }
    if (output == nil) {
        YOLog(@"detector: 推理失败 %@", error.localizedDescription ?: @"unknown");
        return @[];
    }

    // Collect every multiarray output. A single combined tensor is the usual
    // shape; a split (boxes + scores) export yields two.
    NSMutableArray<MLMultiArray *> *arrays = [NSMutableArray array];
    for (NSString *name in _model.modelDescription.outputDescriptionsByName) {
        MLFeatureValue *value = [output featureValueForName:name];
        if (value != nil && value.type == MLFeatureTypeMultiArray && value.multiArrayValue) {
            [arrays addObject:value.multiArrayValue];
        }
    }
    if (arrays.count == 0) {
        return @[];
    }

    // Primary tensor: the one with the most channels, i.e. the class scores.
    MLMultiArray *primary = nil;
    NSInteger primaryChannels = 0;
    MLMultiArray *boxesOnly = nil;
    for (MLMultiArray *array in arrays) {
        if (array.shape.count < 2) {
            continue;
        }
        NSInteger dimA = [array.shape[array.shape.count - 2] integerValue];
        NSInteger dimB = [array.shape[array.shape.count - 1] integerValue];
        NSInteger channels = MIN(dimA, dimB);
        if (channels == 4 && arrays.count > 1) {
            boxesOnly = array;
            continue;
        }
        if (channels > primaryChannels) {
            primaryChannels = channels;
            primary = array;
        }
    }
    if (primary == nil) {
        return @[];
    }

    YOArrayRef scores;
    if (!YOArrayPrepare(&scores, primary)) {
        return @[];
    }

    NSInteger dimA = [primary.shape[primary.shape.count - 2] integerValue];
    NSInteger dimB = [primary.shape[primary.shape.count - 1] integerValue];
    BOOL channelsMajor = (dimA <= dimB);
    NSInteger channelStride = channelsMajor ? scores.strides[scores.rank - 2]
                                            : scores.strides[scores.rank - 1];
    NSInteger anchorStride = channelsMajor ? scores.strides[scores.rank - 1]
                                           : scores.strides[scores.rank - 2];
    NSInteger channels = channelsMajor ? dimA : dimB;
    NSInteger anchors = channelsMajor ? dimB : dimA;
    if (channels < 5 || anchors <= 0) {
        return @[];
    }

    YOArrayRef boxTensor;
    BOOL hasSeparateBoxes = NO;
    if (boxesOnly != nil) {
        hasSeparateBoxes = YOArrayPrepare(&boxTensor, boxesOnly);
        if (hasSeparateBoxes) {
            NSInteger bA = [boxesOnly.shape[boxesOnly.shape.count - 2] integerValue];
            NSInteger bB = [boxesOnly.shape[boxesOnly.shape.count - 1] integerValue];
            NSInteger bChannels = MIN(bA, bB);
            if (bChannels != 4) {
                hasSeparateBoxes = NO;
            } else {
                boxTensor.strides[0] = (bA <= bB) ? boxTensor.strides[boxTensor.rank - 2]
                                                  : boxTensor.strides[boxTensor.rank - 1];
                boxTensor.strides[1] = (bA <= bB) ? boxTensor.strides[boxTensor.rank - 1]
                                                  : boxTensor.strides[boxTensor.rank - 2];
            }
        }
    }

    NSUInteger capacity = (NSUInteger)MIN(anchors, (NSInteger)8400);
    YOCandidate *candidates = calloc(capacity, sizeof(YOCandidate));
    if (candidates == NULL) {
        return @[];
    }
    NSUInteger found = 0;

    // Raw YO coordinates are in input pixels; some exports are normalised
    // already. The magnitude of the width is what distinguishes them.
    double coordinateScale = 1.0;
    BOOL scaleKnown = NO;

    NSInteger scoreBase = 4;
    for (NSInteger i = 0; i < anchors; i++) {
        double bestScore = -1.0;
        int bestClass = -1;
        for (NSInteger c = scoreBase; c < channels; c++) {
            double value = YOArrayValue(&scores, i * anchorStride + c * channelStride);
            if (value > bestScore) {
                bestScore = value;
                bestClass = (int)(c - scoreBase);
            }
        }
        if (bestScore < minimumConfidence || bestClass < 0) {
            continue;
        }
        if (onlyPerson && bestClass != 0) {
            continue;
        }

        double cx, cy, width, height;
        if (hasSeparateBoxes) {
            cx = YOArrayValue(&boxTensor, i * boxTensor.strides[1] + 0 * boxTensor.strides[0]);
            cy = YOArrayValue(&boxTensor, i * boxTensor.strides[1] + 1 * boxTensor.strides[0]);
            width = YOArrayValue(&boxTensor, i * boxTensor.strides[1] + 2 * boxTensor.strides[0]);
            height = YOArrayValue(&boxTensor, i * boxTensor.strides[1] + 3 * boxTensor.strides[0]);
        } else {
            cx = YOArrayValue(&scores, i * anchorStride + 0 * channelStride);
            cy = YOArrayValue(&scores, i * anchorStride + 1 * channelStride);
            width = YOArrayValue(&scores, i * anchorStride + 2 * channelStride);
            height = YOArrayValue(&scores, i * anchorStride + 3 * channelStride);
        }
        if (!isfinite(cx) || !isfinite(cy) || !isfinite(width) || !isfinite(height)) {
            continue;
        }
        if (!scaleKnown) {
            scaleKnown = YES;
            coordinateScale = (width > 1.5 || height > 1.5) ? (double)_inputSize : 1.0;
        }
        if (width <= 0 || height <= 0) {
            continue;
        }

        double normalizedWidth = width / coordinateScale;
        double normalizedHeight = height / coordinateScale;
        double normalizedX = (cx / coordinateScale) - normalizedWidth / 2.0;
        double normalizedY = (cy / coordinateScale) - normalizedHeight / 2.0;
        if (normalizedWidth * normalizedHeight < 1e-5) {
            continue;
        }

        CGRect box = CGRectMake((CGFloat)MAX(0.0, MIN(1.0, normalizedX)),
                                (CGFloat)MAX(0.0, MIN(1.0, normalizedY)),
                                (CGFloat)MAX(0.0, MIN(1.0, normalizedWidth)),
                                (CGFloat)MAX(0.0, MIN(1.0, normalizedHeight)));
        if (found < capacity) {
            candidates[found].box = box;
            candidates[found].score = bestScore;
            candidates[found].classIndex = bestClass;
            found++;
        }
    }

    NSArray<NSValue *> *result = @[];
    if (found > 0) {
        // Highest score first, then a bounded greedy suppression so overlapping
        // proposals on the same person do not each get drawn.
        for (NSUInteger i = 1; i < found; i++) {
            YOCandidate key = candidates[i];
            NSInteger j = (NSInteger)i - 1;
            while (j >= 0 && candidates[j].score < key.score) {
                candidates[j + 1] = candidates[j];
                j--;
            }
            candidates[j + 1] = key;
        }
        NSMutableArray<NSValue *> *kept = [NSMutableArray array];
        int limit = maxBoxes > 0 ? maxBoxes : 4;
        for (NSUInteger i = 0; i < found && (int)kept.count < limit; i++) {
            BOOL suppressed = NO;
            for (NSValue *existing in kept) {
                if (YOIntersectionOverUnion(candidates[i].box, existing.CGRectValue) > 0.45) {
                    suppressed = YES;
                    break;
                }
            }
            if (!suppressed) {
                [kept addObject:[NSValue valueWithCGRect:candidates[i].box]];
            }
        }
        result = kept;
    }

    free(candidates);
    return result;
}

@end
