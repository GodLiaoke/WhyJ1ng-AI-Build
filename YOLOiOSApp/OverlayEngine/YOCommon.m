//
//  YOCommon.m
//  AuthCore / overlay engine
//

#import "YOCommon.h"

#import <time.h>
#import <math.h>

NSString *const YOPrefsDir = @"/var/mobile/Library/Preferences";
NSString *const YOConfigPath =
    @"/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist";

// Primary heartbeat. Named after AuthCore because the component and the
// authorization library are now the same binary: if this file is fresh, the deb
// is installed and loaded into SpringBoard.
NSString *const YOAlivePath =
    @"/var/mobile/Library/Preferences/cc.ouovo.authcore.alive";

NSString *const YOAliveFileName = @"cc.ouovo.authcore.alive";

// Written as well, so an app build from before the merge still sees the
// component as loaded instead of telling the user to reinstall.
NSString *const YOLegacyAlivePath =
    @"/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive";

NSString *const YOLogPath =
    @"/var/mobile/Library/Preferences/cc.ouovo.authcore.log";

NSString *const YOReloadNotification = @"cc.ouovo.yolooverlay.reload";

NSString *const YOAppBundleIdentifier = @"com.yolo.person.YOLOiOSApp";

// MARK: - App container lookup

NSString *YOAppDocumentsPath(void) {
    static NSString *cached = nil;
    static dispatch_once_t once;
    static dispatch_semaphore_t lock;
    dispatch_once(&once, ^{
        lock = dispatch_semaphore_create(1);
    });

    // The interesting case is "not found yet": SpringBoard starts before the
    // app's container necessarily exists, so a missing value is retried on the
    // next call instead of being memoised forever.
    dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
    NSString *result = cached;
    dispatch_semaphore_signal(lock);
    if (result != nil) {
        return result;
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *root = @"/var/mobile/Containers/Data/Application";
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:root error:NULL];
    NSString *found = nil;
    for (NSString *entry in entries) {
        NSString *container = [root stringByAppendingPathComponent:entry];
        NSString *metadata = [container stringByAppendingPathComponent:
                              @".com.apple.mobile_container_manager.metadata.plist"];
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:metadata];
        if (![info isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        NSString *identifier = [info objectForKey:@"MCMMetadataIdentifier"];
        if (![identifier isKindOfClass:[NSString class]]) {
            continue;
        }
        if (![identifier isEqualToString:YOAppBundleIdentifier]) {
            continue;
        }
        NSString *documents = [container stringByAppendingPathComponent:@"Documents"];
        if ([fm fileExistsAtPath:documents]) {
            found = documents;
            break;
        }
    }

    if (found != nil) {
        dispatch_semaphore_wait(lock, DISPATCH_TIME_FOREVER);
        cached = found;
        dispatch_semaphore_signal(lock);
    }
    return found;
}

// MARK: - Heartbeat age

static double YOAgeOfFile(NSString *path) {
    if (path.length == 0) {
        return -1;
    }
    NSString *raw = [NSString stringWithContentsOfFile:path
                                              encoding:NSUTF8StringEncoding
                                                 error:NULL];
    if (raw.length == 0) {
        return -1;
    }
    double stamp = [[raw stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]] doubleValue];
    if (!isfinite(stamp) || stamp < 1.5e9) {
        return -1;
    }
    return YONowUnix() - stamp;
}

double YOHeartbeatAge(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObjects:
                                         YOAlivePath, YOLegacyAlivePath, nil];
    // The app reads its own Documents copy when it cannot read /var/mobile.
    NSString *documents = YOAppDocumentsPath();
    if (documents.length > 0) {
        [paths addObject:[documents stringByAppendingPathComponent:YOAliveFileName]];
    }

    double best = -1;
    for (NSString *path in paths) {
        double age = YOAgeOfFile(path);
        if (age < 0) {
            continue;
        }
        // A stamp a few seconds in the future is rounding, not a fault.
        if (age < -5) {
            continue;
        }
        if (best < 0 || age < best) {
            best = age;
        }
    }
    return best;
}

// MARK: - Environment

BOOL YOIsTrollStoreInstalled(void) {
    static BOOL result = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        result = [fm fileExistsAtPath:
                  @"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist"];
    });
    return result;
}

BOOL YOLooksJailbroken(void) {
    static BOOL result = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *artifacts = @[
            @"/var/jb",
            @"/Applications/Cydia.app",
            @"/Applications/Sileo.app",
            @"/Applications/Zebra.app",
            @"/usr/lib/libellekit.dylib",
            @"/var/lib/dpkg",
        ];
        for (NSString *path in artifacts) {
            if ([fm fileExistsAtPath:path]) {
                result = YES;
                break;
            }
        }
    });
    return result;
}

double YONowUnix(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_REALTIME, &ts) != 0) {
        return [[NSDate date] timeIntervalSince1970];
    }
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1e9;
}

void YOLog(NSString *format, ...) {
    if (format.length == 0) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    if (message.length == 0) {
        return;
    }

    // One serial queue for the whole process so concurrent producers cannot
    // interleave partial lines. Nothing here ever blocks a caller.
    static dispatch_queue_t logQueue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        logQueue = dispatch_queue_create("cc.ouovo.yolooverlay.log",
                                         DISPATCH_QUEUE_SERIAL);
    });

    NSString *stamp;
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
    stamp = [formatter stringFromDate:[NSDate date]];
    NSString *entry = [NSString stringWithFormat:@"%@ [%@] %@\n",
                       stamp, [NSProcessInfo processInfo].processName, message];

    dispatch_async(logQueue, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:YOLogPath
                                                   error:NULL];
        // Rotate rather than grow: this lives on the data partition and a
        // runaway log is a support ticket.
        if ([[attrs objectForKey:NSFileSize] unsignedLongLongValue] > 256 * 1024) {
            [fm removeItemAtPath:YOLogPath error:NULL];
        }
        NSData *data = [entry dataUsingEncoding:NSUTF8StringEncoding];
        if (data.length == 0) {
            return;
        }
        if (![fm fileExistsAtPath:YOLogPath]) {
            [data writeToFile:YOLogPath atomically:YES];
            return;
        }
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:YOLogPath];
        if (handle == nil) {
            return;
        }
        @try {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
        } @catch (__unused NSException *exception) {
            // A log write must never be the reason something breaks.
        }
    });
}

BOOL YOIsSpringBoard(void) {
    static BOOL result = NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *name = [NSProcessInfo processInfo].processName;
        NSString *identifier = [NSBundle mainBundle].bundleIdentifier;
        result = [name isEqualToString:@"SpringBoard"] ||
                 [identifier isEqualToString:@"com.apple.springboard"];
    });
    return result;
}
