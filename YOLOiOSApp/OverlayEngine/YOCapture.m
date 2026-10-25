//
//  YOCapture.m
//  YOOverlay
//

#import "YOCapture.h"
#import "YOCommon.h"

#import <dlfcn.h>
#import <math.h>

// MARK: - Private entry points
//
// Everything below is resolved with dlsym instead of being referenced at link
// time. Two reasons, both practical:
//
//   1. The dylib then links on any SDK. A hard reference to a private symbol
//      that the current SDK does not export is a build failure, and a hard
//      reference to one that the running OS does not export is a launch
//      failure inside SpringBoard.
//   2. A missing symbol becomes a readable status string instead of a crash.
//
// Declared argument lists are the ones these functions have had since iOS 13.
// They are called only after the pointer is confirmed non-NULL.

/// int CARenderServerRenderDisplay(int display, CFStringRef name,
///                                 IOSurfaceRef surface, int x, int y);
typedef int (*YORenderDisplayFn)(int display, CFStringRef name, void *surface,
                                   int x, int y);

/// IOSurfaceRef CVPixelBufferGetIOSurface(CVPixelBufferRef buffer);
typedef void *(*YOGetIOSurfaceFn)(CVPixelBufferRef buffer);

@interface YOCapture () {
    YORenderDisplayFn _renderDisplay;
    YOGetIOSurfaceFn _getIOSurface;
    void *_quartzCore;
    void *_coreVideo;
    NSString *_status;
    NSUInteger _consecutiveFailures;
    BOOL _loggedRenderFailure;
    /// The (display, format) pair that last produced a frame.
    BOOL _hasPreferred;
    int _preferredDisplay;
    OSType _preferredFormat;
}
@end

@implementation YOCapture

+ (instancetype)shared {
    static YOCapture *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[YOCapture alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    [self resolveSymbols];
    return self;
}

- (void)resolveSymbols {
    // RTLD_DEFAULT first: SpringBoard already links QuartzCore, so the symbol is
    // normally visible without opening anything.
    _renderDisplay = (YORenderDisplayFn)dlsym(RTLD_DEFAULT, "CARenderServerRenderDisplay");
    if (_renderDisplay == NULL) {
        // QuartzCore is the documented home of this function; CoreSurface has
        // exposed it on some builds.
        const char *paths[] = {
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            "/System/Library/PrivateFrameworks/CoreSurface.framework/CoreSurface",
        };
        for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
            void *handle = dlopen(paths[i], RTLD_LAZY | RTLD_GLOBAL);
            if (handle == NULL) {
                continue;
            }
            void *symbol = dlsym(handle, "CARenderServerRenderDisplay");
            if (symbol != NULL) {
                _renderDisplay = (YORenderDisplayFn)symbol;
                if (i == 0) {
                    _quartzCore = handle;
                }
                break;
            }
            dlclose(handle);
        }
    }

    _getIOSurface = (YOGetIOSurfaceFn)dlsym(RTLD_DEFAULT, "CVPixelBufferGetIOSurface");
    if (_getIOSurface == NULL) {
        _coreVideo = dlopen("/System/Library/Frameworks/CoreVideo.framework/CoreVideo",
                            RTLD_LAZY | RTLD_GLOBAL);
        if (_coreVideo != NULL) {
            _getIOSurface = (YOGetIOSurfaceFn)dlsym(_coreVideo, "CVPixelBufferGetIOSurface");
        }
    }

    if (_renderDisplay == NULL) {
        _status = @"CARenderServerRenderDisplay 不可用（该系统未导出该符号）";
    } else if (_getIOSurface == NULL) {
        _status = @"CVPixelBufferGetIOSurface 不可用（无法取得 IOSurface）";
    } else {
        _status = @"";
    }
    YOLog(@"capture: render=%p iosurface=%p %@",
            (void *)_renderDisplay, (void *)_getIOSurface,
            _status.length > 0 ? _status : @"ready");
}

- (BOOL)available {
    return _renderDisplay != NULL && _getIOSurface != NULL;
}

- (NSString *)status {
    return _status ?: @"";
}

- (NSUInteger)consecutiveFailures {
    return _consecutiveFailures;
}

- (CVPixelBufferRef)copyFrameWithPointSize:(CGSize)pointSize
                                     scale:(CGFloat)scale CF_RETURNS_RETAINED {
    if (![self available]) {
        return NULL;
    }
    if (pointSize.width < 16 || pointSize.height < 16) {
        return NULL;
    }
    CGFloat effectiveScale = scale > 0 ? scale : 2.0;
    size_t width = (size_t)lround(pointSize.width * effectiveScale);
    size_t height = (size_t)lround(pointSize.height * effectiveScale);
    if (width < 16 || height < 16 || width > 8192 || height > 8192) {
        return NULL;
    }

    // Argument semantics, not just symbol presence.
    //
    // Resolving CARenderServerRenderDisplay with dlsym only proves the symbol is
    // exported. The argument list and, more importantly, which surface format the
    // compositor will accept into, changed across major versions: from iOS 16 on,
    // devices with 10-bit panels have been observed to reject a 32BGRA target and
    // to want a different display index. So each frame tries a short ladder of
    // (display id, pixel format) combinations instead of assuming one, remembers
    // the one that worked, and reports every attempt's return code when none do.
    //
    // The order is fixed so behaviour is reproducible; the version only widens the
    // ladder, it never changes the first attempt.
    struct YOFormatAttempt {
        int display;
        OSType format;
        const char *program;
    };
    static const struct YOFormatAttempt kCommon[] = {
        { 0, kCVPixelFormatType_32BGRA, "display0/BGRA" },
        { 0, kCVPixelFormatType_32ARGB, "display0/ARGB" },
        { 1, kCVPixelFormatType_32BGRA, "display1/BGRA" },
    };
    static const struct YOFormatAttempt kModernExtra[] = {
        { 1, kCVPixelFormatType_32ARGB, "display1/ARGB" },
    };

    BOOL modern = NO;
    @try {
        modern = [NSProcessInfo processInfo].operatingSystemVersion.majorVersion >= 16;
    } @catch (__unused NSException *exception) {
        modern = NO;
    }

    NSMutableArray<NSValue *> *ladder = [NSMutableArray array];
    for (size_t i = 0; i < sizeof(kCommon) / sizeof(kCommon[0]); i++) {
        [ladder addObject:[NSValue value:&kCommon[i] withObjCType:@encode(struct YOFormatAttempt)]];
    }
    if (modern) {
        for (size_t i = 0; i < sizeof(kModernExtra) / sizeof(kModernExtra[0]); i++) {
            [ladder addObject:[NSValue value:&kModernExtra[i]
                                withObjCType:@encode(struct YOFormatAttempt)]];
        }
    }

    // Visit the combination that worked last time first, so a healthy device pays
    // for exactly one attempt per frame. Tracked as a (display, format) pair, not
    // as an index: the ladder's length depends on the version.
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    NSInteger preferred = NSNotFound;
    for (NSUInteger i = 0; i < ladder.count; i++) {
        struct YOFormatAttempt attempt;
        [ladder[i] getValue:&attempt];
        if (_hasPreferred && attempt.display == _preferredDisplay &&
            attempt.format == _preferredFormat) {
            preferred = (NSInteger)i;
            break;
        }
    }
    if (preferred != NSNotFound) {
        [order addObject:@(preferred)];
    }
    for (NSUInteger i = 0; i < ladder.count; i++) {
        if ((NSInteger)i != preferred) {
            [order addObject:@(i)];
        }
    }

    NSMutableString *attempts = [NSMutableString string];
    CVPixelBufferRef buffer = NULL;

    for (NSNumber *slot in order) {
        struct YOFormatAttempt attempt;
        [ladder[slot.unsignedIntegerValue] getValue:&attempt];

        CVPixelBufferRef candidate = NULL;
        // `IOSurfaceProperties` is the string value of
        // kCVPixelBufferIOSurfacePropertiesKey. Passing the literal avoids a
        // symbol dependency on that constant while producing the same dictionary.
        NSDictionary *attributes = @{ @"IOSurfaceProperties": @{} };
        CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault,
                                               width, height,
                                               attempt.format,
                                               (__bridge CFDictionaryRef)attributes,
                                               &candidate);
        if (created != kCVReturnSuccess || candidate == NULL) {
            [attempts appendFormat:@"%@:create=%d ", @(attempt.program), (int)created];
            continue;
        }

        void *surface = _getIOSurface(candidate);
        if (surface == NULL) {
            CVPixelBufferRelease(candidate);
            [attempts appendFormat:@"%@:no-iosurface ", @(attempt.program)];
            continue;
        }

        int rendered = 0;
        @try {
            rendered = _renderDisplay(attempt.display, CFSTR("LCD"), surface, 0, 0);
        } @catch (__unused NSException *exception) {
            rendered = -1;
        }
        if (rendered != 0) {
            CVPixelBufferRelease(candidate);
            [attempts appendFormat:@"%@:rc=%d ", @(attempt.program), rendered];
            continue;
        }

        buffer = candidate;
        _hasPreferred = YES;
        _preferredDisplay = attempt.display;
        _preferredFormat = attempt.format;
        break;
    }

    if (buffer == NULL) {
        _consecutiveFailures++;
        if (!_loggedRenderFailure || _consecutiveFailures == 40) {
            _loggedRenderFailure = YES;
            YOLog(@"capture: every CARenderServerRenderDisplay combination failed "
                  @"on iOS %@ (tried %@). A successful dlsym does not guarantee "
                  @"identical argument semantics; on iOS 16+ the compositor may "
                  @"also require the QuartzCore display-capture entitlement.",
                  [NSProcessInfo processInfo].operatingSystemVersionString,
                  attempts);
            _status = [NSString stringWithFormat:
                       @"抓屏失败（iOS %@）：%@",
                       [NSProcessInfo processInfo].operatingSystemVersionString,
                       attempts];
        }
        return NULL;
    }

    _consecutiveFailures = 0;
    return buffer;
}

@end
