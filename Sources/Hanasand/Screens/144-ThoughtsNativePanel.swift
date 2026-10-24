import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct ThoughtsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var deletingThought: DashboardThought?
    @State private var search = ""
    @State private var sortByTitle = false
    @State private var page = 0

    private var filteredThoughts: [DashboardThought] {
        PublishingList.thoughts(model.thoughts, matching: search, order: sortByTitle ? .title : .newest)
    }
    private var pageCount: Int { PublishingList.pageCount(for: filteredThoughts.count) }
    private var currentPage: Int { min(page, pageCount - 1) }

    let columns = [
        GridItem(.adaptive(minimum: 230), spacing: 12, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                FeatureCard(title: "Thoughts", value: "\(model.thoughts.count)", icon: "brain.head.profile")
                FeatureCard(title: "Mode", value: "Native", icon: "macwindow")
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await model.loadNativeDashboardData() }
                }
            }

            NativeGroupPanel(title: "Create thought", subtitle: "Small idea, saved directly") {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $model.thoughtDraftTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 130, maxHeight: 200)
                        .background(theme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(model.thoughtMutationNeedsRefresh)
                    MarkdownPreviewView(markdown: model.thoughtDraftTitle, theme: theme)
                    ActionButton(title: "Create", icon: "plus") {
                        Task { await model.createNativeThought() }
                    }
                    .disabled(model.isLoadingNativeDashboard || model.thoughtMutationNeedsRefresh)
                }
            }

            NativeGroupPanel(title: "Edit thought", subtitle: model.selectedThoughtID.isEmpty ? "Choose a thought below." : model.selectedThoughtID) {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $model.thoughtEditTitle)
                        .font(.system(size: 14))
                        .foregroundStyle(theme.text)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 170, maxHeight: 260)
                        .background(theme.field)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .disabled(model.thoughtMutationNeedsRefresh)
                    MarkdownPreviewView(markdown: model.thoughtEditTitle, theme: theme)
                    ActionButton(title: "Save", icon: "checkmark") {
                        Task { await model.updateSelectedThought() }
                    }
                    .disabled(model.selectedThoughtID.isEmpty || model.isLoadingNativeDashboard || model.thoughtMutationNeedsRefresh)
                }
            }

            if model.thoughtMutationNeedsRefresh {
                NativeGroupPanel(title: "Thought change needs review", subtitle: "Uncertain result · no automatic retry") {
                    Text(model.thoughtMutationSafety.intent?.action == "delete"
                         ? "The server may have deleted this thought, but Desktop did not receive a confirmation. Refresh Thoughts, check whether the listed thought still exists, then acknowledge the review before another write."
                         : "The server may have saved this Markdown, but Desktop did not receive a confirmation. Refresh Thoughts, compare the displayed list with the retained submitted text, then acknowledge the review before another write.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let intent = model.thoughtMutationSafety.intent {
                        Text("Unconfirmed \(intent.action)\(intent.id.map { " · \($0)" } ?? "")")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.text)
                        if let markdown = intent.markdown {
                            ScrollView {
                                Text(markdown)
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(theme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 110)
                            .padding(9)
                            .background(theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                    }
                    ActionButton(title: "Acknowledge reviewed list and unlock", icon: "checkmark.shield") {
                        model.thoughtMutationSafety.acknowledgeReviewedRefresh()
                        model.nativeDashboardStatus = "Thought list reviewed. No save receipt was inferred."
                    }
                    .disabled(!model.thoughtMutationSafety.mayAcknowledgeReview || model.isLoadingNativeDashboard)
                    if !model.thoughtMutationSafety.mayAcknowledgeReview {
                        Text("Refresh the current Thoughts list before acknowledging.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            if model.thoughts.isEmpty {
                NativeEmptyState(title: "No thoughts loaded", message: "Create a thought or refresh the API-backed thought list.")
            } else {
                HStack(spacing: 10) {
                    TextField("Search titles or IDs", text: Binding(get: { search }, set: { search = $0; page = 0 }))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Search thought titles or IDs")
                    ActionButton(title: sortByTitle ? "Sort: title" : "Sort: newest", icon: "arrow.up.arrow.down") {
                        sortByTitle.toggle(); page = 0
                    }
                }
                Text("\(filteredThoughts.count) of \(model.thoughts.count) thoughts · page \(currentPage + 1) of \(pageCount)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                if filteredThoughts.isEmpty {
                    NativeEmptyState(title: "No matching thoughts", message: "Try another title or ID search.")
                } else {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(PublishingList.page(filteredThoughts, number: currentPage)) { thought in
                            VStack(alignment: .leading, spacing: 9) {
                                Text(thought.displayTitle)
                                    .font(.system(size: 14, weight: .black))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(3)
                                if !thought.markdownRemainder.isEmpty {
                                    MarkdownPreviewView(markdown: thought.markdownRemainder, theme: theme, compact: true)
                                }
                                HStack(spacing: 8) {
                                    Label(thought.updatedLabel, systemImage: "clock")
                                    if let creator = thought.createdBy, !creator.isEmpty {
                                        Label(creator, systemImage: "person.crop.circle")
                                    }
                                }
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                                HStack(spacing: 12) {
                                    Button("Open") {
                                        model.loadThoughtIntoEditor(thought)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.accent)
                                    .disabled(model.thoughtMutationNeedsRefresh || model.isLoadingNativeDashboard)

                                    Button("Edit") {
                                        model.loadThoughtIntoEditor(thought)
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.textSecondary)
                                    .disabled(model.thoughtMutationNeedsRefresh || model.isLoadingNativeDashboard)

                                    Button("Delete") {
                                        deletingThought = thought
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(theme.danger)
                                    .disabled(model.thoughtMutationNeedsRefresh || model.isLoadingNativeDashboard)
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
                    HStack {
                        ActionButton(title: "Previous", icon: "chevron.left") { page = max(0, currentPage - 1) }
                            .disabled(currentPage == 0)
                        Spacer()
                        ActionButton(title: "Next", icon: "chevron.right") { page = min(pageCount - 1, currentPage + 1) }
                            .disabled(currentPage >= pageCount - 1)
                    }
                }
            }
        }
        .alert("Delete thought?", isPresented: Binding(
            get: { deletingThought != nil },
            set: { if !$0 { deletingThought = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                deletingThought = nil
            }
            Button("Delete", role: .destructive) {
                if let deletingThought {
                    Task { await model.deleteSelectedThought(deletingThought) }
                }
                deletingThought = nil
            }
        } message: {
            Text(deletingThought?.displayTitle ?? "This thought will be removed.")
        }
    }
}

private struct MarkdownPreviewView: View {
    let markdown: String
    let theme: DesktopTheme
    var compact = false

    var body: some View {
        Group {
            if markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("Markdown preview appears here.")
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text((try? AttributedString(markdown: markdown)) ?? AttributedString(markdown))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(compact ? 5 : nil)
                    .textSelection(.enabled)
            }
        }
        .font(.system(size: compact ? 12 : 13))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(compact ? 0 : 10)
        .background(compact ? Color.clear : theme.card.opacity(0.65))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
