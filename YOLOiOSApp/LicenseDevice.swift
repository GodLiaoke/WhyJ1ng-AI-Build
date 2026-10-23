import Foundation
import CryptoKit
import UIKit
import Security

// MARK: - Device identity
//
// The device is the identity: there is no username or password to remember, so
// this value must survive reinstalls. `identifierForVendor` is wiped when every
// app from the vendor is removed, so it is combined with a random UUID kept in
// the Keychain, which does survive.
//
// Not a security boundary — a jailbroken device can forge it. It exists so the
// server can bind a licence to one machine and notice obvious sharing.

enum LicenseDevice {

    private static let service = "cc.ouovo.yoloperson.license"
    private static let account = "device_uuid"

    /// Stable per-install UUID, persisted in the Keychain.
    static var stableUUID: String {
        if let existing = keychainRead(account) { return existing }
        let fresh = UUID().uuidString
        keychainWrite(account, fresh)
        return fresh
    }

    /// Combined fingerprint reported to the server.
    static var fingerprint: String {
        let idfv = UIDevice.current.identifierForVendor?.uuidString ?? "no-idfv"
        return sha256Hex("\(stableUUID)|\(idfv)")
    }

    // MARK: Device metadata

    static var modelName: String {
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let id = mirror.children.compactMap { $0.value as? Int8 }
            .filter { $0 != 0 }
            .map { String(UnicodeScalar(UInt8($0))) }
            .joined()
        return id.isEmpty ? UIDevice.current.model : id
    }

    static var systemVersion: String { UIDevice.current.systemVersion }

    static var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0"
    }

    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    // MARK: Keychain

    private static func keychainRead(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8)
        else { return nil }
        return text
    }

    @discardableResult
    private static func keychainWrite(_ account: String, _ value: String) -> Bool {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        // Replace rather than insert: a second insert would silently fail.
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
