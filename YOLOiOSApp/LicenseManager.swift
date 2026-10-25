import Foundation
import CryptoKit
import UIKit
import Darwin

// MARK: - License state

enum LicenseState: Equatable {
    case idle
    case checking
    /// Server wants a display name before the card is consumed.
    /// The card key is stored so the caller can retry with the same input.
    case needsNickname(prompt: String, cardMask: String, levelName: String)
    case notActivated
    case active
    case expired
    case banned(String)
    case killed(String)
    case maintenance(String)
    case networkError(String)

    var canUseApp: Bool {
        switch self {
        case .active, .maintenance: return true
        // No offline grace. A failed heartbeat used to map here and this used to
        // return true, which meant a device that lost connectivity kept working
        // forever without ever contacting the server again. The requirement is
        // explicit: no grace period at all — no server, no app.
        //
        // `.networkError` stays a distinct state so the UI can say "cannot reach
        // the licence server" instead of "not activated"; the heartbeat keeps
        // retrying, so a restored connection unblocks within one interval.
        default: return false
        }
    }

    var isUsable: Bool {
        if case .active = self { return true }
        return false
    }
}

// MARK: - Feature gate
//
// Every feature entry point asks here. Results are never cached as a Bool at
// launch: the server can change a level at any time, and a stale cached value
// is exactly how a revoked user keeps working.

struct FeatureGate {
    let feature: String
    let label: String
    let minLevel: Int
    let needsBeta: Bool
    let unlocked: Bool
}

// MARK: - Manager

@MainActor
final class LicenseManager: ObservableObject {

    static let shared = LicenseManager()

    @Published private(set) var state: LicenseState = .idle
    @Published private(set) var verifying = false
    @Published private(set) var lastError: String?

    /// Profile of the signed-in device.
    @Published private(set) var nickname = ""
    @Published private(set) var level = 0
    @Published private(set) var levelName = "Free"
    @Published private(set) var expiresAt: String?

    /// Feature valves, refreshed with every heartbeat.
    @Published private(set) var gates: [FeatureGate] = []

    /// Announcements for each surface.
    @Published private(set) var loginAnnouncements: [Announcement] = []
    @Published private(set) var mainAnnouncements: [Announcement] = []

    /// Server-side release lines. The App bundle and the auth component ship
    /// independently, so one can be current while the other is behind, and both
    /// notices can be live at the same time.
    @Published private(set) var ipaNotice: VersionNotice?
    @Published private(set) var dylibNotice: VersionNotice?

    /// Updates that must be installed before anything else runs.
    var blockingNotices: [VersionNotice] {
        [ipaNotice, dylibNotice].compactMap { $0 }.filter(\.forced)
    }

    /// Updates the user may take later; the app stays usable meanwhile.
    var advisoryNotices: [VersionNotice] {
        [ipaNotice, dylibNotice].compactMap { $0 }.filter { !$0.forced }
    }

    /// Whether the App should look for the driver at all, and how strictly.
    ///
    /// Server-owned on purpose: the requirement is "the server turns the check
    /// on, then the client checks". A client-side default would let a stale
    /// build keep nagging about a driver an operator deliberately stopped
    /// requiring, so nil (never heard from the server) means "do not check".
    @Published private(set) var dylibCheck: DylibCheckConfig?

    private let crypto = CryptoSession.shared
    private var heartbeatTask: Task<Void, Never>?
    /// Whether the card has been handed to the component this session.
    private var didPublishCard = false

    /// The `feature` block from the most recent heartbeat, kept for diagnostics.
    ///
    /// Only the shape is retained — never the table itself, and never written
    /// to disk. `featureUnavailable` carries the server's own reason when it
    /// deliberately sends no parameters, so the panel can say "server has not
    /// configured it" instead of blaming the network.
    @Published private(set) var featureIssuedAt: Date?
    @Published private(set) var featureUnavailable: String?

    private enum Key {
        static let nickname = "lic.nickname"
        static let level = "lic.level"
        static let levelName = "lic.levelName"
        static let expiresAt = "lic.expiresAt"
        static let hasGrant = "lic.hasGrant"
        static let lastCard = "lic.lastCard"
    }

    private init() {
        let d = UserDefaults.standard
        nickname = d.string(forKey: Key.nickname) ?? ""
        level = d.integer(forKey: Key.level)
        levelName = d.string(forKey: Key.levelName) ?? "Free"
        expiresAt = d.string(forKey: Key.expiresAt)
    }

    var deviceId: String { LicenseDevice.fingerprint }

    // MARK: Feature gate query

    /// Returns whether a feature may be used right now.
    ///
    /// Called at each entry point rather than once at launch, so a server-side
    /// change takes effect on the next tap instead of the next cold start.
    func canUse(_ feature: String) -> Bool {
        guard case .active = state else { return false }
        guard let g = gates.first(where: { $0.feature == feature }) else {
            // Unknown feature: deny rather than allow, so a feature added on the
            // client without a matching server row cannot be used for free.
            return false
        }
        return g.unlocked
    }

    /// Explains why a feature is unavailable, for the UI to show.
    func gateReason(_ feature: String) -> String {
        guard case .active = state else {
            switch state {
            case .expired: return "授权已过期，请续期后使用"
            case .banned(let r): return "账号已被封禁：\(r)"
            case .killed(let r): return "此版本已停用：\(r)"
            case .maintenance(let m): return m
            default: return "请先完成卡密激活"
            }
        }
        guard let g = gates.first(where: { $0.feature == feature }) else {
            return "该功能当前不可用"
        }
        if !g.unlocked {
            let need = LicenseManager.levelDisplayName(g.minLevel)
            return "「\(g.label)」需要 \(need) 及以上权限"
        }
        return ""
    }

    /// Display name for a level.
    ///
    /// `nonisolated` because it is a pure lookup with no state: the feature-gate
    /// view builds its decision in a nonisolated context and cannot await a
    /// main-actor method there.
    nonisolated static func levelDisplayName(_ level: Int) -> String {
        switch level {
        case 4: return "MAX"
        case 3: return "Pro"
        case 2: return "VIP"
        case 1: return "Beta"
        default: return "Free"
        }
    }

    // MARK: Activation

    /// Activates a card. When the server asks for a nickname it returns
    /// `needsNickname` and the card is NOT consumed, so the caller can retry
    /// with the same code plus a name.
    func activate(cardCode: String, nickname: String? = nil) async {
        let code = cardCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !code.isEmpty else {
            lastError = "请输入卡密"
            return
        }

        verifying = true
        lastError = nil
        defer { verifying = false }

        var body: [String: Any] = [
            "card_code": code,
            "device_id": deviceId,
            "device_model": LicenseDevice.modelName,
            "system_version": LicenseDevice.systemVersion,
            "app_version": LicenseDevice.appVersion,
            "dylib_version": AuthCoreBridge.dylibVersion,
            "launch_mode": LaunchModeStore.shared.active?.rawValue ?? "unknown",
        ]
        if let n = nickname, !n.isEmpty { body["nickname"] = n }

        do {
            let data = try await crypto.post("/api/lic/activate", body: body)

            // Step 1: server wants a name.
            if (data["needs_nickname"] as? Bool) == true {
                let card = data["card"] as? [String: Any] ?? [:]
                UserDefaults.standard.set(code, forKey: Key.lastCard)
                state = .needsNickname(
                    prompt: (data["prompt"] as? String) ?? "初次见面，请告诉我们怎么称呼您",
                    cardMask: (card["mask"] as? String) ?? "",
                    levelName: (card["name"] as? String) ?? "")
                return
            }

            try applyActivation(data)

            // Persist the card on the success path too, not only when the
            // server asked for a nickname first. The driver runs its own check
            // against its own endpoint and reads the card from here
            // (`AuthCoreSyncLicense`), so a reinstall that re-activates without
            // a nickname prompt would otherwise leave the driver permanently
            // "unverified" — a false "not ready" for a perfectly good card.
            UserDefaults.standard.set(code, forKey: Key.lastCard)
        } catch {
            lastError = friendlyMessage(error)
        }
    }

    private func applyActivation(_ data: [String: Any]) throws {
        guard let user = data["user"] as? [String: Any] else {
            throw LicenseError.server("响应缺少 user")
        }
        nickname = (user["nickname"] as? String) ?? ""
        level = (user["level"] as? Int) ?? 0
        levelName = (user["level_name"] as? String) ?? "Free"
        expiresAt = user["expires_at"] as? String

        let d = UserDefaults.standard
        d.set(nickname, forKey: Key.nickname)
        d.set(level, forKey: Key.level)
        d.set(levelName, forKey: Key.levelName)
        d.set(expiresAt, forKey: Key.expiresAt)
        d.set(true, forKey: Key.hasGrant)

        if let raw = data["features"] as? [[String: Any]] {
            gates = raw.compactMap(parseGate)
        }

        state = .active
    }

    private func parseGate(_ f: [String: Any]) -> FeatureGate? {
        guard let name = f["feature"] as? String else { return nil }
        return FeatureGate(feature: name,
                           label: (f["label"] as? String) ?? name,
                           minLevel: (f["min_level"] as? Int) ?? 0,
                           needsBeta: ((f["extra"] as? Int) ?? 0) == 1,
                           unlocked: (f["unlocked"] as? Bool) ?? false)
    }

    // MARK: Lifecycle

    /// Entry point from the app's launch path.
    func bootstrap() async {
        state = .checking
        await refresh()

        // No offline fallback.
        //
        // This used to promote a cached grant to `.active` whenever the first
        // heartbeat failed, so a licensed device could start with no network at
        // all and keep running indefinitely. That is the grace period, and it is
        // not allowed: without a server answer the app stays blocked.
        //
        // The cached grant is still written (it drives the device fingerprint and
        // survives reinstall) — it is simply no longer a substitute for a live
        // check.

        await loadAnnouncements(place: "login")
        startHeartbeat()
    }

    func refresh() async {
        do {
            // Both version strings must ride along: the server answers with the
            // update lines it wants this exact build/component pair to see.
            let data = try await crypto.post("/api/lic/heartbeat",
                                             body: ["device_id": deviceId,
                                                    "app_version": LicenseDevice.appVersion,
                                                    "dylib_version": AuthCoreBridge.dylibVersion,
                                                    "launch_mode": LaunchModeStore.shared.active?.rawValue ?? "unknown"])
            // Read once, here, and pass it down. `CryptoSession` is an actor, so
            // this is the only place the offset is reachable without threading
            // `await` through every synchronous parse below.
            let skew = await crypto.serverTimeOffset
            applyHeartbeat(data, serverSkew: skew)
            lastError = nil
        } catch {
            state = .networkError(error.localizedDescription)
            // No heartbeat means no refreshed table. Dropping it here is what
            // makes a lost connection stop aiming immediately rather than at the
            // end of the 60-second window the last table was issued for.
            withdrawAimParams(reason: "网络中断，无法刷新瞄准参数")
        }
    }

    private func applyHeartbeat(_ data: [String: Any], serverSkew: TimeInterval) {
        let status = (data["status"] as? String) ?? "unknown"

        // Driver policy comes before the status switch: it is not licence
        // status, it is an instruction about what to probe, and every branch of
        // the server replies with it. A reply without the field means an older
        // server that has no opinion — read as "do not check", never as
        // "missing driver", so an old server cannot manufacture a fault.
        let check = DylibCheckConfig(json: data["dylib_check"]) ?? DylibCheckConfig.off
        dylibCheck = check
        DeviceCapability.setDriverPolicy(check.policy)

        // Announcements ride along with every heartbeat.
        if let list = data["announcements"] as? [[String: Any]] {
            let parsed = list.compactMap(Announcement.init(json:))
            // Split by surface so the login screen and the panel do not have to
            // filter a shared list.
            loginAnnouncements = parsed
            mainAnnouncements = parsed
        }


        switch status {
        case "killed":
            // Kill switch. No screen, no message, no second chance: the process
            // ends right here. `maintenance` below is a soft lock that keeps the
            // app usable and must stay in the UI.
            killProcess()
        case "guest":
            state = .notActivated
            withdrawAimParams(reason: "设备未激活")
            return
        case "banned":
            state = .banned((data["ban_reason"] as? String) ?? "")
            withdrawAimParams(reason: "账号已被封禁")
            return
        case "expired":
            state = .expired
            withdrawAimParams(reason: "授权已过期")
            return
        case "maintenance":
            let m = data["maintenance"] as? [String: Any] ?? [:]
            state = .maintenance((m["message"] as? String) ?? "服务器维护中")
            // Maintenance mode means "features off", and the parameters *are*
            // the feature. The server already sends no block in this state;
            // dropping whatever we hold makes it unambiguous.
            withdrawAimParams(reason: "服务器维护中")
        default:
            break
        }

        if let user = data["user"] as? [String: Any] {
            nickname = (user["nickname"] as? String) ?? nickname
            level = (user["level"] as? Int) ?? level
            levelName = (user["level_name"] as? String) ?? levelName
            expiresAt = user["expires_at"] as? String
            let d = UserDefaults.standard
            d.set(nickname, forKey: Key.nickname)
            d.set(level, forKey: Key.level)
            d.set(levelName, forKey: Key.levelName)
            d.set(expiresAt, forKey: Key.expiresAt)
        }

        if let raw = data["features"] as? [[String: Any]] {
            gates = raw.compactMap(parseGate)
        }

        if status == "active" {
            state = .active
        }

        // Version policy: the App bundle and the auth component are compared
        // against their own running version, never against each other.
        ipaNotice = notice(from: data["ipa"],
                           product: "ipa",
                           current: AppBrand.shortVersion)

        // The dylib only gets a notice when it actually loaded.
        //
        // AuthCoreBridge.dylibVersion reports "0.0.0" when the library is absent,
        // which is lower than any real release — so an unloaded dylib would
        // surface as "a new dylib is available" and send the user to fetch a file
        // that was never the problem. A missing dylib is a broken install, and the
        // integrity check already covers that case.
        dylibNotice = AuthCoreBridge.isAvailable
            ? notice(from: data["dylib"],
                     product: "dylib",
                     current: AuthCoreBridge.dylibVersion)
            : nil

        // The aim table. Every branch above that withdraws the licence has
        // already returned, so anything reaching here is allowed to ask — but
        // the server is still the one deciding, and it may hand over nothing.
        applyFeatureBlock(data, serverSkew: serverSkew)

        // The component caches its own verdict for 300 s. Without a nudge the
        // driver would flip to "licence invalid" five minutes after launch and
        // stay there — a fault reported for a driver that is perfectly healthy.
        // Re-running its check keeps the verdict as fresh as the heartbeat.
        refreshComponentLicense()

        // Hand the card over the first time a heartbeat lands. Doing it here
        // rather than from the dylib's constructor keeps Keychain, NSUserDefaults
        // and the network off the launch path entirely.
        publishCardToComponentOnce()
    }

    // MARK: - Server-issued aim parameters
    //
    // The heartbeat's `feature` block is the only source of the aim table:
    //
    //   { token, expires_in, expires_at, scope,
    //     params_blob, params_version, params_alg, kdf }
    //
    // Two locks, opened in `AimParams.decrypt`:
    //   1. `token` is AES-256-GCM under the compiled `feature.secret` constant;
    //      its plaintext JSON names the device and carries `exp`. A token bound
    //      to another device, or past `exp`, authorises nothing.
    //   2. `params_blob` is AES-256-GCM under a key derived from the *raw token
    //      bytes* (HKDF-SHA256, salt = the version as a string, info = "params"),
    //      so possessing the blob without a live token is useless — and the
    //      token is replaced on every heartbeat.
    //
    // Three rules, all of them from the round-7 brief:
    //   1. Any failure means no table (`applyRemoteParams(nil)`), never a
    //      fallback table.
    //   2. The deadline is absolute and has no grace.
    //   3. The table is never persisted. It lives in `AimController` for at most
    //      one window and dies with the process.

    /// Decrypts and installs the aim table, or withdraws the current one.
    private func applyFeatureBlock(_ data: [String: Any], serverSkew: TimeInterval) {
        // Absent block: older server, or a branch that deliberately withholds it.
        guard let feature = data["feature"] as? [String: Any] else {
            let reason = (data["feature_unavailable"] as? String) ?? ""
            withdrawAimParams(reason: reason == "feature_secret_missing"
                              ? "服务端未配置参数密钥，暂不下发瞄准参数"
                              : "服务端未下发瞄准参数")
            return
        }

        guard let blob = feature["params_blob"] as? String, !blob.isEmpty,
              let token = feature["token"] as? String, !token.isEmpty else {
            withdrawAimParams(reason: "服务端参数缺少 token 或 blob")
            return
        }

        let version = (feature["params_version"] as? Int)
            ?? (feature["params_version"] as? NSNumber)?.intValue
            ?? 0
        guard version > 0 else {
            withdrawAimParams(reason: "服务端未提供参数版本")
            return
        }

        // Scope. The server sends ["overlay", "aim"]; a block that does not name
        // "aim" is not a table we are allowed to steer with.
        if let scope = feature["scope"] as? [String], !scope.isEmpty,
           !scope.contains("aim") {
            withdrawAimParams(reason: "服务端未授权 aim 范围")
            return
        }

        // The deadline rides on the server's clock. Convert it once, here, using
        // the offset the transport layer already measured. Inside `AimParams`
        // the token's own `exp` is the authority and this stamp can only
        // shorten the window, never extend it. `expires_in` is the fallback for
        // a server that stops sending an absolute stamp.
        let deadline = featureDeadline(feature, serverSkew: serverSkew)

        guard let params = AimParams.decrypt(feature: feature,
                                             token: token,
                                             version: version,
                                             deviceId: deviceId,
                                             serverSkew: serverSkew,
                                             expiresAt: deadline) else {
            // Decryption failure is not an error state to escalate: it means no
            // table, and aiming stays off until the next heartbeat. The token
            // may have failed to open, been bound to another device, or already
            // be past `exp` — from the outside all of them are "no parameters".
            withdrawAimParams(reason: "瞄准参数解密失败，等待下一次下发")
            return
        }

        // `decrypt` already enforced the token's `exp`, and the deadline it
        // returned is the merged (earlier) stamp, so a table that got through
        // is live by construction. The belt-and-braces check costs nothing.
        guard params.isValid else {
            withdrawAimParams(reason: "瞄准参数已过期，等待下一次下发")
            return
        }

        featureIssuedAt = Date()
        featureUnavailable = nil
        AimController.shared.applyRemoteParams(params)
    }

    /// Absolute deadline in local time, or nil when the reply carries no usable
    /// time at all.
    private func featureDeadline(_ feature: [String: Any],
                                 serverSkew: TimeInterval) -> Date? {
        let offset = serverSkew

        if let raw = feature["expires_at"] as? NSNumber, raw.doubleValue > 0 {
            return Date(timeIntervalSince1970: raw.doubleValue + offset)
        }
        if let raw = feature["expires_at"] as? String, let v = Double(raw), v > 0 {
            return Date(timeIntervalSince1970: v + offset)
        }
        if let raw = feature["expires_in"] as? NSNumber, raw.doubleValue > 0 {
            return Date().addingTimeInterval(raw.doubleValue)
        }
        return nil
    }

    /// Drops the table and stops the loop.
    ///
    /// Deliberately does not touch `AimController.settings.isEnabled`: the switch
    /// is the user's intent, and flipping it off every 60 seconds would make a
    /// rolling window look like a broken feature. The loop is already halted by
    /// the nil parameters.
    private func withdrawAimParams(reason: String) {
        featureUnavailable = reason
        featureIssuedAt = nil
        AimController.shared.applyRemoteParams(nil)
    }

    /// Asks the driver to re-verify the card with its own endpoint.
    ///
    /// Runs off the main thread: the call blocks on the network for up to ~5 s
    /// and the heartbeat must never stall the UI. GCD rather than a Task because
    /// the callee is a synchronous, blocking C function — there is nothing to
    /// await, and `qos: .utility` keeps it behind the user's own work.
    ///
    /// Skipped entirely when the server has driver checking off, or when it only
    /// asks for the heartbeat.
    private func refreshComponentLicense() {
        guard let check = dylibCheck, check.enabled, check.strict else { return }
        guard AuthCoreBridge.isAvailable else { return }
        DispatchQueue.global(qos: .utility).async {
            AuthCoreBridge.syncLicense()
        }
    }

    /// Publishes the card to the shared stores once, after the first frame.
    ///
    /// This used to be scheduled from the dylib's constructor, two seconds later,
    /// onto a global utility queue. On iOS 27 that crashed with SIGSEGV in
    /// objc_retain inside AuthCoreSubmitCard — a block captured during dyld's
    /// constructor phase, run afterwards on a queue nobody owned, touching
    /// Keychain, NSUserDefaults and the network.
    ///
    /// Called from the heartbeat path instead, which is well past launch and
    /// already off the main thread. Guarded by the server switch so a device with
    /// driver checking off does no work at all.
    private func publishCardToComponentOnce() {
        guard !didPublishCard else { return }
        guard let check = dylibCheck, check.enabled else { return }
        guard AuthCoreBridge.isAvailable else { return }
        didPublishCard = true
        DispatchQueue.global(qos: .utility).async {
            AuthCoreBridge.syncLicense()
        }
    }

    /// Ends the process immediately.
    ///
    /// A server-side kill has to look like the app vanishing, not like a dialog
    /// the user can argue with, so nothing is drawn and nothing is explained.
    private func killProcess() -> Never {
        heartbeatTask?.cancel()
        // SIGKILL rather than a graceful exit: no teardown screen, no half-drawn
        // frame, no window in which the UI could still respond.
        _ = kill(getpid(), SIGKILL)
        // Unreachable on iOS (the signal cannot be caught); it keeps the promise
        // that this call never returns.
        exit(0)
    }

    /// Builds a notice only when the server's `latest` really is newer than what
    /// this build runs.
    ///
    /// A stale `force_update` flag on an equal (or older) version must never lock
    /// out a client that is already current.
    private func notice(from raw: Any?,
                        product: String,
                        current: String) -> VersionNotice? {
        guard let d = raw as? [String: Any],
              let latest = (d["latest"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !latest.isEmpty,
              VersionCompare.isNewer(latest, than: current) else { return nil }

        // The server already split the release notes into lines.
        let lines = ((d["changelog"] as? [String]) ?? [])
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        return VersionNotice(product: product,
                             latest: latest,
                             url: (d["url"] as? String) ?? "",
                             changelog: lines,
                             forced: (d["force_update"] as? Bool) ?? false)
    }

    // MARK: Announcements

    func loadAnnouncements(place: String) async {
        do {
            let data = try await crypto.post("/api/lic/announcements",
                                             body: ["device_id": deviceId, "place": place])
            guard let list = data["announcements"] as? [[String: Any]] else { return }
            let parsed = list.compactMap(Announcement.init(json:))
            if place == "login" { loginAnnouncements = parsed }
            else { mainAnnouncements = parsed }
        } catch {
            // Announcements are cosmetic; failing to load them must not block.
        }
    }

    func ackAnnouncement(_ id: Int) async {
        _ = try? await crypto.post("/api/lic/ack",
                                   body: ["device_id": deviceId, "id": id])
        loginAnnouncements.removeAll { $0.id == id }
        mainAnnouncements.removeAll { $0.id == id }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refresh()
                // Foreground beats once a minute, without jitter: the user asked
                // for a fixed cadence, and a version change has to reach the
                // client quickly. Background stays slow on purpose.
                let background = UIApplication.shared.applicationState != .active
                let interval: Double = background ? 300 : 60
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    func clearError() { lastError = nil }

    /// Returns to the card entry stage without consuming anything.
    /// Used by the "re-enter card" action on the nickname screen.
    func reloadState() async {
        UserDefaults.standard.removeObject(forKey: Key.lastCard)
        state = .notActivated
        lastError = nil
        withdrawAimParams(reason: "尚未收到服务端瞄准参数")
    }

    /// Lock the app and go back to the card key screen.
    ///
    /// Deliberately local only: the device stays bound to its card on the
    /// server, so signing back in re-uses the same activation instead of
    /// consuming a second card.
    func signOut() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let d = UserDefaults.standard
        d.set(false, forKey: Key.hasGrant)
        d.removeObject(forKey: Key.lastCard)
        nickname = ""
        gates = []
        mainAnnouncements = []
        state = .notActivated
        lastError = nil
        // Signing out must not leave a table behind that keeps steering for the
        // rest of its window.
        withdrawAimParams(reason: "尚未收到服务端瞄准参数")
        AimController.shared.stop()
    }

    // MARK: Helpers

    private func friendlyMessage(_ error: Error) -> String {
        guard case LicenseError.server(let detail) = error else {
            return error.localizedDescription
        }
        switch true {
        case detail == "invalid_card":        return "卡密不存在，请检查是否输错"
        case detail == "card_used_by_other":  return "该卡密已被其它设备使用"
        case detail == "card_revoked":        return "该卡密已被撤销"
        case detail.hasPrefix("card_banned"): return "该卡密已被封禁"
        case detail.hasPrefix("device_banned"): return "此设备已被封禁"
        case detail == "card_expired":        return "该卡密已过期"
        case detail == "license_expired":     return "授权已过期，请使用新卡密续期"
        case detail == "device_required":     return "设备识别失败，请重试"
        case detail == "nickname_empty":      return "请输入称呼"
        default: return detail
        }
    }
}

// MARK: - Version comparison

enum VersionCompare {
    /// Segment-by-segment numeric compare.
    ///
    /// A plain string compare ranks the segments alphabetically, so it reports
    /// "2.10.0" as older than "2.9.0" and silently hides a real update.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = segments(candidate)
        let b = segments(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// "2.6.0" -> [2, 6, 0]. A pre-release suffix is dropped and a non-numeric
    /// segment counts as 0 instead of failing the whole comparison.
    static func segments(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { part in
            Int(part.prefix(while: { $0.isNumber })) ?? 0
        }
    }
}

// MARK: - Update notice

/// One release line as the server describes it: the App bundle or the auth
/// component. `changelog` arrives already split into lines, and is shown to the
/// user verbatim.
struct VersionNotice: Identifiable, Equatable {
    let product: String
    let latest: String
    let url: String
    let changelog: [String]
    let forced: Bool

    var id: String { product }

    var isDylib: Bool { product == "dylib" }

    /// The one place a card key is traded for a one-time download link.
    static let site = "https://ios.ouovo.cc"
    static let siteLabel = "ios.ouovo.cc"

    /// The server's own URL wins when it sends one; otherwise the site.
    ///
    /// A dylib notice deep-links to `?p=dylib` so the site opens with the
    /// component tab already selected. Without it the page defaults to the IPA,
    /// and someone following a dylib prompt would download the wrong artefact.
    var destination: URL? {
        let raw = url.trimmingCharacters(in: .whitespaces)
        if !raw.isEmpty, let u = URL(string: raw) { return u }

        guard isDylib else { return URL(string: Self.site) }
        return URL(string: Self.site + "/?p=dylib")
    }

    var title: String {
        if isDylib {
            return forced ? "驱动需要更新" : "驱动有新版本"
        }
        return forced ? "请更新到新版本" : "有新版本可用"
    }

    var headline: String {
        if isDylib {
            return forced
                ? "当前驱动已停止服务，需要更新到 \(latest) 才能继续使用。"
                : "已发布新驱动 \(latest)。现在可以不更新，稍后再换也行。"
        }
        return forced
            ? "当前版本已停止服务，需要更新到 \(latest) 才能继续使用。"
            : "已发布新版本 \(latest)。现在可以不更新，稍后再升级也行。"
    }

    /// Deliberately two steps, because the download link is not public: it is
    /// issued by the site against a valid card key.
    var steps: [String] {
        if isDylib {
            return ["打开官网 \(Self.siteLabel)，输入你的有效卡密，换取一次性下载链接。",
                    "用链接下载新的 dylib 文件，自行注入到最新版 IPA 包内即可。"]
        }
        return ["打开官网 \(Self.siteLabel)，输入你的有效卡密，换取一次性下载链接。",
                "用链接下载最新版 IPA 安装包，安装后即可使用。"]
    }
}

// MARK: - Driver check config

/// `dylib_check` from the heartbeat: whether to look for the driver, how
/// strictly, which version it has to reach and what counts as fresh.
struct DylibCheckConfig: Equatable {
    let enabled: Bool
    let strict: Bool
    let componentLatest: String
    let heartbeatWindowSec: Double

    /// What an App that has not heard from the server uses: check nothing.
    ///
    /// This is the one default that cannot be "stricter": inventing a required
    /// version or a yes/no answer for a policy the server never sent would show
    /// a permanent "driver not ready" to someone using a build that predates
    /// the switch.
    static let off = DylibCheckConfig(enabled: false,
                                      strict: false,
                                      componentLatest: "",
                                      heartbeatWindowSec: DriverPolicy.defaultWindowSec)

    /// The value `DeviceCapability` holds so the rest of the app can read it
    /// synchronously.
    var policy: DriverPolicy {
        DriverPolicy(enabled: enabled,
                     strict: strict,
                     componentLatest: componentLatest,
                     heartbeatWindowSec: heartbeatWindowSec)
    }
}

extension DylibCheckConfig {

    /// Parses the heartbeat field. nil when the field is absent or not an
    /// object, so the caller can tell "no instruction" from "instruction".
    ///
    /// Declared in an extension so the memberwise initialiser above survives.
    init?(json: Any?) {
        guard let d = json as? [String: Any] else { return nil }
        enabled = DylibCheckConfig.flag(d["enabled"])
        strict = DylibCheckConfig.flag(d["strict"])
        componentLatest = (d["component_latest"] as? String) ?? ""
        let raw = DylibCheckConfig.number(d["heartbeat_window_sec"])
        heartbeatWindowSec = DriverPolicy.clampWindow(raw ?? DriverPolicy.defaultWindowSec)
    }

    /// Accepts the three shapes a JSON boolean arrives in: true, 1 and "1".
    private static func flag(_ v: Any?) -> Bool {
        if let b = v as? Bool { return b }
        if let n = v as? NSNumber { return n.boolValue }
        if let s = v as? String {
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "1", "true", "yes", "on": return true
            default: return false
            }
        }
        return false
    }

    private static func number(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let i = v as? Int { return Double(i) }
        if let n = v as? NSNumber { return n.doubleValue }
        if let s = v as? String { return Double(s) }
        return nil
    }
}

// MARK: - Announcement

struct Announcement: Identifiable, Equatable {
    let id: Int
    let type: String      // modal / banner / toast
    let title: String
    let content: String
    let once: Bool

    init?(json: [String: Any]) {
        guard let id = json["id"] as? Int else { return nil }
        self.id = id
        self.type = (json["type"] as? String) ?? "banner"
        self.title = (json["title"] as? String) ?? ""
        self.content = (json["content"] as? String) ?? ""
        self.once = (json["once"] as? Bool) ?? false
    }

    init(id: Int, type: String, title: String, content: String, once: Bool) {
        self.id = id; self.type = type; self.title = title
        self.content = content; self.once = once
    }
}

// MARK: - AuthCore dylib bridge

enum AuthCoreBridge {
    static var isAvailable: Bool { AuthCoreBridgeAvailable() }

    static var dylibVersion: String {
        guard let p = AuthCoreBridgeVersion() else { return "0.0.0" }
        return String(cString: p)
    }

    static var integritySummary: String {
        guard isAvailable, let p = AuthCoreBridgeIntegrity() else { return "" }
        return String(cString: p)
    }

    static var integrityOK: Bool { AuthCoreBridgeVerify() }

    // ---- The component's own licence verdict --------------------------------
    //
    // The App asks the server once, at activation. The component asks again, on
    // its own endpoint, so a patched App-side verdict does not survive. Every
    // call below goes through the NULL-checking wrappers in AuthCoreBridge.c:
    // a component built before these symbols exist reports false / -1, which is
    // "not verified" — never a pass.

    /// True when the component's last check passed and is still inside its own
    /// cache window.
    static var licenseValid: Bool { AuthCoreBridgeLicenseValid() }

    /// Seconds since the component's last successful check, -1 when it never ran.
    static var licenseAge: Double { AuthCoreBridgeLicenseAge() }

    /// Level the server reported to the component (0..4), -1 when unknown.
    static var licenseLevel: Int { Int(AuthCoreBridgeLicenseLevel()) }

    /// Result code of the component's most recent check.
    static var lastLicenseResult: Int { Int(AuthCoreBridgeLastLicenseResult()) }

    /// Makes the component re-run its check. Blocking, up to ~5 s: never call
    /// it from the main actor.
    static func syncLicense() { AuthCoreBridgeSyncLicense() }
}
