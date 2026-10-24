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
    @State private var isConfirmingDelete = false

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
                if model.noteSaveConflict {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(model.noteConflictServerNote == nil ? "This note was deleted on the website." : "This note has a newer website version.")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(theme.danger)
                        Text("Your local draft is preserved. Review the website version or save your draft as a separate note.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                        if let serverNote = model.noteConflictServerNote {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Website version · \(serverNote.title.isEmpty ? "Untitled" : serverNote.title)")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(theme.text)
                                ScrollView {
                                    Text(serverNote.content.isEmpty ? "(Empty note)" : serverNote.content)
                                        .font(.system(size: 11))
                                        .foregroundStyle(theme.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                                .frame(maxHeight: 120)
                            }
                            .padding(9)
                            .background(theme.field)
                            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                        }
                        HStack {
                            if model.noteConflictServerNote != nil {
                                ActionButton(title: "Use website version", icon: "arrow.uturn.backward") {
                                    model.useWebsiteNoteVersion()
                                }
                            }
                            ActionButton(title: "Save draft as new note", icon: "doc.badge.plus") {
                                Task { await model.saveNoteConflictAsNewNote() }
                            }
                        }
                    }
                    .padding(12)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
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
                            isConfirmingDelete = true
                        }
                    }
                    ActionButton(title: "Save", icon: "checkmark") {
                        Task { await model.saveNoteDraft() }
                    }
                    .disabled(model.noteSaveConflict)
                }
            }
        }
        .alert("Delete this note?", isPresented: $isConfirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task { await model.deleteSelectedNote() }
            }
        } message: {
            Text("This permanently deletes the shared note. Any unsaved local draft for it will also be removed.")
        }
    }
}
