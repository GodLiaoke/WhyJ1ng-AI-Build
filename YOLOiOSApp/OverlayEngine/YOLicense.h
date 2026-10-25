//
//  YOLicense.h
//  AuthCore / overlay engine
//
//  The SpringBoard half's own licence check.
//
//  The app decides at activation time and stores its verdict in its own defaults.
//  That verdict lives in the one process a patcher can reach, so the component
//  asks the server again, from inside SpringBoard, with the card the app
//  published:
//
//      app says valid, server says card revoked  ->  the app's copy was tampered
//
//  The result gates the engine. There is no grace period and no offline
//  tolerance: a failed check stops capture, drawing and injection, and the engine
//  retries once a minute so a later activation starts it without a respring.
//

#import <Foundation/Foundation.h>

/// Runs one check: reads the card/device the app published, submits it, and
/// caches the verdict. Blocking on the network for up to ~5 s the first time;
/// inside the cache window it answers from memory.
BOOL YOLicenseRefresh(void);

/// Verdict of the most recent successful check, inside its cache window.
BOOL YOLicenseValid(void);

/// Human-readable reason for the last failure, or an empty string.
NSString *YOLicenseReason(void);

/// Result code of the last check, mirroring AuthCoreSubmitCard's contract:
/// 0 valid, -1 network, -2 card rejected, -3 signature/config, -4 server refused.
int YOLicenseLastResult(void);
