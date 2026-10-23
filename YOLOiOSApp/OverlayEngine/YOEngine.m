//
//  YOOverlay.m
//  YOOverlay
//
//  SpringBoard-side entry point.
//
//  Everything the feature needs happens in this process, because when aiming
//  actually matters the frontmost app is the game and the app that configured
//  this component is suspended:
//
//      capture the display -> run the model -> draw boxes -> inject a drag
//
//  The app is a configuration surface only. No frames cross the process
//  boundary; only the plist does.
//
//  Load behaviour: the constructor returns immediately unless the process is
//  SpringBoard. Nothing is touched before that check, so injecting this dylib
//  into any other process is harmless.
//

#import "YOCommon.h"
#import "YOConfig.h"
#import "YOCapture.h"
#import "YODetector.h"
#import "YOInjector.h"
#import "YOWindow.h"
#import "YOLicense.h"
#import "YOEngine.h"

#import <math.h>

static const NSTimeInterval kYOHeartbeatInterval = 5.0;
static const NSTimeInterval kYOReloadDebounce = 0.3;
static const NSTimeInterval kYOModelRetryInterval = 15.0;
static const NSTimeInterval kYOAimInterval = 1.0 / 20.0;

// MARK: - Controller

@interface YOEngine : NSObject {
    YOConfig *_config;
    YODetector *_detector;
    dispatch_source_t _heartbeatTimer;
    dispatch_source_t _captureTimer;
    dispatch_source_t _aimTimer;
    dispatch_source_t _licenseTimer;
    dispatch_queue_t _captureQueue;
    NSUInteger _reloadGeneration;
    NSUInteger _installAttempts;
    NSTimeInterval _lastModelAttempt;
    BOOL _started;

    // Shared between the capture queue and the main thread.
    NSArray<NSValue *> *_latestBoxes;
    CGPoint _latestAimNormalized;
    BOOL _hasAim;
    CGPoint _pendingAim;
    CGSize _screenPointSize;
    CGFloat _screenScale;
    CGPoint _cursor;

    NSString *_lastReportedState;
}

// Forward declarations. ObjC needs these visible before use, and several calls
// sit above the definitions later in the file.
+ (instancetype)shared;
- (void)startIfNeeded;
- (void)startAimLoop;
- (void)injectorDidBecomeReady:(NSNotification *)notification;
+ (instancetype)shared;
- (void)startIfNeeded;
/// Coalesces a burst of Darwin notifications into one reload. Called from the
/// notification callback, so it has to be visible outside the implementation.
- (void)scheduleReload;
/// The current config snapshot. `_config` is swapped on the main thread and read
/// on the capture queue, so every access goes through the monitor.
- (YOConfig *)currentConfig;
/// Fired by YOInjector once a touch identity is captured. Injection is unusable
/// before that, so the aim loop is (re)started here rather than polled.
- (void)injectorDidBecomeReady:(NSNotification *)notification;
/// Starts the aim loop. Declared because the ready callback above calls it and
/// the definition sits further down the file.
- (void)startAimLoop;
@end

@implementation YOEngine

+ (instancetype)shared {
    static YOEngine *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[YOEngine alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _captureQueue = dispatch_queue_create("cc.ouovo.yolooverlay.capture",
                                          DISPATCH_QUEUE_SERIAL);
    _config = [YOConfig load];
    _latestBoxes = @[];
    _screenPointSize = CGSizeMake(390, 844);
    _screenScale = 2.0;
    _cursor = CGPointMake(195, 422);
    return self;
}

- (YOConfig *)currentConfig {
    @synchronized (self) {
        return _config;
    }
}

// MARK: Start

- (void)startIfNeeded {
    if (_started) {
        return;
    }
    _started = YES;

    YOLog(@"component %@ starting in %@ (iOS %@)",
            YO_VERSION,
            [NSProcessInfo processInfo].processName,
            [NSProcessInfo processInfo].operatingSystemVersionString);

    [self startHeartbeat];
    [self registerReloadObserver];
    [self refreshScreenMetrics];

    // Licence first, and deliberately AFTER the heartbeat: "the deb is installed"
    // and "the card is valid" are different facts. The heartbeat keeps being
    // written either way, so the app never concludes the component is missing
    // just because the card is bad.
    //
    // The check blocks on the network, so it runs off the main thread. Blocking
    // SpringBoard's main queue for seconds is how you get a watchdog respring.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (![self passLicenseGate]) {
            [self startLicenseWatchdog];
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attemptInstall];
        });
    });
}

/// Runs the dylib's own card check. Blocking on the network for up to a few
/// seconds, so it must not run on the caller's thread of control.
- (BOOL)passLicenseGate {
    if (YOLicenseRefresh()) {
        return YES;
    }
    [self setReportedState:[@"卡密校验未通过：" stringByAppendingString:YOLicenseReason()]];
    return NO;
}

/// Re-checks once a minute. A user who activates after the component loaded gets
/// the overlay without a respring; a user whose card is revoked loses it.
- (void)startLicenseWatchdog {
    if (_licenseTimer != nil) {
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("cc.ouovo.authcore.license",
                                                   DISPATCH_QUEUE_SERIAL);
    _licenseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (_licenseTimer == nil) {
        return;
    }
    dispatch_source_set_timer(_licenseTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(60.0 * NSEC_PER_SEC)),
                              (uint64_t)(60.0 * NSEC_PER_SEC),
                              (uint64_t)(5.0 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_licenseTimer, ^{
        if (YOLicenseRefresh()) {
            dispatch_source_cancel(self->_licenseTimer);
            self->_licenseTimer = nil;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self attemptInstall];
            });
            return;
        }
        // Losing the licence mid-session tears the engine down: no grace period.
        if (!YOLicenseValid()) {
            [self stopCaptureLoop];
            dispatch_async(dispatch_get_main_queue(), ^{
                [[YOWindow shared] setDrawingHidden:YES];
            });
            [self setReportedState:@"卡密校验失效，悬浮已停止"];
        }
    });
    dispatch_resume(_licenseTimer);
}

/// Startup races SpringBoard's own window setup, so installation is retried for
/// the first ~20 s instead of giving up on the first attempt.
- (void)attemptInstall {
    _installAttempts++;
    [self refreshScreenMetrics];

    YOConfig *config = [YOConfig load];
    @synchronized (self) {
        _config = config;
    }

    if (!config.enabled) {
        YOLog(@"config disabled; heartbeat only");
        return;
    }

    // Ask for a touch identity before the window appears. Injection is dead
    // until one is captured, and the only source is a real touch, so surfacing it
    // during setup is far better than the user tapping a toggle that does nothing.
    if (config.aimEnabled) {
        YOInjector *hid = [YOInjector shared];
        if (hid.senderID == 0) {
            [hid startGrabbing];
        }
    }

    BOOL installed = [[YOWindow shared] install];
    if (!installed) {
        if (_installAttempts < 12) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [self attemptInstall];
            });
        } else {
            YOLog(@"overlay: giving up on window install after %lu attempts",
                    (unsigned long)_installAttempts);
        }
        return;
    }

    [[YOWindow shared] setDrawingHidden:!config.showOverlay];
    [self startCaptureLoop];
    [self startAimLoop];
}

- (void)refreshScreenMetrics {
    @try {
        UIScreen *screen = [UIScreen mainScreen];
        CGRect bounds = screen.bounds;
        if (bounds.size.width > 1 && bounds.size.height > 1) {
            _screenPointSize = bounds.size;
            _cursor = CGPointMake(bounds.size.width / 2.0, bounds.size.height / 2.0);
        }
        CGFloat scale = screen.scale;
        _screenScale = scale > 0 ? scale : 2.0;
    } @catch (__unused NSException *exception) {
        // Keep the last known values; the loop is tolerant of a wrong size.
    }
}

// MARK: Heartbeat

- (void)startHeartbeat {
    if (_heartbeatTimer != nil) {
        return;
    }
    dispatch_queue_t queue = dispatch_queue_create("cc.ouovo.yolooverlay.heartbeat",
                                                   DISPATCH_QUEUE_SERIAL);
    _heartbeatTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    if (_heartbeatTimer == nil) {
        return;
    }
    dispatch_source_set_timer(_heartbeatTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 0),
                              (uint64_t)(kYOHeartbeatInterval * NSEC_PER_SEC),
                              (uint64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_heartbeatTimer, ^{
        [self writeHeartbeat];
    });
    dispatch_resume(_heartbeatTimer);
}

/// The heartbeat is the app's only evidence that the component is installed and
/// alive. It is written before anything else works, and keeps being written even
/// when capture or injection is unavailable on this device.
///
/// Three files, because three different readers exist:
///   /var/mobile/Library/Preferences/cc.ouovo.authcore.alive    primary
///   /var/mobile/.../cc.ouovo.authcore.alive (app Documents)     sandbox-readable
///   /var/mobile/Library/Preferences/cc.ouovo.yolooverlay.alive  legacy name
- (void)writeHeartbeat {
    @try {
        NSString *payload = [NSString stringWithFormat:@"%.0f", YONowUnix()];
        [payload writeToFile:YOAlivePath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:NULL];
        [payload writeToFile:YOLegacyAlivePath
                  atomically:YES
                    encoding:NSUTF8StringEncoding
                       error:NULL];

        // The app is sandboxed and cannot read /var/mobile; SpringBoard can write
        // into the app's own container, so the stamp is mirrored there.
        NSString *documents = YOAppDocumentsPath();
        if (documents.length > 0) {
            NSString *mirror = [documents stringByAppendingPathComponent:YOAliveFileName];
            [payload writeToFile:mirror
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:NULL];
        }
    } @catch (__unused NSException *exception) {
        // A device where this fails is not jailbroken enough to be here.
    }
}

// MARK: Reload

static void YODarwinNotifyCallback(CFNotificationCenterRef center,
                                     void *observer,
                                     CFStringRef name,
                                     const void *object,
                                     CFDictionaryRef userInfo) {
    // Delivered on an arbitrary thread and possibly many times in a row (the app
    // posts once per flush). Coalesced on the main thread.
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YOEngine shared] scheduleReload];
    });
}

- (void)registerReloadObserver {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                    NULL,
                                    YODarwinNotifyCallback,
                                    (__bridge CFStringRef)YOReloadNotification,
                                    NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);

    // Injection turns on the moment an identity is captured, without waiting for
    // a config change. Posted by YOInjector from the HID run loop.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(injectorDidBecomeReady:)
               name:YOInjectorDidBecomeReadyNotification
             object:nil];
}

- (void)injectorDidBecomeReady:(NSNotification *)notification {
    (void)notification;
    [self setReportedState:@"injector ready"];
    // A pending aim target was dropped while injection was unavailable, so start
    // the loop again rather than waiting for the next detection.
    [self startAimLoop];
}

- (void)scheduleReload {
    _reloadGeneration++;
    NSUInteger generation = _reloadGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kYOReloadDebounce * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != self->_reloadGeneration) {
            return;  // a newer reload is already queued
        }
        [self performReload];
    });
}

- (void)performReload {
    YOConfig *next = [YOConfig load];
    YOConfig *previous = [self currentConfig];
    BOOL rebuild = [next needsRebuildComparedTo:previous];
    @synchronized (self) {
        _config = next;
    }

    if (!next.enabled) {
        [self stopCaptureLoop];
        [[YOWindow shared] setDrawingHidden:YES];
        [self setReportedState:@"配置已关闭"];
        return;
    }

    if (rebuild) {
        [self stopCaptureLoop];
        // The detector belongs to the capture queue; resetting it here would race
        // the loop that is using it.
        dispatch_async(_captureQueue, ^{
            self->_detector = nil;
            self->_lastModelAttempt = 0;
        });
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attemptInstall];
        });
        return;
    }

    [[YOWindow shared] setDrawingHidden:!next.showOverlay];
    if (next.showOverlay) {
        NSArray<NSValue *> *boxes = nil;
        CGPoint aim = CGPointZero;
        BOOL hasAim = NO;
        @synchronized (self) {
            boxes = _latestBoxes;
            aim = _latestAimNormalized;
            hasAim = _hasAim;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [[YOWindow shared] updateWithBoxes:boxes
                                               aimPoint:aim
                                                 hasAim:hasAim
                                                  color:next.boxColor];
        });
    }
}

- (void)setReportedState:(NSString *)state {
    if ([state isEqualToString:_lastReportedState ?: @""]) {
        return;
    }
    _lastReportedState = [state copy];
    YOLog(@"state: %@", state);
}

// MARK: Capture loop

- (void)startCaptureLoop {
    if (_captureTimer != nil) {
        return;
    }
    if (![[YOCapture shared] available]) {
        [self setReportedState:[YOCapture shared].status];
        return;
    }

    double fps = [self currentConfig].captureFPS;
    if (fps < 5) {
        fps = 5;
    }
    if (fps > 30) {
        fps = 30;
    }
    uint64_t interval = (uint64_t)((1.0 / fps) * NSEC_PER_SEC);

    _captureTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
    if (_captureTimer == nil) {
        return;
    }
    dispatch_source_set_timer(_captureTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)interval),
                              interval,
                              (uint64_t)(0.2 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_captureTimer, ^{
        [self captureTick];
    });
    dispatch_resume(_captureTimer);
    YOLog(@"capture loop started at %.1f fps", fps);
}

- (void)stopCaptureLoop {
    if (_captureTimer != nil) {
        dispatch_source_cancel(_captureTimer);
        _captureTimer = nil;
        YOLog(@"capture loop stopped");
    }
}

- (void)captureTick {
    YOConfig *config = _config;
    if (!config.enabled) {
        return;
    }

    YOCapture *capture = [YOCapture shared];
    // A device that refuses capture will keep refusing it; stop hammering the
    // compositor once that is established.
    if (capture.consecutiveFailures > 40) {
        [self setReportedState:@"屏幕捕获被拒绝（可能缺少权限）"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [self stopCaptureLoop];
        });
        return;
    }

    // Consume app-requested movement here rather than on the aim tick: this is
    // the only place allowed to touch the disk.
    CGPoint pending = [config consumePendingAim];
    if (pending.x != 0 || pending.y != 0) {
        @synchronized (self) {
            _pendingAim = CGPointMake(_pendingAim.x + pending.x, _pendingAim.y + pending.y);
        }
    }

    if (_detector == nil || !_detector.ready) {
        NSTimeInterval now = [NSDate date].timeIntervalSince1970;
        if (now - _lastModelAttempt < kYOModelRetryInterval) {
            return;
        }
        _lastModelAttempt = now;
        NSString *path = [config resolvedModelPath];
        _detector = [[YODetector alloc] initWithModelPath:path];
        [self setReportedState:_detector.status];
        if (!_detector.ready) {
            return;
        }
    }

    CVPixelBufferRef buffer = [capture copyFrameWithPointSize:_screenPointSize
                                                        scale:_screenScale];
    if (buffer == NULL) {
        return;
    }

    NSArray<NSValue *> *boxes = [_detector detectInPixelBuffer:buffer
                                                    confidence:config.confidence
                                                    onlyPerson:config.onlyPerson
                                                      maxBoxes:config.maxBoxes];
    CVPixelBufferRelease(buffer);

    // Target selection matches the app: the largest box is the nearest person,
    // and its box is the most stable thing to steer by.
    CGPoint aim = CGPointZero;
    BOOL hasAim = NO;
    if (boxes.count > 0) {
        CGRect best = CGRectZero;
        double bestArea = -1;
        for (NSValue *value in boxes) {
            CGRect box = value.CGRectValue;
            double area = (double)box.size.width * (double)box.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = box;
            }
        }
        // Head, not box centre: a band measured down from the top of the box,
        // centred horizontally. Same geometry as AimSettings on the app side, so
        // the two views of the same target agree.
        double headBand = (double)best.size.height * config.headHeightFraction;
        aim.x = (CGFloat)((double)best.origin.x + (double)best.size.width * config.headWidthFraction);
        aim.y = (CGFloat)((double)best.origin.y + headBand * 0.5);
        hasAim = YES;
    }

    // Written on the capture queue, read from the main thread by the aim loop
    // and the drawing update; a CGPoint is two words, so the swap is guarded.
    @synchronized (self) {
        _latestBoxes = boxes;
        _latestAimNormalized = aim;
        _hasAim = hasAim;
    }

    if (!config.showOverlay) {
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [[YOWindow shared] updateWithBoxes:boxes
                                           aimPoint:aim
                                             hasAim:hasAim
                                              color:config.boxColor];
    });
}

// MARK: Aim loop

- (void)startAimLoop {
    if (_aimTimer != nil) {
        return;
    }
    _aimTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                                       dispatch_get_main_queue());
    if (_aimTimer == nil) {
        return;
    }
    dispatch_source_set_timer(_aimTimer,
                              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kYOAimInterval * NSEC_PER_SEC)),
                              (uint64_t)(kYOAimInterval * NSEC_PER_SEC),
                              (uint64_t)(0.005 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(_aimTimer, ^{
        [self aimTick];
    });
    dispatch_resume(_aimTimer);
}

- (void)aimTick {
    YOConfig *config = _config;
    if (!config.enabled || !config.aimEnabled) {
        _pendingAim = CGPointZero;
        return;
    }

    YOInjector *hid = [YOInjector shared];
    if (!hid.available) {
        // Injection needs a sender identity, and one can only be read off a real
        // touch. Asking for it here means the user is prompted on the first aim
        // frame rather than after a failed attempt they cannot explain.
        if (hid.senderID == 0) {
            [hid startGrabbing];
        }
        [self setReportedState:hid.status];
        _pendingAim = CGPointZero;
        return;
    }

    CGPoint move = CGPointZero;
    CGPoint aim = CGPointZero;
    BOOL hasAim = NO;
    @synchronized (self) {
        move = _pendingAim;
        _pendingAim = CGPointZero;
        aim = _latestAimNormalized;
        hasAim = _hasAim;
    }

    // Autonomous aiming on the component's own detections. This is the path that
    // works while a game is frontmost; the app cannot contribute a frame then.
    if (config.autoAim && hasAim) {
        CGFloat screenWidth = _screenPointSize.width;
        CGFloat screenHeight = _screenPointSize.height;
        CGPoint target = CGPointMake(aim.x * screenWidth,
                                     aim.y * screenHeight);
        CGFloat gain = (CGFloat)config.speed * (CGFloat)(1.0 - config.smoothing);
        CGPoint step = CGPointMake((target.x - _cursor.x) * gain,
                                   (target.y - _cursor.y) * gain);
        // One tick can never teleport the aim: bounded to 8% of the width, the
        // same ceiling the app-side loop uses.
        CGFloat limit = MAX(8.0f, screenWidth * 0.08f);
        CGFloat length = hypot(step.x, step.y);
        if (length > limit && length > 0) {
            step.x = step.x / length * limit;
            step.y = step.y / length * limit;
        }
        move.x += step.x;
        move.y += step.y;
    }

    // Deadzone: injecting a 0.4 pt drag 20 times a second would look like noise
    // in the touch stream and gain nothing.
    CGFloat distance = hypot(move.x, move.y);
    if (distance < 1.5) {
        return;
    }
    // A single tick should never fling the cursor across the display either.
    CGFloat maxStep = MAX(16.0f, _screenPointSize.width * 0.25f);
    if (distance > maxStep) {
        move.x = move.x / distance * maxStep;
        move.y = move.y / distance * maxStep;
        distance = maxStep;
    }

    CGRect screen = CGRectMake(0, 0, _screenPointSize.width, _screenPointSize.height);
    CGPoint next = CGPointMake(_cursor.x + move.x, _cursor.y + move.y);
    next.x = MAX(CGRectGetMinX(screen) + 1, MIN(CGRectGetMaxX(screen) - 1, next.x));
    next.y = MAX(CGRectGetMinY(screen) + 1, MIN(CGRectGetMaxY(screen) - 1, next.y));

    double scale = config.hidScale > 0 ? config.hidScale : (double)_screenScale;
    if ([hid dragFrom:_cursor to:next scale:scale]) {
        _cursor = next;
    }
}

@end

// MARK: - Entry point

void YOEngineStart(void) {
    // Defence in depth: AuthCore.m already branches on the process, but the
    // engine is only ever correct inside SpringBoard, so it refuses to start
    // anywhere else even if some future caller forgets to check.
    if (!YOIsSpringBoard()) {
        return;
    }

    // SpringBoard's UI is not up at constructor time. A short delay is cheaper
    // than an observer for a notification that has usually already fired here.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[YOEngine shared] startIfNeeded];
    });
}
