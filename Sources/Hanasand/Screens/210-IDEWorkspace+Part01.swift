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

struct IDEWorkspaceLayoutWidths: Equatable {
    let navigator: CGFloat
    let tools: CGFloat
    let editor: CGFloat
}

enum IDEWorkspaceLayout {
    static let navigatorWidth: CGFloat = 272
    static let compactNavigatorWidth: CGFloat = 180
    static let collapsedToolsWidth: CGFloat = 40
    static let expandedToolsWidth: CGFloat = 288
    static let compactExpandedToolsWidth: CGFloat = 190
    static let editorMinimumWidth: CGFloat = 320
    static let dividerWidth: CGFloat = 1

    static var expandedLayoutBreakpoint: CGFloat {
        navigatorWidth + expandedToolsWidth + editorMinimumWidth + dividerWidth * 2
    }

    static var minimumSupportedContentWidth: CGFloat {
        compactNavigatorWidth + compactExpandedToolsWidth + editorMinimumWidth + dividerWidth * 2
    }

    static func widths(contentWidth: CGFloat, toolsExpanded: Bool) -> IDEWorkspaceLayoutWidths {
        let navigator: CGFloat
        let tools: CGFloat
        if toolsExpanded {
            let navigatorCompression = navigatorWidth - compactNavigatorWidth
            let toolsCompression = expandedToolsWidth - compactExpandedToolsWidth
            let totalCompression = navigatorCompression + toolsCompression
            let neededCompression = min(
                totalCompression,
                max(0, expandedLayoutBreakpoint - contentWidth)
            )
            navigator = navigatorWidth - neededCompression * navigatorCompression / totalCompression
            tools = expandedToolsWidth - neededCompression * toolsCompression / totalCompression
        } else {
            navigator = navigatorWidth
            tools = collapsedToolsWidth
        }
        let editor = max(0, contentWidth - navigator - tools - dividerWidth * 2)
        return IDEWorkspaceLayoutWidths(navigator: navigator, tools: tools, editor: editor)
    }
}

extension IDEWorkspace {

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            GeometryReader { geometry in
                let widths = IDEWorkspaceLayout.widths(
                    contentWidth: geometry.size.width,
                    toolsExpanded: toolsExpanded
                )

                HStack(spacing: 0) {
                    ideNavigator
                        .frame(width: widths.navigator)
                    Divider()
                        .background(theme.divider)
                    VStack(spacing: 0) {
                        ideMinimalHeader
                        editorTabStrip
                        editorPane
                    }
                    .frame(minWidth: IDEWorkspaceLayout.editorMinimumWidth)
                    Divider()
                        .background(theme.divider)
                    ideToolRail
                        .frame(width: widths.tools)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(theme.background)
        .onAppear {
            model.configure(settings: appModel.settings)
            consumeIDEOpenRequest()
        }
        .onChange(of: appModel.ideOpenRequest?.id) { _, _ in
            consumeIDEOpenRequest()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            model.saveCurrent()
        }
        .onDisappear {
            model.saveCurrent()
        }
        .confirmationDialog("Overwrite external disk changes?", isPresented: $confirmingDiskOverwrite, titleVisibility: .visible) {
            Button("Overwrite disk file", role: .destructive) {
                model.overwriteCurrentDiskFile()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces the newer disk contents with your current IDE draft.")
        }
    }

    func consumeIDEOpenRequest() {
        model.configure(settings: appModel.settings)
        guard let request = appModel.ideOpenRequest else { return }
        model.openRequest(request)
        appModel.ideOpenRequest = nil
    }

    var ideNavigator: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Files")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(theme.text)
                Text(model.projectStatus)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(1)
            }
            .padding(.top, 16)
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                TextField("Find file", text: $model.projectFileFilter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.text)
                Button {
                    model.scanProjectFiles()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(theme.field)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .padding(.horizontal, 12)
            .padding(.bottom, 10)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(model.filteredProjectFiles.prefix(90)) { file in
                        Button {
                            model.openProjectFile(file)
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: file.icon)
                                    .font(.system(size: 11, weight: .bold))
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(file.name)
                                        .font(.system(size: 11, weight: .bold))
                                        .lineLimit(1)
                                    Text(file.relativePath)
                                        .font(.system(size: 9, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .foregroundStyle(file.absolutePath == model.selectedFile?.diskPath ? theme.text : theme.textSecondary)
                            .padding(.horizontal, 9)
                            .frame(height: 34)
                            .background(file.absolutePath == model.selectedFile?.diskPath ? theme.sidebarSelected : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(file.absolutePath)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(maxHeight: .infinity)

            Divider()
                .background(theme.divider)

            gitNavigator
                .frame(height: 310)
        }
        .background(theme.sidebar.opacity(0.9))
    }
}
