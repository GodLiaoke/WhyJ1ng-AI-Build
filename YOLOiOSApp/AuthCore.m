//
//  AuthCore.m
//  Runtime authorization core for YOLO Person.
//
//  ONE BINARY, TWO HOSTS.
//
//  1. The app process loads it from Frameworks/AuthCore.dylib (@rpath). There it
//     exposes the small C surface the app calls and reports integrity rather
//     than enforcing policy on its own. Enforcement lives on the server, because
//     anything a client decides can be patched out.
//
//  2. SpringBoard loads the same binary from /usr/lib (installed by the .deb,
//     via a MobileSubstrate filter that targets com.apple.springboard). There it
//     runs the overlay engine: capture the display, run the YOLO model, draw the
//     floating window, inject the aim drag.
//
//  The second host is the only way the overlay can survive an app switch. A
//  UIWindow owned by an app is composited inside that app's process, so it
//  disappears as soon as the app is backgrounded; SpringBoard's windows sit above
//  every app and SpringBoard is never suspended.
//
//  The constructor therefore branches on the host and does nothing heavy itself:
//  dyld runs constructors before UIKit is ready.
//
//  Entry points (see AuthCoreBridge.h):
//    AuthCoreIsLoaded()              true once the constructor has run
//    AuthCoreVersion()               marketing version of this build
//    AuthCoreIntegritySummary()      compact key=value integrity report
//    AuthCoreVerifyIntegrity()       full check, true when everything passes
//    AuthCoreSystemAvailable()       true when the deb is installed and running
//    AuthCoreSystemHeartbeatAge()    seconds since the component's last stamp, -1
//    AuthCoreIsSpringBoardHost()     true when running inside SpringBoard
//
//  Comments are English only: this file is compiled by clang inside Docker with
//  a non-UTF8 locale, and multibyte comments have broken the build before.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Security/Security.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonHMAC.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/getsect.h>
#import <mach-o/nlist.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <dlfcn.h>
#import <string.h>
#import <stdlib.h>
#import <unistd.h>

#import "OverlayEngine/YOCommon.h"
#import "OverlayEngine/YOEngine.h"

// The iOS SDK does not ship <sys/ptrace.h>, so the single function used here is
// declared directly. PT_DENY_ATTACH is request 31 on Darwin.
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
extern int ptrace(int request, pid_t pid, caddr_t addr, int data);

#pragma mark - Build constants

// Bumped with each dylib release. The server keeps its own record of the
// expected value, so a downgrade shows up as a stale version in the heartbeat.
static const char *kAuthCoreVersion = "1.1.0";

#pragma mark - Loaded flag

// Set by the constructor. Checked by AuthCoreIsLoaded so a caller can tell a
// successful load from a dylib whose symbols were bound but never initialized.
static volatile bool gLoaded = false;

// Forward declarations. clang 14 defaults to C99, which rejects an implicit
// function declaration, and these three are called from the entry points above
// their definitions.
static bool IsDebugged(void);
static bool HasSuspiciousImages(void);
static NSString *TextSegmentDigest(void);
static void ScheduleComponentEnforcement(void);
void AuthCoreSyncLicense(void);

// The closed-loop self-check. Defined at the bottom of this file; declared here
// because AuthCoreVerifyIntegrity and the summary are earlier.
bool AuthCoreIntegrityVerified(void);
const char *AuthCoreIntegrityDigest(void);
const char *AuthCoreVersionFingerprint(void);
const char *AuthCoreIntegrityState(void);

// Last verdict of the self-check. Written by YOIntegrityAllPass, read by
// AuthCoreIntegrityVerified. Nothing in the app displays it: a failed check must
// not tell a patcher that they found something (see the notes on the self-check
// at the bottom of this file).
static volatile bool gIntegrityOK = false;

#pragma mark - Host detection

// Which host this image is loaded into. Matched on the bundle identifier rather
// than the executable name so a renamed SpringBoard build still works, and on
// the process name as a fallback for hosts that report no identifier.
bool AuthCoreIsSpringBoardHost(void)
{
    static bool resolved = false;
    static bool isSpringBoard = false;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            NSString *identifier = [[NSBundle mainBundle] bundleIdentifier];
            NSString *name = [[NSProcessInfo processInfo] processName];
            isSpringBoard = [identifier isEqualToString:@"com.apple.springboard"] ||
                            [name isEqualToString:@"SpringBoard"];
            resolved = true;
        }
    });
    return resolved && isSpringBoard;
}

__attribute__((constructor))
static void AuthCoreInit(void)
{
    // Do not do real work here: dyld runs constructors before the app is ready,
    // and object creation on the main thread at this point is a known crash.
    gLoaded = true;

    if (AuthCoreIsSpringBoardHost()) {
        // Second host: hand over to the overlay engine. It schedules its own
        // delay and hops to the main queue, so nothing UIKit-shaped happens
        // inside this constructor.
        YOEngineStart();
        return;
    }

    // First host (the app): schedule the component requirement check. Nothing is
    // enforced while the dylib is still being initialised.
    ScheduleComponentEnforcement();

    // The card sync used to be scheduled here, from a constructor, onto a global
    // utility queue two seconds later. It crashed on iOS 27 with a SIGSEGV in
    // objc_retain inside AuthCoreSubmitCard, on that queue, with a non-canonical
    // address - the signature of a pointer that was never valid. A block captured
    // during dyld's constructor phase and run on a background queue afterwards is
    // the wrong place to touch Keychain, NSUserDefaults and the network.
    //
    // The app now calls AuthCoreSyncLicense() itself once it is past its first
    // frame (see DeviceCapability/LicenseManager), which is both later and on a
    // queue the app owns.
}

#pragma mark - Public surface

bool AuthCoreIsLoaded(void)
{
    return gLoaded;
}

const char *AuthCoreVersion(void)
{
    return kAuthCoreVersion;
}

bool AuthCoreVerifyIntegrity(void)
{
    @autoreleasepool {
        if (IsDebugged()) {
            return false;
        }
        if (HasSuspiciousImages()) {
            return false;
        }
        // The closed-loop __TEXT self-check. Deliberately last: the debugger and
        // injected-image checks are cheap, and this one hashes a segment.
        return AuthCoreIntegrityVerified();
    }
}

const char *AuthCoreIntegritySummary(void)
{
    // Cached: the summary is sent on every heartbeat, and recomputing the image
    // scan each time is wasted work. The per-heartbeat verdict comes from
    // AuthCoreVerifyIntegrity(), which does re-run; this string is the report a
    // human reads.
    //
    // `text` is the digest this build actually computes (64 hex characters), and
    // is what the server matches against the value registered for the release.
    // `int` is the local verdict: ok / unarmed / tampered / broken. `fp` is the
    // L2 version fingerprint.
    static char *cached = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        @autoreleasepool {
            BOOL debugged = IsDebugged();
            BOOL injected = HasSuspiciousImages();
            // Run the self-check once here so the reported state is populated
            // even when nothing else has asked for a verdict yet.
            (void)AuthCoreIntegrityVerified();

            // The probe digest supersedes TextSegmentDigest() as the reported
            // value, but only when the image can describe itself. On a build
            // whose __TEXT layout cannot be ranged it stays empty, and the old
            // single-pass digest is worth more than nothing.
            const char *text = AuthCoreIntegrityDigest();
            if (text == NULL || text[0] == '\0') {
                text = TextSegmentDigest().UTF8String ?: "";
            }

            NSString *summary = [NSString stringWithFormat:
                @"v=%s;dbg=%d;inj=%d;int=%s;text=%s;fp=%s",
                kAuthCoreVersion,
                debugged ? 1 : 0,
                injected ? 1 : 0,
                AuthCoreIntegrityState(),
                text,
                AuthCoreVersionFingerprint()];
            cached = strdup(summary.UTF8String);
        }
    });
    return cached;
}

#pragma mark - Overlay component requirement

// The overlay component is a hard requirement. Without the .deb the overlay
// cannot exist at all (an app-owned window dies the moment the app is
// backgrounded), so shipping an app that advertises it while running without it
// is the failure mode this check removes.
//
// The check is deliberately narrow:
//   * it waits, so a device where SpringBoard is merely slow to load the dylib
//     is not punished for it;
//   * it is skipped on TrollStore-only devices, which have no SpringBoard
//     injection at all and therefore no way to comply;
//   * it is skipped on devices with no jailbreak artifacts, i.e. where the .deb
//     was never installable in the first place.
//
// AuthCoreIsLoaded() is NOT the test for this: it only says the copy embedded in
// the app bundle loaded. The heartbeat is what proves the deb is installed.

#define kComponentGraceSeconds 10.0
#define kComponentHeartbeatWindow 15.0

/// Whether the server still wants the driver to be required.
///
/// The switch is owned by the server (`dylib.verify`) and written here by the
/// app after every heartbeat. Enforcement used to ignore it entirely and gate on
/// the jailbreak check alone, so turning the switch off changed nothing - the
/// app still exited on any device that looked jailbroken. Default NO: until the
/// server has an opinion, nothing is enforced.
static volatile bool gDriverEnforcementEnabled = false;

/// Set by the app when a heartbeat arrives. Called with NO when the server turns
/// the check off or does not mention it.
void AuthCoreSetDriverEnforcement(bool enabled)
{
    gDriverEnforcementEnabled = enabled;
}

bool AuthCoreDriverEnforcementEnabled(void)
{
    return gDriverEnforcementEnabled;
}

/// True when the SpringBoard component is running with a fresh heartbeat.
bool AuthCoreSystemAvailable(void)
{
    @autoreleasepool {
        double age = YOHeartbeatAge();
        return age >= 0 && age <= kComponentHeartbeatWindow;
    }
}

/// Seconds since the component's last heartbeat, or -1 when it was never seen.
double AuthCoreSystemHeartbeatAge(void)
{
    @autoreleasepool {
        return YOHeartbeatAge();
    }
}

/// True when a missing component is a fault on this device, i.e. when the app
/// should refuse to run. Exposed so the UI can show the install instructions
/// instead of letting the grace period expire in silence.
bool AuthCoreComponentRequired(void)
{
    @autoreleasepool {
        if (!gDriverEnforcementEnabled) {
            return false;
        }
        if (AuthCoreSystemAvailable()) {
            return false;
        }
        if (YOIsTrollStoreInstalled()) {
            return false;
        }
        return YOLooksJailbroken();
    }
}

static void ScheduleComponentEnforcement(void);

static void ScheduleComponentEnforcement(void)
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kComponentGraceSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @autoreleasepool {
            // Re-checked at fire time: the component may have come up while the
            // grace period was running.
            //
            // The server switch is re-checked too. Heartbeats land during the
            // grace period, so an operator who turns the requirement off has ten
            // seconds to do it before this fires - and must be able to.
            if (!gDriverEnforcementEnabled) {
                return;
            }
            if (AuthCoreSystemAvailable()) {
                return;
            }
            if (YOIsTrollStoreInstalled()) {
                return;
            }
            if (!YOLooksJailbroken()) {
                return;
            }

            // A missing driver is NOT a reason to kill the app.
            //
            // The driver adds system-wide overlay and touch injection. Everything
            // else - camera detection, photo recognition, chat - runs entirely in
            // this process and needs nothing installed. Exiting here meant a user
            // who flipped the server switch on before installing the component
            // saw the app vanish with no screen, no message and no way back, which
            // is indistinguishable from a crash.
            //
            // The requirement is now advisory: the dashboard reports "driver not
            // ready" with the install steps, and the app keeps working.
            YOLog(@"driver missing after %.0f s; continuing in limited mode",
                  (double)kComponentGraceSeconds);
        }
    });
}

#pragma mark - Card verification (second check, from inside the dylib)

// The app asks the server once, at activation, and keeps the verdict in its own
// defaults. That verdict is the easiest thing in the app to patch out, so the
// dylib performs a second, independent check of the same card. Its result is what
// gates the overlay engine, and it is reported to the server together with what
// the app claimed, so the two can be compared:
//
//     ipa says "valid" but the server says "card revoked"
//        -> the app's copy of the verdict was tampered with
//
// Transport: plain JSON POST. The endpoint is exempt from the encrypted envelope
// on purpose - implementing RSA-OAEP + AES-GCM + a strictly increasing nonce in C
// would add a lot of surface for no gain, since the HMAC below already proves the
// request came from a build that knows the shared secret.
//
// NO GRACE PERIOD. The 300 s cache is a performance measure, not a tolerance:
//   * past the window the answer becomes "invalid" until a fresh check succeeds,
//   * a network failure is a failure, not a reason to keep going,
//   * and the engine stops rather than guessing.

#define kLicenseEndpoint        "https://ios.ouovo.cc/api/lic/dylib"
#define kLicenseCacheSeconds    300.0
#define kLicenseTimeoutSeconds  5.0

// Shared HMAC secret, XOR-masked with 0x5A in the same style as the anti-injection
// image list above. It is a compiled constant by design: a shared-secret scheme,
// not a security boundary. Masking it keeps `strings` from handing it over, which
// is the difference between "forgeable by someone who can disassemble" and
// "forgeable by anyone who can run strings".
static const uint8_t kMaskedLicenseSecret[] = {
    0x63, 0x6f, 0x39, 0x38, 0x62, 0x6e, 0x3b, 0x3f, 0x6a, 0x3b, 0x38, 0x63,
    0x3f, 0x69, 0x63, 0x38, 0x39, 0x6c, 0x6d, 0x62, 0x6f, 0x3e, 0x3c, 0x6a,
    0x3b, 0x6f, 0x3f, 0x6d, 0x6a, 0x3f, 0x3e, 0x62, 0x68, 0x39, 0x68, 0x3b,
    0x38, 0x39, 0x3b, 0x69, 0x6e, 0x6a, 0x3c, 0x6a, 0x6c, 0x3e, 0x63, 0x6d,
    0x3c, 0x3c, 0x3e, 0x6c, 0x6a, 0x63, 0x68, 0x6d, 0x62, 0x3e, 0x6f, 0x6d,
    0x69, 0x3c, 0x69, 0x6c,
};
static const uint8_t kLicenseSecretMask = 0x5A;

/// Keys shared with the SpringBoard half and with the overlay settings panel.
static NSString *const kLicenseCardKey = @"licenseCard";
static NSString *const kLicenseDeviceKey = @"licenseDevice";
static NSString *const kLicenseVerdictKey = @"ipaVerdict";

// Mirrors the paths in OverlayEngine/YOCommon.h. Duplicated deliberately: this
// file must keep compiling and linking even if the engine is ever split out.
static NSString *const kSharedConfigPath =
    @"/var/mobile/Library/Preferences/cc.ouovo.yolooverlay.plist";
static NSString *const kAppLicenseStoreName = @"cc.ouovo.license.plist";

// Result cache. Guarded by a single lock; the network call never holds it.
static NSObject *LicenseLock(void)
{
    static NSObject *lock = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSObject alloc] init];
    });
    return lock;
}

static bool gLicenseValid = false;
static int gLicenseLevel = -1;
static int gLicenseLastResult = 0;
static double gLicenseVerifiedAt = 0;
static NSString *gLicenseCard = nil;
static NSString *gLicenseDevice = nil;

static NSString *HexDigest(const uint8_t *bytes, size_t length)
{
    NSMutableString *hex = [NSMutableString stringWithCapacity:length * 2];
    for (size_t i = 0; i < length; i++) {
        [hex appendFormat:@"%02x", bytes[i]];
    }
    return hex;
}

/// HMAC-SHA256(device_id|card_code|nonce|ts, secret), lowercase hex.
static NSString *LicenseSignature(NSString *device,
                                  NSString *card,
                                  NSString *nonce,
                                  long long timestamp)
{
    NSString *message = [NSString stringWithFormat:@"%@|%@|%@|%lld",
                         device, card, nonce, timestamp];
    const char *data = message.UTF8String;
    if (data == NULL) {
        return nil;
    }

    char secret[sizeof(kMaskedLicenseSecret) + 1];
    size_t secretLength = sizeof(kMaskedLicenseSecret);
    for (size_t i = 0; i < secretLength; i++) {
        secret[i] = (char)(kMaskedLicenseSecret[i] ^ kLicenseSecretMask);
    }
    secret[secretLength] = '\0';

    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CCHmac(kCCHmacAlgSHA256, secret, secretLength, data, strlen(data), digest);
    memset(secret, 0, sizeof(secret));
    return HexDigest(digest, sizeof(digest));
}

static NSString *RandomNonce(void)
{
    uint8_t raw[16];
    for (size_t i = 0; i < sizeof(raw); i++) {
        raw[i] = (uint8_t)(arc4random() & 0xFF);
    }
    return HexDigest(raw, sizeof(raw));
}

/// Reads a string out of the shared config plist, or the app-container copy the
/// SpringBoard half mirrors, whichever is newer. `key` is one of the kLicense*Key.
static NSString *LicenseStoreValue(NSString *key)
{
    @autoreleasepool {
        NSArray<NSString *> *candidates = @[ kSharedConfigPath ];
        // The app's own container, readable by both hosts.
        NSString *documents = nil;
        if (!AuthCoreIsSpringBoardHost()) {
            documents = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                             NSUserDomainMask, YES) firstObject];
        }
        NSMutableArray<NSString *> *paths = [NSMutableArray arrayWithArray:candidates];
        if (documents.length > 0) {
            [paths addObject:[documents stringByAppendingPathComponent:kAppLicenseStoreName]];
        }

        for (NSString *path in paths) {
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:path];
            if (![plist isKindOfClass:[NSDictionary class]]) {
                continue;
            }
            id value = plist[key];
            if ([value isKindOfClass:[NSString class]] && [(NSString *)value length] > 0) {
                return value;
            }
        }
        return nil;
    }
}

/// Writes the license pair where the SpringBoard half can read it.
/// Two destinations because exactly one of them is always writable:
/// the shared plist (needs an unsandboxed app) and the app's own Documents.
static void LicensePublish(NSString *card, NSString *device, BOOL appVerdict)
{
    if (card.length == 0 || device.length == 0) {
        return;
    }
    @autoreleasepool {
        NSString *verdict = appVerdict ? @"1" : @"0";

        // Shared plist: merge, never clobber the overlay tuning keys.
        NSMutableDictionary *shared =
            [[NSDictionary dictionaryWithContentsOfFile:kSharedConfigPath] mutableCopy];
        if (shared == nil) {
            shared = [NSMutableDictionary dictionary];
        }
        [shared setObject:card forKey:kLicenseCardKey];
        [shared setObject:device forKey:kLicenseDeviceKey];
        [shared setObject:verdict forKey:kLicenseVerdictKey];
        [shared writeToFile:kSharedConfigPath atomically:YES];

        // App container: always writable, and SpringBoard can read it.
        NSString *documents =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,
                                                 NSUserDomainMask, YES) firstObject];
        if (documents.length > 0) {
            NSDictionary *payload = @{
                kLicenseCardKey: card,
                kLicenseDeviceKey: device,
                kLicenseVerdictKey: verdict,
            };
            NSString *path = [documents stringByAppendingPathComponent:kAppLicenseStoreName];
            [payload writeToFile:path atomically:YES];
        }
    }
}

/// Device fingerprint, identical to LicenseDevice.fingerprint in Swift:
/// sha256("<keychain uuid>|<idfv>"). Only computable in the app process, because
/// identifierForVendor is per-app and SpringBoard has none.
static NSString *ComputeDeviceFingerprint(void)
{
    @autoreleasepool {
        NSString *stable = nil;
        NSDictionary *query = @{
            (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
            (__bridge id)kSecAttrService: @"cc.ouovo.yoloperson.license",
            (__bridge id)kSecAttrAccount: @"device_uuid",
            (__bridge id)kSecReturnData: @YES,
            (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne,
        };
        CFTypeRef item = NULL;
        if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &item) == errSecSuccess &&
            item != NULL) {
            NSData *data = (__bridge_transfer NSData *)item;
            stable = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
        if (stable.length == 0) {
            return nil;
        }

        NSString *identifier = nil;
        @try {
            identifier = [[[UIDevice currentDevice] identifierForVendor] UUIDString];
        } @catch (__unused NSException *exception) {
            identifier = nil;
        }
        if (identifier.length == 0) {
            identifier = @"no-idfv";
        }

        NSString *joined = [NSString stringWithFormat:@"%@|%@", stable, identifier];
        const char *bytes = joined.UTF8String;
        if (bytes == NULL) {
            return nil;
        }
        uint8_t digest[CC_SHA256_DIGEST_LENGTH];
        CC_SHA256(bytes, (CC_LONG)strlen(bytes), digest);
        return HexDigest(digest, sizeof(digest));
    }
}

/// One request, synchronous with a hard timeout. Returns 0 when a response
/// arrived (whatever its verdict), -1 when it did not.
static int LicensePerformRequest(NSString *card,
                                 NSString *device,
                                 NSDictionary **outJSON,
                                 long *outStatus)
{
    @autoreleasepool {
        NSString *nonce = RandomNonce();
        long long timestamp = (long long)[[NSDate date] timeIntervalSince1970];
        NSString *signature = LicenseSignature(device, card, nonce, timestamp);
        if (signature.length == 0) {
            return -1;
        }

        NSString *verdict = LicenseStoreValue(kLicenseVerdictKey) ?: @"1";
        NSDictionary *body = @{
            @"device_id": device,
            @"card_code": card,
            @"ipa_verdict": verdict,
            @"nonce": nonce,
            @"ts": @(timestamp),
            @"sig": signature,
        };

        NSError *encodeError = nil;
        NSData *payload = [NSJSONSerialization dataWithJSONObject:body
                                                         options:0
                                                           error:&encodeError];
        if (payload == nil) {
            return -1;
        }

        NSURL *url = [NSURL URLWithString:@(kLicenseEndpoint)];
        if (url == nil) {
            return -1;
        }
        NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
        request.HTTPMethod = @"POST";
        request.HTTPBody = payload;
        request.timeoutInterval = kLicenseTimeoutSeconds;
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];

        NSURLSessionConfiguration *configuration =
            [NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.timeoutIntervalForRequest = kLicenseTimeoutSeconds;
        configuration.timeoutIntervalForResource = kLicenseTimeoutSeconds;
        configuration.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
        NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];

        __block NSData *responseData = nil;
        __block long status = 0;
        __block BOOL finished = NO;
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);

        NSURLSessionDataTask *task =
            [session dataTaskWithRequest:request
                       completionHandler:^(NSData *data,
                                           NSURLResponse *response,
                                           NSError *error) {
            if (error == nil) {
                responseData = data;
                if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
                    status = (long)[(NSHTTPURLResponse *)response statusCode];
                }
            }
            finished = YES;
            dispatch_semaphore_signal(semaphore);
        }];
        [task resume];

        // The timeout is enforced here as well as on the request: a stalled
        // session must not hold the caller for longer than the budget.
        dispatch_semaphore_wait(semaphore,
                                dispatch_time(DISPATCH_TIME_NOW,
                                              (int64_t)((kLicenseTimeoutSeconds + 0.5) * NSEC_PER_SEC)));
        [session invalidateAndCancel];

        if (!finished || responseData == nil) {
            return -1;
        }
        if (outStatus != NULL) {
            *outStatus = status;
        }
        if (outJSON != NULL) {
            id parsed = [NSJSONSerialization JSONObjectWithData:responseData
                                                        options:0
                                                          error:NULL];
            *outJSON = [parsed isKindOfClass:[NSDictionary class]] ? parsed : nil;
        }
        return 0;
    }
}

/// Maps a server response onto the result codes the header documents.
static int LicenseEvaluate(NSDictionary *json, long status, int *outLevel)
{
    if (outLevel != NULL) {
        *outLevel = -1;
    }
    // 403 signature_invalid / 400 stale_request are configuration problems, not
    // card problems - a wrong secret would look like "everything is revoked".
    if (status == 403 || status == 400) {
        return -3;
    }
    if (json == nil) {
        return (status >= 200 && status < 300) ? -4 : -4;
    }

    id data = json[@"data"];
    NSDictionary *payload = [data isKindOfClass:[NSDictionary class]] ? data : json;

    int level = -1;
    for (NSString *key in @[@"level", @"user_level", @"tier"]) {
        id value = payload[key];
        if ([value isKindOfClass:[NSNumber class]]) {
            level = [value intValue];
            break;
        }
    }
    if (level < 0) {
        id user = payload[@"user"];
        if ([user isKindOfClass:[NSDictionary class]]) {
            id value = user[@"level"];
            if ([value isKindOfClass:[NSNumber class]]) {
                level = [value intValue];
            }
        }
    }
    if (outLevel != NULL) {
        *outLevel = level;
    }

    if (status < 200 || status >= 300) {
        return -4;
    }

    id ok = json[@"ok"];
    BOOL okFlag = [ok isKindOfClass:[NSNumber class]] ? [ok boolValue] : (status == 200);
    id valid = payload[@"valid"];
    if ([valid isKindOfClass:[NSNumber class]] && ![valid boolValue]) {
        okFlag = NO;
    }
    if (!okFlag) {
        // A card-level rejection is distinguishable from a generic refusal by the
        // reason string the server sends.
        NSString *reason = payload[@"reason"] ?: json[@"reason"];
        if ([reason isKindOfClass:[NSString class]] &&
            [reason rangeOfString:@"card"].location != NSNotFound) {
            return -2;
        }
        return -4;
    }
    return 0;
}

int AuthCoreSubmitCard(const char *cardCode, const char *deviceId)
{
    if (cardCode == NULL || deviceId == NULL) {
        return -3;
    }
    @autoreleasepool {
        NSString *card = [[NSString stringWithUTF8String:cardCode]
                          stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        NSString *device = [NSString stringWithUTF8String:deviceId];
        if (card.length == 0 || device.length == 0) {
            return -3;
        }

        double now = [[NSDate date] timeIntervalSince1970];
        @synchronized (LicenseLock()) {
            if (gLicenseValid && (now - gLicenseVerifiedAt) <= kLicenseCacheSeconds &&
                [gLicenseCard isEqualToString:card] &&
                [gLicenseDevice isEqualToString:device]) {
                return 0;
            }
        }

        NSDictionary *json = nil;
        long status = 0;
        int result;
        int level = -1;
        if (LicensePerformRequest(card, device, &json, &status) != 0) {
            result = -1;
        } else {
            result = LicenseEvaluate(json, status, &level);
        }

        @synchronized (LicenseLock()) {
            gLicenseLastResult = result;
            gLicenseCard = [card copy];
            gLicenseDevice = [device copy];
            if (result == 0) {
                gLicenseValid = true;
                gLicenseVerifiedAt = now;
                if (level >= 0) {
                    gLicenseLevel = level;
                }
            } else {
                // No grace: a failure invalidates immediately, including a
                // previously good result.
                gLicenseValid = false;
            }
        }
        YOLog(@"license check card=%@ result=%d level=%d", [card substringToIndex:MIN(4u, card.length)],
              result, level);
        return result;
    }
}

bool AuthCoreLicenseValid(void)
{
    @synchronized (LicenseLock()) {
        if (!gLicenseValid) {
            return false;
        }
        double age = [[NSDate date] timeIntervalSince1970] - gLicenseVerifiedAt;
        return age >= 0 && age <= kLicenseCacheSeconds;
    }
}

double AuthCoreLicenseAge(void)
{
    @synchronized (LicenseLock()) {
        if (gLicenseVerifiedAt <= 0) {
            return -1.0;
        }
        return [[NSDate date] timeIntervalSince1970] - gLicenseVerifiedAt;
    }
}

int AuthCoreLicenseLevel(void)
{
    @synchronized (LicenseLock()) {
        return gLicenseValid ? gLicenseLevel : -1;
    }
}

int AuthCoreLastLicenseResult(void)
{
    @synchronized (LicenseLock()) {
        return gLicenseLastResult;
    }
}

/// Publishes the card and device the app holds into the shared stores, then runs
/// one check. Called from the app host after launch and when the app asks.
///
/// Returns immediately when the server has turned the driver check off. This runs
/// two seconds after launch on a utility queue and performs a blocking POST; doing
/// that unconditionally meant every launch on a device without the component
/// started a network round trip nobody asked for, at exactly the moment the first
/// frame is being presented.
void AuthCoreSyncLicense(void)
{
    @autoreleasepool {
        if (!gDriverEnforcementEnabled) {
            return;
        }
        NSString *card = [[NSUserDefaults standardUserDefaults] stringForKey:@"lic.lastCard"];
        BOOL granted = [[NSUserDefaults standardUserDefaults] boolForKey:@"lic.hasGrant"];
        NSString *device = ComputeDeviceFingerprint();
        if (card.length == 0 || device.length == 0) {
            return;
        }
        LicensePublish(card, device, granted);
        (void)AuthCoreSubmitCard(card.UTF8String, device.UTF8String);
    }
}

#pragma mark - Anti-debugging

// Two independent checks: the ptrace flag and the kernel's own view of this
// process. Either one firing is enough to report a debugger.
static bool IsDebugged(void)
{
    // A debugger attaching after DENY_ATTACH fails, so this also stops a live
    // debugger from connecting later.
    (void)ptrace(PT_DENY_ATTACH, 0, 0, 0);

    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid() };
    struct kinfo_proc info;
    memset(&info, 0, sizeof(info));
    size_t size = sizeof(info);

    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        // If the query itself fails, do not treat that as evidence.
        return false;
    }
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

#pragma mark - Anti-injection

// Image names that indicate a hooking framework. Stored XOR-masked with 0x7F so
// a plain `strings` pass over the binary does not reveal the whole list.
static const char *kMaskedNames[] = {
    "\x39\x0d\x16\x1b\x1e\x38\x1e\x1b\x18\x1a\x0b\x51\x1b\x06\x13\x16\x1d", // FridaGadget.dylib
    "\x19\x0d\x16\x1b\x1e\x52\x1e\x18\x1a\x11\x0b\x51\x1b\x06\x13\x16\x1d", // frida-agent.dylib
    "\x13\x16\x1d\x0c\x0a\x1d\x0c\x0b\x0d\x1e\x0b\x1a\x51\x1b\x06\x13\x16\x1d", // libsubstrate.dylib
    "\x3c\x06\x1b\x16\x1e\x2c\x0a\x1d\x0c\x0b\x0d\x1e\x0b\x1a",              // CydiaSubstrate
    "\x13\x16\x1d\x1c\x06\x1c\x0d\x16\x0f\x0b\x51\x1b\x06\x13\x16\x1d",      // libcycript.dylib
    "\x32\x2c\x37\x10\x10\x14\x36\x11\x15\x1a\x1c\x0b\x51\x1b\x06\x13\x16\x1d", // MSHookInject.dylib
    "\x2b\x08\x1a\x1e\x14\x36\x11\x15\x1a\x1c\x0b\x51\x1b\x06\x13\x16\x1d",  // TweakInject.dylib
};
static const uint8_t kMask = 0x7F;

// Decrypts and matches one masked name against a live image path.
static bool MatchesMasked(const char *imagePath, const char *masked)
{
    if (imagePath == NULL || masked == NULL) return false;

    size_t len = strlen(masked);
    if (len == 0 || len > 128) return false;

    char plain[129];
    for (size_t i = 0; i < len; i++) {
        plain[i] = (char)(masked[i] ^ kMask);
    }
    plain[len] = '\0';

    return strstr(imagePath, plain) != NULL;
}

static bool HasSuspiciousImages(void)
{
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name == NULL) continue;
        for (size_t j = 0; j < sizeof(kMaskedNames) / sizeof(kMaskedNames[0]); j++) {
            if (MatchesMasked(name, kMaskedNames[j])) {
                return true;
            }
        }
    }
    return false;
}

#pragma mark - Integrity

// SHA-256 over this image's __TEXT segment up to a bounded size.
//
// Only __TEXT is hashed: signatures and link metadata live in __LINKEDIT, so
// re-signing the app does not change this value. Hashing the whole file would
// report a mismatch after every re-sign.
static NSString *TextSegmentDigest(void)
{
    const struct mach_header_64 *header = NULL;

    // Find our own image by locating this function's address inside it.
    Dl_info info;
    if (dladdr((const void *)&TextSegmentDigest, &info) == 0 ||
        info.dli_fbase == NULL) {
        return @"unavailable";
    }
    header = (const struct mach_header_64 *)info.dli_fbase;

    if (header->magic != MH_MAGIC_64) {
        return @"unavailable";
    }

    const uint8_t *base = (const uint8_t *)header;
    const uint8_t *cursor = base + sizeof(struct mach_header_64);

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, "__TEXT", 16) == 0) {
                // Cap the length: the segment can be larger than needed and a
                // full hash on every call is avoidable.
                const uint8_t *start = base + seg->fileoff;
                size_t length = (size_t)seg->filesize;
                if (length > 512 * 1024) length = 512 * 1024;

                uint8_t digest[CC_SHA256_DIGEST_LENGTH];
                CC_SHA256(start, (CC_LONG)length, digest);

                NSMutableString *hex =
                    [NSMutableString stringWithCapacity:CC_SHA256_DIGEST_LENGTH * 2];
                // Only the first 8 bytes are reported: enough to detect a change,
                // short enough to keep the heartbeat payload small.
                for (int i = 0; i < 8; i++) {
                    [hex appendFormat:@"%02x", digest[i]];
                }
                return hex;
            }
        }
        cursor += lc->cmdsize;
    }

    return @"unavailable";
}

#pragma mark - __TEXT closed-loop self-check

// WHY THIS EXISTS
// ---------------
// Every verdict this dylib reaches about itself can be patched out; this check
// only raises the cost of doing it. It hashes four disjoint intervals of this
// image's own __TEXT and compares each against a value baked in at link time.
//
// The expected values cannot live in __TEXT, because they describe __TEXT. They
// cannot live in __LINKEDIT either: re-signing rewrites the signature block, so
// every codesign would invalidate them. They live in a custom section:
//
//     -Wl,-sectcreate,__DATA,__guard,<payload>
//
// produced by the two-stage link in scripts/authcore_integrity.py: link once with
// a zero-filled payload, hash the resulting __TEXT, fill the payload, link again.
// The second link must not move a byte of __TEXT, and the script's `verify`
// command asserts that rather than trusting it.
//
// FOUR VARIANTS, FOUR RANGES
// --------------------------
// Each probe hashes the interval of __TEXT that starts at its own entry address
// and ends at the next probe's address, so the four intervals partition the
// segment. Patching one probe's body therefore breaks that probe's own range and
// the range of whichever probe precedes it. Each probe also uses a different
// digest shape - SHA-256 head, SHA-256 tail, SHA-512 head, XOR-folded SHA-256 -
// so neutralising the verdict means defeating four different comparisons instead
// of one.
//
// The probes are deliberately non-static: the build has to find their addresses
// in the symbol table to compute the same ranges, and dladdr() has to resolve
// them at runtime for the device to agree with the build.
//
// FAILURE IS SILENT
// -----------------
// Nothing here draws, logs or alerts. A failed verdict only clears gIntegrityOK,
// which is reported to the server with the heartbeat. Telling a patcher that the
// check failed tells them which branch to look at next.
//
// A zero-filled payload means the feature was never armed (a build that skipped
// the stage-2 link, e.g. the local xcodeproj stub). That is treated as a pass: a
// self-check that was not built must not break a legitimate install. The real
// signal in that case is the digest reported with the heartbeat, which the server
// compares against the value registered for the release.

#define kIntegrityPayloadMagic0 'A'
#define kIntegrityPayloadMagic1 'U'
#define kIntegrityPayloadMagic2 'G'
#define kIntegrityPayloadMagic3 '2'

// Payload geometry, must match scripts/authcore_integrity.py.
#define kIntegritySlotCount     4
#define kIntegritySlotLength    56
#define kIntegrityPayloadLength 256
#define kIntegritySlotBase      16
#define kIntegrityDigestLength  8

// The four probes. Declared here because YOProbeOffset needs their addresses
// before their bodies are reached: the ranges are defined by where the linker
// placed them, and the only way to know that at runtime is to take the address.
bool YOIntegrityProbeA(void);
bool YOIntegrityProbeB(void);
bool YOIntegrityProbeC(void);
bool YOIntegrityProbeD(void);

typedef enum {
    YOIntegrityStateUnknown = 0,
    YOIntegrityStateOK,
    YOIntegrityStateUnarmed,
    YOIntegrityStateTampered,
    YOIntegrityStateBroken,
} YOIntegrityState;

static volatile YOIntegrityState gIntegrityState = YOIntegrityStateUnknown;

/// What the runtime needs to hash and compare: where the hashed section is,
/// where the expected values are, and which slot belongs to the CPU executing
/// this code.
typedef struct {
    const struct mach_header_64 *header;
    const uint8_t *text;        // first byte of __TEXT,__text in memory
    size_t textLength;          // its size
    const uint8_t *guard;       // __DATA,__guard payload, or NULL
    size_t guardLength;
    const uint8_t *slot;        // 56-byte slot for this CPU, or NULL when unarmed
    bool armed;                 // payload present and self-consistent
} YOIntegrityContext;

/// The segment command for `name` in this image, or NULL.
static const struct segment_command_64 *YOFindSegment(const struct mach_header_64 *header,
                                                      const char *name)
{
    const uint8_t *cursor = (const uint8_t *)header + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)cursor;
        if (lc->cmdsize < sizeof(struct load_command)) {
            return NULL;
        }
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strncmp(seg->segname, name, 16) == 0) {
                return seg;
            }
        }
        cursor += lc->cmdsize;
    }
    return NULL;
}

/// The section called `name` inside `seg`, or NULL.
static const struct section_64 *YOFindSection(const struct segment_command_64 *seg,
                                              const char *name)
{
    if (seg == NULL) {
        return NULL;
    }
    const struct section_64 *sect =
        (const struct section_64 *)((const uint8_t *)seg + sizeof(struct segment_command_64));
    for (uint32_t i = 0; i < seg->nsects; i++, sect++) {
        if (strncmp(sect->sectname, name, 16) == 0) {
            return sect;
        }
    }
    return NULL;
}

/// Address of the exported symbol at or below `address` in this process.
static const uint8_t *YOSymbolStart(const void *address)
{
    Dl_info info;
    if (dladdr(address, &info) == 0) {
        return NULL;
    }
    if (info.dli_saddr == NULL) {
        return NULL;
    }
    return (const uint8_t *)info.dli_saddr;
}

/// Fills `ctx` from this image's own load commands.
///
/// Returns false only when the image cannot be introspected at all - no dladdr,
/// no Mach-O header, no __TEXT. A missing or zero-filled __guard is not a
/// failure: it sets armed = false and the caller treats the check as disabled.
static bool YOLoadIntegrityContext(YOIntegrityContext *ctx)
{
    memset(ctx, 0, sizeof(*ctx));

    // Identify this image by the address of a function in it.
    Dl_info info;
    if (dladdr((const void *)&YOLoadIntegrityContext, &info) == 0 ||
        info.dli_fbase == NULL) {
        return false;
    }
    const struct mach_header_64 *header = (const struct mach_header_64 *)info.dli_fbase;
    if (header->magic != MH_MAGIC_64) {
        return false;
    }
    ctx->header = header;

    const struct segment_command_64 *text = YOFindSegment(header, "__TEXT");
    if (text == NULL || text->filesize == 0) {
        return false;
    }
    // The hashed region is the __TEXT,__text SECTION, not the whole segment.
    //
    // __TEXT also holds __stubs, __cstring, __const and, on arm64e with chained
    // fixups, __auth_stubs - whose pointer slots dyld rebases at load time. A
    // segment-wide hash would therefore compare live memory against file bytes
    // that dyld has legitimately rewritten, and report tampering on every clean
    // install. __text is pure code: the linker emits no rebase or bind into it,
    // so the file bytes and the mapped bytes are identical.
    const struct section_64 *textSection = YOFindSection(text, "__text");
    if (textSection == NULL || textSection->size == 0) {
        return false;
    }
    ctx->text = (const uint8_t *)header + textSection->offset;
    ctx->textLength = (size_t)textSection->size;

    // __DATA,__guard, read with getsectiondata() from this image's own header.
    //
    // The LP64 prototype is
    //     uint8_t *getsectiondata(const struct mach_header_64 *mhp,
    //                             const char *segname, const char *sectname,
    //                             unsigned long *size);
    // so the header is passed through unchanged and the size is an
    // `unsigned long`. Casting the header to `struct mach_header *` - the 32-bit
    // branch's shape - would be an incompatible-pointer argument on every 64-bit
    // build, which this file must not depend on a warning setting to survive.
    unsigned long guardSize = 0;
    const uint8_t *guard =
        getsectiondata(header, "__DATA", "__guard", &guardSize);
    if (guard == NULL) {
        // Fallback for the one case getsectiondata() cannot serve: an image
        // whose __TEXT mapping was relocated away from its link-time address.
        // The arithmetic is the same one dyld uses, keeping the guard address a
        // pure vmaddr computation rather than a pointer derived from PAC-tagged
        // code.
        const struct segment_command_64 *data = YOFindSegment(header, "__DATA");
        const struct section_64 *sect = YOFindSection(data, "__guard");
        if (sect != NULL && sect->offset != 0) {
            const uintptr_t slide = (uintptr_t)header - (uintptr_t)text->vmaddr;
            guard = (const uint8_t *)(slide + (uintptr_t)sect->addr);
            guardSize = (unsigned long)sect->size;
        }
    }
    if (guard == NULL || guardSize < kIntegrityPayloadLength) {
        return true;
    }
    ctx->guard = guard;
    ctx->guardLength = (size_t)guardSize;

    // Magic. A zero-filled payload from the stage-1 link lands here, and so does
    // a build that never filled it in: both mean "not armed", not "tampered".
    if (guard[0] != kIntegrityPayloadMagic0 ||
        guard[1] != kIntegrityPayloadMagic1 ||
        guard[2] != kIntegrityPayloadMagic2 ||
        guard[3] != (uint8_t)kIntegrityPayloadMagic3) {
        return true;
    }

    // Trailer: sha256(bytes[0:240])[0:16]. A payload that fails this is not a
    // payload this build wrote, so it is treated as unarmed rather than as
    // evidence of tampering - a corrupted section is a build fault.
    uint8_t trailer[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(guard, (CC_LONG)(kIntegrityPayloadLength - 16), trailer);
    if (memcmp(trailer, guard + kIntegrityPayloadLength - 16, 16) != 0) {
        return true;
    }

    uint32_t count = (uint32_t)guard[4] | ((uint32_t)guard[5] << 8) |
                     ((uint32_t)guard[6] << 16) | ((uint32_t)guard[7] << 24);
    if (count < 1 || count > kIntegritySlotCount) {
        return true;
    }

    // One slot per CPU. The layout is written by the build from the same header
    // fields, so the comparison is exact rather than a guess.
    //
    // The subtype is masked to its low 24 bits on both sides: the ptrauth feature
    // bits above bit 24 describe capabilities, not the CPU variant, and the build
    // applies the same mask before writing the slot.
    const int32_t cputype = header->cputype;
    const int32_t cpusubtype = (int32_t)(header->cpusubtype & 0x00FFFFFFu);
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *candidate = guard + kIntegritySlotBase + i * kIntegritySlotLength;
        int32_t cpu = (int32_t)((uint32_t)candidate[0] | ((uint32_t)candidate[1] << 8) |
                                ((uint32_t)candidate[2] << 16) | ((uint32_t)candidate[3] << 24));
        int32_t sub = (int32_t)((uint32_t)candidate[4] | ((uint32_t)candidate[5] << 8) |
                                ((uint32_t)candidate[6] << 16) | ((uint32_t)candidate[7] << 24));
        if (cpu == cputype && sub == cpusubtype) {
            ctx->slot = candidate;
            ctx->armed = true;
            break;
        }
    }
    return true;
}

/// Byte offset of the probe at `index` inside __TEXT,__text, or false when its
/// symbol cannot be resolved. `index` is 0..3 for probes A..D.
static bool YOProbeOffset(int index, const YOIntegrityContext *ctx, size_t *outOffset)
{
    // The four entry points, in probe order. Referenced through a table rather
    // than four copies of the same call, so the ranges stay in step with the
    // build's PROBE_SYMBOLS list.
    typedef bool (*YOProbeEntry)(void);
    static const YOProbeEntry kEntries[4] = {
        YOIntegrityProbeA,
        YOIntegrityProbeB,
        YOIntegrityProbeC,
        YOIntegrityProbeD,
    };
    if (index < 0 || index > 3) {
        return false;
    }
    const uint8_t *start = YOSymbolStart((const void *)kEntries[index]);
    if (start == NULL) {
        return false;
    }
    if (start < ctx->text || start >= ctx->text + ctx->textLength) {
        return false;
    }
    // Both sides measure from the start of the section, so the index is just the
    // distance into the mapped section. No vmaddr arithmetic is involved.
    size_t offset = (size_t)(start - ctx->text);
    if (offset >= ctx->textLength) {
        return false;
    }
    *outOffset = offset;
    return true;
}

/// The interval probe `index` is responsible for.
///
/// The four probes PARTITION __TEXT,__text. Boundaries are the four probe entry
/// addresses plus 0 and the section end; the probe with the lowest address also
/// owns everything before it. Starting that lowest range at 0 rather than at its
/// own entry is not cosmetic: __text opens with code defined earlier in this
/// file (the constructor, the host check, the entry points), and a range that
/// began at the first probe would leave all of it unhashed - a free patch site
/// inside the section the check claims to cover.
///
/// This mirrors probe_ranges() in scripts/authcore_integrity.py exactly, because
/// a range that differs by one byte on either side reports a false mismatch on
/// every device.
static bool YOProbeRange(int index, const YOIntegrityContext *ctx,
                         const uint8_t **outBuffer, size_t *outLength)
{
    size_t own = 0;
    if (!YOProbeOffset(index, ctx, &own)) {
        return false;
    }

    // Lower bound: everything from 0 when this probe is the lowest, otherwise
    // the highest probe entry strictly below it.
    size_t lo = 0;
    size_t hi = ctx->textLength;
    for (int other = 0; other < 4; other++) {
        if (other == index) {
            continue;
        }
        size_t candidate = 0;
        if (!YOProbeOffset(other, ctx, &candidate)) {
            // A probe whose symbol is missing cannot be ranged. Give up on all
            // four rather than hash a range the build never computed.
            return false;
        }
        if (candidate < own && candidate > lo) {
            lo = candidate;
        }
        if (candidate > own && candidate < hi) {
            hi = candidate;
        }
    }
    if (hi <= lo) {
        return false;
    }

    *outBuffer = ctx->text + lo;
    *outLength = hi - lo;
    return true;
}

/// Compares the 8-byte digest of probe `index` with the value in __guard.
///
/// Unarmed returns true: the caller has already established that arming was never
/// possible, and a check that was not built must not report a fault.
static bool YOIntegrityExpected(int index, const uint8_t *actual)
{
    YOIntegrityContext ctx;
    if (!YOLoadIntegrityContext(&ctx)) {
        return false;
    }
    if (!ctx.armed || ctx.slot == NULL) {
        return true;
    }
    const uint8_t *want = ctx.slot + 8 + index * kIntegrityDigestLength;
    uint8_t difference = 0;
    for (size_t i = 0; i < kIntegrityDigestLength; i++) {
        difference |= (uint8_t)(actual[i] ^ want[i]);
    }
    return difference == 0;
}

#pragma mark - Probes A..D

// Each probe hashes the __TEXT interval that starts at its own entry address.
// They are non-static: the two-stage build resolves these symbols to compute the
// same intervals, and dladdr() resolves them on device.

__attribute__((noinline)) __attribute__((visibility("default")))
bool YOIntegrityProbeA(void)
{
    YOIntegrityContext ctx;
    const uint8_t *buffer = NULL;
    size_t length = 0;
    if (!YOLoadIntegrityContext(&ctx)) {
        return false;
    }
    if (!YOProbeRange(0, &ctx, &buffer, &length)) {
        return false;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(buffer, (CC_LONG)length, digest);
    return YOIntegrityExpected(0, digest);      // SHA-256, leading 8 bytes
}

__attribute__((noinline)) __attribute__((visibility("default")))
bool YOIntegrityProbeB(void)
{
    YOIntegrityContext ctx;
    const uint8_t *buffer = NULL;
    size_t length = 0;
    if (!YOLoadIntegrityContext(&ctx)) {
        return false;
    }
    if (!YOProbeRange(1, &ctx, &buffer, &length)) {
        return false;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(buffer, (CC_LONG)length, digest);
    return YOIntegrityExpected(1, digest + (CC_SHA256_DIGEST_LENGTH - 8));
                                                // SHA-256, trailing 8 bytes
}

__attribute__((noinline)) __attribute__((visibility("default")))
bool YOIntegrityProbeC(void)
{
    YOIntegrityContext ctx;
    const uint8_t *buffer = NULL;
    size_t length = 0;
    if (!YOLoadIntegrityContext(&ctx)) {
        return false;
    }
    if (!YOProbeRange(2, &ctx, &buffer, &length)) {
        return false;
    }
    uint8_t digest[CC_SHA512_DIGEST_LENGTH];
    CC_SHA512(buffer, (CC_LONG)length, digest);
    return YOIntegrityExpected(2, digest);      // SHA-512, leading 8 bytes
}

__attribute__((noinline)) __attribute__((visibility("default")))
bool YOIntegrityProbeD(void)
{
    YOIntegrityContext ctx;
    const uint8_t *buffer = NULL;
    size_t length = 0;
    if (!YOLoadIntegrityContext(&ctx)) {
        return false;
    }
    if (!YOProbeRange(3, &ctx, &buffer, &length)) {
        return false;
    }
    uint8_t digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256(buffer, (CC_LONG)length, digest);

    // XOR-folded: every byte of the digest participates in the comparison, so a
    // patch that flips one digest byte cannot hide in the half that is skipped.
    uint8_t folded[8];
    memset(folded, 0, sizeof(folded));
    for (size_t i = 0; i < CC_SHA256_DIGEST_LENGTH; i++) {
        folded[i % sizeof(folded)] ^= digest[i];
    }
    return YOIntegrityExpected(3, folded);
}

/// All four verdicts, evaluated unconditionally.
///
/// No short-circuit: `a && b && ...` on four calls would stop at the first false,
/// and a patcher only needs one probe left alive. Each probe is called into a
/// local first, so the compiler cannot fold the four into a chain either.
static bool YOIntegrityAllPass(void)
{
    YOIntegrityContext ctx;
    if (!YOLoadIntegrityContext(&ctx)) {
        gIntegrityState = YOIntegrityStateBroken;
        gIntegrityOK = false;
        return false;
    }
    if (!ctx.armed) {
        // Zero-filled payload: the two-stage link did not run. Report "not
        // armed" and let the reported digest carry the signal to the server.
        gIntegrityState = YOIntegrityStateUnarmed;
        gIntegrityOK = true;
        return true;
    }

    bool a = YOIntegrityProbeA();
    bool b = YOIntegrityProbeB();
    bool c = YOIntegrityProbeC();
    bool d = YOIntegrityProbeD();

    bool pass = a && b && c && d;
    gIntegrityState = pass ? YOIntegrityStateOK : YOIntegrityStateTampered;
    gIntegrityOK = pass;
    return pass;
}

bool AuthCoreIntegrityVerified(void)
{
    // Evaluated in full before the cached verdict is consulted: `&&` here would
    // short-circuit past YOIntegrityAllPass on a stale false.
    bool pass = YOIntegrityAllPass();
    return pass && gIntegrityOK;
}

/// The digest this build actually computes, 64 lowercase hex characters: four
/// 8-byte probe digests in probe order.
///
/// This is what the server compares against lic_versions.text_digest. It is
/// computed from the live image, so a zeroed __guard leaves it intact - the
/// local verdict is a decoy, this value is the evidence.
const char *AuthCoreIntegrityDigest(void)
{
    static char *cached = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char *hex = (char *)calloc(65, 1);
        if (hex == NULL) {
            return;
        }

        YOIntegrityContext ctx;
        uint8_t digests[4][kIntegrityDigestLength];
        bool ok = YOLoadIntegrityContext(&ctx);
        for (int i = 0; ok && i < 4; i++) {
            const uint8_t *buffer = NULL;
            size_t length = 0;
            if (!YOProbeRange(i, &ctx, &buffer, &length)) {
                ok = false;
                break;
            }
            switch (i) {
                case 0: {
                    uint8_t raw[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(buffer, (CC_LONG)length, raw);
                    memcpy(digests[0], raw, kIntegrityDigestLength);
                    break;
                }
                case 1: {
                    uint8_t raw[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(buffer, (CC_LONG)length, raw);
                    memcpy(digests[1], raw + (CC_SHA256_DIGEST_LENGTH - 8),
                           kIntegrityDigestLength);
                    break;
                }
                case 2: {
                    uint8_t raw[CC_SHA512_DIGEST_LENGTH];
                    CC_SHA512(buffer, (CC_LONG)length, raw);
                    memcpy(digests[2], raw, kIntegrityDigestLength);
                    break;
                }
                default: {
                    uint8_t raw[CC_SHA256_DIGEST_LENGTH];
                    CC_SHA256(buffer, (CC_LONG)length, raw);
                    memset(digests[3], 0, kIntegrityDigestLength);
                    for (size_t k = 0; k < CC_SHA256_DIGEST_LENGTH; k++) {
                        digests[3][k % kIntegrityDigestLength] ^= raw[k];
                    }
                    break;
                }
            }
        }

        if (!ok) {
            // Empty means "not reported": the server treats it as a legacy
            // client rather than as a mismatch, which is the honest answer when
            // this image cannot describe itself.
            hex[0] = '\0';
            cached = hex;
            return;
        }

        static const char kHex[] = "0123456789abcdef";
        for (int i = 0; i < 4; i++) {
            for (size_t k = 0; k < kIntegrityDigestLength; k++) {
                hex[i * 16 + k * 2] = kHex[(digests[i][k] >> 4) & 0xF];
                hex[i * 16 + k * 2 + 1] = kHex[digests[i][k] & 0xF];
            }
        }
        cached = hex;
    });
    return cached != NULL ? cached : "";
}

/// L2: the version fingerprint registered for this build, 32 lowercase hex
/// characters, or an empty string when the payload is not armed.
const char *AuthCoreVersionFingerprint(void)
{
    static char *cached = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char *hex = (char *)calloc(33, 1);
        if (hex == NULL) {
            return;
        }
        YOIntegrityContext ctx;
        if (!YOLoadIntegrityContext(&ctx) || !ctx.armed || ctx.slot == NULL) {
            hex[0] = '\0';
            cached = hex;
            return;
        }
        // Fingerprint occupies the last 16 bytes of the slot.
        const uint8_t *fingerprint = ctx.slot + 8 + 4 * kIntegrityDigestLength;
        static const char kHex[] = "0123456789abcdef";
        for (size_t i = 0; i < 16; i++) {
            hex[i * 2] = kHex[(fingerprint[i] >> 4) & 0xF];
            hex[i * 2 + 1] = kHex[fingerprint[i] & 0xF];
        }
        cached = hex;
    });
    return cached != NULL ? cached : "";
}

/// Stable name for the last verdict, for logs the operator can read. The app
/// never shows this; it is for the heartbeat report only.
const char *AuthCoreIntegrityState(void)
{
    switch (gIntegrityState) {
        case YOIntegrityStateOK:       return "ok";
        case YOIntegrityStateUnarmed:  return "unarmed";
        case YOIntegrityStateTampered: return "tampered";
        case YOIntegrityStateBroken:   return "broken";
        default:                       return "unknown";
    }
}
