// Bridge to AuthCore.dylib.
//
// The dylib is loaded at launch by the dynamic linker (it is embedded in
// Frameworks with an @executable_path install name), so these symbols resolve
// normally when it is present.
//
// When it is absent the linker would fail, so the app is built with
// `-weak_framework`-style weak symbols: each declaration is marked weak_import
// and the bridge checks for nil before calling. That keeps the app buildable and
// runnable without the dylib while still using it when present.

#ifndef AUTHCORE_BRIDGE_H
#define AUTHCORE_BRIDGE_H

#include <stdbool.h>

/// True when the AuthCore dylib is loaded in this process.
/// Weak: returns false when the dylib is not embedded.
extern bool AuthCoreIsLoaded(void) __attribute__((weak_import));

/// Version string of the loaded dylib, or NULL when absent.
extern const char *AuthCoreVersion(void) __attribute__((weak_import));

/// Compact integrity report, or NULL when absent.
extern const char *AuthCoreIntegritySummary(void) __attribute__((weak_import));

/// Runs the full integrity check and returns true when everything passes.
extern bool AuthCoreVerifyIntegrity(void) __attribute__((weak_import));

// ---- Overlay component (SpringBoard half) --------------------------------
//
// The same AuthCore.dylib is installed by the .deb into /usr/lib and loaded into
// SpringBoard, where it runs the overlay engine. These three answer "is that copy
// actually running", which the copy inside this bundle cannot know.
//
// AuthCoreIsLoaded() is NOT the test: it only says the embedded dylib loaded.

/// True when the SpringBoard component is running with a heartbeat under 15 s old.
extern bool AuthCoreSystemAvailable(void) __attribute__((weak_import));

/// Seconds since the component's last heartbeat, or -1 when it was never seen.
extern double AuthCoreSystemHeartbeatAge(void) __attribute__((weak_import));

/// True when a missing component is a fault on this device: jailbroken (so the
/// .deb is installable) and not TrollStore-only (where it never is). The app is
/// expected to show install instructions while this is true and the component is
/// not available.
extern bool AuthCoreComponentRequired(void) __attribute__((weak_import));

/// Toggles the driver requirement. Passed down from the server switch on every
/// heartbeat; NO also stops the component's licence round trip, which otherwise
/// fires two seconds after launch on a utility queue whatever the setting says.
extern void AuthCoreSetDriverEnforcement(bool enabled) __attribute__((weak_import));
extern bool AuthCoreDriverEnforcementEnabled(void) __attribute__((weak_import));

// ---- Card verification (the dylib's own second check) ---------------------
//
// The app asks the server once, at activation. The dylib asks again, on its own,
// so a patched app-side verdict does not survive. The result gates the overlay
// engine: invalid -> capture, drawing and injection never start.
//
// There is no grace period. The 300 s cache is a performance measure; past it the
// answer is "invalid" until a fresh check succeeds, and a network failure is a
// failure.

/// Submits a card for the dylib's own check. Blocking, up to ~5 s.
///   0 = valid, -1 = network, -2 = card rejected, -3 = signature/config,
///   -4 = server refused.
extern int AuthCoreSubmitCard(const char *cardCode, const char *deviceId)
    __attribute__((weak_import));

/// Whether the last check passed and is still inside the cache window.
extern bool AuthCoreLicenseValid(void) __attribute__((weak_import));

/// Seconds since the last successful check, -1 when it never ran.
extern double AuthCoreLicenseAge(void) __attribute__((weak_import));

/// Level reported by the server (0..4), -1 when unknown.
extern int AuthCoreLicenseLevel(void) __attribute__((weak_import));

/// Result code of the most recent check (see AuthCoreSubmitCard).
extern int AuthCoreLastLicenseResult(void) __attribute__((weak_import));

/// Republishes the card/device the app holds into the shared stores and runs one
/// check. Call it after activation succeeds.
extern void AuthCoreSyncLicense(void) __attribute__((weak_import));

// ---- Safe wrappers -------------------------------------------------------
// Swift cannot test a weak function pointer for NULL, so every call is routed
// through these. Each one checks availability before dereferencing.
//
// `AuthCoreBridgeAnchor` exists because a weak_import reference that is only
// ever compared against NULL does not make the linker emit a load command, and
// the dylib would then never be loaded. The anchor takes the address in a way
// the optimiser cannot remove.

bool AuthCoreBridgeAnchor(void);
bool AuthCoreBridgeAvailable(void);
const char *AuthCoreBridgeVersion(void);
const char *AuthCoreBridgeIntegrity(void);
bool AuthCoreBridgeVerify(void);

/// Overlay-component wrappers. Unlike the four above they return a definite
/// "no" when the dylib is absent, which is the correct answer there.
bool AuthCoreBridgeSystemAvailable(void);
double AuthCoreBridgeSystemHeartbeatAge(void);
bool AuthCoreBridgeComponentRequired(void);

/// Tells the dylib whether the server still requires the driver.
///
/// Enforcement used to run purely off the jailbreak check, so an operator turning
/// dylib.verify off changed nothing and the app still exited on any device that
/// looked jailbroken. The app calls this after every heartbeat; NO disables both
/// the exit gate and the component's own licence round trip.
void AuthCoreBridgeSetDriverEnforcement(bool enabled);
bool AuthCoreBridgeDriverEnforcementEnabled(void);

// Card-verification wrappers. Swift cannot call a weak C symbol directly, and
// cannot pass a `const char *` that may be NULL, so both are handled here.
int AuthCoreBridgeSubmitCard(const char *cardCode, const char *deviceId);
bool AuthCoreBridgeLicenseValid(void);
double AuthCoreBridgeLicenseAge(void);
int AuthCoreBridgeLicenseLevel(void);
int AuthCoreBridgeLastLicenseResult(void);
void AuthCoreBridgeSyncLicense(void);

#endif /* AUTHCORE_BRIDGE_H */
