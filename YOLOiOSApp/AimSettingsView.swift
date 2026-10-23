import SwiftUI

// MARK: - Aim assist settings
//
// Every parameter the aim loop reads, plus a live readout so the effect of a
// change is visible without leaving the page.

struct AimSettingsView: View {
    @ObservedObject private var aim = AimController.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        statusSection
                        transportSection
                        aimPointSection
                        motionSection
                        targetSection
                        resetSection
                        CopyrightBadge()
                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("Aim 辅助")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Status

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "状态", systemImage: "scope")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    PrimaryButton(title: aim.settings.isEnabled ? "停止 Aim" : "启动 Aim",
                                  systemImage: aim.settings.isEnabled ? "stop.fill" : "play.fill") {
                        if aim.settings.isEnabled { aim.stop() } else { aim.start() }
                    }

                    if aim.settings.isEnabled {
                        Hairline()
                        VStack(spacing: DS.Space.s) {
                            InfoRow(label: "目标", value: aim.targetBox == nil ? "无" : "已锁定")
                            InfoRow(label: "误差距离",
                                    value: String(format: "%.4f", aim.errorDistance),
                                    mono: true)
                            InfoRow(label: "速度",
                                    value: String(format: "%.3f, %.3f",
                                                  aim.lastDelta.dx, aim.lastDelta.dy),
                                    mono: true)
                            InfoRow(label: "刻度", value: "\(aim.ticks)", mono: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Transport

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "移动方式", systemImage: "arrow.up.and.down.and.arrow.left.and.right")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("不同移动方式需要的权限不同。当前签名下只有「内部视角」可用，它会移动本 App 的取景，用来验证参数是否合理。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    ForEach(AimTransport.allCases) { t in
                        Button {
                            aim.settings.transport = t
                            aim.refreshTransport()
                        } label: {
                            HStack(alignment: .top, spacing: DS.Space.m) {
                                ZStack {
                                    Circle()
                                        .stroke(aim.settings.transport == t ? Palette.accent : Palette.border,
                                                lineWidth: 1.6)
                                        .frame(width: 18, height: 18)
                                    if aim.settings.transport == t {
                                        Circle().fill(Palette.accent).frame(width: 9, height: 9)
                                    }
                                }
                                .padding(.top, 1)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(t.title)
                                        .font(DS.Font.body)
                                        .fontWeight(.medium)
                                        .foregroundColor(Palette.ink)
                                    Text(t.detail)
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !aim.transportNote.isEmpty {
                        Hairline()
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            Image(systemName: "info.circle.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Palette.warning)
                            Text(aim.transportNote)
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Aim point

    private var aimPointSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "瞄准点", systemImage: "target")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text("瞄准点由检测框推算：从框顶往下取一段作为头部，再取这段的中间。人的手臂抬起时，头部位置比身体中心稳定。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SliderRow(title: "头部高度占比",
                              subtitle: "从检测框顶部往下算的比例。人站直时约 20%，坐姿或半身可调高。",
                              value: $aim.settings.headHeightFraction,
                              range: 0.08...0.45,
                              step: 0.01,
                              valueText: String(format: "%.0f%%", aim.settings.headHeightFraction * 100))

                    SliderRow(title: "水平位置",
                              subtitle: "0 是框左边缘，0.5 是正中。侧身目标可微调。",
                              value: $aim.settings.headWidthFraction,
                              range: 0.2...0.8,
                              step: 0.05,
                              valueText: String(format: "%.2f", aim.settings.headWidthFraction))
                }
            }
        }
    }

    // MARK: Motion

    private var motionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "移动手感", systemImage: "wind")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    SliderRow(title: "速度",
                              subtitle: "越高越贴近目标，过高会抖动。",
                              value: $aim.settings.speed,
                              range: 0.1...3.0,
                              step: 0.05,
                              valueText: String(format: "%.2f", aim.settings.speed))

                    SliderRow(title: "平滑",
                              subtitle: "越高越稳但越迟钝。0.2 偏硬，0.6 偏软。",
                              value: $aim.settings.smoothing,
                              range: 0.0...0.8,
                              step: 0.02,
                              valueText: String(format: "%.2f", aim.settings.smoothing))

                    SliderRow(title: "预判",
                              subtitle: "按目标移动速度提前量，抵消检测到移动之间的延迟。0 为关闭。",
                              value: $aim.settings.prediction,
                              range: 0.0...1.0,
                              step: 0.05,
                              valueText: String(format: "%.2f", aim.settings.prediction))
                }
            }
        }
    }

    // MARK: Target selection

    private var targetSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "目标筛选", systemImage: "line.3.horizontal.decrease")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    ToggleRow(title: "只瞄准人",
                              subtitle: "关闭后会瞄准任何识别到的目标。",
                              isOn: $aim.settings.onlyPerson)

                    Hairline()

                    SliderRow(title: "最低置信度",
                              value: $aim.settings.minConfidence,
                              range: 0.1...0.9,
                              step: 0.05,
                              valueText: String(format: "%.2f", aim.settings.minConfidence))

                    SliderRow(title: "最小目标尺寸",
                              subtitle: "过滤远距离的小框，避免瞄到噪点。",
                              value: $aim.settings.minSize,
                              range: 0.0...0.3,
                              step: 0.01,
                              valueText: String(format: "%.0f%%", aim.settings.minSize * 100))

                    Hairline()

                    Text("目标选择规则：优先取画面中最大的框（即最近的人），面积接近时取置信度更高的。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var resetSection: some View {
        SurfaceCard(padding: DS.Space.xs) {
            ActionRow(title: "恢复默认参数",
                      subtitle: "速度 1.0 · 平滑 0.35 · 预判 0.15",
                      systemImage: "arrow.counterclockwise",
                      iconTint: Palette.warning,
                      iconBackground: Palette.warningSoft,
                      showsChevron: false) {
                aim.settings = AimSettings()
                aim.refreshTransport()
            }
        }
    }
}
