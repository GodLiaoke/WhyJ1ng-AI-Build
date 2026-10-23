import SwiftUI

// MARK: - App identity
//
// Single source of truth for the product name, version label and authorship.
// Referenced from the login screen, the dashboard footer, the chat tab and the
// floating overlay so the notice is impossible to miss and only defined once.

enum AppBrand {
    /// Display name shown beside the logo.
    ///
    /// Renamed from "YOLO Person" to match the website and the dashboard title.
    /// The old name survives as `formerName` so the about rows and crash reports
    /// can still say which product a build came from.
    static let name = "WhyJ1ng AI"
    static let formerName = "YOLO Person"

    /// Folder name the user sees in Files.app -> On My iPhone.
    ///
    /// This is `CFBundleDisplayName`, which is still "YOLO Person". Renaming the
    /// bundle would rename the visible folder and orphan every path we print in
    /// the UI, so the rename stops at the product name until that is decided.
    /// Kept here so the instruction strings have a single source.
    static let filesFolder = "YOLO Person"

    static let tagline = "端侧实时人体检测 · 本地离线对话"

    /// Release channel.
    static let channel = "内测版"

    /// Author credit.
    static let author = "WhyJ1ng"
    static let contact = "QQ 1844222527"

    /// One-line notice, used where space is tight.
    static var shortNotice: String {
        "\(channel) by \(author) · \(contact)"
    }

    /// Full notice for the login screen and about rows.
    static var fullNotice: String {
        "\(name) \(channel)"
    }

    /// Marketing version only, e.g. "2.0.0".
    static var shortVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?"
    }

    /// Build number only, e.g. "14".
    static var buildNumber: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "?"
    }

    /// Marketing version + build pulled from the bundle at runtime.
    static var buildVersion: String {
        "\(shortVersion) (\(buildNumber))"
    }

    static var copyright: String {
        "Copyright © \(currentYear) \(author). 保留所有权利。"
    }

    private static var currentYear: Int {
        Calendar.current.component(.year, from: Date())
    }
}

// MARK: - Copyright badge
// Compact, high-contrast credit line. Used on the login screen and the dashboard.

struct CopyrightBadge: View {
    var compact: Bool = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: "seal.fill")
                .font(.system(size: compact ? 11 : 13, weight: .semibold))
                .foregroundColor(Palette.accent)

            VStack(alignment: .leading, spacing: 1) {
                Text(AppBrand.shortNotice)
                    .font(.system(size: compact ? 11 : 13,
                                  weight: .semibold,
                                  design: .rounded))
                    .foregroundColor(Palette.ink)
                if !compact {
                    Text(AppBrand.copyright)
                        .font(.system(size: 10))
                        .foregroundColor(Palette.inkTertiary)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, compact ? 8 : 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .fill(Palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                .stroke(Palette.separator, lineWidth: 1)
        )
    }
}

/// Prominent variant for the lock screen: accent-tinted, centred, full width.
struct CopyrightBanner: View {
    var body: some View {
        VStack(spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "seal.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text(AppBrand.fullNotice)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundColor(Palette.accent)

            Text("by \(AppBrand.author) · \(AppBrand.contact)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundColor(Palette.ink)

            Text(AppBrand.copyright)
                .font(.system(size: 10))
                .foregroundColor(Palette.inkTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DS.Space.m)
        .padding(.horizontal, DS.Space.l)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(Palette.accentSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(Palette.accent.opacity(0.25), lineWidth: 1)
        )
    }
}
