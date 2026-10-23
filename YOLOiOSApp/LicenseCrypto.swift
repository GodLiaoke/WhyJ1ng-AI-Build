import Foundation
import CryptoKit

// MARK: - Crypto session
//
// Application-layer encryption for the license backend.
//
// The server requires every request to arrive inside an encrypted envelope
// (it answers `426 encryption_required` otherwise), so this layer is not
// optional — it is the transport.
//
// Protocol, mirroring `core/crypto.php`:
//
//   1. GET  /api/crypto/handshake
//        -> { public_key (base64 SPKI), server_nonce, ... }
//   2. Generate a random 32-byte AES key.
//      RSA-OAEP/SHA-256 encrypt it with that public key.
//      POST /api/crypto/session { encrypted_key, client_nonce }
//        -> { session_id, expires_in }
//   3. Every request thereafter:
//        header X-Session: <session_id>
//        header X-Nonce:   <monotonic counter, must increase>
//        header X-Sign:    HMAC-SHA256(plaintextJSON, aesKey)
//        body   { "payload": base64(iv||tag||cipher) }
//
// Two details that are easy to get wrong:
//
//   * The wire layout is `iv(12) || tag(16) || ciphertext`, while CryptoKit's
//     `SealedBox.combined` is `nonce || ciphertext || tag`. The pieces are
//     assembled by hand rather than using `combined`.
//   * `X-Nonce` must strictly increase per session or the server rejects the
//     request as a replay.

/// Errors surfaced to the caller with enough detail to diagnose a failure.
enum CryptoSessionError: LocalizedError {
    case handshakeFailed(String)
    case invalidPublicKey
    case keyEncryptionFailed
    case noSession
    case encryptFailed(String)
    case decryptFailed(String)
    case notAnEnvelope

    var errorDescription: String? {
        switch self {
        case .handshakeFailed(let s): return "握手失败：\(s)"
        case .invalidPublicKey: return "服务端公钥无效"
        case .keyEncryptionFailed: return "会话密钥加密失败"
        case .noSession: return "加密会话未建立"
        case .encryptFailed(let s): return "请求加密失败：\(s)"
        case .decryptFailed(let s): return "响应解密失败：\(s)"
        case .notAnEnvelope: return "响应不是加密信封"
        }
    }
}

actor CryptoSession {

    static let shared = CryptoSession()

    private let baseURL: URL
    private var sessionId: String?
    private var aesKey: SymmetricKey?
    private var nonceCounter: UInt64 = 0
    private var expiresAt: Date?

    /// Rolling offset between the server's clock and this device's, in seconds.
    ///
    /// Validity windows are judged against server time, so a device with a
    /// wrong clock would otherwise be locked out for no real reason.
    private(set) var serverTimeOffset: TimeInterval = 0

    init(baseURL: URL = URL(string: "https://ios.ouovo.cc")!) {
        self.baseURL = baseURL
    }

    // MARK: Session state

    var isEstablished: Bool {
        guard sessionId != nil, aesKey != nil else { return false }
        if let exp = expiresAt, exp <= Date() { return false }
        return true
    }

    /// Server time, derived from the last response rather than the device clock.
    var serverNow: Date { Date().addingTimeInterval(serverTimeOffset) }

    // MARK: Handshake

    /// Establishes a session if one is not already live.
    func ensureSession() async throws {
        if isEstablished { return }

        // Step 1: fetch the RSA public key.
        let handshakeURL = baseURL.appendingPathComponent("api/crypto/handshake")
        let (hsData, _) = try await URLSession.shared.data(from: handshakeURL)
        let hs = try JSONDecoder().decode(Envelope.self, from: hsData)
        guard hs.ok == true, let pkB64 = hs.data?["public_key"]?.stringValue else {
            throw CryptoSessionError.handshakeFailed("缺少 public_key")
        }

        // Step 2: wrap a fresh AES key with it.
        // The server emits a raw base64 SubjectPublicKeyInfo block for
        // RSA-2048-OAEP.
        guard let pkData = Data(base64Encoded: pkB64) else {
            throw CryptoSessionError.invalidPublicKey
        }
        let publicKey: SecKey
        do {
            publicKey = try Self.importRSAPublicKey(pkData)
        } catch {
            throw CryptoSessionError.invalidPublicKey
        }

        var aesBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &aesBytes)
        let key = SymmetricKey(data: Data(aesBytes))
        // Do not leave the raw key sitting in a local buffer.
        for i in aesBytes.indices { aesBytes[i] = 0 }

        let wrapped: Data
        do {
            wrapped = try Self.rsaEncryptOAEPSHA256(key.withUnsafeBytes { Data($0) },
                                                    publicKey: publicKey)
        } catch {
            throw CryptoSessionError.keyEncryptionFailed
        }

        var clientNonce = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, 16, &clientNonce)
        let nonceHex = clientNonce.map { String(format: "%02x", $0) }.joined()

        // Step 3: exchange for a session id.
        let sessionURL = baseURL.appendingPathComponent("api/crypto/session")
        var req = URLRequest(url: sessionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "encrypted_key": wrapped.base64EncodedString(),
            "client_nonce": nonceHex,
        ])

        let (sData, _) = try await URLSession.shared.data(for: req)
        let sr = try JSONDecoder().decode(Envelope.self, from: sData)
        guard sr.ok == true, let sid = sr.data?["session_id"]?.stringValue else {
            throw CryptoSessionError.handshakeFailed(sr.detail ?? "未返回 session_id")
        }

        self.sessionId = sid
        self.aesKey = key
        self.nonceCounter = 0
        let ttl = sr.data?["expires_in"]?.doubleValue ?? 1800
        // Renew a little early so a request never races the expiry.
        self.expiresAt = Date().addingTimeInterval(ttl - 30)

        if let st = sr.data?["server_time"]?.doubleValue {
            syncTime(serverTime: st)
        } else if let ts = sr.timestamp {
            // `timestamp` is already a Double, not a wrapped value.
            syncTime(serverTime: ts)
        }
    }

    /// Drops the session so the next call renegotiates.
    func invalidate() {
        sessionId = nil
        aesKey = nil
        expiresAt = nil
        nonceCounter = 0
    }

    // MARK: Request

    /// Sends an encrypted request and returns the decrypted `data` object.
    ///
    /// Retries once on an expired session, because a 30-minute TTL guarantees
    /// this happens during a normal session and it should not be visible.
    func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        do {
            return try await send(path: path, body: body, allowRetry: true)
        } catch CryptoSessionError.noSession {
            try await ensureSession()
            return try await send(path: path, body: body, allowRetry: false)
        }
    }

    private func send(path: String,
                      body: [String: Any],
                      allowRetry: Bool) async throws -> [String: Any] {
        try await ensureSession()
        guard let sid = sessionId, let key = aesKey else {
            throw CryptoSessionError.noSession
        }

        let plain = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])

        // Server-side `decryptRequest` strips nothing, so it must receive the
        // exact bytes that were signed.
        let plainString = String(data: plain, encoding: .utf8) ?? "{}"
        guard let payload = Self.aesGCMEncrypt(plain, key: key) else {
            throw CryptoSessionError.encryptFailed("AES-GCM 失败")
        }
        let signature = Self.hmacSHA256Hex(plainString, key: key)

        // X-Nonce must strictly increase within a session.
        nonceCounter += 1
        let nonceValue = Int(Date().timeIntervalSince1970 * 1000) + Int(nonceCounter)

        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(sid, forHTTPHeaderField: "X-Session")
        req.setValue(String(nonceValue), forHTTPHeaderField: "X-Nonce")
        req.setValue(signature, forHTTPHeaderField: "X-Sign")
        req.timeoutInterval = 20

        let envelope: [String: Any] = [
            "payload": payload,
            "signature": signature,
            "timestamp": Int(Date().timeIntervalSince1970),
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: envelope)

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse

        // A session that expired mid-flight is recoverable; anything else is not.
        if http?.statusCode == 401, allowRetry {
            if let e = try? JSONDecoder().decode(Envelope.self, from: data),
               e.detail == "session_expired" {
                invalidate()
                throw CryptoSessionError.noSession
            }
        }

        let env = try JSONDecoder().decode(Envelope.self, from: data)

        // `timestamp` is already a Double; it is not a wrapped value.
        if let st = env.timestamp { syncTime(serverTime: st) }

        // Encrypted response: unwrap `payload`.
        if let payloadB64 = env.payload, let raw = Data(base64Encoded: payloadB64) {
            guard let decrypted = Self.aesGCMDecrypt(raw, key: key) else {
                throw CryptoSessionError.decryptFailed("AES-GCM 校验失败")
            }
            let inner = try JSONSerialization.jsonObject(with: decrypted) as? [String: Any]
            let dataObj = inner?["data"] as? [String: Any] ?? [:]
            if inner?["ok"] as? Bool == false {
                throw LicenseError.server(inner?["detail"] as? String ?? "请求被拒绝")
            }
            return dataObj
        }

        // Plain response: the server answers handshake and errors unpacked.
        if env.ok == false {
            throw LicenseError.server(env.detail ?? "请求被拒绝")
        }
        // `data` is the type-erased wrapper; convert back for the callers, which
        // expect plain Foundation containers.
        return env.data?.toDictionary() ?? [:]
    }

    // MARK: Crypto primitives

    private func syncTime(serverTime: Double) {
        guard serverTime > 0 else { return }
        let delta = serverTime - Date().timeIntervalSince1970
        // Ignore absurd values: they indicate a clock so far off that the
        // window check would fail anyway.
        if abs(delta) < 86_400 * 365 { serverTimeOffset = delta }
    }

    /// Imports a base64 SubjectPublicKeyInfo blob as an RSA public key.
    ///
    /// OpenSSL hands out SPKI (`SEQUENCE { AlgorithmIdentifier, BIT STRING }`),
    /// but `SecKeyCreateWithData` expects a bare PKCS#1 `RSAPublicKey` for the
    /// RSA key type. Feeding it SPKI directly fails — so the outer wrapper is
    /// stripped first, yielding the inner `SEQUENCE { n, e }`.
    static func importRSAPublicKey(_ der: Data) throws -> SecKey {
        let pkcs1 = stripSPKI(der) ?? der

        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        var error: Unmanaged<CFError>?
        if let key = SecKeyCreateWithData(pkcs1 as CFData,
                                          attrs as CFDictionary,
                                          &error) {
            return key
        }

        // Some systems accept SPKI directly; try it before giving up.
        if pkcs1 != der, let key = SecKeyCreateWithData(der as CFData,
                                                        attrs as CFDictionary,
                                                        &error) {
            return key
        }
        throw CryptoSessionError.invalidPublicKey
    }

    /// Returns the PKCS#1 body of an SPKI blob, or nil when it is not SPKI.
    ///
    /// Layout being unwrapped (294 bytes for RSA-2048):
    ///   SEQUENCE {                                30 82 01 22
    ///     SEQUENCE { OID rsaEncryption, NULL }     30 0D ...
    ///     BIT STRING {                             03 82 01 0F
    ///       00                                     unused-bits byte
    ///       SEQUENCE { INTEGER n, INTEGER e }      30 82 01 0A ...
    ///     }
    ///   }
    static func stripSPKI(_ der: Data) -> Data? {
        // Outer SEQUENCE tag + length.
        guard der.count > 8, der[der.startIndex] == 0x30 else { return nil }
        var i = der.index(der.startIndex, offsetBy: 1)
        guard readLength(der, &i) != nil else { return nil }

        // AlgorithmIdentifier: skip tag + length + body as one unit.
        guard i < der.endIndex, der[i] == 0x30 else { return nil }
        let algStart = i
        i = der.index(after: i)
        guard let algLen = readLength(der, &i) else { return nil }
        let headerLen = der.distance(from: algStart, to: i)
        // Guard against a length that would run past the buffer.
        guard der.distance(from: algStart, to: der.endIndex) >= headerLen + algLen else {
            return nil
        }
        i = der.index(algStart, offsetBy: headerLen + algLen)

        // BIT STRING: one unused-bits byte, then the PKCS#1 SEQUENCE.
        guard i < der.endIndex, der[i] == 0x03 else { return nil }
        i = der.index(after: i)
        guard let bitLen = readLength(der, &i), bitLen > 1 else { return nil }
        guard i < der.endIndex, der[i] == 0x00 else { return nil }
        i = der.index(after: i)

        let bodyLen = bitLen - 1
        guard der.distance(from: i, to: der.endIndex) >= bodyLen else { return nil }
        let end = der.index(i, offsetBy: bodyLen)
        let body = der.subdata(in: i..<end)

        // Sanity: a PKCS#1 RSAPublicKey is itself a SEQUENCE.
        guard body.first == 0x30 else { return nil }
        return body
    }

    /// Reads a DER length at `i`, advancing past it.
    private static func readLength(_ data: Data, _ i: inout Data.Index) -> Int? {
        guard i < data.endIndex else { return nil }
        let first = data[i]
        i = data.index(after: i)
        if first & 0x80 == 0 { return Int(first) }

        let count = Int(first & 0x7F)
        guard count > 0, count <= 4 else { return nil }
        var value = 0
        for _ in 0..<count {
            guard i < data.endIndex else { return nil }
            value = (value << 8) | Int(data[i])
            i = data.index(after: i)
        }
        return value
    }

    /// RSA-OAEP with SHA-256, matching the server's preferred branch.
    static func rsaEncryptOAEPSHA256(_ plain: Data, publicKey: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        let algo = SecKeyAlgorithm.rsaEncryptionOAEPSHA256
        guard let out = SecKeyCreateEncryptedData(publicKey, algo, plain as CFData, &error) else {
            throw CryptoSessionError.keyEncryptionFailed
        }
        return out as Data
    }

    /// AES-256-GCM, laid out as the server expects: `iv(12) || tag(16) || ct`.
    static func aesGCMEncrypt(_ plain: Data, key: SymmetricKey) -> String? {
        guard let sealed = try? AES.GCM.seal(plain, using: key) else { return nil }
        let iv = sealed.nonce.withUnsafeBytes { Data($0) }
        var out = Data()
        out.append(iv)
        out.append(sealed.tag)
        out.append(sealed.ciphertext)
        return out.base64EncodedString()
    }

    /// Reverses `aesGCMEncrypt`, rebuilding CryptoKit's expected layout.
    static func aesGCMDecrypt(_ raw: Data, key: SymmetricKey) -> Data? {
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

    static func hmacSHA256Hex(_ text: String, key: SymmetricKey) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(text.utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Wire envelope

/// The server's response shape, both encrypted and plain.
struct Envelope: Decodable {
    let ok: Bool?
    let detail: String?
    let timestamp: Double?
    /// Present when the response is encrypted.
    let payload: String?
    /// Present when the response is plain.
    let data: AnyCodableDict?

    private enum CodingKeys: String, CodingKey {
        case ok, detail, timestamp, payload, data
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ok = try? c.decodeIfPresent(Bool.self, forKey: .ok)
        detail = try? c.decodeIfPresent(String.self, forKey: .detail)
        timestamp = try? c.decodeIfPresent(Double.self, forKey: .timestamp)
        payload = try? c.decodeIfPresent(String.self, forKey: .payload)
        data = try? c.decodeIfPresent(AnyCodableDict.self, forKey: .data)
    }
}

/// Minimal type-erased dictionary so mixed server payloads decode without a
/// bespoke model for every endpoint.
struct AnyCodableDict: Decodable {
    private let storage: [String: AnyCodableValue]

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        storage = (try? c.decode([String: AnyCodableValue].self)) ?? [:]
    }

    subscript(key: String) -> AnyCodableValue? { storage[key] }
    var keys: [String] { Array(storage.keys) }

    /// Converts back to plain Foundation containers.
    ///
    /// The callers of `CryptoSession.post` expect `[String: Any]` so they can
    /// pull fields out by name; this bridges the two representations in one
    /// place rather than making every caller do it.
    func toDictionary() -> [String: Any] {
        var out: [String: Any] = [:]
        for (k, v) in storage { out[k] = v.rawValue }
        return out
    }
}

enum AnyCodableValue: Decodable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object(AnyCodableDict)
    case array([AnyCodableValue])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode(AnyCodableDict.self) { self = .object(v); return }
        if let v = try? c.decode([AnyCodableValue].self) { self = .array(v); return }
        self = .null
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "1" : "0"
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .double(let d): return d
        case .int(let i): return Double(i)
        case .string(let s): return Double(s)
        default: return nil
        }
    }

    var intValue: Int? {
        switch self {
        case .int(let i): return i
        case .double(let d): return Int(d)
        case .string(let s): return Int(s)
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .int(let i): return i != 0
        case .string(let s): return s == "1" || s.lowercased() == "true"
        default: return nil
        }
    }

    var objectValue: AnyCodableDict? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [AnyCodableValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Unwraps into a plain Foundation value.
    var rawValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .object(let o): return o.toDictionary()
        case .array(let a): return a.map(\.rawValue)
        case .null: return NSNull()
        }
    }
}

/// Errors from the license layer, with the server's own reason preserved.
enum LicenseError: LocalizedError {
    case server(String)
    case notActivated
    case banned(String)
    case expired
    case killed(String)
    case maintenance(String)

    var errorDescription: String? {
        switch self {
        case .server(let s): return s
        case .notActivated: return "设备未激活，请输入卡密"
        case .banned(let s): return "账号已被封禁：\(s)"
        case .expired: return "授权已过期"
        case .killed(let s): return "授权已终止：\(s)"
        case .maintenance(let s): return s
        }
    }
}
