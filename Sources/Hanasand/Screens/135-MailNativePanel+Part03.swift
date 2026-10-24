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

extension MailNativePanel {

    func threadedMessageList(_ overview: MailOverviewEnvelope) -> some View {
        NativeGroupPanel(title: "Messages", subtitle: "\(filteredMessages.count) visible · \(threadCount) threads") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(MailQuickFilter.allCases) { filter in
                        let selected = quickFilter == filter
                        Button {
                            quickFilter = filter
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: filter.symbol)
                                Text(filter.title)
                                Text("\(quickFilterCounts[filter, default: 0])")
                                    .monospacedDigit()
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(selected ? theme.accent : theme.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 30)
                            .background(selected ? theme.accentSoft : theme.cardRaised)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(selected ? theme.accent.opacity(0.35) : theme.divider, lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 1)
            }

            LazyVGrid(columns: mailToolbarActionColumns, alignment: .leading, spacing: 8) {
                mailToolbarActionButton(title: "All", icon: "checkmark.circle") {
                    model.selectAllVisibleMailMessages(filteredMessages)
                }
                mailToolbarActionButton(title: "Clear", icon: "xmark.circle") {
                    model.clearMailSelection()
                }
                mailToolbarActionButton(title: "Archive", icon: "archivebox") {
                    Task { await model.runBulkMailAction("archive") }
                }
                mailToolbarActionButton(title: "Read", icon: "envelope.open") {
                    Task { await model.runBulkMailAction("read") }
                }
                mailToolbarActionButton(title: "Unread", icon: "envelope.badge") {
                    Task { await model.runBulkMailAction("unread") }
                }
                mailToolbarActionButton(title: "Trash", icon: "trash", tone: .danger) {
                    Task { await model.runBulkMailAction("trash") }
                }
            }

            if !model.mailSearchError.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.danger)
                    Text(model.mailSearchError)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    if !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button("Retry") { Task { await model.searchMail(searchText) } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .bold))
                    }
                }
                .padding(10)
                .background(theme.danger.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }

            if filteredMessages.isEmpty {
                if model.mailSearchPending {
                    NativeEmptyState(title: "Searching mailbox", message: "Looking for messages in this folder.")
                } else if model.mailSearchError.isEmpty {
                    NativeEmptyState(title: searchText.isEmpty ? "No messages" : "No matching mail", message: searchText.isEmpty ? "This folder is empty." : "Try another mailbox or search term.")
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(filteredMessages.prefix(120)) { message in
                                messageRow(message)
                                    .id(message.id)
                            }
                        }
                    }
                    .frame(minHeight: 470)
                    .onChange(of: model.selectedMailMessageID) { _, id in
                        withAnimation(.easeInOut(duration: 0.18)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }

            if model.mailSearchCursor != nil {
                ActionButton(title: model.mailSearchPending ? "Loading…" : "Load more results", icon: "arrow.down.circle") {
                    guard let cursor = model.mailSearchCursor else { return }
                    Task { await model.searchMail(searchText, after: cursor) }
                }
                .disabled(model.mailSearchPending)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    var threadCount: Int {
        Set(filteredMessages.map { $0.threadId ?? $0.id }).count
    }

    func messageRow(_ message: MailOverviewEnvelope.Message) -> some View {
        let isSelected = message.id == selectedMessage?.id
        let isChecked = model.selectedMailMessageIDs.contains(message.id)
        return Button {
            Task { await model.selectMailMessage(message) }
        } label: {
            HStack(alignment: .top, spacing: 9) {
                Button {
                    model.toggleMailSelection(message)
                } label: {
                    Image(systemName: isChecked ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isChecked ? theme.accent : theme.textTertiary)
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(message.isRead == true ? theme.textTertiary.opacity(0.35) : theme.accent)
                            .frame(width: 7, height: 7)
                        Text(message.fromLabel)
                            .font(.system(size: 12, weight: .black))
                            .foregroundStyle(theme.text)
                            .lineLimit(1)
                        if message.hasAttachment == true || !(message.attachments ?? []).isEmpty {
                            Image(systemName: "paperclip")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.textTertiary)
                        }
                        if message.isFlagged == true {
                            Image(systemName: "flag.fill")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.accent)
                        }
                        Spacer()
                        Text(message.dateLabel)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(theme.textTertiary)
                    }
                    Text(message.subjectLabel)
                        .font(.system(size: 13, weight: message.isRead == true ? .semibold : .black))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                    Text(message.preview ?? "")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(11)
            .background(isSelected ? theme.accentSoft : (isChecked ? theme.card.opacity(0.95) : theme.cardRaised))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? theme.accent.opacity(0.55) : Color.clear, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(message.isRead == true ? "Mark unread" : "Mark read") {
                Task { await model.runMailAction(message.isRead == true ? "unread" : "read", message: message) }
            }
            Button(message.isFlagged == true ? "Unflag" : "Flag") {
                Task { await model.runMailAction(message.isFlagged == true ? "unflag" : "flag", message: message) }
            }
            Button("Archive") {
                Task { await model.runMailAction("archive", message: message) }
            }
            Button(message.isJunk == true ? "Not spam" : "Spam") {
                Task { await model.runMailAction(message.isJunk == true ? "ham" : "junk", message: message) }
            }
            if message.isDeleted == true {
                Button("Restore") {
                    Task { await model.runMailAction("restore", message: message) }
                }
            }
            Button("Move to trash") {
                Task { await model.runMailAction("trash", message: message) }
            }
        }
    }
}
