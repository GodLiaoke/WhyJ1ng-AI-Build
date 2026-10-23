import SwiftUI

// MARK: - Detection tuning
// Live controls for the accuracy / false-positive trade-off. Every value is
// read by YOLOViewModel on the next frame, so changes apply instantly.

struct SettingsView: View {
    @ObservedObject private var settings = DetectorSettings.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showAISettings = false

    private let confidencePresets: [(String, Double)] = [
        ("宽松 0.30", 0.30),
        ("标准 0.45", 0.45),
        ("严格 0.60", 0.60),
        ("极严 0.75", 0.75),
    ]

    private let sizePresets: [(String, Double)] = [
        ("全部 0%", 0.0),
        ("小目标 2%", 0.02),
        ("常规 4%", 0.04),
        ("近景 8%", 0.08),
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {

                        // Confidence
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "置信度阈值", systemImage: "dial.high")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    Text("低于该分数的结果会被丢弃。被子、窗帘这类高纹理物体误报时，调高这里。")
                                        .font(DS.Font.caption)
                                        .foregroundColor( Palette.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    SliderRow(title: "阈值",
                                              value: $settings.confidence,
                                              range: 0.1...0.9,
                                              step: 0.01,
                                              valueText: String(format: "%.2f", settings.confidence))

                                    HStack(spacing: DS.Space.s) {
                                        ForEach(confidencePresets, id: \.0) { preset in
                                            Chip(text: preset.0,
                                                 selected: abs(settings.confidence - preset.1) < 0.005) {
                                                settings.confidence = preset.1
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        // Persistence
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "持续帧数", systemImage: "square.stack.3d.down.right")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    Text("必须连续多少帧都检测到才画框。真人会持续出现，误报通常闪一下就消失 —— 这是消除闪框最有效的开关。")
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    SliderRow(title: "帧数",
                                              value: Binding(
                                                get: { Double(settings.requiredFrames) },
                                                set: { settings.requiredFrames = Int($0.rounded()) }
                                              ),
                                              range: 1...10,
                                              step: 1,
                                              valueText: "\(settings.requiredFrames) 帧")

                                    HStack(spacing: DS.Space.s) {
                                        Chip(text: "关闭 1", selected: settings.requiredFrames <= 1) {
                                            settings.requiredFrames = 1
                                        }
                                        Chip(text: "轻 3", selected: settings.requiredFrames == 3) {
                                            settings.requiredFrames = 3
                                        }
                                        Chip(text: "中 5", selected: settings.requiredFrames == 5) {
                                            settings.requiredFrames = 5
                                        }
                                        Chip(text: "强 8", selected: settings.requiredFrames == 8) {
                                            settings.requiredFrames = 8
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Hairline()

                                    ToggleRow(title: "启用时序跟踪",
                                              subtitle: "关闭后每帧结果直接显示，误报会明显变多。",
                                              isOn: $settings.trackingEnabled)
                                }
                            }
                        }

                        // Size filter
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "最小目标尺寸", systemImage: "arrow.up.left.and.arrow.down.right")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    Text("过滤掉小于画面短边该比例的结果。远处的噪点误报大多是极小的框。")
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    SliderRow(title: "最小尺寸",
                                              value: $settings.minSize,
                                              range: 0.0...0.25,
                                              step: 0.005,
                                              valueText: String(format: "%.1f%%", settings.minSize * 100))

                                    HStack(spacing: DS.Space.s) {
                                        ForEach(sizePresets, id: \.0) { preset in
                                            Chip(text: preset.0,
                                                 selected: abs(settings.minSize - preset.1) < 0.0025) {
                                                settings.minSize = preset.1
                                            }
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }

                        // Performance
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "性能", systemImage: "speedometer")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    Text("限制推理频率能降低发热，长时间使用时反而比满速更稳。0 表示不限速。")
                                        .font(DS.Font.caption)
                                        .foregroundColor(Palette.inkTertiary)
                                        .fixedSize(horizontal: false, vertical: true)

                                    SliderRow(title: "最大帧率",
                                              value: $settings.maxFPS,
                                              range: 0.0...60.0,
                                              step: 1.0,
                                              valueText: settings.maxFPS <= 0
                                                  ? "不限"
                                                  : "\(Int(settings.maxFPS)) fps")

                                    HStack(spacing: DS.Space.s) {
                                        Chip(text: "不限", selected: settings.maxFPS <= 0) {
                                            settings.maxFPS = 0
                                        }
                                        Chip(text: "30", selected: settings.maxFPS == 30) {
                                            settings.maxFPS = 30
                                        }
                                        Chip(text: "15", selected: settings.maxFPS == 15) {
                                            settings.maxFPS = 15
                                        }
                                        Chip(text: "10", selected: settings.maxFPS == 10) {
                                            settings.maxFPS = 10
                                        }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)

                                    Hairline()

                                    ToggleRow(title: "显示计时信息",
                                              subtitle: "检测页显示推理耗时、后处理耗时、候选框数量。",
                                              isOn: $settings.showDebug)
                                }
                            }
                        }

                        // Interaction
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "交互", systemImage: "hand.tap")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    ToggleRow(title: "点击检测框查看详情",
                                              subtitle: "开启后，在检测页点任意框会弹出该目标的详细信息（坐标、置信度、占比）。关闭则框只做显示，不接收点击。",
                                              isOn: $settings.boxTapDetails)

                                    Hairline()

                                    ToggleRow(title: "悬浮窗「点击目标」默认开启",
                                              subtitle: "开启后悬浮窗会给每个识别到的目标留出穿透区，点那些区域会点到下层 App。也可在悬浮窗面板里随时切换。",
                                              isOn: $settings.overlayTapThrough)
                                }
                            }
                        }

                        // Class + NMS
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "类别与合并", systemImage: "square.on.square")
                            SurfaceCard(padding: DS.Space.l) {
                                VStack(alignment: .leading, spacing: DS.Space.l) {
                                    ToggleRow(title: "只检测人",
                                              subtitle: "关闭后会画出全部 80 个 COCO 类别（车、椅子、杯子…），便于确认真是模型在看什么。",
                                              isOn: $settings.personOnly)

                                    Hairline()

                                    SliderRow(title: "重叠合并 IoU",
                                              subtitle: "同一个人的多个框有多重叠时视为重复，保留分数最高的。",
                                              value: $settings.nmsIoU,
                                              range: 0.2...0.8,
                                              step: 0.01,
                                              valueText: String(format: "%.2f", settings.nmsIoU))
                                }
                            }
                        }

                        SurfaceCard(padding: DS.Space.xs) {
                            ActionRow(title: "恢复默认值",
                                      subtitle: "置信度 0.45 · 3 帧 · 最小 4%",
                                      systemImage: "arrow.counterclockwise",
                                      iconTint: Palette.warning,
                                      iconBackground: Palette.warningSoft,
                                      showsChevron: false) {
                                settings.resetToDefaults()
                            }
                        }

                        // Chat / AI behaviour lives in its own sheet.
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "对话 AI", systemImage: "brain.head.profile")
                            SurfaceCard(padding: DS.Space.xs) {
                                ActionRow(title: "AI 设置",
                                          subtitle: "系统提示词 · 检测上下文注入 · 沙盒工具权限",
                                          systemImage: "brain.head.profile",
                                          iconTint: Palette.accent,
                                          iconBackground: Palette.accentSoft) {
                                    showAISettings = true
                                }
                            }
                        }

                        CrashLogSection()

                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("检测调参")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(isPresented: $showAISettings) {
                AISettingsView()
            }
        }
        .navigationViewStyle(.stack)
    }
}
