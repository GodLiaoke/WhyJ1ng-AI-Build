import Foundation
import SwiftUI
import UIKit

// MARK: - Launch mode
//
// Chosen every time the overlay starts, because what a mode can deliver depends
// on the device, not on the label.
//
// The two modes are install paths, not promises:
//
//   trollstore  Installed outside the App Store (TrollStore or a jailbroken
//               sideload). The window *can* live in SpringBoard and the kernel
//               layer *can* be attempted — but only on a jailbroken device, and
//               only inside the kernel window.
//
//   selfSigned  Normal sandboxed sideload. The overlay stays inside this app and
//               aim falls back to the internal-viewport transport.
//
// Every string below is generated from `DeviceCapability`, so the picker cannot
// advertise something the probes did not observe. The previous hardcoded
// "未沙盒 · 系统级悬浮 · Kernel 可用" was false on most devices and is exactly
// what this file no longer does.

enum LaunchMode: String, CaseIterable, Identifiable {
    case trollstore
    case selfSigned

    var id: String { rawValue }

    // MARK: Availability
    //
    // Three states instead of a boolean, because "works" and "works partly" need
    // different words in the UI: a partial mode is still worth starting, and the
    // reason it is partial is the thing the user has to act on.

    enum Availability: Equatable {
        /// Everything this mode promises can be delivered right now.
        case full
        /// Starts, and delivers part of what it is for. Carries the reason.
        case partial(String)
        /// Cannot deliver its defining capability on this device. Carries why.
        case unavailable(String)

        /// Whether starting the mode is meaningful at all.
        var isUsable: Bool {
            if case .unavailable = self { return false }
            return true
        }

        /// The attached explanation, when there is one.
        var reason: String? {
            switch self {
            case .full: return nil
            case .partial(let s): return s
            case .unavailable(let s): return s
            }
        }

        var badge: String {
            switch self {
            case .full: return "可用"
            case .partial: return "部分可用"
            case .unavailable: return "不可用"
            }
        }
    }

    /// What this mode can actually do on this device, right now.
    var availability: Availability {
        switch self {
        case .trollstore:
            guard DeviceCapability.isJailbroken else {
                let why = DeviceCapability.isTrollStore
                    ? "TrollStore 安装，但系统未越狱：没有往 SpringBoard 注入的途径，系统级悬浮和点击注入都做不到。"
                    : "系统未越狱：系统级悬浮和点击注入都需要越狱环境。"
                return .unavailable(why)
            }
            if DeviceCapability.supportsKernelExploit && DeviceCapability.systemOverlayLoaded {
                return .full
            }
            var missing: [String] = []
            if !DeviceCapability.systemOverlayLoaded {
                missing.append("悬浮组件未安装或未运行")
            }
            if !DeviceCapability.supportsKernelExploit {
                missing.append("iOS \(DeviceCapability.osVersion) 超出内核注入窗口 \(KernelSupport.windowLabel)")
            }
            if missing.isEmpty {
                return .full
            }
            return .partial(missing.joined(separator: "；"))
        case .selfSigned:
            // Sandboxed overlay plus simulated aim needs nothing from the system.
            return .full
        }
    }

    // MARK: Labels
    //
    // `title` and `icon` are fixed: they name the install path, which does not
    // change. Everything that makes a claim about behaviour is computed.

    var title: String {
        switch self {
        case .trollstore: return "巨魔模式"
        case .selfSigned: return "自签模式"
        }
    }

    var icon: String {
        switch self {
        case .trollstore: return "shield.lefthalf.filled"
        case .selfSigned: return "signature"
        }
    }

    var subtitle: String {
        switch self {
        case .trollstore:
            guard DeviceCapability.isJailbroken else {
                return "仅本 App 内悬浮 · 不可注入点击"
            }
            let overlay = DeviceCapability.systemOverlayLoaded
                ? "系统级悬浮已就绪"
                : "系统级悬浮（需安装悬浮组件）"
            let kernel = DeviceCapability.supportsKernelExploit
                ? "内核注入"
                : "不支持内核注入"
            return "\(overlay) · \(kernel)"
        case .selfSigned:
            return "仅本 App 内悬浮 · 模拟瞄准"
        }
    }

    var detail: String {
        switch self {
        case .trollstore:
            return trollstoreDetail
        case .selfSigned:
            return "用于普通自签安装。悬浮窗只在本 App 前台显示，"
                 + "瞄准使用内部视角模拟，不涉及内核操作。"
        }
    }

    private var trollstoreDetail: String {
        let version = DeviceCapability.osVersion

        guard DeviceCapability.isJailbroken else {
            var text = "当前设备未越狱（iOS \(version)），没有把代码注入 SpringBoard 的途径。"
            text += "此模式下悬浮窗只能活在本 App 内，切到其它 App 就会消失，瞄准也只有内部模拟。"
            if DeviceCapability.isTrollStore {
                text += "检测到 TrollStore 安装：进程未沙盒，但系统级悬浮仍需要越狱。"
            }
            text += "想要真正的系统级悬浮，需要越狱设备并安装悬浮组件。"
            return text
        }

        var text = "越狱环境已检测到，悬浮窗由 SpringBoard 内的组件绘制，可以浮在其它 App 之上。"
        if DeviceCapability.supportsKernelExploit {
            text += "iOS \(version) 在 kfd 漏洞窗口 \(KernelSupport.windowLabel) 内，内核注入可以尝试。"
        } else {
            text += "iOS \(version) 已超出 kfd 漏洞窗口 \(KernelSupport.windowLabel)，内核注入不可用，"
                  + "瞄准走 IOHIDEvent 点击注入。"
        }
        if !DeviceCapability.systemOverlayLoaded {
            text += "悬浮组件目前未安装或未运行，系统级悬浮要等它就绪。"
        }
        return text
    }

    /// Whether the kernel chain should be attempted in this mode.
    var attemptsKernel: Bool { self == .trollstore }

    /// Whether aim may move anything outside this app.
    var allowsAimTransport: Bool { self == .trollstore }

    /// The mode to preselect when nothing was remembered.
    static var recommended: LaunchMode {
        trollstore.availability.isUsable ? .trollstore : .selfSigned
    }
}

// MARK: - Launch mode store

@MainActor
final class LaunchModeStore: ObservableObject {
    static let shared = LaunchModeStore()

    private enum Key {
        static let remembered = "launch.mode"
    }

    /// Remembered across launches, offered as the default next time.
    @Published var remembered: LaunchMode? = nil
    /// The mode chosen for the current session.
    @Published private(set) var active: LaunchMode? = nil
    /// Set when the user asked for a mode the environment cannot honour.
    @Published var warning: String? = nil

    private init() {
        if let raw = UserDefaults.standard.string(forKey: Key.remembered),
           let m = LaunchMode(rawValue: raw) {
            remembered = m
        }
    }

    var needsSelection: Bool { active == nil }

    /// Commits a choice and reports anything the environment cannot deliver.
    ///
    /// Only an outright unusable mode raises `warning`: it surfaces through the
    /// overlay's error line, and a partial mode is already explained where the
    /// user picks it, so repeating it on every launch would just be noise.
    func select(_ mode: LaunchMode, remember: Bool) {
        active = mode
        warning = nil

        if remember {
            remembered = mode
            UserDefaults.standard.set(mode.rawValue, forKey: Key.remembered)
        }

        if case .unavailable(let why) = mode.availability {
            warning = "\(mode.title)不可用：\(why)"
        }
    }

    /// Clears the session choice so the picker appears again.
    func reset() {
        active = nil
        warning = nil
    }
}

// MARK: - Picker
//
// Fully custom: no alert, no action sheet, no confirmation dialog. The system
// presentations cannot be themed to match the panel and would break the
// full-screen overlay illusion.

struct LaunchModePicker: View {
    @ObservedObject private var store = LaunchModeStore.shared
    @ObservedObject private var kernel = KernelExploitRunner.shared

    @State private var selection: LaunchMode = .selfSigned
    @State private var remember = true

    let onConfirm: (LaunchMode) -> Void
    let onCancel: (() -> Void)?

    /// Red for "cannot work here". The palette has no danger colour because
    /// until now nothing in the overlay could be outright impossible.
    private var danger: Color { Color(red: 1.00, green: 0.42, blue: 0.36) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    environmentCard
                    modeList
                    if let warn = store.warning {
                        warningBox(warn)
                    }
                    rememberRow
                }
                .padding(14)
            }
            .frame(maxHeight: 420)

            footer
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(CheatPalette.bg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(CheatPalette.border, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.55), radius: 28, y: 12)
        .colorScheme(.dark)
        .onAppear {
            selection = store.remembered ?? LaunchMode.recommended
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "power")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(CheatPalette.accent)
            Text("选择启动方式")
                .font(.system(size: 13, weight: .heavy, design: .monospaced))
                .foregroundColor(CheatPalette.text)
                .letterSpacing(0.8)
            Spacer(minLength: 0)
            if let onCancel {
                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(CheatPalette.textDim)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(CheatPalette.surface))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    // MARK: Environment
    //
    // Mirrors what the picker is about to claim: jailbreak state, system version,
    // and the resulting capability line. Reading the same source as the mode rows
    // is the point — a caption that disagrees with the rows above it is how the
    // old version lied.

    private var environmentCard: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: environmentIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(environmentColor)
                Text(environmentLabel)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(environmentColor)
                Spacer(minLength: 0)
                Text("iOS \(DeviceCapability.osVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(CheatPalette.textDim)
            }

            Text(DeviceCapability.summary)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CheatPalette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)

            Text(KernelSupport.comparisonLine)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(DeviceCapability.supportsKernelExploit
                                 ? CheatPalette.accent : CheatPalette.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(CheatPalette.surface)
        )
    }

    private var environmentIcon: String {
        if DeviceCapability.isJailbroken { return "checkmark.shield.fill" }
        if DeviceCapability.isTrollStore { return "shippingbox.fill" }
        return "shield.slash.fill"
    }

    private var environmentLabel: String {
        if DeviceCapability.isJailbroken { return "已越狱" }
        if DeviceCapability.isTrollStore { return "TrollStore · 未越狱" }
        return "未越狱"
    }

    private var environmentColor: Color {
        DeviceCapability.isJailbroken ? CheatPalette.accent : CheatPalette.warn
    }

    // MARK: Modes

    private var modeList: some View {
        VStack(spacing: 8) {
            ForEach(LaunchMode.allCases) { mode in
                modeRow(mode)
            }
        }
    }

    private func modeRow(_ mode: LaunchMode) -> some View {
        let selected = selection == mode
        let availability = mode.availability
        let accent = badgeColor(availability)

        return Button {
            selection = mode
        } label: {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .stroke(selected ? CheatPalette.accent : CheatPalette.border,
                                lineWidth: 1.6)
                        .frame(width: 18, height: 18)
                    if selected {
                        Circle().fill(CheatPalette.accent).frame(width: 9, height: 9)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Image(systemName: mode.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(selected
                                             ? CheatPalette.accent : CheatPalette.textDim)
                        Text(mode.title)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundColor(CheatPalette.text)
                        Spacer(minLength: 0)
                        availabilityBadge(availability, color: accent)
                        if store.remembered == mode {
                            Text("上次")
                                .font(.system(size: 8, weight: .bold, design: .monospaced))
                                .foregroundColor(CheatPalette.textDim)
                                .padding(.horizontal, 5).padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(CheatPalette.surfaceStrong)
                                )
                        }
                    }
                    Text(mode.subtitle)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundColor(selected ? CheatPalette.accent : CheatPalette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(mode.detail)
                        .font(.system(size: 9))
                        .foregroundColor(CheatPalette.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                    if selected, let reason = availability.reason {
                        Text(reason)
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundColor(accent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? CheatPalette.accentDim : CheatPalette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected
                            ? CheatPalette.accent.opacity(0.45) : CheatPalette.border,
                            lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func availabilityBadge(_ availability: LaunchMode.Availability,
                                   color: Color) -> some View {
        Text(availability.badge)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .foregroundColor(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.15))
            )
    }

    private func badgeColor(_ availability: LaunchMode.Availability) -> Color {
        switch availability {
        case .full: return CheatPalette.accent
        case .partial: return CheatPalette.warn
        case .unavailable: return danger
        }
    }

    // MARK: Warning

    private func warningBox(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(CheatPalette.warn)
            Text(text)
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(CheatPalette.warn)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(CheatPalette.warnDim)
        )
    }

    // MARK: Remember

    private var rememberRow: some View {
        HStack {
            Text("记住选择")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundColor(CheatPalette.textDim)
            Spacer()
            Toggle("", isOn: $remember)
                .labelsHidden()
                .tint(CheatPalette.accent)
                .scaleEffect(0.78)
        }
        .frame(height: 20)
    }

    // MARK: Footer

    private var canStart: Bool {
        selection.availability.isUsable
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                onCancel?()
            } label: {
                Text("取消")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(CheatPalette.text)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(CheatPalette.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(CheatPalette.border, lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)

            Button {
                store.select(selection, remember: remember)
                onConfirm(selection)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: canStart ? "play.fill" : "xmark.octagon.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(canStart ? "启动" : "此模式不可用")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                }
                .foregroundColor(canStart ? Color.black : CheatPalette.textDim)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 11)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(canStart ? CheatPalette.accent : CheatPalette.surface)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canStart)
        }
        .padding(14)
        .padding(.top, 0)
    }
}
