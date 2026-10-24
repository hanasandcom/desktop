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

extension BrowserWorkspace {

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            HStack(spacing: 0) {
                browserWorkspaceRail
                    .frame(width: 250)
                Rectangle()
                    .fill(theme.divider)
                    .frame(width: 1)
                VStack(spacing: 0) {
                    destinationStrip
                    tabStrip
                    if let tab = workspace.selectedTab {
                        browserToolbar(tab)
                        agentControlPanel(tab)
                        ZStack(alignment: .top) {
                            NativeBrowserView(
                                tab: tab,
                                onOpenNativeHanasandRoute: openNativeHanasandRoute,
                                configuredWebsiteBaseURL: model.settings.websiteBaseURL
                            )
                                .background(theme.background)
                            if tab.isLoading {
                                ProgressView(value: tab.progress)
                                    .progressViewStyle(.linear)
                                    .tint(theme.accent)
                                    .frame(height: 2)
                            }
                        }
                        browserStatusBar(tab)
                    } else {
                        ContentUnavailableView("No workspace selected", systemImage: "rectangle.on.rectangle")
                    }
                }
            }
            .background(theme.background)
        }
        .background(theme.background)
        .onAppear {
            workspace.onOpenNativeRoute = openNativeDashboardRoute
            workspace.configure(settings: model.settings)
            consumeBrowserOpenRequest()
        }
        .onChange(of: model.browserOpenRequest?.id) { _, _ in
            consumeBrowserOpenRequest()
        }
        .onChange(of: workspace.selectedTab?.address ?? "") { _, address in
            guard !address.isEmpty else { return }
            model.browserActiveAddress = address
            model.browserActiveTitle = workspace.selectedTab?.title ?? model.browserActiveTitle
        }
    }

    func openNativeHanasandRoute(_ rawValue: String) -> Bool {
        guard let route = BrowserWorkspaceModel.nativeRoute(for: rawValue, configuredWebsiteBaseURL: model.settings.websiteBaseURL) else { return false }
        return openNativeDashboardRoute(route)
    }

    func openNativeDashboardRoute(_ route: BrowserNativeRoute) -> Bool {
        guard BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com\(route.path)", configuredWebsiteBaseURL: model.settings.websiteBaseURL) != nil else { return false }
        return model.openNativeHanasandRoute(route)
    }

    var browserWorkspaceRail: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Workspaces")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                Spacer()
                BrowserIconButton(systemName: "plus") {
                    workspace.createGroup()
                }
                .help("Create tab group")
                BrowserIconButton(systemName: "minus", disabled: workspace.groups.count <= 1) {
                    workspace.removeSelectedGroup()
                }
                .help("Remove selected group")
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 2) {
                    ForEach(workspace.groups) { group in
                        Button {
                            workspace.selectGroup(group.id)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: group.icon)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(group.title)
                                        .font(.system(size: 14, weight: .bold))
                                    Text("\(group.tabs.count) tabs")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(theme.textTertiary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(workspace.selectedGroupID == group.id ? theme.text : theme.textSecondary)
                            .padding(.horizontal, 12)
                            .frame(height: 48)
                            .background(workspace.selectedGroupID == group.id ? theme.sidebarSelected : Color.clear)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.bottom, 8)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 8)
        .background(theme.sidebar.opacity(0.72))
    }

    var destinationStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(workspace.selectedGroup?.destinations ?? []) { destination in
                    Button {
                        workspace.open(destination)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: destination.icon)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(destination.title)
                                    .font(.system(size: 12, weight: .bold))
                                Text(destination.subtitle)
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        .foregroundStyle(theme.text)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(theme.backgroundElevated)
    }

    var tabStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(workspace.selectedGroup?.tabs ?? []) { tab in
                        BrowserTabButton(tab: tab, selected: workspace.selectedTabID == tab.id) {
                            workspace.selectTab(tab.id)
                        } close: {
                            workspace.close(tab)
                        } moveTargets: {
                            workspace.groups.filter { $0.id != workspace.selectedGroupID }
                        } move: { groupID in
                            workspace.move(tab, to: groupID)
                        }
                        .id(tab.id)
                    }
                    Button {
                        workspace.open(url: "https://duckduckgo.com")
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .bold))
                            .frame(width: 28, height: 28)
                            .background(theme.cardRaised)
                            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
            }
            .scrollIndicators(.visible)
            .padding(.bottom, 8)
            .background(theme.backgroundElevated)
            .onAppear {
                scrollToSelectedTab(using: proxy)
            }
            .onChange(of: workspace.selectedTabID) { _, _ in
                scrollToSelectedTab(using: proxy)
            }
        }
    }

    private func scrollToSelectedTab(using proxy: ScrollViewProxy) {
        guard let selectedTabID = workspace.selectedTabID else { return }
        withAnimation(.easeInOut(duration: 0.18)) {
            proxy.scrollTo(selectedTabID, anchor: .trailing)
        }
    }
}
