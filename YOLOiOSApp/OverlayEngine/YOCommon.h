//
//  YOCommon.h
//  AuthCore / overlay engine
//
//  Shared constants and helpers for the SpringBoard half of AuthCore.dylib.
//
//  One binary, two hosts. The same AuthCore.dylib is
//    * embedded in the app bundle (Frameworks/AuthCore.dylib, @rpath) and loaded
//      into the app process, where it keeps doing the integrity work it always
//      did, and
//    * installed by the .deb into /usr/lib and loaded into SpringBoard by a
//      filter that targets com.apple.springboard, where it runs the overlay.
//
//  The overlay has to live in SpringBoard: a UIWindow owned by an app is only
//  composited inside that app's process, so it disappears the moment the app is
//  backgrounded. SpringBoard's own windows sit above every app and SpringBoard is
//  never suspended.
//
//  Design rule that governs every file here: nothing is assumed to exist. Every
//  private symbol is resolved with dlsym at runtime and every call is checked. On
//  a system where the private API is gone the component still loads, writes its
//  heartbeat, reports why the rest is unavailable, and touches nothing else. It
//  never aborts SpringBoard.
//

#import <Foundation/Foundation.h>

#define YO_VERSION @"1.1.0"

/// Directory shared between the app and this component. Writable on a
/// jailbroken device; on a stock device the writes below simply fail.
extern NSString *const YOPrefsDir;

/// Config written by the app, read here. Keys are documented in README.md.
extern NSString *const YOConfigPath;

/// Primary heartbeat: unix timestamp, rewritten every 5 s.
/// The app cannot read this on a non-escaped build, which is why the same stamp
/// is also mirrored into the app's own Documents directory (see below).
extern NSString *const YOAlivePath;

/// Mirror of the heartbeat inside the app's container, readable by the sandboxed
/// app without any jailbreak-specific escape.
extern NSString *const YOAliveFileName;

/// Pre-rename heartbeat path. Still written so an app build that predates the
/// merge keeps reporting the component as loaded.
extern NSString *const YOLegacyAlivePath;

/// Diagnostic log. Capped and rotated so it can never fill /var.
extern NSString *const YOLogPath;

/// Darwin notification posted by the app after it rewrites the config.
extern NSString *const YOReloadNotification;

/// App bundle identifier whose container receives the heartbeat mirror.
extern NSString *const YOAppBundleIdentifier;

/// Append a line to the log file. Safe to call from any thread and from a
/// process without write access (the write is simply dropped).
void YOLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// YES when the current process is SpringBoard. Cached after the first call.
BOOL YOIsSpringBoard(void);

/// Unix seconds, as a double.
double YONowUnix(void);

/// `Documents` directory of the app's data container, or nil when it cannot be
/// found. SpringBoard has the file-system access to locate it; the app itself
/// knows its own path and never calls this.
///
/// Resolution walks /var/mobile/Containers/Data/Application and matches
/// MCMMetadataIdentifier in each container's metadata plist. The result is
/// cached, and re-resolved only while still unknown.
NSString *YOAppDocumentsPath(void);

/// Age in seconds of the freshest heartbeat this process can see, or -1 when no
/// heartbeat has ever been written.
///
/// Reads the primary path first, then the legacy one, then the app container
/// mirror, and returns the smallest age.
double YOHeartbeatAge(void);

/// YES when TrollStore is installed. TrollStore grants no SpringBoard injection,
/// so on such a device the component cannot be installed at all - callers must
/// not treat "component missing" as a fault there.
BOOL YOIsTrollStoreInstalled(void);

/// YES when this device shows jailbreak artifacts (i.e. the .deb is installable).
BOOL YOLooksJailbroken(void);
