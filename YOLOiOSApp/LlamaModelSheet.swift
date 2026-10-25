import SwiftUI
import UniformTypeIdentifiers

// MARK: - Model selection sheet

struct LlamaModelSheet: View {
    @ObservedObject private var manager = LlamaModelManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var importError: String? = nil
    @State private var localModels: [URL] = []
    @State private var pendingDelete = false

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: DS.Space.xl) {
                        deviceCard
                        tierSection
                        actionSection
                        importSection
                        CopyrightBadge()
                        Color.clear.frame(height: DS.Space.xl)
                    }
                    .padding(DS.Space.l)
                }
            }
            .navigationTitle("对话模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: [.data],
                          allowsMultipleSelection: false) { result in
                handleImport(result)
            }
            .onAppear { localModels = manager.discoveredLocalModels() }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: Device

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "设备", systemImage: "iphone")
            SurfaceCard(padding: DS.Space.l) {
                VStack(spacing: DS.Space.m) {
                    InfoRow(label: "物理内存",
                            value: String(format: "%.0f GB", ModelCatalog.physicalMemoryGB))
                    Hairline()
                    InfoRow(label: "推荐档位", value: ModelCatalog.recommendedTier.title)
                    Hairline()
                    InfoRow(label: "可用档位",
                            value: LlamaTier.allCases
                                .filter { ModelCatalog.isSupported($0) }
                                .map(\.title)
                                .joined(separator: " · "))
                }
            }
        }
    }

    // MARK: Tiers

    private var tierSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "档位", systemImage: "square.stack.3d.up")
            VStack(spacing: DS.Space.s) {
                ForEach(LlamaTier.allCases) { tier in
                    TierRow(tier: tier,
                            spec: ModelCatalog.spec(for: tier),
                            selected: manager.tier == tier,
                            supported: ModelCatalog.isSupported(tier),
                            isCurrent: manager.tier == tier,
                            state: manager.tier == tier ? manager.state : nil) {
                        Task { await manager.select(tier: tier) }
                    }
                }
            }
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "当前档位", systemImage: "wrench.and.screwdriver")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    InfoRow(label: "模型", value: manager.spec.displayName)
                    Hairline()
                    InfoRow(label: "体积", value: manager.spec.sizeText)
                    Hairline()
                    InfoRow(label: "状态", value: manager.state.label)
                    if !manager.statusLine.isEmpty {
                        Hairline()
                        InfoRow(label: "详情", value: manager.statusLine)
                    }

                    if manager.state == .downloading {
                        VStack(alignment: .leading, spacing: 6) {
                            ProgressView(value: manager.downloadProgress)
                                .tint(Palette.accent)
                            HStack(spacing: DS.Space.s) {
                                Text(String(format: "%.0f%%", manager.downloadProgress * 100))
                                    .font(DS.Font.mono)
                                    .foregroundColor(Palette.accent)
                                Text("·").foregroundColor(Palette.inkTertiary)
                                Text(manager.downloadSpeedText)
                                    .font(DS.Font.mono)
                                    .foregroundColor(Palette.inkSecondary)
                                Text("·").foregroundColor(Palette.inkTertiary)
                                Text("剩余 \(manager.downloadETAText)")
                                    .font(DS.Font.mono)
                                    .foregroundColor(Palette.inkSecondary)
                                Spacer(minLength: 0)
                            }
                            Text(manager.downloadProgressText)
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                        }
                    }

                    VStack(spacing: DS.Space.s) {
                        if manager.spec.isDownloaded {
                            PrimaryButton(title: manager.state == .ready ? "重新加载" : "加载到内存",
                                          systemImage: "bolt.fill") {
                                Task { await manager.ensureLoaded() }
                            }
                            SecondaryButton(title: "从内存卸载",
                                            systemImage: "eject") {
                                Task { await manager.unload() }
                            }
                            SecondaryButton(title: "删除模型文件",
                                            systemImage: "trash",
                                            role: .destructive) {
                                pendingDelete = true
                            }
                        } else if manager.state == .downloading {
                            SecondaryButton(title: "暂停下载",
                                            systemImage: "pause.fill") {
                                manager.pauseDownload()
                            }
                        } else if manager.hasPartialDownload {
                            // A partial file survived an interrupt, so offer to
                            // continue rather than starting over.
                            PrimaryButton(title: "继续下载（断点续传）",
                                          systemImage: "arrow.down.circle") {
                                manager.resumeDownload()
                            }
                            SecondaryButton(title: "放弃并重新开始",
                                            systemImage: "trash",
                                            role: .destructive) {
                                manager.cancelDownload()
                            }
                            Text("已下载 \(manager.downloadProgressText)，进度已保留。")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.success)
                                .fixedSize(horizontal: false, vertical: true)
                        } else {
                            PrimaryButton(title: "下载（\(manager.spec.sizeText)）",
                                          systemImage: "arrow.down.circle") {
                                manager.download()
                            }
                            Text("支持断点续传：中断后再次进入会从上次的位置继续。下载走 hf-mirror 国内镜像，失败会自动切备用源。")
                                .font(DS.Font.caption)
                                .foregroundColor(Palette.inkTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    Hairline()

                    ToggleRow(title: "进后台后自动卸载",
                              subtitle: "iOS 不会在挂起后执行定时器，所以改为进入后台立即释放。返回 App 时会自动重新加载（几秒）。开启可显著降低被系统回收的概率。",
                              isOn: $manager.autoUnloadOnBackground)
                }
            }
        }
        .confirmationDialog("删除 \(manager.spec.displayName)？",
                            isPresented: $pendingDelete,
                            titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                Task { await manager.deleteModel() }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: Import

    private var importSection: some View {
        VStack(alignment: .leading, spacing: DS.Space.m) {
            SectionHeader(title: "从文件导入 GGUF", systemImage: "folder")

            SurfaceCard(padding: DS.Space.l) {
                VStack(alignment: .leading, spacing: DS.Space.m) {
                    Text("任意 GGUF 都可以导入。也可以把 .gguf 直接放进「文件」App → 我的 iPhone → \(AppBrand.filesFolder) → LLMModels，然后在这里选。")
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkTertiary)
                        .fixedSize(horizontal: false, vertical: true)

                    SecondaryButton(title: "从「文件」选择 .gguf",
                                    systemImage: "doc.badge.plus") {
                        showImporter = true
                    }

                    if let importError {
                        Text(importError)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !localModels.isEmpty {
                        Hairline()
                        Text("已发现的本地文件")
                            .font(DS.Font.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(Palette.inkSecondary)
                        ForEach(localModels, id: \.path) { url in
                            localModelRow(url)
                        }
                    }
                }
            }
        }
    }

    // MARK: Local model row
    //
    // An imported file is not one of the three catalog tiers, so it previously
    // showed up with no way to actually use it. Each file now has its own
    // "use this model" action.

    @ViewBuilder
    private func localModelRow(_ url: URL) -> some View {
        let isActive = CustomModelStore.shared.activeURL?.path == url.path

        VStack(alignment: .leading, spacing: DS.Space.s) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "doc")
                    .font(.system(size: 13))
                    .foregroundColor(isActive ? Palette.success : Palette.accent)
                VStack(alignment: .leading, spacing: 1) {
                    Text(url.lastPathComponent)
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(Self.sizeText(for: url))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Palette.inkTertiary)
                }
                Spacer(minLength: 0)
                if isActive {
                    Text("使用中")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Palette.success)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Palette.successSoft))
                }
            }

            HStack(spacing: DS.Space.s) {
                if !isActive {
                    SecondaryButton(title: "使用这个模型",
                                    systemImage: "play.circle") {
                        Task { await CustomModelStore.shared.activate(url) }
                    }
                } else {
                    SecondaryButton(title: "释放内存",
                                    systemImage: "eject") {
                        Task { await CustomModelStore.shared.deactivate() }
                    }
                }
            }
        }
        .padding(.vertical, DS.Space.s)
    }

    // MARK: Logic

    private func handleImport(_ result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                try manager.importFile(from: url)
                localModels = manager.discoveredLocalModels()
            } catch {
                importError = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            importError = error.localizedDescription
        }
    }

    private static func sizeText(for url: URL) -> String {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        if bytes > 1_073_741_824 {
            return String(format: "%.2f GB", Double(bytes) / 1_073_741_824.0)
        }
        return String(format: "%.0f MB", Double(bytes) / 1_048_576.0)
    }
}

// MARK: - Tier row

private struct TierRow: View {
    let tier: LlamaTier
    let spec: LlamaModelSpec
    let selected: Bool
    let supported: Bool
    let isCurrent: Bool
    let state: ModelState?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: DS.Space.m) {
                ZStack {
                    Circle()
                        .stroke(selected ? Palette.accent : Palette.border, lineWidth: 1.6)
                        .frame(width: 18, height: 18)
                    if selected {
                        Circle().fill(Palette.accent).frame(width: 9, height: 9)
                    }
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: DS.Space.s) {
                        Text(tier.title)
                            .font(DS.Font.body)
                            .fontWeight(.semibold)
                            .foregroundColor(supported ? Palette.ink : Palette.inkTertiary)
                        if tier == ModelCatalog.recommendedTier {
                            Text("推荐")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(Palette.accent)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Palette.accentSoft))
                        }
                        Spacer(minLength: 0)
                        if let state, isCurrent {
                            Text(state.label)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundColor(stateColor(state))
                        }
                    }

                    Text(spec.displayName)
                        .font(DS.Font.caption)
                        .foregroundColor(Palette.inkSecondary)
                        .lineLimit(1)

                    HStack(spacing: DS.Space.xs) {
                        Text(spec.sizeText)
                        Text("·")
                        Text(spec.note)
                        if !supported {
                            Text("·")
                            Text("内存不足")
                                .foregroundColor(Palette.warning)
                        }
                        if spec.isDownloaded {
                            Text("·")
                            Text("已下载")
                                .foregroundColor(Palette.success)
                        }
                    }
                    .font(DS.Font.caption)
                    .foregroundColor(Palette.inkTertiary)
                }
            }
            .padding(DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .fill(selected ? Palette.accentSoft : Palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.Radius.m, style: .continuous)
                    .stroke(selected ? Palette.accent.opacity(0.35) : Palette.separator, lineWidth: 1)
            )
            .opacity(supported ? 1 : 0.6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!supported)
    }

    private func stateColor(_ s: ModelState) -> Color {
        switch s {
        case .ready: return Palette.success
        case .absent: return Palette.inkTertiary
        case .paused: return Palette.warning
        case .failed: return Palette.danger
        case .loading, .downloading: return Palette.accent
        }
    }
}
