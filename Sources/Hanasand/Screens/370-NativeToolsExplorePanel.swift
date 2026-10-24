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

struct NativeToolsExplorePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var searchText = ""
    @State private var collapsedSections: Set<String> = []

    private var sections: [NativeToolsSection] {
        NativeToolsCatalog.sections(
            dashboard: model.dashboardActions,
            administration: model.adminActions,
            query: searchText
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SearchFieldRow(placeholder: "Find a tool", text: $searchText)
                .accessibilityLabel("Search tools")

            if sections.isEmpty {
                NativeEmptyState(title: "No matching tools", message: "Try another name or search term.")
            } else {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(sections) { section in
                        sectionPanel(section)
                    }
                }
            }
        }
    }

    private func sectionPanel(_ section: NativeToolsSection) -> some View {
        let isExpanded = searchText.isEmpty ? !collapsedSections.contains(section.id) : true

        return NativeGroupPanel(title: section.title, subtitle: "\(section.actions.count) tools") {
            Button {
                if isExpanded {
                    collapsedSections.insert(section.id)
                } else {
                    collapsedSections.remove(section.id)
                }
            } label: {
                HStack {
                    Text(isExpanded ? "Hide tools" : "Show tools")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                    Spacer()
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .foregroundStyle(theme.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(isExpanded ? "Collapse" : "Expand") \(section.title)")

            if isExpanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(section.actions, id: \.title) { action in
                        Button {
                            action.perform(with: model)
                        } label: {
                            HStack(alignment: .top, spacing: 11) {
                                Image(systemName: action.icon)
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(theme.accent)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(action.title)
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundStyle(theme.text)
                                        .lineLimit(2)
                                        .fixedSize(horizontal: false, vertical: true)
                                    Text(action.subtitle)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(theme.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: action.trailingIcon)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                            .padding(11)
                            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
                            .background(theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Opens \(action.title)")
                    }
                }
            }
        }
    }
}
