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

extension IDEWorkspace {

    var terminalPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Label("Terminal", systemImage: "terminal")
                    .font(.system(size: 12, weight: .black))
                Spacer(minLength: 2)
                if model.terminal.isRunning {
                    ProgressView()
                        .scaleEffect(0.55)
                }
                Button { model.terminal.stop() } label: {
                    Image(systemName: "stop.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Stop terminal command")
                .accessibilityLabel("Stop")
                Button { model.terminal.run() } label: {
                    Image(systemName: "play.fill").frame(width: 22, height: 22)
                }
                .buttonStyle(.borderless)
                .help("Run terminal command")
                .accessibilityLabel("Run")
                Menu {
                    Section("Quick commands") {
                        ForEach(model.quickCommands) { quickCommand in
                            Button {
                                model.terminal.run(quickCommand.command)
                            } label: {
                                Label(quickCommand.title, systemImage: quickCommand.icon)
                            }
                        }
                    }
                    Section("Terminal") {
                        Button("Copy working directory") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.terminal.cwd, forType: .string)
                        }
                        Button("Reveal working directory") {
                            NSWorkspace.shared.open(URL(fileURLWithPath: model.terminal.cwd, isDirectory: true))
                        }
                        Button(terminalAutoScroll ? "Disable auto-scroll" : "Enable auto-scroll") {
                            terminalAutoScroll.toggle()
                        }
                        Button("Copy output") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(model.terminal.output, forType: .string)
                        }
                        Button("Clear output") { model.terminal.clear() }
                        Button("Previous command") { model.terminal.previousHistory() }
                        Button("Next command") { model.terminal.nextHistory() }
                    }
                } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .menuStyle(.borderlessButton)
            }
            .foregroundStyle(theme.text)
            .padding(.horizontal, 12)
            .frame(height: 34)
            .background(theme.commandBar)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.terminal.output)
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .padding(12)
                        Color.clear
                            .frame(height: 1)
                            .id("terminal-bottom")
                    }
                }
                .onChange(of: model.terminal.output) { _, _ in
                    guard terminalAutoScroll else { return }
                    proxy.scrollTo("terminal-bottom", anchor: .bottom)
                }
            }
            .background(Color.black.opacity(0.16))

            VStack(spacing: 0) {
                TextField(
                    "cwd",
                    text: Binding(
                        get: { model.terminal.cwd },
                        set: {
                            model.terminal.cwd = $0
                            model.scanProjectFiles()
                            model.persistWorkspaceState()
                        }
                    )
                )
                    .textFieldStyle(.plain)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(model.terminal.cwd)
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                HStack(spacing: 8) {
                    Text("$")
                        .font(.system(size: 12, weight: .black, design: .monospaced))
                        .foregroundStyle(theme.accent)
                    TextField(
                        "Run command",
                        text: Binding(
                            get: { model.terminal.command },
                            set: { model.terminal.command = $0 }
                        )
                    )
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(theme.text)
                        .frame(minWidth: 44, maxWidth: .infinity, alignment: .leading)
                        .onSubmit {
                            model.terminal.run()
                            model.scanProjectFiles()
                        }
                }
                .padding(.horizontal, 12)
                .frame(height: 36)
            }
            .background(theme.field)
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.divider)
                .frame(height: 1)
        }
    }

    func openLocalFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if panel.runModal() == .OK, let url = panel.url {
            model.importLocalFile(url)
        }
    }

    func exportCurrentFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = model.selectedFile?.title ?? "scratch.md"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportCurrent(to: url)
        }
    }
}
