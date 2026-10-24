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

struct AIModelsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme

    var body: some View {
        AIMetricsNativeContent(model: model, settings: model.settings, theme: theme)
    }
}

private struct AIMetricsNativeContent: View {
    @ObservedObject var model: DesktopAgentModel
    @StateObject private var metrics: AIMetricsClient
    let settings: HanasandDesktopSettings
    let theme: DesktopTheme
    @State private var draft = ""
    private let columns = [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)]
    init(model: DesktopAgentModel, settings: HanasandDesktopSettings, theme: DesktopTheme) {
        self.model = model; self.settings = settings; self.theme = theme
        _metrics = StateObject(wrappedValue: AIMetricsClient(settings: settings))
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack { Text("AI operations").font(.system(size: 21, weight: .bold)); Spacer(); Button("Refresh") { metrics.refresh(manual: true) }.disabled(metrics.state.loading || metrics.promptPhase == .connecting || metrics.promptPhase == .running) }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    metricCard("Live clients", "\(metrics.state.clients.count)", "\(metrics.state.liveState) · \(metrics.state.participants.map(String.init) ?? "—") viewers")
                    metricCard("Typical first output", metric(metrics.state.economics?.firstOutputP50, suffix: " ms"), "P95 \(metric(metrics.state.economics?.firstOutputP95, suffix: " ms")) · \(metric(metrics.state.economics?.sampleCount, suffix: " runs", decimals: 0))")
                    metricCard("GPU energy", metric(totalWatts, suffix: " W"), "Reported monthly \(metric(totalKWh, suffix: " kWh"))")
                }
                if !metrics.state.errors.isEmpty { ForEach(Array(metrics.state.errors.enumerated()), id: \.offset) { _, error in NativeNotice(message: error, title: "AI telemetry") } }
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(metrics.state.clients) { client in clientCard(client) }
                }
                economicsCard
                containersCard
                promptCard
            }
            .padding(.vertical, 10)
        }
        .onAppear { metrics.start() }
        .onDisappear { metrics.stop() }
        .onChange(of: settings) { _, newValue in metrics.update(settings: newValue) }
    }
    private var totalWatts: Double? { sum(metrics.state.clients.map(\.watts)) }
    private var totalKWh: Double? { sum(metrics.state.clients.map(\.monthlyKwh)) }
    private func sum(_ values: [Double?]) -> Double? { guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }; return values.compactMap { $0 }.reduce(0, +) }
    private func metric(_ value: Double?, suffix: String = "", decimals: Int = 1) -> String { value.map { String(format: "%.*f%@", decimals, $0, suffix) } ?? "Unavailable" }
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View { VStack(alignment: .leading, spacing: 10, content: content).padding(14).frame(maxWidth: .infinity, alignment: .leading).background(theme.card).clipShape(RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.divider, lineWidth: 1)) }
    private func metricCard(_ title: String, _ value: String, _ detail: String) -> some View { card { Text(title).font(.caption).foregroundStyle(theme.textTertiary); Text(value).font(.system(size: 22, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8); Text(detail).font(.caption).foregroundStyle(theme.textSecondary).lineLimit(3).fixedSize(horizontal: false, vertical: true) } }
    private func clientCard(_ client: AIMetricClient) -> some View {
        card {
            HStack { Image(systemName: "cpu").foregroundStyle(theme.accent); VStack(alignment: .leading) { Text(client.displayName.isEmpty ? client.name : client.displayName).font(.headline).lineLimit(2).fixedSize(horizontal: false, vertical: true); Text(client.model.status ?? "Connected").font(.caption).foregroundStyle(theme.textTertiary) }; Spacer(minLength: 0) }
            Text("\(client.modelId) · \(client.profile)").font(.caption).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), spacing: 8)], spacing: 8) {
                MiniMetricCard(label: "TPS", value: metric(client.model.tps)); MiniMetricCard(label: "Tokens", value: "\(client.model.generatedTokens ?? 0)"); MiniMetricCard(label: "Context", value: "\(client.model.contextTokens ?? 0) / \(client.model.contextMaxTokens ?? 0)")
            }
            if let error = client.model.lastError, !error.isEmpty { NativeNotice(message: error, title: "Last model error") }
            ForEach(Array([("RAM", client.ram), ("CPU", client.cpu), ("GPU", client.gpu)].enumerated()), id: \.offset) { _, row in
                if let sensors = row.1 { Text("\(row.0): " + sensors.map { "\($0.name) \(metric($0.load.map { $0 * 100 }, suffix: "%", decimals: 0)) · \(metric($0.temperatureC, suffix: "°C"))" }.joined(separator: "  ·  ")).font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true) }
            }
            if let lanes = client.lanes { ForEach(lanes) { lane in Text("\(lane.label) · \(lane.model.isEmpty ? lane.gpuName : lane.model)\n\(metric(lane.active, suffix: " active", decimals: 0)) · \(metric(lane.queued, suffix: " queued", decimals: 0)) · \(metric(lane.watts, suffix: " W"))").font(.caption).lineLimit(3).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(8).background(theme.accentSoft).clipShape(RoundedRectangle(cornerRadius: 8)) } }
            Button(metrics.selectedClient == client.name ? "Selected for prompt test" : "Select for prompt test") { metrics.select(client.name) }.disabled(metrics.promptPhase == .connecting || metrics.promptPhase == .running || metrics.promptPhase == .uncertain)
        }
    }
    private var economicsCard: some View { card {
        Text("30-day reliability and queue").font(.headline)
        if let economics = metrics.state.economics {
            Text("Window: \(metric(economics.windowDays, suffix: " days", decimals: 0)) · first useful output P50 \(metric(economics.firstOutputP50, suffix: " ms")) / P95 \(metric(economics.firstOutputP95, suffix: " ms")) · samples \(metric(economics.sampleCount, decimals: 0))").font(.caption).fixedSize(horizontal: false, vertical: true)
            let activeRows = economics.queue.filter { ["queued", "running"].contains($0.status.lowercased()) }
            if activeRows.isEmpty { Text("No queued or running work.").font(.caption).foregroundStyle(theme.textTertiary) }
            ForEach(activeRows) { row in Text("\(row.status) · \(row.count.map { String(format: "%.0f", $0) } ?? "Unavailable") · \(row.lane) · \(row.model) · \(row.kind)").font(.caption).lineLimit(4).fixedSize(horizontal: false, vertical: true) }
        } else { Text("Response timing and queue data unavailable. Other telemetry remains visible.").font(.caption) }
    } }
    private var containersCard: some View { card {
        Text("AI container health").font(.headline)
        if let data = metrics.state.containers {
            if !data.unavailable.isEmpty { Text(data.unavailable).font(.caption) }
            if data.items.isEmpty { Text("No matching AI containers reported.").font(.caption).foregroundStyle(theme.textTertiary) }
            ForEach(data.items) { item in Text("\(item.name) · \(item.health.isEmpty ? "Unknown" : item.health)\n\(item.image)\n\(item.status)").font(.caption).lineLimit(4).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        } else { Text("Container health unavailable. Refresh to retry.").font(.caption) }
    } }
    private var promptCard: some View { card {
        Text("Selected-client prompt test").font(.headline)
        Text(metrics.selectedClient.isEmpty ? "Select a live client above. Tests use that model directly and never enter AI Chat." : "Target: \(metrics.selectedClient)").font(.caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        TextField("Prompt (up to 8,000 characters)", text: $draft, axis: .vertical).lineLimit(3...7).textFieldStyle(.roundedBorder).disabled(!settings.impersonatingUserID.isEmpty || !settings.impersonationToken.isEmpty || metrics.promptPhase == .uncertain || metrics.promptPhase == .connecting || metrics.promptPhase == .running)
        HStack { Button("Test selected model") { if metrics.send(draft) { draft = "" } }.disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || metrics.selectedClient.isEmpty || !settings.impersonatingUserID.isEmpty || !settings.impersonationToken.isEmpty || metrics.promptPhase == .uncertain || metrics.promptPhase == .connecting || metrics.promptPhase == .running); if metrics.promptPhase == .connecting || metrics.promptPhase == .running { Button("Stop") { metrics.cancelPrompt() } } }
        if !metrics.promptError.isEmpty { NativeNotice(message: metrics.promptError, title: metrics.promptPhase == .uncertain ? "Review required" : "Prompt test") }
        if !metrics.promptOutput.isEmpty { Text(metrics.promptOutput).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(10).background(theme.accentSoft).clipShape(RoundedRectangle(cornerRadius: 8)) }
        if metrics.promptPhase == .uncertain { Text("Refresh all telemetry successfully to clear this review gate. A sent prompt is never retried automatically.").font(.caption).foregroundStyle(theme.textTertiary) }
    } }
}
