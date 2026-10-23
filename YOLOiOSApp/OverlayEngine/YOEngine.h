//
//  YOEngine.h
//  AuthCore / overlay engine
//
//  Entry point for the SpringBoard half of AuthCore.dylib.
//
//  AuthCore.m's constructor decides which host it is in and calls this only from
//  SpringBoard. The function double-checks that itself, so a mistaken call from
//  the app process is a no-op rather than a second overlay.
//

#ifndef YO_ENGINE_H
#define YO_ENGINE_H

#import <Foundation/Foundation.h>

/// Starts the overlay engine: capture loop, Core ML inference, the overlay
/// window and the aim injector.
///
/// Safe to call from any process, any thread, and more than once. UI work is
/// moved to the main queue; nothing is touched before the SpringBoard check.
void YOEngineStart(void);

#endif /* YO_ENGINE_H */
