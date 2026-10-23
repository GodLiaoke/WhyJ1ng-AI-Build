//
//  YOConfig.m
//  YOOverlay
//

#import "YOConfig.h"
#import "YOCommon.h"

#import <math.h>

// MARK: - Typed readers
//
// Every key is optional. A plist written by an older build of the app must not
// make this component fall over, so each read has a default and each wrong type
// is tolerated.

static NSNumber *YONumberObject(NSDictionary *dictionary, NSString *key) {
    id value = [dictionary objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return value;
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSScanner *scanner = [NSScanner scannerWithString:value];
        double parsed = 0;
        if ([scanner scanDouble:&parsed] && scanner.isAtEnd) {
            return @(parsed);
        }
    }
    return nil;
}

static double YODouble(NSDictionary *dictionary, NSString *key, double fallback) {
    NSNumber *number = YONumberObject(dictionary, key);
    if (number == nil) {
        return fallback;
    }
    double value = number.doubleValue;
    if (!isfinite(value)) {
        return fallback;
    }
    return value;
}

static int YOInt(NSDictionary *dictionary, NSString *key, int fallback) {
    NSNumber *number = YONumberObject(dictionary, key);
    return number == nil ? fallback : number.intValue;
}

static BOOL YOBool(NSDictionary *dictionary, NSString *key, BOOL fallback) {
    id value = [dictionary objectForKey:key];
    if ([value isKindOfClass:[NSNumber class]]) {
        return [value boolValue];
    }
    if ([value isKindOfClass:[NSString class]]) {
        NSString *text = [(NSString *)value lowercaseString];
        if ([text isEqualToString:@"true"] || [text isEqualToString:@"yes"] ||
            [text isEqualToString:@"1"]) {
            return YES;
        }
        if ([text isEqualToString:@"false"] || [text isEqualToString:@"no"] ||
            [text isEqualToString:@"0"]) {
            return NO;
        }
    }
    return fallback;
}

static NSString *YOString(NSDictionary *dictionary, NSString *key, NSString *fallback) {
    id value = [dictionary objectForKey:key];
    if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
        return value;
    }
    return fallback;
}

static double YOClamp(double value, double low, double high) {
    if (value < low) {
        return low;
    }
    if (value > high) {
        return high;
    }
    return value;
}

/// `#2563EB`, `2563EB` or `#2563EBFF`.
static UIColor *YOColorFromHex(NSString *hex, UIColor *fallback) {
    if (![hex isKindOfClass:[NSString class]]) {
        return fallback;
    }
    NSString *text = [hex stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([text hasPrefix:@"#"]) {
        text = [text substringFromIndex:1];
    }
    if (text.length != 6 && text.length != 8) {
        return fallback;
    }
    unsigned long long raw = 0;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    if (![scanner scanHexLongLong:&raw] || !scanner.isAtEnd) {
        return fallback;
    }
    double alpha = 1.0;
    if (text.length == 8) {
        alpha = (double)(raw & 0xFF) / 255.0;
        raw >>= 8;
    }
    double red = (double)((raw >> 16) & 0xFF) / 255.0;
    double green = (double)((raw >> 8) & 0xFF) / 255.0;
    double blue = (double)(raw & 0xFF) / 255.0;
    return [UIColor colorWithRed:red green:green blue:blue alpha:alpha];
}

// MARK: - Config

@implementation YOConfig

+ (instancetype)current {
    static YOConfig *snapshot;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        snapshot = [YOConfig load];
    });
    return snapshot;
}

+ (instancetype)load {
    YOConfig *config = [[YOConfig alloc] init];
    [config readFromDisk];
    return config;
}

- (void)readFromDisk {
    NSDictionary *dictionary = nil;
    @try {
        dictionary = [NSDictionary dictionaryWithContentsOfFile:YOConfigPath];
    } @catch (__unused NSException *exception) {
        dictionary = nil;
    }
    if (![dictionary isKindOfClass:[NSDictionary class]]) {
        dictionary = @{};
    }

    // `enabled` defaults to YES: with no config file at all the component still
    // has to prove it is loaded, and the heartbeat is the only proof the app
    // gets. Everything that draws or moves defaults to off.
    _enabled = YOBool(dictionary, @"enabled", YES);
    _showOverlay = YOBool(dictionary, @"overlay", YES);
    _aimEnabled = YOBool(dictionary, @"aim", NO);
    _autoAim = YOBool(dictionary, @"autoAim", YES);
    _onlyPerson = YOBool(dictionary, @"onlyPerson", YES);
    _maxBoxes = (int)YOClamp(YOInt(dictionary, @"maxBoxes", 4), 1, 16);

    _modelPath = YOString(dictionary, @"modelPath", @"");

    _confidence = YOClamp(YODouble(dictionary, @"confidence", 0.35), 0.05, 0.95);
    _headHeightFraction = YOClamp(YODouble(dictionary, @"headHeightFraction", 0.22),
                                    0.02, 0.9);
    _headWidthFraction = YOClamp(YODouble(dictionary, @"headWidthFraction", 0.5),
                                   0.0, 1.0);
    _speed = YOClamp(YODouble(dictionary, @"speed", 1.0), 0.05, 3.0);
    _smoothing = YOClamp(YODouble(dictionary, @"smoothing", 0.35), 0.0, 0.95);
    // Capture + inference is the expensive half of the loop; 15 fps is the
    // default ceiling and the upper bound is deliberately low.
    _captureFPS = YOClamp(YODouble(dictionary, @"captureFPS", 15.0), 5.0, 30.0);
    _hidScale = YOClamp(YODouble(dictionary, @"hidScale", 0.0), 0.0, 4.0);

    _boxColor = YOColorFromHex(YOString(dictionary, @"boxColor", @"#2563EB"),
                                 [UIColor colorWithRed:0.145 green:0.388 blue:0.922 alpha:1.0]);
}

- (BOOL)needsRebuildComparedTo:(YOConfig *)other {
    if (other == nil) {
        return YES;
    }
    // Showing or hiding the drawing is cosmetic and handled without a teardown.
    // Only the master switch and the model identity force a rebuild.
    if (self.enabled != other.enabled) {
        return YES;
    }
    if (![self.modelPath isEqualToString:other.modelPath]) {
        return YES;
    }
    return NO;
}

- (CGPoint)consumePendingAim {
    NSMutableDictionary *dictionary = nil;
    @try {
        dictionary = [[NSDictionary dictionaryWithContentsOfFile:YOConfigPath] mutableCopy];
    } @catch (__unused NSException *exception) {
        dictionary = nil;
    }
    if (dictionary == nil) {
        return CGPointZero;
    }

    double dx = YODouble(dictionary, @"pendingDx", 0.0);
    double dy = YODouble(dictionary, @"pendingDy", 0.0);
    if (fabs(dx) < 1e-6 && fabs(dy) < 1e-6) {
        return CGPointZero;
    }

    // Re-read immediately before the write. The app accumulates into the same
    // two keys, and a stale snapshot would silently delete a movement written
    // between the read above and this write.
    NSMutableDictionary *fresh = nil;
    @try {
        fresh = [[NSDictionary dictionaryWithContentsOfFile:YOConfigPath] mutableCopy];
    } @catch (__unused NSException *exception) {
        fresh = nil;
    }
    if (fresh == nil) {
        return CGPointMake(dx, dy);
    }

    double freshX = YODouble(fresh, @"pendingDx", 0.0);
    double freshY = YODouble(fresh, @"pendingDy", 0.0);
    [fresh setObject:@(freshX - dx) forKey:@"pendingDx"];
    [fresh setObject:@(freshY - dy) forKey:@"pendingDy"];
    @try {
        [fresh writeToFile:YOConfigPath atomically:YES];
    } @catch (__unused NSException *exception) {
        // Consuming is best effort; the next tick retries.
    }
    return CGPointMake(freshX, freshY);
}

- (NSString *)resolvedModelPath {
    NSFileManager *fm = [NSFileManager defaultManager];

    if (_modelPath.length > 0) {
        if ([fm fileExistsAtPath:_modelPath]) {
            return _modelPath;
        }
        YOLog(@"modelPath in config does not exist: %@", _modelPath);
    }

    // Documented fallbacks so the component works without the app having been
    // able to write the config (a sandboxed app cannot write to
    // /var/mobile/Library/Preferences on every jailbreak).
    NSArray<NSString *> *candidates = @[
        @"/var/jb/Library/Application Support/YOOverlay/yolo11s.mlmodelc",
        @"/var/mobile/Library/Application Support/YOOverlay/yolo11s.mlmodelc",
        @"/var/mobile/Documents/YOOverlay/yolo11s.mlmodelc",
        @"/var/jb/var/mobile/Documents/YOOverlay/yolo11s.mlmodelc",
        @"/var/mobile/Library/Preferences/cc.ouovo.yolooverlay/yolo11s.mlmodelc",
    ];
    for (NSString *candidate in candidates) {
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

@end
