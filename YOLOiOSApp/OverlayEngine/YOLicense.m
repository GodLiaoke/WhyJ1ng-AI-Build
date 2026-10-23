//
//  YOLicense.m
//  AuthCore / overlay engine
//

#import "YOLicense.h"
#import "YOCommon.h"

// Defined in AuthCore.m, in this same dylib. Declared plainly rather than through
// AuthCoreBridge.h: that header marks the entry points weak_import for the app's
// benfit, and mixing a weak declaration with a same-image definition buys
// nothing here.
extern int AuthCoreSubmitCard(const char *cardCode, const char *deviceId);
extern bool AuthCoreLicenseValid(void);

static NSString *const kCardKey = @"licenseCard";
static NSString *const kDeviceKey = @"licenseDevice";
static NSString *const kStoreName = @"cc.ouovo.license.plist";

// MARK: - Cached verdict

static NSObject *LicenseLock(void) {
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

static BOOL gValid = NO;
static int gResult = 0;
static double gCheckedAt = 0;
static NSString *gReason = @"";

static void SetVerdict(BOOL valid, int result, NSString *reason) {
    @synchronized (LicenseLock()) {
        gValid = valid;
        gResult = result;
        gCheckedAt = YONowUnix();
        gReason = [reason copy] ?: @"";
    }
}

BOOL YOLicenseValid(void) {
    @synchronized (LicenseLock()) {
        if (!gValid) {
            return NO;
        }
        // The export in AuthCore.m owns the cache window; deferring to it keeps
        // one definition of "still valid" instead of two that can drift.
        return AuthCoreLicenseValid();
    }
}

NSString *YOLicenseReason(void) {
    @synchronized (LicenseLock()) {
        return gReason ?: @"";
    }
}

int YOLicenseLastResult(void) {
    @synchronized (LicenseLock()) {
        return gResult;
    }
}

// MARK: - Published credentials

/// The card and device the app wrote, from whichever store is newer.
///
/// Two stores exist because exactly one is writable at any time: the shared
/// preferences plist needs an unsandboxed app, while the app's own Documents
/// directory is always writable and SpringBoard can read it.
static NSDictionary *NewestLicenseStore(void) {
    NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithObject:YOConfigPath];
    NSString *documents = YOAppDocumentsPath();
    if (documents.length > 0) {
        [paths addObject:[documents stringByAppendingPathComponent:kStoreName]];
    }

    NSFileManager *fm = [NSFileManager defaultManager];
    NSDictionary *best = nil;
    NSDate *bestDate = nil;
    for (NSString *path in paths) {
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            continue;
        }
        id card = plist[kCardKey];
        id device = plist[kDeviceKey];
        if (![card isKindOfClass:[NSString class]] || [(NSString *)card length] == 0) {
            continue;
        }
        if (![device isKindOfClass:[NSString class]] || [(NSString *)device length] == 0) {
            continue;
        }
        NSDictionary *attributes = [fm attributesOfItemAtPath:path error:NULL];
        NSDate *modified = [attributes objectForKey:NSFileModificationDate] ?: [NSDate date];
        if (best == nil || [modified compare:bestDate] == NSOrderedDescending) {
            best = @{ kCardKey: card, kDeviceKey: device };
            bestDate = modified;
        }
    }
    return best;
}

// MARK: - Check

static NSString *ReasonForResult(int result) {
    switch (result) {
        case 0:
            return @"";
        case -1:
            return @"网络请求失败（无法连接校验服务器，按失败处理）";
        case -2:
            return @"卡密无效 / 已过期 / 已封禁";
        case -3:
            return @"签名或配置错误（请求被服务器拒绝）";
        default:
            return @"服务端拒绝本次校验";
    }
}

BOOL YOLicenseRefresh(void) {
    @autoreleasepool {
        NSDictionary *store = NewestLicenseStore();
        if (store == nil) {
            SetVerdict(NO, -2, @"App 尚未把卡密写入共享配置，悬浮组件不启动");
            YOLog(@"license: no card published yet");
            return NO;
        }

        NSString *card = store[kCardKey];
        NSString *device = store[kDeviceKey];
        int result = AuthCoreSubmitCard(card.UTF8String, device.UTF8String);
        if (result == 0) {
            // AuthCore already cached the level and the timestamp; mirror the
            // verdict so the engine's own readers stay consistent.
            SetVerdict(YES, 0, @"");
            return YES;
        }

        NSString *reason = ReasonForResult(result);
        SetVerdict(NO, result, reason);
        YOLog(@"license: check failed (%d) %@", result, reason);
        return NO;
    }
}
