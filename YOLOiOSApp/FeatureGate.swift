import SwiftUI

// MARK: - Feature gate UI
//
// Every feature entry point funnels through here. The check happens on each
// interaction rather than once at launch, because the server can change a level
// at any time and a value cached at startup is how a revoked user keeps working.
//
// Usage:
//
//   FeatureGateBox("overlay") {
//       Button("开启悬浮窗") { ... }
//   }
//
// When the feature is locked the button is replaced by the reason, so the user
// learns what is missing instead of tapping something inert.

/// What the gate decides for one feature.
struct GateDecision {
    let allowed: Bool
    let reason: String
}

/// Central query point. Kept separate from the view so non-UI code
/// (view models, engines) can consult it too.
@MainActor
enum FeatureGateCheck {

    static func decide(_ feature: String) -> GateDecision {
        let m = LicenseManager.shared
        return GateDecision(allowed: m.canUse(feature),
                            reason: m.gateReason(feature))
    }

    /// Convenience for imperative call sites. Returns true when the feature may
    /// run, and records the reason so the UI can surface it.
    static func allow(_ feature: String) -> Bool {
        decide(feature).allowed
    }
}

// MARK: - Inline gate

/// Renders `content` when the feature is unlocked, otherwise a lock notice.
struct FeatureGateBox<Content: View>: View {
    let feature: String
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        // Read through the observed object so a level change repaints
        // immediately instead of on the next cold start.
        let decision = Decision(feature: feature, gates: license.gates,
                                stateUsable: license.state.isUsable,
                                fallbackReason: license.gateReason(feature))
        if decision.allowed {
            content()
        } else {
            LockedNotice(feature: feature,
                         label: license.gates.first(where: { $0.feature == feature })?.label
                                ?? feature,
                         reason: decision.reason,
                         compact: compact)
        }
    }

    /// Pure value type so the branch above does not re-query the manager.
    private struct Decision {
        let allowed: Bool
        let reason: String

        init(feature: String, gates: [FeatureGate],
             stateUsable: Bool, fallbackReason: String) {
            guard stateUsable else {
                self.allowed = false
                self.reason = fallbackReason
                return
            }
            guard let g = gates.first(where: { $0.feature == feature }) else {
                // Unknown feature on the client: deny, so a newly added feature
                // without a server row cannot be used for free.
                self.allowed = false
                self.reason = "该功能当前不可用"
                return
            }
            self.allowed = g.unlocked
            self.reason = g.unlocked
                ? ""
                : "「\(g.label)」需要 \(LicenseManager.levelDisplayName(g.minLevel)) 及以上权限"
        }
    }
}

// MARK: - Locked notice

struct LockedNotice: View {
    let feature: String
    let label: String
    let reason: String
    var compact: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "lock.fill")
                .font(.system(size: compact ? 10 : 12, weight: .semibold))
                .foregroundColor(Palette.inkTertiary)

            VStack(alignment: .leading, spacing: 1) {
                Text(reason.isEmpty ? "未解锁" : reason)
                    .font(.system(size: compact ? 10 : 12))
                    .foregroundColor(Palette.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? DS.Space.s : DS.Space.m)
        .padding(.vertical, compact ? 6 : 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(Palette.surfaceAlt)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .stroke(Palette.separator, lineWidth: 1)
        )
    }
}

// MARK: - Action row with a gate
//
// Wraps the shared `ActionRow` so a locked action renders the reason in place of
// the chevron instead of appearing tappable.

struct GatedActionRow: View {
    let feature: String
    let title: String
    var subtitle: String = ""
    let systemImage: String
    var iconTint: Color = Palette.accent
    var iconBackground: Color = Palette.accentSoft
    let action: () -> Void

    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        let allowed = license.canUse(feature)

        Button {
            guard allowed else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            action()
        } label: {
            HStack(spacing: DS.Space.m) {
                ZStack {
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(allowed ? iconBackground : Palette.surfaceAlt)
                        .frame(width: 32, height: 32)
                    Image(systemName: allowed ? systemImage : "lock.fill")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(allowed ? iconTint : Palette.inkTertiary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(DS.Font.body)
                        .foregroundColor(allowed ? Palette.ink : Palette.inkTertiary)
                    if !allowed {
                        Text(license.gateReason(feature))
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                    }
                }

                Spacer(minLength: 0)

                if allowed {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Palette.inkTertiary)
                }
            }
            .padding(DS.Space.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!allowed)
    }
}

// MARK: - Banner
//
// Shown at the top of a screen whose whole purpose is one gated feature.

struct FeatureLockedBanner: View {
    let feature: String

    @ObservedObject private var license = LicenseManager.shared

    var body: some View {
        if !license.canUse(feature) {
            HStack(alignment: .top, spacing: DS.Space.s) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.warning)
                VStack(alignment: .leading, spacing: 2) {
                    Text("功能未解锁")
                        .font(DS.Font.body.weight(.semibold))
                        .foregroundColor(Palette.ink)
                    Text(license.gateReason(feature))
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("前往「我的」查看权限详情。")
                        .font(.system(size: 10))
                        .foregroundColor(Palette.inkTertiary)
                }
                Spacer(minLength: 0)
            }
            .padding(DS.Space.m)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(Palette.warningSoft)
            )
        }
    }
}
