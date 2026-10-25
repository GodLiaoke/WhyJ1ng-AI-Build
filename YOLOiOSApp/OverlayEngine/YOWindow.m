//
//  YOWindow.m
//  YOOverlay
//

#import "YOWindow.h"
#import "YOCommon.h"

/// Above the alert level, so nothing SpringBoard itself shows covers it. Not
/// INT_MAX: a value that large is treated as invalid on some builds.
static const UIWindowLevel kYOWindowLevel = 1000000.0;

// MARK: - Canvas

/// Draws the detection boxes. Non-interactive; drawing only.
@interface YOCanvas : UIView
@property (nonatomic, copy) NSArray<NSValue *> *boxes;
@property (nonatomic, assign) CGPoint aimPoint;
@property (nonatomic, assign) BOOL hasAim;
@property (nonatomic, strong) UIColor *strokeColor;
@end

@implementation YOCanvas

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self == nil) {
        return nil;
    }
    self.opaque = NO;
    self.backgroundColor = [UIColor clearColor];
    self.userInteractionEnabled = NO;
    self.contentMode = UIViewContentModeRedraw;
    self.clearsContextBeforeDrawing = NO;
    _strokeColor = [UIColor colorWithRed:0.145 green:0.388 blue:0.922 alpha:1.0];
    return self;
}

- (void)setBoxes:(NSArray<NSValue *> *)boxes {
    _boxes = [boxes copy];
    [self setNeedsDisplay];
}

- (void)setAimPoint:(CGPoint)aimPoint {
    _aimPoint = aimPoint;
    [self setNeedsDisplay];
}

- (void)setHasAim:(BOOL)hasAim {
    _hasAim = hasAim;
    [self setNeedsDisplay];
}

- (void)setStrokeColor:(UIColor *)strokeColor {
    _strokeColor = strokeColor ?: self.strokeColor;
    [self setNeedsDisplay];
}

- (void)drawRect:(CGRect)rect {
    CGContextRef context = UIGraphicsGetCurrentContext();
    if (context == NULL) {
        return;
    }
    CGSize size = self.bounds.size;
    if (size.width < 1 || size.height < 1) {
        return;
    }

    UIColor *color = self.strokeColor ?: [UIColor colorWithRed:0.145 green:0.388 blue:0.922 alpha:1.0];
    CGContextSetShouldAntialias(context, YES);

    for (NSValue *value in self.boxes) {
        CGRect normalized = value.CGRectValue;
        CGRect box = CGRectMake(normalized.origin.x * size.width,
                                normalized.origin.y * size.height,
                                normalized.size.width * size.width,
                                normalized.size.height * size.height);
        if (box.size.width < 2 || box.size.height < 2) {
            continue;
        }
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, 2.0);
        CGContextStrokeRect(context, box);

        // A corner tick on each corner: readable over a busy game frame without
        // covering the target the way a full translucent fill would.
        CGFloat tick = MIN(14.0, MIN(box.size.width, box.size.height) * 0.25);
        CGContextSetLineWidth(context, 3.0);
        CGPoint corners[4] = {
            CGPointMake(CGRectGetMinX(box), CGRectGetMinY(box)),
            CGPointMake(CGRectGetMaxX(box), CGRectGetMinY(box)),
            CGPointMake(CGRectGetMinX(box), CGRectGetMaxY(box)),
            CGPointMake(CGRectGetMaxX(box), CGRectGetMaxY(box)),
        };
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, corners[0].x, corners[0].y + tick);
        CGContextAddLineToPoint(context, corners[0].x, corners[0].y);
        CGContextAddLineToPoint(context, corners[0].x + tick, corners[0].y);
        CGContextMoveToPoint(context, corners[1].x - tick, corners[1].y);
        CGContextAddLineToPoint(context, corners[1].x, corners[1].y);
        CGContextAddLineToPoint(context, corners[1].x, corners[1].y + tick);
        CGContextMoveToPoint(context, corners[2].x, corners[2].y - tick);
        CGContextAddLineToPoint(context, corners[2].x, corners[2].y);
        CGContextAddLineToPoint(context, corners[2].x + tick, corners[2].y);
        CGContextMoveToPoint(context, corners[3].x - tick, corners[3].y);
        CGContextAddLineToPoint(context, corners[3].x, corners[3].y);
        CGContextAddLineToPoint(context, corners[3].x, corners[3].y - tick);
        CGContextStrokePath(context);
    }

    if (self.hasAim) {
        CGPoint point = CGPointMake(self.aimPoint.x * size.width,
                                    self.aimPoint.y * size.height);
        CGFloat radius = 9.0;
        CGContextSetStrokeColorWithColor(context, color.CGColor);
        CGContextSetLineWidth(context, 1.6);
        CGContextStrokeEllipseInRect(context,
                                     CGRectMake(point.x - radius, point.y - radius,
                                                radius * 2, radius * 2));
        CGContextBeginPath(context);
        CGContextMoveToPoint(context, point.x - radius - 6, point.y);
        CGContextAddLineToPoint(context, point.x + radius + 6, point.y);
        CGContextMoveToPoint(context, point.x, point.y - radius - 6);
        CGContextAddLineToPoint(context, point.x, point.y + radius + 6);
        CGContextStrokePath(context);
    }
}

@end

// MARK: - Window

@interface YOWindow () {
    UIWindow *_window;
    YOCanvas *_canvas;
    NSString *_status;
}
@end

@implementation YOWindow

+ (instancetype)shared {
    static YOWindow *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[YOWindow alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _status = @"未安装";
    return self;
}

- (BOOL)installed {
    return _window != nil;
}

- (NSString *)status {
    return _status ?: @"";
}

// MARK: Scene

/// SpringBoard owns the only window scenes on the device. Any foreground-active
/// scene is the one being displayed; falling back to the first window's scene
/// covers the moment during boot when activation has not settled yet.
- (UIWindowScene *)activeWindowScene {
    UIApplication *application = nil;
    @try {
        application = [UIApplication sharedApplication];
    } @catch (__unused NSException *exception) {
        application = nil;
    }
    if (application == nil) {
        return nil;
    }

    NSSet<UIScene *> *scenes = nil;
    if ([application respondsToSelector:@selector(connectedScenes)]) {
        scenes = application.connectedScenes;
    }
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        if (scene.activationState == UISceneActivationStateForegroundActive) {
            return (UIWindowScene *)scene;
        }
    }
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]] &&
            scene.activationState != UISceneActivationStateBackground) {
            return (UIWindowScene *)scene;
        }
    }
    // `UIApplication.windows` is deprecated; a scene's own window list is the
    // supported replacement and is what the fallback below needs.
    for (UIScene *scene in scenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) {
            continue;
        }
        for (UIWindow *candidate in ((UIWindowScene *)scene).windows) {
            if (candidate.windowScene != nil) {
                return candidate.windowScene;
            }
        }
    }
    for (UIScene *scene in scenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) {
            return (UIWindowScene *)scene;
        }
    }
    return nil;
}

- (CGRect)screenBounds {
    CGRect bounds = CGRectZero;
    @try {
        bounds = [UIScreen mainScreen].bounds;
    } @catch (__unused NSException *exception) {
        bounds = CGRectZero;
    }
    if (bounds.size.width < 1 || bounds.size.height < 1) {
        bounds = CGRectMake(0, 0, 390, 844);
    }
    return bounds;
}

// MARK: Install

- (BOOL)install {
    if (_window != nil) {
        return YES;
    }
    UIWindowScene *scene = [self activeWindowScene];
    UIWindow *window = nil;
    CGRect bounds = [self screenBounds];

    if (scene != nil) {
        @try {
            window = [[UIWindow alloc] initWithWindowScene:scene];
            window.frame = bounds;
        } @catch (__unused NSException *exception) {
            window = nil;
        }
    }
    if (window == nil) {
        _status = @"无法取得 window scene，悬浮窗未安装";
        YOLog(@"overlay: %@", _status);
        return NO;
    }

    window.windowLevel = kYOWindowLevel;
    window.backgroundColor = [UIColor clearColor];
    window.opaque = NO;
    window.hidden = YES;
    // The whole point of the level here is to be above apps; a window that also
    // swallowed touches would make the device unusable.
    window.userInteractionEnabled = NO;
    window.layer.masksToBounds = NO;

    YOCanvas *canvas = [[YOCanvas alloc] initWithFrame:bounds];
    canvas.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    UIViewController *controller = [[UIViewController alloc] init];
    controller.view = canvas;
    controller.view.backgroundColor = [UIColor clearColor];
    controller.view.userInteractionEnabled = NO;
    window.rootViewController = controller;

    _canvas = canvas;
    _window = window;
    _status = @"已安装";
    YOLog(@"overlay: window installed at level %.0f scene=%@",
            (double)kYOWindowLevel, NSStringFromClass([scene class]));
    return YES;
}

- (void)uninstall {
    if (_window != nil) {
        _window.hidden = YES;
        _window.rootViewController = nil;
    }
    _window = nil;
    _canvas = nil;
    _status = @"未安装";
    YOLog(@"overlay: window removed");
}

// MARK: Update

- (void)updateWithBoxes:(NSArray<NSValue *> *)boxes
               aimPoint:(CGPoint)aimPoint
                 hasAim:(BOOL)hasAim
                  color:(UIColor *)color {
    if (_canvas == nil || _window == nil) {
        return;
    }
    _canvas.strokeColor = color;
    _canvas.boxes = boxes ?: @[];
    _canvas.hasAim = hasAim;
    _canvas.aimPoint = aimPoint;
    if (_window.hidden) {
        _window.hidden = NO;
    }
}

- (void)setDrawingHidden:(BOOL)hidden {
    if (_window == nil) {
        return;
    }
    _window.hidden = hidden;
    if (hidden) {
        _canvas.boxes = @[];
        _canvas.hasAim = NO;
    }
}

@end
