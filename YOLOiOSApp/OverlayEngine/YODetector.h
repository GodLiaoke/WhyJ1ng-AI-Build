//
//  YODetector.h
//  YOOverlay
//
//  Core ML inference on a captured display frame, entirely inside SpringBoard.
//  The app is suspended while a game is frontmost, so this cannot be delegated
//  back to it: the frame never leaves this process.
//

#import <Foundation/Foundation.h>
// UIKit is required, not incidental: the boxes travel as NSValue-wrapped CGRects
// and that category (-valueWithCGRect: / .CGRectValue) lives in UIGeometry.
#import <UIKit/UIKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreVideo/CoreVideo.h>

@interface YODetector : NSObject

/// Loads a compiled `.mlmodelc`. Returns an object whose `ready` is NO when the
/// path is missing or the model cannot be loaded; callers must check `ready`.
- (instancetype)initWithModelPath:(NSString *)modelPath;

@property (nonatomic, readonly) BOOL ready;
@property (nonatomic, readonly, copy) NSString *status;
/// Side length the model expects, in pixels. Used to un-normalise raw output.
@property (nonatomic, readonly) CGFloat inputSize;

/// Returns boxes in normalised (0..1) frame coordinates, largest first.
/// An empty array is a valid answer: it means "nothing above threshold".
- (NSArray<NSValue *> *)detectInPixelBuffer:(CVPixelBufferRef)buffer
                                 confidence:(double)minimumConfidence
                                 onlyPerson:(BOOL)onlyPerson
                                   maxBoxes:(int)maxBoxes;

@end
