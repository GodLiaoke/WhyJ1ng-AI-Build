//
//  YOCapture.h
//  YOOverlay
//
//  Reads the composited contents of the main display from inside SpringBoard.
//
//  The screen, not the camera: the aim loop only ever looks at what is on the
//  display, because by the time aiming happens the frontmost app is the game and
//  this component is the only thing still running.
//

#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

@interface YOCapture : NSObject

+ (instancetype)shared;

/// NO when the private render entry point or its IOSurface dependency could not
/// be resolved on this system. `status` then says which one.
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, copy) NSString *status;

/// Composites the display into a BGRA pixel buffer. Returns a retained buffer
/// that the caller must CVPixelBufferRelease, or NULL when capture failed.
- (CVPixelBufferRef)copyFrameWithPointSize:(CGSize)pointSize
                                     scale:(CGFloat)scale CF_RETURNS_RETAINED;

/// Failures since load. Used to stop retrying a path this device will never
/// allow instead of burning CPU on it forever.
@property (nonatomic, readonly) NSUInteger consecutiveFailures;

@end
