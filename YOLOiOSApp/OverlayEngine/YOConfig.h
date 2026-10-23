//
//  YOConfig.h
//  YOOverlay
//
//  Snapshot of the shared plist. The app is the only writer of the tuning keys;
//  this component reads them, plus the one pair of keys it owns
//  (`pendingDx` / `pendingDy`, consumed and zeroed).
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface YOConfig : NSObject

/// Last loaded snapshot. Do not use for decision making when freshness
/// matters  -  call `+load` instead.
+ (instancetype)current;

/// Re-reads the plist from disk. Never returns nil.
+ (instancetype)load;

/// Master switch. Default YES so that an installed component with no config
/// file still writes its heartbeat, which is how the app detects it.
@property (nonatomic, readonly) BOOL enabled;
/// Draw the detection boxes.
@property (nonatomic, readonly) BOOL showOverlay;
/// Inject drag gestures. Default NO: moving someone's finger unasked is not a
/// sensible default.
@property (nonatomic, readonly) BOOL aimEnabled;
/// Let the component aim on its own detections (the real cross-app path, since
/// the app is suspended while a game is frontmost).
@property (nonatomic, readonly) BOOL autoAim;
/// Only consider class 0 ("person").
@property (nonatomic, readonly) BOOL onlyPerson;
/// Boxes kept per frame after suppression.
@property (nonatomic, readonly) int maxBoxes;
/// Absolute path to a compiled `.mlmodelc`.
@property (nonatomic, readonly, copy) NSString *modelPath;
@property (nonatomic, readonly) double confidence;
@property (nonatomic, readonly) double headHeightFraction;
@property (nonatomic, readonly) double headWidthFraction;
@property (nonatomic, readonly) double speed;
@property (nonatomic, readonly) double smoothing;
/// Capture + inference rate ceiling, frames per second.
@property (nonatomic, readonly) double captureFPS;
/// Points -> digitizer units multiplier. 0 means "use the screen scale".
@property (nonatomic, readonly) double hidScale;
@property (nonatomic, readonly, copy) UIColor *boxColor;

/// YES when the difference requires tearing down the window or reloading the
/// model rather than just changing a number.
- (BOOL)needsRebuildComparedTo:(YOConfig *)other;

/// Reads and zeroes `pendingDx` / `pendingDy` written by the app transport.
/// Returns the amount consumed in points.
- (CGPoint)consumePendingAim;

/// Model path actually used: `modelPath` when it exists, otherwise the first
/// readable entry of the documented fallback list.
- (NSString *)resolvedModelPath;

@end
