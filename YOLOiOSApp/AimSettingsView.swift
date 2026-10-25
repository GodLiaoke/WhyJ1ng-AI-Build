import SwiftUI

// MARK: - Aim assist settings
//
// Two kinds of control live on this page, and the split is the whole point of
// the round-7 design:
//
//   * What the user may decide — which box to aim at, and which transport to
//     deliver the movement through. These are switches and sliders.
//   * What the user may not decide — the head band, the smoothing, the speed
//     tiers, the look-ahead weights, the output clamp. The server samples these
//     and re-samples them on every heartbeat, so they are shown, read-only, with
//     the time left before the current table expires.
//
// There is nothing here that could be used to invent a table: no "reset to
// defaults" (there are no defaults), and the parameter card renders whatever
// the heartbeat delivered or an explicit "not received yet".

struct AimSettingsView: View {
    @ObservedObject private var aim = AimController.shared
    @ObservedObject private var license = LicenseManager.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        statusSection
                        paramsSection
                        transportSection
                        targetSection
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
                    // The switch shows intent; the caption below says whether the
                    // loop is actually stepping. Without a server table those two
                    // differ, and pretending otherwise is what the old build did.
                    PrimaryButton(title: aim.settings.isEnabled ? "停止 Aim" : "启动 Aim",
                                  systemImage: aim.settings.isEnabled ? "stop.fill" : "play.fill") {
                        if aim.settings.isEnabled { aim.stop() } else { aim.start() }
                    }

                    if !aim.paramsIsLive {
                        HStack(alignment: .top, spacing: DS.Space.s) {
                            Image(systemName: "lock.slash")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(Palette.warning)
                            Text(aim.paramsNote.isEmpty
                                 ? "没有服务端瞄准参数，瞄准不会启动。"
                                 : aim.paramsNote)
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    if aim.isAiming {
                        Hairline()
                        VStack(spacing: DS.Space.s) {
                            InfoRow(label: "目标", value: aim.targetBox == nil ? "无" : "已锁定")
                            InfoRow(label: "误差距离",
                                    value: String(format: "%.4f", aim.errorDistance),
                                    mono: true)
                            InfoRow(label: "位移",
                                    value: String(format: "%.4f, %.4f",
                                                  aim.lastDelta.dx, aim.lastDelta.dy),
                                    mono: true)
                            InfoRow(label: "刻度", value: "\(aim.ticks)", mono: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: Server parameters

    private var paramsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "服务端参数", systemImage: "server.rack")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.l) {
                    Text("瞄准参数由服务端下发")
                        .font(DS.Font.body)
                        .fontWeight(.medium)
                        .foregroundColor(Palette.ink)

                    if let p = aim.params, p.isValid {
                        VStack(spacing: DS.Space.s) {
                            InfoRow(label: "头部偏移",
                                    value: String(format: "%.2f / %.2f",
                                                  p.displayHeadOffset.y,
                                                  p.displayHeadOffset.x),
                                    mono: true)
                            InfoRow(label: "平滑系数",
                                    value: String(format: "%.2f", p.displaySmoothing),
                                    mono: true)
                            InfoRow(label: "速度表",
                                    value: p.speedTable
                                        .map { String(format: "%.2f", $0) }
                                        .joined(separator: " · "),
                                    mono: true)
                            InfoRow(label: "预判权重",
                                    value: p.predictionWeights
                                        .map { String(format: "%.2f", $0) }
                                        .joined(separator: " · "),
                                    mono: true)
                            InfoRow(label: "锚点 / 表行数",
                                    value: "\(p.anchors.count) / \(p.headOffsetTable.count)",
                                    mono: true)
                            InfoRow(label: "输出限幅",
                                    value: String(format: "%.3f ~ %.3f",
                                                  p.clampMin, p.clampMax),
                                    mono: true)
                            InfoRow(label: "参数版本", value: "v\(p.version)", mono: true)
                            InfoRow(label: "剩余有效期",
                                    value: String(format: "%.0f 秒", p.remaining),
                                    mono: true)
                        }

                        Hairline()

                        Text("这张表由服务端每次心跳重新采样（锚点 4–7 个、位置随机），数值每次不同但行为等价。到期即停，不做宽限。")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        VStack(alignment: .leading, spacing: DS.Space.s) {
                            InfoRow(label: "头部偏移", value: "—", mono: true)
                            InfoRow(label: "平滑系数", value: "—", mono: true)
                            InfoRow(label: "剩余有效期", value: "0 秒", mono: true)
                        }

                        Hairline()

                        Text(license.featureUnavailable
                             ?? "尚未收到服务端参数。请确认已激活且网络正常。")
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Hairline()

                    Text("这些数值不可在本机调整：算法在服务端，客户端只负责查表。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
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
                    Text("不同移动方式需要的权限不同。当前签名下只有「内部视角」可用，它会移动本 App 的取景，用来验证服务端下发的表是否合理。")
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

                    Text("目标选择规则：优先取画面中最大的框（即最近的人），面积接近时取置信度更高的。这一项是本机策略，不影响服务端下发的比例。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
