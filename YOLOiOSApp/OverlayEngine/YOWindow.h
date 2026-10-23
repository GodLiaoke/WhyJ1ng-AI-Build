//
//  YOWindow.h
//  YOOverlay
//
//  The reason this component exists. A UIWindow created *in SpringBoard* is
//  composited above every app, so it survives the foreground app changing  -  the
//  thing an app-owned window can never do.
//
//  The window is non-interactive on purpose: `isUserInteractionEnabled = NO` on
//  both window and canvas, so it can never eat a touch meant for the game
//  underneath.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface YOWindow : NSObject

+ (instancetype)shared;

/// Creates the window. Idempotent. Returns NO when no window scene could be
/// obtained, which is the only case where the overlay cannot be shown at all.
- (BOOL)install;

/// Removes the window and drops every reference to it.
- (void)uninstall;

@property (nonatomic, readonly) BOOL installed;
@property (nonatomic, readonly, copy) NSString *status;

/// Boxes and aim point are in normalised (0..1) *screen* coordinates.
/// Must be called on the main thread.
- (void)updateWithBoxes:(NSArray<NSValue *> *)boxes
               aimPoint:(CGPoint)aimPoint
                 hasAim:(BOOL)hasAim
                  color:(UIColor *)color;

/// Hides the drawing without tearing the window down.
- (void)setDrawingHidden:(BOOL)hidden;

@end
