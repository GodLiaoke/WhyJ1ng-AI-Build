import Foundation
import CoreGraphics
import CryptoKit

// MARK: - Server-issued aim parameters
//
// Round 7 moved every number that shapes the aim movement out of the app. The
// server samples the values, encrypts them, and hands them over inside the
// heartbeat's `feature` block:
//
//   feature.token          base64(iv || tag || ct), AES-256-GCM under
//                          lic_settings.feature.secret (32 raw bytes from the
//                          compiled hex constant below). MUST be decrypted and
//                          validated here: a token that is not bound to this
//                          device and still inside its window authorises
//                          nothing.
//   feature.params_blob    base64(iv || tag || ct), AES-256-GCM under a key
//                          derived from the *raw token bytes*.
//   feature.params_version structure version, also the KDF `salt` input.
//   feature.expires_at     unix seconds; the token and the table die together.
//
// Wire facts confirmed against the deployed server (`lic_api.php` L4a and the
// end-to-end contract probe):
//   * envelope layout is `iv(12) || tag(16) || ciphertext` — NOT CryptoKit's
//     `nonce || ct || tag` combined form, so the pieces are reassembled by hand;
//   * the token payload is JSON `{device, version, scope, exp, nonce, window}`;
//   * the params key is
//     HKDF-SHA256(ikm: token raw bytes, salt: "7" (the version as a string),
//     info: "params", 32). Swapping salt and info also yields 32 bytes, but the
//     GCM tag then rejects them — authentication is what keeps the order honest;
//   * `anchors` arrives 4–7 points, strictly increasing, first=0, last=1, and is
//     re-sampled every heartbeat. Nothing may assume equal spacing or a fixed
//     row count.
//
// What this file deliberately does NOT contain: any default table, any fallback
// coefficient, any "if decryption fails use these numbers". Decryption failure
// is nil, and nil means aiming does not run.

struct AimParams {

    // MARK: Compiled key material
    //
    // The token is sealed with `lic_settings.feature.secret` — 64 hex chars →
    // 32 raw bytes. The server does not send the key (a client that needed it
    // delivered over the wire could not be the only holder of it), so it ships
    // compiled in, XOR-masked exactly like AuthCore.m's `kMaskedLicenseSecret`:
    // the bytes are not the key, the XOR with `featureSecretMask` is.
    //
    // Rotating the server key means updating this constant and shipping a new
    // build; until then tokens fail to open and the client simply has no table
    // — which is the designed "no parameters" state, not an error.

    private static let featureSecretMask: UInt8 = 0x5C

    /// XOR-masked 32 bytes; reconstructed at first use, never stored back.
    private static let maskedFeatureSecret: [UInt8] = [
        0xde, 0x01, 0x8d, 0x2f, 0x52, 0x22, 0xa9, 0x1a,
        0x24, 0x58, 0x23, 0xcf, 0x25, 0x8d, 0x83, 0xa0,
        0x42, 0x2a, 0x76, 0x86, 0x86, 0xbe, 0x7c, 0x3b,
        0x3a, 0xe1, 0x15, 0xc0, 0x34, 0x28, 0x24, 0xcb,
    ]

    // MARK: Stored payload

    /// Rows of `[heightFraction, widthFraction]`.
    ///
    /// `heightFraction` is the band measured down from the top of the detection
    /// box that counts as the head; `widthFraction` is where in the box the
    /// head sits horizontally. The table is sampled, not written out: the
    /// server re-samples the same curve on every heartbeat, so the numbers
    /// differ between two replies that behave identically.
    let headOffsetTable: [[Double]]

    /// Smoothing samples, one per anchor. 0 = rigid, toward 1 = soft.
    let smoothingCurve: [Double]

    /// Weights over successive look-ahead steps, normalised to sum 1 by the
    /// server. Their order matters: index 0 is the nearest horizon.
    let predictionWeights: [Double]

    /// Movement-speed tiers, smallest first. Selected by target scale.
    let speedTable: [Double]

    /// Per-tick output bound on one axis, in normalised frame units.
    let clampMin: Double
    let clampMax: Double

    /// Hard deadline. `isValid` is a plain comparison: no grace, per the
    /// requirement.
    let expiresAt: Date

    /// Abscissa shared by `headOffsetTable` and `smoothingCurve`.
    ///
    /// The server samples at uneven, randomly chosen positions (4–7 rows,
    /// `anchors[0] == 0`, `anchors[last] == 1`), so an evenly spaced assumption
    /// would read the wrong row for every target. Both curves are linear in the
    /// anchor, which is what makes re-sampling at new positions produce
    /// identical results.
    let anchors: [Double]

    /// `params_version` this table was issued under.
    let version: Int

    /// `window` from the token payload — the 60-second slot the token was
    /// minted in. Diagnostic only; the deadline is `exp`.
    let tokenWindow: Int

    /// `nonce` from the token payload (16 hex chars). Diagnostic only.
    let tokenNonce: String

    init(headOffsetTable: [[Double]],
         smoothingCurve: [Double],
         predictionWeights: [Double],
         speedTable: [Double],
         clampMin: Double,
         clampMax: Double,
         expiresAt: Date,
         anchors: [Double],
         version: Int,
         tokenWindow: Int = 0,
         tokenNonce: String = "") {
        self.headOffsetTable = headOffsetTable
        self.smoothingCurve = smoothingCurve
        self.predictionWeights = predictionWeights
        self.speedTable = speedTable
        self.clampMin = clampMin
        self.clampMax = clampMax
        self.expiresAt = expiresAt
        self.anchors = anchors
        self.version = version
        self.tokenWindow = tokenWindow
        self.tokenNonce = tokenNonce
    }

    // MARK: Validity

    /// Zero grace: once the deadline passes there is no table.
    var isValid: Bool { Date() < expiresAt }

    /// Seconds left, floored at 0. For display only.
    var remaining: TimeInterval { max(0, expiresAt.timeIntervalSinceNow) }

    // MARK: Lookup

    /// Head geometry for a target of the given normalised height.
    ///
    /// Returns `CGPoint(x: widthFraction, y: heightFraction)` - x is horizontal
    /// (as `CGPoint` implies), so the caller can use the components directly
    /// against the box without remembering which column was which.
    ///
    /// `confidence` is part of the frozen call signature but does not move the
    /// lookup: the table the server issues is indexed by target scale only.
    /// Confidence feeds `smoothing(forConfidence:)` instead, which is the curve
    /// the server built for it. Guessing a second axis here would be inventing
    /// an algorithm.
    func headOffset(forHeight h: Double, confidence: Double) -> CGPoint {
        let t = AimParams.unit(h)
        let heightFraction = rowValue(at: t, column: 0)
        let widthFraction = rowValue(at: t, column: 1)
        return CGPoint(x: CGFloat(widthFraction), y: CGFloat(heightFraction))
    }

    /// The aim point inside a normalised detection box.
    ///
    /// The table gives a band *height* and a horizontal position. The point is
    /// the middle of that band, which is the same construction the SpringBoard
    /// component uses (`YOEngine.m`: `aim.y = origin.y + headBand / 2`), so the
    /// two halves of the app cannot disagree about where the head is.
    ///
    /// `rect` is normalised (0...1) and the result is too, in the same space.
    func aimPoint(for rect: CGRect, confidence: Double) -> CGPoint {
        let head = headOffset(forHeight: Double(rect.height), confidence: confidence)
        let x = Double(rect.minX) + Double(rect.width) * Double(head.x)
        let y = Double(rect.minY) + Double(rect.height) * Double(head.y) * 0.5
        return CGPoint(x: x, y: y)
    }

    /// Smoothing for a confidence in 0...1, interpolated over the anchors.
    func smoothing(forConfidence c: Double) -> Double {
        curveValue(smoothingCurve, at: AimParams.unit(c))
    }

    /// Lead time for one tick, in seconds, as a per-axis factor.
    ///
    /// `predictionWeights` describes successive horizons: weight i belongs to
    /// `(i + 1) * dt`. The weighted mean collapses them into the single horizon
    /// the caller multiplies its velocity by, which keeps the units honest -
    /// velocity is in normalised units per second and the result is seconds,
    /// so the product is a distance and the lead does not drift with the tick
    /// rate.
    func prediction(forDt dt: Double) -> CGVector {
        guard dt.isFinite, dt > 0 else { return .zero }

        var totalWeight = 0.0
        var weightedHorizon = 0.0
        for (i, w) in predictionWeights.enumerated() where w > 0 && w.isFinite {
            totalWeight += w
            weightedHorizon += w * Double(i + 1)
        }
        guard totalWeight > 0 else { return .zero }

        let horizon = weightedHorizon / totalWeight * dt
        return CGVector(dx: CGFloat(horizon), dy: CGFloat(horizon))
    }

    /// Speed tier by index, clamped into range so a short table cannot crash.
    func speed(forIndex i: Int) -> Double {
        guard !speedTable.isEmpty else { return 0 }
        let idx = min(max(i, 0), speedTable.count - 1)
        return speedTable[idx]
    }

    /// Which speed tier a target of the given normalised height falls in.
    ///
    /// Near (large box) targets get the faster tier: the box is stable and the
    /// error is a bigger fraction of the frame, so the same gain looks slower.
    /// Derived from the table length rather than fixed at three tiers, because
    /// the server owns how many there are.
    func speedIndex(forHeight h: Double) -> Int {
        guard !speedTable.isEmpty else { return 0 }
        let n = speedTable.count
        if n == 1 { return 0 }
        let t = AimParams.unit(h)
        let idx = Int(t * Double(n))
        return min(max(idx, 0), n - 1)
    }

    /// Bounds one axis of movement to the server's output clamp.
    func clamp(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, clampMin), clampMax)
    }

    // MARK: Display

    /// Geometry at anchor 0, which the server defines as the configured
    /// baseline (`t = 0` leaves the curve value untouched).
    var displayHeadOffset: CGPoint {
        guard let row = headOffsetTable.first, row.count >= 2 else { return .zero }
        return CGPoint(x: CGFloat(row[1]), y: CGFloat(row[0]))
    }

    /// Smoothing at anchor 0, same reasoning.
    var displaySmoothing: Double { smoothingCurve.first ?? 0 }

    /// Mid speed tier - what the rail is centred on.
    var displaySpeed: Double { speed(forIndex: speedTable.count / 2) }

    // MARK: Interpolation

    /// Clamps an abscissa into the unit interval; anchors live in 0...1 and a
    /// target can sit slightly outside it after box expansion.
    private static func unit(_ v: Double) -> Double {
        guard v.isFinite else { return 0 }
        return min(max(v, 0), 1)
    }

    /// Linear interpolation between anchors, per the server's `interp: linear`.
    ///
    /// Never assumes the anchors are equally spaced and never assumes a fixed
    /// row count: the server re-samples 4–7 uneven points on every heartbeat.
    private func curveValue(_ table: [Double], at t: Double) -> Double {
        let n = min(table.count, anchors.count)
        guard n > 0 else { return 0 }
        if n == 1 { return table[0] }

        if t <= anchors[0] { return table[0] }
        if t >= anchors[n - 1] { return table[n - 1] }

        var hi = 1
        while hi < n - 1 && anchors[hi] < t { hi += 1 }
        let lo = hi - 1

        let span = anchors[hi] - anchors[lo]
        guard span > 0 else { return table[lo] }
        let f = (t - anchors[lo]) / span
        return table[lo] + (table[hi] - table[lo]) * f
    }

    /// Same interpolation, reading one column of the offset rows.
    private func rowValue(at t: Double, column: Int) -> Double {
        let n = min(headOffsetTable.count, anchors.count)
        guard n > 0 else { return 0 }
        func cell(_ i: Int) -> Double {
            let row = headOffsetTable[i]
            return column < row.count ? row[column] : 0
        }
        if n == 1 { return cell(0) }

        if t <= anchors[0] { return cell(0) }
        if t >= anchors[n - 1] { return cell(n - 1) }

        var hi = 1
        while hi < n - 1 && anchors[hi] < t { hi += 1 }
        let lo = hi - 1

        let span = anchors[hi] - anchors[lo]
        guard span > 0 else { return cell(lo) }
        let f = (t - anchors[lo]) / span
        return cell(lo) + (cell(hi) - cell(lo)) * f
    }

    // MARK: Decryption

    /// Decrypts and validates one heartbeat `feature` block.
    ///
    /// Order matters and is the whole point: the token is opened first, its
    /// binding is checked, and only then is it used as key material for the
    /// blob. A block whose token cannot be opened, is bound to another device,
    /// or has already expired yields nil — never a table, never a fallback.
    ///
    /// - Parameters:
    ///   - feature: the decoded `feature` object from the heartbeat reply.
    ///   - token: `feature.token`
    ///   - version: `feature.params_version`
    ///   - deviceId: this device's fingerprint; the token must name it.
    ///   - serverSkew: seconds to add to server timestamps to reach local time
    ///     (measured by the transport layer). The deadline inside the token is
    ///     on the server's clock; converting once here keeps `isValid` a plain
    ///     local comparison.
    ///   - expiresAt: optional caller-side deadline (`feature.expires_at`
    ///     converted with the same skew). The token's own `exp` is authoritative;
    ///     when the two disagree the earlier one wins, so a stale `expires_at`
    ///     can never extend a token past its own word.
    /// - Returns: a usable table, or nil for every failure mode.
    static func decrypt(feature: [String: Any],
                        token: String,
                        version: Int,
                        deviceId: String,
                        serverSkew: TimeInterval,
                        expiresAt: Date? = nil) -> AimParams? {
        guard !token.isEmpty, version > 0, !deviceId.isEmpty else { return nil }
        guard let secret = featureSecret() else { return nil }
        guard let tokenRaw = Data(base64Encoded: token), tokenRaw.count > 28 else {
            return nil
        }

        // ---- 1. open the token with the compiled feature secret ----
        guard let tokenPlain = open(tokenRaw, key: SymmetricKey(data: secret)) else {
            return nil
        }
        guard let tokenJson = (try? JSONSerialization.jsonObject(with: tokenPlain))
            as? [String: Any] else { return nil }

        // ---- 2. token binding: this device, still inside the window ----
        guard let boundDevice = tokenJson["device"] as? String,
              boundDevice == deviceId else { return nil }
        guard let exp = number(tokenJson["exp"]), exp.isFinite, exp > 0 else {
            return nil
        }
        let tokenDeadline = Date(timeIntervalSince1970: exp + serverSkew)
        guard Date() < tokenDeadline else { return nil }

        // ---- 3. scope: the token must name aim ----
        if let scope = tokenJson["scope"] as? [String], !scope.isEmpty,
           !scope.contains("aim") { return nil }

        // The caller's stamp (from `feature.expires_at`) can only shorten the
        // window, never extend it past the token's own `exp`.
        let deadline: Date
        if let callerDeadline = expiresAt, callerDeadline < tokenDeadline {
            deadline = callerDeadline
        } else {
            deadline = tokenDeadline
        }

        // ---- 4. blob: HKDF over the RAW token bytes, salt = version string ----
        guard let blobB64 = feature["params_blob"] as? String, !blobB64.isEmpty,
              let blobRaw = Data(base64Encoded: blobB64), blobRaw.count > 28 else {
            return nil
        }
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: tokenRaw),
                                         salt: Data(String(version).utf8),
                                         info: Data("params".utf8),
                                         outputByteCount: 32)
        guard let plain = open(blobRaw, key: key),
              let json = (try? JSONSerialization.jsonObject(with: plain)) as? [String: Any]
        else { return nil }

        // ---- 5. tables ----
        guard let rawRows = json["headOffsetTable"] as? [Any], !rawRows.isEmpty else { return nil }
        var rows: [[Double]] = []
        rows.reserveCapacity(rawRows.count)
        for raw in rawRows {
            guard let pair = raw as? [Any], pair.count >= 2 else { return nil }
            guard let h = number(pair[0]), let w = number(pair[1]) else { return nil }
            rows.append([h, w])
        }

        guard let rawSmoothing = json["smoothingCurve"] as? [Any] else { return nil }
        guard let smoothing = doubles(rawSmoothing), !smoothing.isEmpty else { return nil }

        guard let rawWeights = json["predictionWeights"] as? [Any],
              let weights = doubles(rawWeights), !weights.isEmpty else { return nil }

        guard let rawSpeed = json["speedTable"] as? [Any],
              let speeds = doubles(rawSpeed), !speeds.isEmpty else { return nil }

        // ---- 6. anchors: required, uneven-capable, re-sampled every beat ----
        guard let rawAnchors = json["anchors"] as? [Any],
              let anchors = doubles(rawAnchors), anchors.count >= 2 else { return nil }
        guard anchors.count == rows.count, anchors.count == smoothing.count else { return nil }
        for i in 1..<anchors.count where anchors[i] <= anchors[i - 1] { return nil }

        // ---- 7. clamp ----
        let clamp = json["clamp"] as? [String: Any] ?? [:]
        guard let clampMin = number(clamp["min"]), let clampMax = number(clamp["max"]) else {
            return nil
        }
        guard clampMin.isFinite, clampMax.isFinite, clampMax >= clampMin else { return nil }

        return AimParams(headOffsetTable: rows,
                         smoothingCurve: smoothing,
                         predictionWeights: weights,
                         speedTable: speeds,
                         clampMin: clampMin,
                         clampMax: clampMax,
                         expiresAt: deadline,
                         anchors: anchors,
                         version: version,
                         tokenWindow: number(tokenJson["window"]).map { Int($0) } ?? 0,
                         tokenNonce: (tokenJson["nonce"] as? String) ?? "")
    }

    /// Unmasks the compiled secret. Returns nil when the constant is not a
    /// well-formed 32-byte key, which keeps a half-edited build failing closed.
    private static func featureSecret() -> Data? {
        let masked = maskedFeatureSecret
        guard masked.count == 32 else { return nil }
        var raw = [UInt8](repeating: 0, count: masked.count)
        for i in 0..<masked.count {
            raw[i] = masked[i] ^ featureSecretMask
        }
        return Data(raw)
    }

    /// Opens a server envelope: `iv(12) || tag(16) || ciphertext`.
    ///
    /// Same wire layout as the transport layer, and the same reason for not
    /// using `SealedBox.combined` — CryptoKit orders those three parts
    /// differently (`nonce || ciphertext || tag`), so the pieces are assembled
    /// by hand. Kept local rather than calling `CryptoSession.aesGCMDecrypt`
    /// because that type is an actor: this is a pure function called from the
    /// main actor on every heartbeat, and hopping into an actor to decrypt is
    /// both pointless and a source of ordering surprises.
    private static func open(_ raw: Data, key: SymmetricKey) -> Data? {
        guard raw.count > 28 else { return nil }
        let iv = raw.prefix(12)
        let tag = raw.dropFirst(12).prefix(16)
        let ct = raw.dropFirst(28)
        guard let nonce = try? AES.GCM.Nonce(data: iv),
              let box = try? AES.GCM.SealedBox(nonce: nonce,
                                               ciphertext: ct,
                                               tag: tag)
        else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: JSON helpers

    /// PHP's `json_encode` emits whole numbers as ints, so one field can arrive
    /// as Int, Double, NSNumber or a stringy number depending on the value.
    private static func number(_ raw: Any?) -> Double? {
        switch raw {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String: return Double(s)
        default: return nil
        }
    }

    private static func doubles(_ raw: [Any]) -> [Double]? {
        var out: [Double] = []
        out.reserveCapacity(raw.count)
        for item in raw {
            guard let v = number(item), v.isFinite else { return nil }
            out.append(v)
        }
        return out
    }
}

extension AimParams: Equatable {
    /// Identity of a table, for the panel to tell one heartbeat's reply from
    /// the next without comparing every number. The token nonce participates:
    /// two replies with the same numbers but different tokens are still
    /// different deliveries.
    static func == (lhs: AimParams, rhs: AimParams) -> Bool {
        lhs.version == rhs.version
            && lhs.expiresAt == rhs.expiresAt
            && lhs.tokenNonce == rhs.tokenNonce
            && lhs.clampMin == rhs.clampMin
            && lhs.clampMax == rhs.clampMax
            && lhs.headOffsetTable == rhs.headOffsetTable
            && lhs.smoothingCurve == rhs.smoothingCurve
            && lhs.predictionWeights == rhs.predictionWeights
            && lhs.speedTable == rhs.speedTable
            && lhs.anchors == rhs.anchors
    }
}
