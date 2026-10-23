import SwiftUI

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @State private var showPicker = false
    @State private var showSettings = false
    @State private var showPhoto = false
    @State private var toast: String? = nil
    @State private var toastIsError = false
    @State private var showImportHelp = false
    @ObservedObject private var overlay = OverlayState.shared
    @ObservedObject private var license = LicenseManager.shared

    private var selected: ModelItem? { app.selectedModel }

    var body: some View {
        ZStack(alignment: .top) {
            Palette.canvas.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: DS.Space.xl) {

                    header

                    // Driver readiness sits above everything else: it is the one
                    // row that can explain why the rest of the page does not work.
                    // Renders nothing while the server has the check switched off.
                    DriverStatusCard()

                    modelSection

                    actionsSection

                    environmentSection

                    footer

                    // Reserve room for the floating tab bar, which sits over the
                    // content rather than below it.
                    Color.clear.frame(height: MainTabView.barFootprint)
                }
                .padding(.horizontal, DS.Space.l)
                .padding(.top, DS.Space.s)
            }

            if let toast {
                ToastView(message: toast, isError: toastIsError)
                    .padding(.top, DS.Space.s)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .zIndex(1)
            }
        }
        .animation(DS.Motion.spring, value: toast)
        .sheet(isPresented: $showPicker) {
            ModelPicker { url in
                app.importModel(from: url)
                if let err = app.modelError {
                    present(err, isError: true)
                } else {
                    present("模型已导入", isError: false)
                }
            }
        }
        .sheet(isPresented: $showImportHelp) {
            ImportHelpSheet(inboxPath: ModelLoader.inboxURL.path)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
        }
        .sheet(isPresented: $showPhoto) {
            PhotoDetectView()
        }
        .onAppear {
            app.refreshModels()
            overlay.sourceWindow = nil
            // Plays once per process. If RootView also arms it, the second call
            // is a no-op - the gate is process wide, not per view.
            LaunchSplash.presentIfNeeded()
            // The card observes the model itself; subscribing the whole page to
            // a probe that ticks every few seconds would re-render all of it.
            DriverStatus.shared.activate()
        }
        .onDisappear {
            DriverStatus.shared.deactivate()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            HStack(alignment: .center, spacing: DS.Space.m) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("WhyJ1ng AI")
                        .font(DS.Font.display)
                        .foregroundColor(Palette.ink)
                    Text("端侧 YOLO · Core ML · Apple Neural Engine")
                        .font(DS.Font.callout)
                        .foregroundColor(Palette.inkTertiary)
                }
                Spacer(minLength: 0)
                // Says "model" explicitly: the driver card below uses the same
                // ready/not-ready vocabulary for a completely different thing.
                StatusChip(level: selected == nil ? .idle : .ready,
                           text: selected == nil ? "模型未选" : "模型就绪")
            }

            // Credit line, visible without scrolling.
            CopyrightBadge(compact: true)
        }
    }

    // MARK: Model

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "推理模型", systemImage: "cube.box")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    if let m = selected {
                        HStack(alignment: .top, spacing: DS.Space.m) {
                            ZStack {
                                RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                                    .fill(Palette.accentSoft)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "brain")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundColor(Palette.accent)
                            }
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: DS.Space.s) {
                                    Text(m.name)
                                        .font(DS.Font.body)
                                        .fontWeight(.semibold)
                                        .foregroundColor(Palette.ink)
                                        .lineLimit(2)
                                    Text(m.tier.label)
                                        .font(DS.Font.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(m.tier.tint)
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(m.tier.tint.opacity(0.12)))
                                }
                                Text(m.tier.detail)
                                    .font(DS.Font.caption)
                                    .foregroundColor(Palette.inkSecondary)
                                HStack(spacing: DS.Space.xs) {
                                    Text(m.sizeText)
                                    Text("·")
                                    Text(m.isBundled ? "内置" : "本地")
                                    Text("·")
                                    Text(m.isCompiled ? "已编译" : "首次使用需编译")
                                }
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                            }
                            Spacer(minLength: 0)
                        }

                        Hairline()

                        HStack(spacing: DS.Space.s) {
                            Text("类别")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                            Spacer()
                            Text("COCO person · id 0")
                                .font(DS.Font.mono)
                                .foregroundColor(Palette.inkSecondary)
                        }
                    } else {
                        EmptyState(systemImage: "cube.box",
                                   title: "尚未选择模型",
                                   message: "把 yolov8n.mlpackage 放进 App 文件夹，或从「文件」导入。")
                    }

                    VStack(spacing: DS.Space.s) {
                        if app.models.count > 1 {
                            Menu {
                                ForEach(app.models) { item in
                                    Button {
                                        app.select(item)
                                    } label: {
                                        Label("\(item.name)  ·  \(item.sizeText)",
                                              systemImage: item.id == selected?.id ? "checkmark" : "cube.box")
                                    }
                                }
                            } label: {
                                HStack(spacing: DS.Space.s) {
                                    Image(systemName: "square.stack.3d.up")
                                        .font(.system(size: 15, weight: .semibold))
                                    Text("切换模型（\(app.models.count)）")
                                        .font(DS.Font.headline)
                                    Spacer()
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 12, weight: .semibold))
                                }
                                .foregroundColor(Palette.ink)
                                .padding(.vertical, 14)
                                .padding(.horizontal, DS.Space.m)
                                .background(
                                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                        .fill(Palette.surfaceAlt)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                                        .stroke(Palette.border, lineWidth: 1)
                                )
                            }
                        }

                        SecondaryButton(title: "从「文件」导入模型",
                                        systemImage: "folder.badge.plus") {
                            showPicker = true
                        }

                        SecondaryButton(title: "查看放置位置说明",
                                        systemImage: "questionmark.circle") {
                            showImportHelp = true
                        }
                    }

                    if let err = app.modelError {
                        Text(err)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    // MARK: Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "操作", systemImage: "bolt")

            SurfaceCard(padding: DS.Space.xs) {
                VStack(spacing: 0) {
                    // Each of these is gated. GatedActionRow renders the reason
                    // in place of the chevron when the level is too low, so a
                    // locked feature explains itself rather than looking broken.
                    GatedActionRow(feature: "detect_camera",
                                   title: "开始实时检测",
                                   subtitle: selected == nil
                                       ? "未选择模型，将尝试使用内置模型"
                                       : "开启摄像头，实时框出画面中的人",
                                   systemImage: "camera.viewfinder") {
                        app.showCamera = true
                    }

                    Hairline().padding(.leading, DS.Space.m)

                    GatedActionRow(feature: "photo_detect",
                                   title: "图片识别",
                                   subtitle: "从相册选图或拍照，识别图中内容",
                                   systemImage: "photo.on.rectangle.angled") {
                        showPhoto = true
                    }

                    Hairline().padding(.leading, DS.Space.m)

                    GatedActionRow(feature: "overlay",
                                   title: "悬浮窗",
                                   subtitle: overlay.isVisible
                                       ? "已开启 · 控制面板"
                                       : "悬浮控制面板，可扫描屏幕内容",
                                   systemImage: "rectangle.on.rectangle.angled",
                                   iconTint: Palette.success,
                                   iconBackground: Palette.successSoft) {
                        toggleOverlay()
                    }

                    Hairline().padding(.leading, DS.Space.m)

                    ActionRow(title: "检测调参",
                              subtitle: "置信度 · 持续帧数 · 最小尺寸 · 类别",
                              systemImage: "slider.horizontal.3",
                              iconTint: Palette.accent,
                              iconBackground: Palette.accentSoft) {
                        showSettings = true
                    }

                    Hairline().padding(.leading, DS.Space.m)

                    ActionRow(title: "重新扫描本地模型",
                              subtitle: "刷新 App 文件夹中的模型列表",
                              systemImage: "arrow.clockwise",
                              iconTint: Palette.success,
                              iconBackground: Palette.successSoft) {
                        app.refreshModels()
                        present("已重新扫描，发现 \(app.models.count) 个模型", isError: false)
                    }
                }
            }
        }
    }

    private func toggleOverlay() {
        if overlay.isVisible {
            overlay.hideOverlay()
            present("悬浮窗已关闭", isError: false)
        } else {
            let ok = overlay.showOverlay()
            present(ok ? "悬浮窗已开启 · 拖动手柄移动" : "悬浮窗创建失败",
                    isError: !ok)
        }
    }

    // MARK: Environment
    //
    // Compute-unit and network-access rows were removed: they describe the
    // implementation, not anything the user can act on. Replaced with the
    // licence facts that matter — when it expires and which device it is bound to.

    private var environmentSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "运行环境", systemImage: "cpu")

            SurfaceCard(padding: DS.Space.l) {
                VStack(spacing: DS.Space.m) {
                    InfoRow(label: "推理位置", value: "本机端侧")
                    Hairline()
                    InfoRow(label: "输入尺寸", value: "640 × 640")
                    Hairline()
                    InfoRow(label: "置信度阈值", value: "0.35")
                    Hairline()
                    InfoRow(label: "应用版本", value: Self.appVersion, mono: true)
                    Hairline()
                    InfoRow(label: "发布通道", value: AppBrand.channel)
                    Hairline()
                    InfoRow(label: "授权等级", value: license.levelName)
                    Hairline()
                    InfoRow(label: "到期时间", value: licenceExpiry, mono: true)
                    Hairline()
                    InfoRow(label: "机器码",
                            value: String(LicenseManager.shared.deviceId.prefix(20)) + "…",
                            mono: true)
                }
            }
        }
    }

    private var licenceExpiry: String {
        if let e = license.expiresAt, !e.isEmpty { return e }
        return license.level > 0 ? "永久有效" : "—"
    }

    /// Marketing version + build, straight from the bundle.
    private static var appVersion: String { AppBrand.buildVersion }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "会话", systemImage: "person.crop.circle")

            SurfaceCard(padding: DS.Space.xs) {
                ActionRow(title: "退出登录",
                          subtitle: "锁定应用并返回验证页",
                          systemImage: "rectangle.portrait.and.arrow.right",
                          iconTint: Palette.danger,
                          iconBackground: Palette.dangerSoft,
                          showsChevron: false) {
                    license.signOut()
                }
            }

            // Full credit, at the bottom of the dashboard.
            CopyrightBadge()
        }
    }

    // MARK: Helpers

    private func present(_ message: String, isError: Bool) {
        toastIsError = isError
        withAnimation(DS.Motion.spring) { toast = message }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            withAnimation(DS.Motion.standard) {
                if toast == message { toast = nil }
            }
        }
    }
}

// MARK: - Import help

struct ImportHelpSheet: View {
    let inboxPath: String
    @Environment(\.dismiss) private var dismiss

    private let steps = [
        "在「文件」App 里进入 我的 iPhone → \(AppBrand.filesFolder)",
        "把 yolov8n.mlpackage 整个文件夹拷进去（不要只拷里面的文件）",
        "回到本页点「重新扫描本地模型」",
        "在模型卡片里选中它，然后开始检测"
    ]

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.l) {
                        SurfaceCard(padding: DS.Space.l) {
                            VStack(alignment: .leading, spacing: DS.Space.m) {
                                Text("放置位置")
                                    .font(DS.Font.headline)
                                    .foregroundColor(Palette.ink)
                                Text("\(AppBrand.filesFolder) 已在「文件」App 里暴露了可写入的文件夹，根目录就是上面那个路径。")
                                    .font(DS.Font.callout)
                                    .foregroundColor(Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        SurfaceCard(padding: DS.Space.l) {
                            VStack(alignment: .leading, spacing: DS.Space.m) {
                                Text("操作步骤")
                                    .font(DS.Font.headline)
                                    .foregroundColor(Palette.ink)
                                ForEach(Array(steps.enumerated()), id: \.offset) { idx, text in
                                    HStack(alignment: .top, spacing: DS.Space.m) {
                                        ZStack {
                                            Circle().fill(Palette.accentSoft).frame(width: 22, height: 22)
                                            Text("\(idx + 1)")
                                                .font(.system(size: 12, weight: .bold))
                                                .foregroundColor(Palette.accent)
                                        }
                                        Text(text)
                                            .font(DS.Font.callout)
                                            .foregroundColor(Palette.inkSecondary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }

                        SurfaceCard(padding: DS.Space.l) {
                            VStack(alignment: .leading, spacing: DS.Space.s) {
                                Text("注意")
                                    .font(DS.Font.headline)
                                    .foregroundColor(Palette.ink)
                                Text("模型是文件夹包，必须整体拷贝，名称为 yolov8n.mlpackage。iOS 里在「文件」中点击它会像进入文件夹一样，这是正常的。")
                                    .font(DS.Font.callout)
                                    .foregroundColor(Palette.inkSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("导入模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .navigationViewStyle(.stack)
    }
}
