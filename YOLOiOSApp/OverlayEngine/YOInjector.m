//
//  YOInjector.m
//  YOOverlay
//

#import "YOInjector.h"
#import "YOCommon.h"

#import <dlfcn.h>
#import <mach/mach_time.h>

// MARK: - Private IOKit surface
//
// Same policy as the capture path: every entry point is resolved with dlsym, so
// a build against a current SDK always links and a system without the function
// reports a reason instead of aborting.

typedef struct __IOHIDEvent *YOIOHIDEventRef;
typedef struct __IOHIDEventSystemClient *YOIOHIDClientRef;

/// IOHIDEventCreateDigitizerEvent(allocator, timestamp, type, index, identity,
///     eventMask, buttonMask, handEventMask,
///     x, y, z, tipPressure, barrelPressure, range, touch, options);
typedef YOIOHIDEventRef (*YOCreateDigitizerEventFn)(CFAllocatorRef allocator,
                                                       uint64_t timestamp,
                                                       uint32_t type,
                                                       uint32_t index,
                                                       uint32_t identity,
                                                       uint32_t eventMask,
                                                       uint32_t buttonMask,
                                                       uint32_t handEventMask,
                                                       double x, double y, double z,
                                                       double tipPressure,
                                                       double barrelPressure,
                                                       BOOL range,
                                                       BOOL touch,
                                                       uint32_t options);

/// IOHIDEventCreateDigitizerFingerEvent(allocator, timestamp, index, identity,
///     eventMask, x, y, z, tipPressure, twist, range, touch, options);
typedef YOIOHIDEventRef (*YOCreateFingerEventFn)(CFAllocatorRef allocator,
                                                     uint64_t timestamp,
                                                     uint32_t index,
                                                     uint32_t identity,
                                                     uint32_t eventMask,
                                                     double x, double y, double z,
                                                     double tipPressure,
                                                     double twist,
                                                     BOOL range,
                                                     BOOL touch,
                                                     uint32_t options);

typedef void (*YOAppendEventFn)(YOIOHIDEventRef parent, YOIOHIDEventRef child);
typedef void (*YODispatchEventFn)(YOIOHIDClientRef client, YOIOHIDEventRef event);
typedef YOIOHIDClientRef (*YOCreateClientFn)(CFAllocatorRef allocator);
typedef YOIOHIDClientRef (*YOCreateClientWithTypeFn)(CFAllocatorRef allocator,
                                                         int type,
                                                         CFDictionaryRef properties);

// ---- senderID ------------------------------------------------------------
//
// An event with no sender identity is dropped by the system without any error,
// log or exception: the gesture simply never reaches the app underneath. That
// makes a missing senderID the single worst failure mode here, because every
// other signal says the injector is working.
//
// The only way to obtain a valid one is to listen to the live input stream and
// read the identity off a real touch, which means asking the user to tap once
// after every SpringBoard respawn.

typedef uint32_t (*YOGetEventTypeFn)(YOIOHIDEventRef event);
typedef uint64_t (*YOGetSenderIDFn)(YOIOHIDEventRef event);
typedef void (*YOSetSenderIDFn)(YOIOHIDEventRef event, uint64_t senderID);
typedef void (*YOSetIntegerValueFn)(YOIOHIDEventRef event, uint32_t field, int32_t value);
typedef void (*YOSetFloatValueFn)(YOIOHIDEventRef event, uint32_t field, double value);
typedef void (*YORegisterCallbackFn)(YOIOHIDClientRef client,
                                     void *callback, void *target, void *refcon);
typedef void (*YOUnregisterCallbackFn)(YOIOHIDClientRef client,
                                       void *callback, void *target, void *refcon);
typedef void (*YOScheduleRunLoopFn)(YOIOHIDClientRef client,
                                    CFRunLoopRef runLoop, CFStringRef mode);

// Values from the private IOHIDEvent.h. They are compile-time constants, so they
// cannot be resolved at runtime; the ones used here have been stable since
// iOS 11 and a wrong value would only make the event a no-op, never a crash.
static const uint32_t kYOTransducerHand = 3;
static const uint32_t kYOEventMaskRangeTouch = 0x03;
static const uint32_t kYOFingerIdentity = 2;
static const uint32_t kYOEventTypeDigitizer = 11;

// IOHIDEventField constants, also stable across the range this targets.
static const uint32_t kYOFieldDigitizerRange = 0x000B0010;
static const uint32_t kYOFieldDigitizerTouch = 0x000B0011;
static const uint32_t kYOFieldDigitizerMajorRadius = 0x000B0014;
static const uint32_t kYOFieldDigitizerMinorRadius = 0x000B0015;
static const uint32_t kYOFieldDigitizerIsDisplayIntegrated = 0x000B0032;

// Contact radius in normalised units. The system expects roughly a real finger;
// leaving it at zero makes some apps treat the touch as malformed and discard it.
static const double kYOContactRadius = 0.04;

/// Converts nanoseconds to the units mach_absolute_time uses on this device.
/// The timebase is not 1:1 on Apple silicon, and a hard-coded factor would make
/// the gesture duration wrong by a factor of eight.
static uint64_t YOMachTicksForNanoseconds(uint64_t nanoseconds) {
    static mach_timebase_info_data_t info;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        mach_timebase_info(&info);
    });
    if (info.numer == 0 || info.denom == 0) {
        return nanoseconds;
    }
    return (uint64_t)((double)nanoseconds * (double)info.denom / (double)info.numer);
}

@interface YOInjector () {
    YOCreateDigitizerEventFn _createDigitizerEvent;
    YOCreateFingerEventFn _createFingerEvent;
    YOAppendEventFn _appendEvent;
    YODispatchEventFn _dispatchEvent;
    YOGetEventTypeFn _getEventType;
    YOGetSenderIDFn _getSenderID;
    YOSetSenderIDFn _setSenderID;
    YOSetIntegerValueFn _setIntegerValue;
    YOSetFloatValueFn _setFloatValue;
    YORegisterCallbackFn _registerCallback;
    YOUnregisterCallbackFn _unregisterCallback;
    YOScheduleRunLoopFn _scheduleRunLoop;
    YOIOHIDClientRef _client;
    YOIOHIDClientRef _grabClient;
    YOIOHIDEventRef _grabClientPlaceholder;
    uint64_t _senderID;
    NSString *_status;
    BOOL _dispatchLogged;
    BOOL _grabbing;
}
@end

NSString *const YOInjectorDidBecomeReadyNotification = @"cc.ouovo.yolo.hidReady";

@implementation YOInjector

+ (instancetype)shared {
    static YOInjector *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[YOInjector alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    [self resolveSymbols];
    _senderID = [self cachedSenderID];
    return self;
}

- (void)resolveSymbols {
    void *iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",
                         RTLD_LAZY | RTLD_GLOBAL);

    // RTLD_DEFAULT covers the case where SpringBoard already has IOKit loaded;
    // the explicit handle covers a build where it does not.
    #define YO_RESOLVE(field, name)                                            \
        do {                                                                     \
            void *symbol = dlsym(RTLD_DEFAULT, name);                            \
            if (symbol == NULL && iokit != NULL) {                               \
                symbol = dlsym(iokit, name);                                     \
            }                                                                    \
            field = (__typeof__(field))symbol;                                   \
        } while (0)

    YO_RESOLVE(_createDigitizerEvent, "IOHIDEventCreateDigitizerEvent");
    YO_RESOLVE(_createFingerEvent, "IOHIDEventCreateDigitizerFingerEvent");
    YO_RESOLVE(_appendEvent, "IOHIDEventAppendEvent");
    YO_RESOLVE(_dispatchEvent, "IOHIDEventSystemClientDispatchEvent");
    YO_RESOLVE(_getEventType, "IOHIDEventGetType");
    YO_RESOLVE(_getSenderID, "IOHIDEventGetSenderID");
    YO_RESOLVE(_setSenderID, "IOHIDEventSetSenderID");
    YO_RESOLVE(_setIntegerValue, "IOHIDEventSetIntegerValue");
    YO_RESOLVE(_setFloatValue, "IOHIDEventSetFloatValue");
    YO_RESOLVE(_registerCallback, "IOHIDEventSystemClientRegisterEventCallback");
    YO_RESOLVE(_unregisterCallback, "IOHIDEventSystemClientUnregisterEventCallback");
    YO_RESOLVE(_scheduleRunLoop, "IOHIDEventSystemClientScheduleWithRunLoop");
    #undef YO_RESOLVE

    YOCreateClientFn createClient =
        (YOCreateClientFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (createClient == NULL && iokit != NULL) {
        createClient = (YOCreateClientFn)dlsym(iokit, "IOHIDEventSystemClientCreate");
    }
    YOCreateClientWithTypeFn createClientWithType =
        (YOCreateClientWithTypeFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreateWithType");
    if (createClientWithType == NULL && iokit != NULL) {
        createClientWithType =
            (YOCreateClientWithTypeFn)dlsym(iokit, "IOHIDEventSystemClientCreateWithType");
    }

    if (createClient != NULL) {
        @try {
            _client = createClient(kCFAllocatorDefault);
        } @catch (__unused NSException *exception) {
            _client = NULL;
        }
    }
    if (_client == NULL && createClientWithType != NULL) {
        @try {
            _client = createClientWithType(kCFAllocatorDefault, 1, NULL);
        } @catch (__unused NSException *exception) {
            _client = NULL;
        }
    }

    if (_createDigitizerEvent == NULL || _createFingerEvent == NULL ||
        _appendEvent == NULL || _dispatchEvent == NULL) {
        _status = @"IOHIDEvent 相关符号不可用（该系统未导出）";
    } else if (_client == NULL) {
        _status = @"IOHIDEventSystemClient 创建失败（输入注入需要未沙盒进程）";
    } else if (_senderID == 0) {
        // Not an error yet: grabbing a sender identity needs one real touch.
        _status = @"等待捕获触摸标识（请点一下屏幕）";
    } else {
        _status = @"";
    }
    YOLog(@"hid: digitizer=%p finger=%p append=%p dispatch=%p client=%p senderID=%llu %@",
            (void *)_createDigitizerEvent, (void *)_createFingerEvent,
            (void *)_appendEvent, (void *)_dispatchEvent, (void *)_client,
            (unsigned long long)_senderID,
            _status.length > 0 ? _status : @"ready");
}

#pragma mark - senderID

// Persisted so a respawn of this dylib alone does not force another tap. The
// value is only valid for the current boot: SpringBoard gets a fresh input
// identity on device restart, and a stale one makes every injected event vanish
// silently, which looks identical to "injection is broken".
static NSString *const kYOSenderIDKey = @"cc.ouovo.yolo.senderID";
static NSString *const kYOBootStampKey = @"cc.ouovo.yolo.senderID.boot";

/// A boot stamp that cannot survive a restart: boot time is reconstructed from
/// the current time minus uptime, so it changes on every boot and is stable
/// within one.
static double YOBootStamp(void) {
    return [NSDate date].timeIntervalSince1970 -
           [NSProcessInfo processInfo].systemUptime;
}

- (uint64_t)cachedSenderID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    NSNumber *stamp = [defaults objectForKey:kYOBootStampKey];
    if (stamp == nil || fabs(stamp.doubleValue - YOBootStamp()) > 5.0) {
        return 0;
    }
    return (uint64_t)[[defaults objectForKey:kYOSenderIDKey] unsignedLongLongValue];
}

- (void)storeSenderID:(uint64_t)senderID {
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    [defaults setObject:@(senderID) forKey:kYOSenderIDKey];
    [defaults setObject:@(YOBootStamp()) forKey:kYOBootStampKey];
}

/// The callback signature of IOHIDEventSystemClientRegisterEventCallback has
/// taken two forms across releases: (target, refcon, IOHIDServiceRef, event) and
/// (target, refcon, IOHIDEventSystemClientRef, event). The first two arguments
/// are identical in both, and the last is the event either way, so only arg2 is
/// ambiguous — and it is never dereferenced here, which makes the ambiguity
/// harmless. Reading arg2 instead of guessing would be a stack corruption.
static void YOGrabTouchCallback(void *target, void *refcon, void *arg2, YOIOHIDEventRef event) {
    (void)arg2;
    YOInjector *injector = (__bridge YOInjector *)target;
    (void)refcon;
    [injector consumeTouchedEvent:event];
}

- (void)consumeTouchedEvent:(YOIOHIDEventRef)event {
    if (event == NULL || _getEventType == NULL || _getSenderID == NULL) {
        return;
    }
    uint32_t type = 0;
    @try {
        type = _getEventType(event);
    } @catch (__unused NSException *exception) {
        return;
    }
    if (type != kYOEventTypeDigitizer) {
        return;
    }
    uint64_t identity = 0;
    @try {
        identity = _getSenderID(event);
    } @catch (__unused NSException *exception) {
        return;
    }
    if (identity == 0) {
        return;
    }

    _senderID = identity;
    [self storeSenderID:identity];
    [self stopGrabbing];

    _status = @"";
    YOLog(@"hid: senderID captured 0x%llx", (unsigned long long)identity);

    // The engine treats an empty status as "injection is live", so tell it that
    // capability changed rather than waiting for the next config reload.
    [[NSNotificationCenter defaultCenter]
        postNotificationName:YOInjectorDidBecomeReadyNotification object:self];
}

/// Starts listening for one real touch. Safe to call repeatedly; the second call
/// is a no-op while a capture is already in flight.
- (void)startGrabbing {
    if (_grabbing || _senderID != 0) {
        return;
    }
    if (_registerCallback == NULL || _scheduleRunLoop == NULL || _unregisterCallback == NULL) {
        _status = @"IOHID 回调符号不可用，无法捕获触摸标识";
        return;
    }

    YOCreateClientFn createClient =
        (YOCreateClientFn)dlsym(RTLD_DEFAULT, "IOHIDEventSystemClientCreate");
    if (createClient == NULL) {
        _status = @"无法创建捕获客户端";
        return;
    }

    _grabClient = createClient(kCFAllocatorDefault);
    if (_grabClient == NULL) {
        _status = @"捕获客户端创建失败";
        return;
    }

    _grabbing = YES;
    _status = @"等待捕获触摸标识（请点一下屏幕）";
    YOLog(@"hid: waiting for a touch to capture senderID");

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        strongSelf->_scheduleRunLoop(strongSelf->_grabClient,
                                     CFRunLoopGetMain(),
                                     kCFRunLoopDefaultMode);
        strongSelf->_registerCallback(strongSelf->_grabClient,
                                      (void *)YOGrabTouchCallback,
                                      (__bridge void *)strongSelf,
                                      NULL);
    });
}

- (void)stopGrabbing {
    if (!_grabbing || _grabClient == NULL) {
        return;
    }
    _grabbing = NO;
    if (_unregisterCallback != NULL) {
        _unregisterCallback(_grabClient, (void *)YOGrabTouchCallback,
                            (__bridge void *)self, NULL);
    }
    // The client itself is intentionally kept alive: releasing it from inside its
    // own callback is the classic way to crash inside the HID run loop.
}

- (uint64_t)senderID {
    return _senderID;
}

- (BOOL)available {
    // The senderID clause is the important one. Without it every event is
    // discarded silently, so reporting YES here would make the app claim the
    // aim transport works while nothing whatsoever reaches the screen.
    return _client != NULL && _createDigitizerEvent != NULL && _createFingerEvent != NULL &&
           _appendEvent != NULL && _dispatchEvent != NULL && _senderID != 0;
}

- (NSString *)status {
    return _status ?: @"";
}

// MARK: - Event construction

- (YOIOHIDEventRef)newHandEventAt:(CGPoint)point
                          timestamp:(uint64_t)timestamp
                         fingerDown:(BOOL)fingerDown {
    if (_createDigitizerEvent == NULL) {
        return NULL;
    }
    // The hand carrier does not take the contact state from an argument on every
    // release; the fields below make it authoritative either way.
    BOOL handleDown = fingerDown;
    YOIOHIDEventRef hand = NULL;
    @try {
        hand = _createDigitizerEvent(kCFAllocatorDefault,
                                     timestamp,
                                     kYOTransducerHand,
                                     0,                       // index
                                     0,                       // identity
                                     0,                       // eventMask
                                     0,                       // buttonMask
                                     kYOEventMaskRangeTouch,
                                     (double)point.x,
                                     (double)point.y,
                                     0.0,                     // z
                                     0.0,                     // tipPressure
                                     0.0,                     // barrelPressure
                                     handleDown,              // range
                                     handleDown,              // touch
                                     0);                      // options
    } @catch (__unused NSException *exception) {
        hand = NULL;
    }
    if (hand == NULL) {
        return NULL;
    }

    // Without display-integrated, the system treats the event as coming from an
    // external trackpad rather than the panel, and most apps ignore it.
    if (_setIntegerValue != NULL) {
        _setIntegerValue(hand, kYOFieldDigitizerIsDisplayIntegrated, 1);
        _setIntegerValue(hand, kYOFieldDigitizerRange, fingerDown ? 1 : 0);
        _setIntegerValue(hand, kYOFieldDigitizerTouch, fingerDown ? 1 : 0);
    }
    return hand;
}

- (YOIOHIDEventRef)newFingerEventAt:(CGPoint)point
                            timestamp:(uint64_t)timestamp
                           fingerDown:(BOOL)fingerDown {
    if (_createFingerEvent == NULL) {
        return NULL;
    }
    YOIOHIDEventRef finger = NULL;
    @try {
        // The finger inherits the parent's range/touch, otherwise the child
        // contradicts the hand event and the gesture is discarded.
        finger = _createFingerEvent(kCFAllocatorDefault,
                                    timestamp,
                                    0,                    // index
                                    kYOFingerIdentity,  // identity
                                    kYOEventMaskRangeTouch,
                                    (double)point.x,
                                    (double)point.y,
                                    0.0,                  // z
                                    1.0,                  // tipPressure
                                    0.0,                  // twist
                                    fingerDown,           // range
                                    fingerDown,           // touch
                                    0);                   // options
    } @catch (__unused NSException *exception) {
        finger = NULL;
    }
    if (finger == NULL) {
        return NULL;
    }

    // A zero contact radius reads as a malformed touch to some apps. 0.04 is
    // roughly a real fingertip in normalised units.
    if (_setFloatValue != NULL) {
        _setFloatValue(finger, kYOFieldDigitizerMajorRadius, kYOContactRadius);
        _setFloatValue(finger, kYOFieldDigitizerMinorRadius, kYOContactRadius);
    }
    // The identity the input stack issued to this boot. Without it the event is
    // dropped before it ever reaches an app.
    if (_setSenderID != NULL && _senderID != 0) {
        _setSenderID(finger, _senderID);
    }
    return finger;
}

- (void)postEvent:(YOIOHIDEventRef)event {
    if (event == NULL || _dispatchEvent == NULL || _client == NULL) {
        return;
    }
    @try {
        _dispatchEvent(_client, event);
    } @catch (__unused NSException *exception) {
        if (!_dispatchLogged) {
            _dispatchLogged = YES;
            YOLog(@"hid: dispatch 异常 %@", exception.reason ?: @"unknown");
        }
    }
}

/// Sends one digitizer sample: a hand event carrying one finger child.
- (BOOL)sendSampleAt:(CGPoint)point
           timestamp:(uint64_t)timestamp
          fingerDown:(BOOL)fingerDown {
    YOIOHIDEventRef hand = [self newHandEventAt:point
                                        timestamp:timestamp
                                       fingerDown:fingerDown];
    if (hand == NULL) {
        return NO;
    }
    YOIOHIDEventRef finger = [self newFingerEventAt:point
                                            timestamp:timestamp
                                           fingerDown:fingerDown];
    if (finger != NULL) {
        _appendEvent(hand, finger);
        CFRelease((CFTypeRef)finger);
    }
    [self postEvent:hand];
    CFRelease((CFTypeRef)hand);
    return YES;
}

// MARK: - Drag

/// Converts a point in screen points to the normalised 0..1 space IOHID expects.
///
/// This is the difference between a working injector and a silent no-op: the HID
/// stack does not accept pixels. Passing 390.0 for a 390-point-wide screen puts
/// the touch 390 screen-widths off the panel, and the system reports nothing at
/// all — same as a missing senderID.
static CGPoint YONormalizedPoint(CGPoint point) {
    CGSize size = CGSizeZero;
    @try {
        size = [UIScreen mainScreen].bounds.size;
    } @catch (__unused NSException *exception) {
        size = CGSizeZero;
    }
    // Read the live size every time: it flips with orientation, and a cached
    // value would send landscape touches into the wrong axis.
    if (size.width <= 0 || size.height <= 0) {
        return CGPointMake(0, 0);
    }
    CGFloat nx = point.x / size.width;
    CGFloat ny = point.y / size.height;
    // Clamp: an out-of-range coordinate is discarded, so pinning it to the edge
    // at least produces a usable gesture.
    nx = MAX(0.0, MIN(1.0, nx));
    ny = MAX(0.0, MIN(1.0, ny));
    return CGPointMake(nx, ny);
}

- (BOOL)dragAlongPath:(NSArray<NSValue *> *)points scale:(double)scale {
    // `scale` is accepted for source compatibility but ignored: coordinates are
    // normalised against the live screen size, so a caller-supplied scale would
    // only reintroduce the pixel/normalised confusion this fixes.
    (void)scale;
    if (![self available] || points.count < 2) {
        return NO;
    }

    uint64_t timestamp = mach_absolute_time();
    uint64_t stepTicks = YOMachTicksForNanoseconds(8 * 1000 * 1000);  // 8 ms

    // Press.
    CGPoint start = YONormalizedPoint(points.firstObject.CGPointValue);
    if (![self sendSampleAt:start timestamp:timestamp fingerDown:YES]) {
        return NO;
    }

    // Move: one sample per point. Timestamps are spaced by ~8 ms so the event
    // system sees a gesture rather than a teleport.
    uint64_t step = 0;
    for (NSUInteger i = 1; i < points.count; i++) {
        step += stepTicks;
        CGPoint point = YONormalizedPoint([points objectAtIndex:i].CGPointValue);
        [self sendSampleAt:point timestamp:timestamp + step fingerDown:YES];
    }

    // Release.
    step += stepTicks;
    CGPoint end = YONormalizedPoint(points.lastObject.CGPointValue);
    [self sendSampleAt:end timestamp:timestamp + step fingerDown:NO];

    return YES;
}

- (BOOL)dragFrom:(CGPoint)from to:(CGPoint)to scale:(double)scale {
    // A single long jump reads as a snap rather than a steer, so the movement is
    // split into short segments. Distance-dependent, capped: enough segments to
    // look continuous, few enough to stay under a frame of latency.
    CGFloat dx = to.x - from.x;
    CGFloat dy = to.y - from.y;
    CGFloat distance = hypot(dx, dy);
    NSInteger segments = (NSInteger)lround(distance / 40.0);
    if (segments < 1) {
        segments = 1;
    }
    if (segments > 4) {
        segments = 4;
    }

    NSMutableArray<NSValue *> *path = [NSMutableArray arrayWithCapacity:(NSUInteger)segments + 1];
    [path addObject:[NSValue valueWithCGPoint:from]];
    for (NSInteger i = 1; i <= segments; i++) {
        CGFloat t = (CGFloat)i / (CGFloat)segments;
        [path addObject:[NSValue valueWithCGPoint:CGPointMake(from.x + dx * t,
                                                              from.y + dy * t)]];
    }
    return [self dragAlongPath:path scale:scale];
}

@end
