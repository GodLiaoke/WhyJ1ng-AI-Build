import SwiftUI

// MARK: - Conversation history

struct ChatHistorySheet: View {
    @ObservedObject var vm: ChatViewModel
    @ObservedObject private var history = ChatHistoryStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var pendingDelete: UUID? = nil
    @State private var confirmClearAll = false

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f
    }()

    var body: some View {
        NavigationView {
            ZStack {
                Palette.canvas.ignoresSafeArea()

                if history.conversations.isEmpty {
                    VStack {
                        EmptyState(systemImage: "bubble.left.and.bubble.right",
                                   title: "还没有对话记录",
                                   message: "开始聊天后会自动保存，退出 App 也不会丢。")
                        Spacer()
                    }
                    .padding(.top, DS.Space.xxl)
                } else {
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: DS.Space.m) {
                            SectionHeader(title: "\(history.conversations.count) 个对话",
                                          systemImage: "clock.arrow.circlepath")

                            SurfaceCard(padding: DS.Space.xs) {
                                VStack(spacing: 0) {
                                    ForEach(history.conversations) { conv in
                                        row(conv)
                                        if conv.id != history.conversations.last?.id {
                                            Hairline().padding(.leading, DS.Space.m)
                                        }
                                    }
                                }
                            }

                            SecondaryButton(title: "清空全部记录",
                                            systemImage: "trash",
                                            role: .destructive) {
                                confirmClearAll = true
                            }
                            .padding(.top, DS.Space.s)

                            Color.clear.frame(height: DS.Space.xl)
                        }
                        .padding(DS.Space.l)
                    }
                }
            }
            .navigationTitle("对话记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog("删除这个对话？",
                                isPresented: Binding(get: { pendingDelete != nil },
                                                     set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if let id = pendingDelete { vm.deleteConversation(id) }
                    pendingDelete = nil
                }
                Button("取消", role: .cancel) { pendingDelete = nil }
            }
            .confirmationDialog("清空全部对话记录？",
                                isPresented: $confirmClearAll,
                                titleVisibility: .visible) {
                Button("全部删除", role: .destructive) {
                    history.deleteAll()
                    vm.startNewConversation()
                }
                Button("取消", role: .cancel) {}
            }
        }
        .navigationViewStyle(.stack)
    }

    @ViewBuilder
    private func row(_ conv: ChatConversation) -> some View {
        let isCurrent = history.currentID == conv.id

        HStack(spacing: DS.Space.m) {
            Button {
                vm.openConversation(conv.id)
                dismiss()
            } label: {
                HStack(spacing: DS.Space.m) {
                    ZStack {
                        RoundedRectangle(cornerRadius: DS.Radius.s, style: .continuous)
                            .fill(isCurrent ? Palette.accentSoft : Palette.surfaceAlt)
                            .frame(width: 34, height: 34)
                        Image(systemName: isCurrent
                              ? "bubble.left.and.text.bubble.right.fill"
                              : "bubble.left.and.text.bubble.right")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(isCurrent ? Palette.accent : Palette.inkTertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(conv.title.isEmpty ? "新对话" : conv.title)
                            .font(DS.Font.body)
                            .fontWeight(.medium)
                            .foregroundColor(Palette.ink)
                            .lineLimit(1)
                        Text(conv.summaryText)
                            .font(DS.Font.caption)
                            .foregroundColor(Palette.inkTertiary)
                            .lineLimit(1)
                        HStack(spacing: DS.Space.xs) {
                            Text(Self.formatter.string(from: conv.updatedAt))
                            Text("·")
                            Text("\(conv.messageCount) 条")
                            if !conv.modelName.isEmpty {
                                Text("·")
                                Text(conv.modelName)
                                    .lineLimit(1)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundColor(Palette.inkTertiary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button {
                pendingDelete = conv.id
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Palette.danger)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(Palette.dangerSoft))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Space.m)
    }
}
