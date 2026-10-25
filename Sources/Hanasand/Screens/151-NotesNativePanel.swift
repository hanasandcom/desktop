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

struct NotesNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var searchQuery = ""

    private var visibleNotes: [DashboardNote] {
        NotesSearch.filter(model.notes, query: searchQuery)
    }

    private var hasSavedLocalDraft: Bool {
        let draftID = model.selectedNoteID.isEmpty ? DashboardNoteDraftStore.newNoteID : model.selectedNoteID
        return DashboardNoteDraftStore().draft(noteID: draftID, for: model.userIDForRequests) != nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                ActionButton(title: "New note", icon: "plus") {
                    model.newNoteDraft()
                }
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(theme.textTertiary)
                    TextField("Search title or content", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("Search notes")
                }
                .padding(10)
                .background(theme.field)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                ForEach(visibleNotes) { note in
                    Button {
                        model.selectNote(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(note.title.isEmpty ? "Untitled" : note.title)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(theme.text)
                                .lineLimit(1)
                            Text(formatDateText(note.updatedAt, fallback: note.source))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                                .lineLimit(1)
                        }
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(model.selectedNoteID == note.id ? theme.sidebarSelected : theme.cardRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                if visibleNotes.isEmpty {
                    CompactInfoCard(
                        title: model.notes.isEmpty ? "No notes" : "No matching notes",
                        lines: [model.notes.isEmpty ? "Create the first shared desktop note." : "Try another title or content search."]
                    )
                }
            }
            .frame(width: 260, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 12) {
                TextField("Title", text: Binding(
                    get: { model.noteDraftTitle },
                    set: { model.updateNoteDraftTitle($0) }
                ))
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(theme.text)
                    .padding(14)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                TextEditor(text: Binding(
                    get: { model.noteDraftContent },
                    set: { model.updateNoteDraftContent($0) }
                ))
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 360)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))

                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.selectedNoteID.isEmpty ? "New note" : "Editing note")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                        if hasSavedLocalDraft {
                            Text("Draft saved on this Mac")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textTertiary)
                        }
                    }
                    Spacer()
                    if !model.selectedNoteID.isEmpty {
                        ActionButton(title: "Delete", icon: "trash", tone: .danger) {
                            Task { await model.deleteSelectedNote() }
                        }
                    }
                    ActionButton(title: "Save", icon: "checkmark") {
                        Task { await model.saveNoteDraft() }
                    }
                }
            }
        }
    }
}
