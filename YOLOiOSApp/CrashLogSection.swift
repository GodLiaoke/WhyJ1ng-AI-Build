import SwiftUI
import UIKit

// MARK: - Crash logs
//
// Shown in Settings so a crash report can be read and copied on the phone,
// without needing Xcode or a cable.

struct CrashLogSection: View {
    @ObservedObject private var safeMode = SafeMode.shared
    @State private var reports: [CrashReporter.Report] = []
    @State private var expanded: String? = nil
    @State private var copied = false
    @State private var bootLog = ""
    @State private var showBoot = false
    @State private var armSafeMode = false

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "诊断", systemImage: "ladybug")

            bootCard

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if reports.isEmpty {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Palette.success)
                            Text("没有崩溃记录")
                                .font(DS.Font.callout)
                                .foregroundColor(Palette.inkSecondary)
                            Spacer(minLength: 0)
                        }
                    } else {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(Palette.warning)
                            Text("发现 \(reports.count) 条崩溃记录")
                                .font(DS.Font.callout)
                                .fontWeight(.medium)
                                .foregroundColor(Palette.ink)
                            Spacer(minLength: 0)
                        }

                        ForEach(reports) { r in
                            reportRow(r)
                        }
                    }

                    Hairline()

                    VStack(spacing: DS.Space.s) {
                        SecondaryButton(title: copied ? "已复制" : "复制全部诊断信息",
                                        systemImage: copied ? "checkmark" : "doc.on.doc") {
                            UIPasteboard.general.string = fullDiagnostics
                            withAnimation { copied = true }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation { copied = false }
                            }
                        }
                        SecondaryButton(title: "清空日志",
                                        systemImage: "trash",
                                        role: .destructive) {
                            CrashReporter.clearAll()
                            BootLog.clear()
                            refresh()
                        }
                        SecondaryButton(title: "下次启动进入安全模式",
                                        systemImage: "shield.lefthalf.filled",
                                        role: .destructive) {
                            armSafeMode = true
                        }
                    }
                }
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("下次启动进入安全模式？",
                            isPresented: $armSafeMode,
                            titleVisibility: .visible) {
            Button("进入安全模式", role: .destructive) {
                SafeMode.shared.forceNextLaunch()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("下次启动会显示启动诊断页，不加载悬浮窗和对话模型。用于排查启动崩溃。")
        }
    }

    // MARK: Boot log

    private var bootCard: some View {
        SurfaceCard(padding: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                Button {
                    withAnimation(DS.Motion.standard) { showBoot.toggle() }
                } label: {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: showBoot ? "chevron.down" : "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Palette.inkTertiary)
                        Text("启动阶段记录")
                            .font(DS.Font.callout)
                            .fontWeight(.medium)
                            .foregroundColor(Palette.ink)
                        Spacer(minLength: 0)
                        Text("boot.log")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.inkTertiary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if showBoot {
                    ScrollView {
                        Text(bootLog.isEmpty ? "(空)" : bootLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 260)
                    .padding(DS.Space.s)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(Palette.surfaceAlt)
                    )
                }
            }
        }
    }

    // MARK: Report row

    @ViewBuilder
    private func reportRow(_ r: CrashReporter.Report) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Button {
                withAnimation(DS.Motion.standard) {
                    expanded = (expanded == r.id) ? nil : r.id
                }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: expanded == r.id ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.inkTertiary)
                    Text(r.name)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded == r.id {
                ScrollView {
                    Text(r.text)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.inkSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 260)
                .padding(DS.Space.s)
                .background(
                    RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                        .fill(Palette.surfaceAlt)
                )
            }
        }
    }

    // MARK: Helpers

    private var fullDiagnostics: String {
        var out = """
        ===== \(AppBrand.name) 诊断 =====
        version : \(AppBrand.buildVersion)
        device  : \(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        safe    : \(safeMode.isEngaged)

        ----- boot.log -----
        \(bootLog)

        """
        for r in reports {
            out += "\n----- \(r.name) -----\n\(r.text)\n"
        }
        return out
    }

    private func refresh() {
        reports = CrashReporter.reports()
        bootLog = BootLog.read()
    }
}
