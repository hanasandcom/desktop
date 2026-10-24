import SwiftUI

enum SharesNativePanelLayout {
    static let stackedBreakpoint: CGFloat = 520
    static let originalColumnsBreakpoint: CGFloat = 656

    static func editorWidth(contentWidth: CGFloat) -> CGFloat {
        if contentWidth >= originalColumnsBreakpoint { return 380 }
        return min(380, max(240, (contentWidth - 16) * 0.45))
    }

    static func listWidth(contentWidth: CGFloat) -> CGFloat {
        max(0, contentWidth - 16 - editorWidth(contentWidth: contentWidth))
    }
}

extension SharesNativePanel {
    var body: some View {
        GeometryReader { geometry in
            Group {
                if geometry.size.width >= SharesNativePanelLayout.originalColumnsBreakpoint {
                    HStack(alignment: .top, spacing: 16) {
                        editorColumn.frame(width: 380)
                        shareListColumn.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if geometry.size.width >= SharesNativePanelLayout.stackedBreakpoint {
                    HStack(alignment: .top, spacing: 16) {
                        editorColumn.frame(width: SharesNativePanelLayout.editorWidth(contentWidth: geometry.size.width))
                        shareListColumn.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        editorColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                        shareListColumn.frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .alert("Delete share?", isPresented: Binding(
            get: { deletingShare != nil },
            set: { if !$0 { deletingShare = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deletingShare = nil
            }
            Button("Delete", role: .destructive) {
                if let deletingShare {
                    Task { await model.deleteNativeShare(deletingShare) }
                }
                deletingShare = nil
            }
        } message: {
            Text(deletingShare?.displayName ?? "This share will be removed.")
        }
    }

    private var editorColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeGroupPanel(title: "Create share", subtitle: "Fast native share creation") {
                TextField("Name", text: $model.shareDraftName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextEditor(text: $model.shareDraftContent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 210)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Text(model.shareDraftContent.isEmpty ? "Paste or write content." : "\(model.shareDraftContent.count) chars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    ActionButton(title: "Create", icon: "plus") {
                        Task { await model.createNativeShare() }
                    }
                    .disabled(model.isLoadingNativeDashboard)
                }
            }
            NativeGroupPanel(title: "Edit selected", subtitle: model.selectedShareID.isEmpty ? "Choose a share from the list." : model.selectedShareID) {
                TextField("Name", text: $model.shareEditName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextField("Path", text: $model.shareEditPath)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .padding(12)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                TextEditor(text: $model.shareEditContent)
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 170)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Text(model.selectedShareID.isEmpty ? "No share selected." : "\(model.shareEditContent.count) chars")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    ActionButton(title: "Save edits", icon: "checkmark") {
                        Task { await model.updateSelectedShare() }
                    }
                    .disabled(model.selectedShareID.isEmpty || model.isLoadingNativeDashboard)
                }
            }
        }
    }

    private var shareListColumn: some View {
        VStack(alignment: .leading, spacing: 12) {
            LazyVGrid(columns: summaryColumns, alignment: .leading, spacing: 12) {
                FeatureCard(title: "Shares", value: "\(model.shares.count)", icon: "folder.badge.gearshape")
                FeatureCard(title: "CDN", value: "Native", icon: "network")
            }
            HStack {
                Text(model.shares.isEmpty ? "Load or create shares from the CDN-backed workspace." : "Recent shares")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                Spacer()
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await model.loadNativeDashboardData() }
                }
            }
            if model.shares.isEmpty {
                NativeEmptyState(title: "No shares loaded", message: "Create a share or refresh the CDN-backed share list.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                    ForEach(model.shares) { share in
                        VStack(alignment: .leading, spacing: 12) {
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: share.locked == true ? "lock.fill" : "doc.text")
                                    .font(.system(size: 15, weight: .bold))
                                    .foregroundStyle(share.locked == true ? theme.danger : theme.accent)
                                    .frame(width: 34, height: 34)
                                    .background(theme.cardRaised)
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(share.displayName)
                                        .font(.system(size: 14, weight: .black))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(1)
                                    Text(share.subtitle.isEmpty ? share.id : share.subtitle)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            HStack(spacing: 8) {
                                Label(share.updatedLabel, systemImage: "clock")
                                if let wordCount = share.wordCount {
                                    Label("\(wordCount) words", systemImage: "text.word.spacing")
                                }
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(1)
                            HStack(spacing: 8) {
                                Button("Open") {
                                    model.openShare(share)
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(theme.accent)
                                Menu {
                                    Button("Edit") {
                                        model.loadShareIntoEditor(share)
                                    }
                                    Button(share.locked == true ? "Unlock" : "Lock") {
                                        Task { await model.toggleNativeShareLock(share) }
                                    }
                                    Button("Load tree") {
                                        Task { await model.loadNativeShareTree(share) }
                                    }
                                    Button("Delete", role: .destructive) {
                                        deletingShare = share
                                    }
                                } label: {
                                    Label("More", systemImage: "ellipsis")
                                        .labelStyle(.titleAndIcon)
                                }
                                .menuStyle(.borderlessButton)
                                .accessibilityLabel("More actions for \(share.displayName)")
                            }
                            HStack(spacing: 5) {
                                Text("ID")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                                Text(share.id)
                                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            if let tree = model.shareTrees[share.id], !tree.isEmpty {
                                Text(treePreview(tree))
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .foregroundStyle(theme.textTertiary)
                                    .lineLimit(8)
                                    .padding(10)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(theme.backgroundElevated.opacity(0.72))
                                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                            }
                        }
                        .padding(13)
                        .background(theme.card)
                        .overlay(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .stroke(theme.divider, lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
    }
}
