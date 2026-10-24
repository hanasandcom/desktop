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

    func filtersPanel(_ overview: MailOverviewEnvelope) -> some View {
        NativeGroupPanel(title: "Rules", subtitle: "\(overview.filters?.count ?? 0) filters") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Rule name", text: $model.mailFilterName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(10)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Picker("Match in", selection: $model.mailFilterField) {
                    ForEach(MailFilterPayload.CriteriaField.allCases) { field in
                        Text(field.title).tag(field)
                    }
                }
                .pickerStyle(.menu)
                TextField("Contains…", text: $model.mailFilterContains)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(10)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                TextField("Move to mailbox", text: $model.mailFilterTargetMailbox)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                    .padding(10)
                    .background(theme.field)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                Toggle("Mark read after moving", isOn: $model.mailFilterMarkRead)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                ActionButton(title: "Add rule", icon: "line.3.horizontal.decrease.circle") {
                    Task { await model.createMailFilter() }
                }
            }

            if let filters = overview.filters, !filters.isEmpty {
                ScrollView(.vertical, showsIndicators: true) {
                    LazyVStack(spacing: 8) {
                        ForEach(filters) { filter in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: filter.enabled == false ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
                                    .foregroundStyle(filter.enabled == false ? theme.textTertiary : theme.accent)
                                    .padding(.top, 2)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(filter.name)
                                        .font(.system(size: 11, weight: .black))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(2)
                                    Text(filter.ruleLabel)
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(3)
                                        .textSelection(.enabled)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Button("Delete") {
                                    Task { await model.deleteMailFilter(filter) }
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.danger)
                            }
                            .padding(9)
                            .background(theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
    }

    var mailFilterSourceMessages: [MailOverviewEnvelope.Message] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return overview?.messages ?? []
        }
        guard model.mailSearchQuery.lowercased() == query else { return [] }
        return model.mailSearchResults
    }

    var filteredMessages: [MailOverviewEnvelope.Message] {
        mailFilterSourceMessages.filter { message in
            quickFilter.matches(
                isRead: message.isRead,
                isFlagged: message.isFlagged,
                hasAttachment: message.hasAttachment == true || !(message.attachments ?? []).isEmpty
            )
        }
    }

    var quickFilterCounts: [MailQuickFilter: Int] {
        return Dictionary(uniqueKeysWithValues: MailQuickFilter.allCases.map { filter in
            let count = mailFilterSourceMessages.filter { message in
                filter.matches(
                    isRead: message.isRead,
                    isFlagged: message.isFlagged,
                    hasAttachment: message.hasAttachment == true || !(message.attachments ?? []).isEmpty
                )
            }.count
            return (filter, count)
        })
    }
}
