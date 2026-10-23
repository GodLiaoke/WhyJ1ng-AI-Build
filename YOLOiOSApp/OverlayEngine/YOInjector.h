//
//  YOInjector.h
//  YOOverlay
//
//  Injects a touch drag into the system input stream from inside SpringBoard.
//  This is the only place in the project that is allowed to post synthetic
//  input, and it is only reachable from a process that already has the right
//  sandbox profile  -  which is why it lives here and not in the app.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// Posted when a touch identity is captured and injection becomes usable. The
/// engine listens for it so the aim transport can flip on without waiting for a
/// configuration reload.
extern NSString *const YOInjectorDidBecomeReadyNotification;

@interface YOInjector : NSObject

+ (instancetype)shared;

/// NO when the private IOKit entry points are absent, the client could not be
/// created, or no touch identity has been captured yet. `status` says which.
///
/// The identity clause matters: the system silently discards every event that
/// carries no senderID  -  no error, no crash, no log. Reporting available without
/// one would make the app claim aiming works while nothing reaches the screen.
@property (nonatomic, readonly) BOOL available;
@property (nonatomic, readonly, copy) NSString *status;

/// The input identity issued to this boot, or 0 before one has been captured.
@property (nonatomic, readonly) uint64_t senderID;

/// Starts listening for one real touch so its senderID can be captured.
///
/// There is no way to synthesise a valid identity: it has to be read off a live
/// event. Safe to call repeatedly; it is a no-op while already waiting or when an
/// identity is already known. The value is cached per boot, so this only needs to
/// run once after each SpringBoard start.
- (void)startGrabbing;

/// Stops listening. Called automatically once an identity is captured.
- (void)stopGrabbing;

/// Drags a single finger from `from` to `to`, both in display points.
///
/// Coordinates are normalised against the live screen size internally; the HID
/// stack does not accept pixels.
///
/// `scale` is ignored and kept only for source compatibility.
///
/// A drag, not a tap: a game's look control is a press-move-release gesture, so
/// the sequence sent is exactly down -> moves -> up.
- (BOOL)dragFrom:(CGPoint)from to:(CGPoint)to scale:(double)scale;

/// Drags along an explicit path, one move event per point after the first.
- (BOOL)dragAlongPath:(NSArray<NSValue *> *)points scale:(double)scale;

@end
