// AuthCore bridge implementation.
//
// The dylib is loaded by the dynamic linker when it is embedded in the app
// bundle's Frameworks directory. Its C entry points are declared `weak_import`
// in the header, so when the dylib is absent the symbols resolve to NULL instead
// of failing the build or crashing at launch.
//
// A subtlety worth recording: with `-weak_library`, a translation unit that only
// ever *tests* the symbol addresses produces NO LC_LOAD_WEAK_DYLIB command, and
// the dylib is then never loaded even though it sits in the bundle. Taking the
// address into a volatile local forces a real relocation against the library,
// which is what emits the load command. `anchorWeakReferences` below does that
// once at startup, and its result is what the availability check reports.

#include "AuthCoreBridge.h"
#include <stddef.h>

// Set by the anchor. Never read directly outside this file.
static int gAnchorLoaded = 0;

/// Forces the linker to emit a load command for AuthCore.
///
/// Called from `AuthCoreBridgeAvailable`. The volatile sink prevents the
/// compiler from folding the address comparison away, which would silently
/// remove the only reference to the library.
bool AuthCoreBridgeAnchor(void) {
    static volatile void *sink = NULL;
    sink = (void *)AuthCoreIsLoaded;
    return sink != NULL;
}

bool AuthCoreBridgeAvailable(void) {
    // The anchor doubles as the availability check: it is non-NULL only when the
    // dylib was actually loaded.
    bool present = AuthCoreBridgeAnchor();
    if (!present) {
        gAnchorLoaded = 0;
        return false;
    }
    if (AuthCoreIsLoaded == NULL) return false;
    gAnchorLoaded = AuthCoreIsLoaded() ? 1 : 0;
    return gAnchorLoaded == 1;
}

const char *AuthCoreBridgeVersion(void) {
    if (!AuthCoreBridgeAvailable()) return NULL;
    if (AuthCoreVersion == NULL) return NULL;
    return AuthCoreVersion();
}

const char *AuthCoreBridgeIntegrity(void) {
    if (!AuthCoreBridgeAvailable()) return NULL;
    if (AuthCoreIntegritySummary == NULL) return NULL;
    return AuthCoreIntegritySummary();
}

bool AuthCoreBridgeVerify(void) {
    if (!AuthCoreBridgeAvailable()) return false;
    if (AuthCoreVerifyIntegrity == NULL) return false;
    return AuthCoreVerifyIntegrity();
}

// Overlay-component wrappers.
//
// These deliberately do NOT go through AuthCoreBridgeAvailable(): there are two
// copies of this library (the one embedded here and the one the .deb installs
// into SpringBoard), and the whole question is about the *other* copy. If the
// embedded one is missing, the answer is simply "no component" — returning false
// rather than failing is the honest result, and the app can then show the
// install instructions.

bool AuthCoreBridgeSystemAvailable(void) {
    if (AuthCoreSystemAvailable == NULL) return false;
    return AuthCoreSystemAvailable();
}

double AuthCoreBridgeSystemHeartbeatAge(void) {
    if (AuthCoreSystemHeartbeatAge == NULL) return -1.0;
    return AuthCoreSystemHeartbeatAge();
}

void AuthCoreBridgeSetDriverEnforcement(bool enabled) {
    if (AuthCoreSetDriverEnforcement == NULL) return;
    AuthCoreSetDriverEnforcement(enabled);
}

bool AuthCoreBridgeDriverEnforcementEnabled(void) {
    if (AuthCoreDriverEnforcementEnabled == NULL) return false;
    return AuthCoreDriverEnforcementEnabled();
}

bool AuthCoreBridgeComponentRequired(void) {
    if (AuthCoreComponentRequired == NULL) return false;
    return AuthCoreComponentRequired();
}

// Card verification.
//
// These also bypass AuthCoreBridgeAvailable(): the check can be initiated from
// either host, and "dylib absent" is already reported by -1 (network) / -3
// (configuration) rather than needing a separate failure mode.

int AuthCoreBridgeSubmitCard(const char *cardCode, const char *deviceId) {
    if (AuthCoreSubmitCard == NULL) return -3;
    if (cardCode == NULL || deviceId == NULL) return -3;
    if (cardCode[0] == '\0' || deviceId[0] == '\0') return -3;
    return AuthCoreSubmitCard(cardCode, deviceId);
}

bool AuthCoreBridgeLicenseValid(void) {
    if (AuthCoreLicenseValid == NULL) return false;
    return AuthCoreLicenseValid();
}

double AuthCoreBridgeLicenseAge(void) {
    if (AuthCoreLicenseAge == NULL) return -1.0;
    return AuthCoreLicenseAge();
}

int AuthCoreBridgeLicenseLevel(void) {
    if (AuthCoreLicenseLevel == NULL) return -1;
    return AuthCoreLicenseLevel();
}

int AuthCoreBridgeLastLicenseResult(void) {
    if (AuthCoreLastLicenseResult == NULL) return -3;
    return AuthCoreLastLicenseResult();
}

void AuthCoreBridgeSyncLicense(void) {
    if (AuthCoreSyncLicense == NULL) return;
    AuthCoreSyncLicense();
}
