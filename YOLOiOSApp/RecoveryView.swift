import SwiftUI
import UIKit

// MARK: - Recovery screen
//
// Shown when the previous launch failed to finish starting. Its job is to get
// diagnostic text off the device, and to offer a way back to the normal UI
// without reinstalling.
//
// It deliberately avoids the overlay, the LLM and the camera, so it renders even
// when those are what broke.

struct RecoveryView: View {
    @ObservedObject private var safeMode = SafeMode.shared
    @State private var bootLog: String = ""
    @State private var crashReports: [CrashReporter.Report] = []
    @State private var copied = false
    @State private var expanded: String? = nil

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        banner
                        logCard
                        if !crashReports.isEmpty { crashCard }
                        actions
                        CopyrightBadge()
                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("启动诊断")
            .navigationBarTitleDisplayMode(.inline)
        }
        .navigationViewStyle(.stack)
        .onAppear(perform: refresh)
    }

    // MARK: Banner

    private var banner: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(Palette.warning)
                Text("上次启动没有完成")
                    .font(DS.Font.headline)
                    .foregroundColor(Palette.ink)
            }
            Text("连续失败 \(safeMode.consecutiveFailures) 次。已进入安全模式：悬浮窗、对话模型、摄像头均不会自动启用，方便你导出下面这份日志。")
                .font(DS.Font.callout)
                .foregroundColor(Palette.inkSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(DS.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .fill(Palette.warningSoft)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.l, style: .continuous)
                .stroke(Palette.warning.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: Boot log

    private var logCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "启动阶段记录", systemImage: "list.number")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    Text("最后一行就是崩溃前执行到的位置。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)

                    ScrollView {
                        Text(bootLog.isEmpty ? "(空)" : bootLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(Palette.inkSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 300)
                    .padding(DS.Space.s)
                    .background(
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(Palette.surfaceAlt)
                    )
                }
            }
        }
    }

    // MARK: Crash reports

    private var crashCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "崩溃报告", systemImage: "ladybug")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.s) {
                    ForEach(crashReports) { r in
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            Button {
                                withAnimation(DS.Motion.standard) {
                                    expanded = (expanded == r.id) ? nil : r.id
                                }
                            } label: {
                                HStack(spacing: DS.Space.s) {
                                    Image(systemName: expanded == r.id
                                          ? "chevron.down" : "chevron.right")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundColor(Palette.inkTertiary)
                                    Text(r.name)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundColor(Palette.ink)
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
                }
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        VStack(spacing: DS.Space.s) {
            PrimaryButton(title: "退出安全模式，正常使用",
                          systemImage: "checkmark.shield.fill") {
                safeMode.clearAndContinue()
            }

            PrimaryButton(title: copied ? "已复制到剪贴板" : "复制全部诊断信息",
                          systemImage: copied ? "checkmark" : "doc.on.doc") {
                UIPasteboard.general.string = fullText
                withAnimation { copied = true }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    withAnimation { copied = false }
                }
            }

            SecondaryButton(title: "清除日志",
                            systemImage: "trash") {
                CrashReporter.clearAll()
                BootLog.clear()
                refresh()
            }

            Text("诊断信息也会写入「文件」App → \(AppBrand.filesFolder) → CrashLogs，可直接拖出来。")
                .font(DS.Font.caption)
                .foregroundColor(Palette.inkTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, DS.Space.s)
        }
    }

    // MARK: Helpers

    private var fullText: String {
        var out = """
        ===== \(AppBrand.name) 启动诊断 =====
        app     : \(AppBrand.name) \(AppBrand.channel)
        version : \(AppBrand.buildVersion)
        device  : \(UIDevice.current.model) / \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        safe    : \(safeMode.isEngaged)   failures: \(safeMode.consecutiveFailures)

        ----- boot.log -----
        \(bootLog)

        """
        for r in crashReports {
            out += "\n----- \(r.name) -----\n\(r.text)\n"
        }
        return out
    }

    private func refresh() {
        bootLog = BootLog.read()
        crashReports = CrashReporter.reports()
    }
}
