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

struct DashboardRecentTest: Decodable, Identifiable {
    let id: String
    let url: String
    let timeout: Int?
    let status: String
    let logs: [String]?
    let errors: [String]?
    let createdAt: String?
    let finishedAt: String?
    let exitCode: Int?
    let visits: Int?
    let summary: JSONValue?
    let latestRunSummary: JSONValue?
    let previousRunSummary: JSONValue?
    let latestRunNumber: Int?
    let p95DeltaMs: Double?

    var createdLabel: String {
        formatDateText(createdAt, fallback: "No timestamp")
    }

    var finishedLabel: String {
        formatDateText(finishedAt, fallback: finishedAt == nil ? "Not finished" : "No timestamp")
    }

    var statusLabel: String {
        status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "unknown" : status
    }

    var displayURL: String {
        url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No URL" : url
    }

    var activeSummary: JSONValue? {
        latestRunSummary ?? summary
    }

    var reportSummary: DashboardLoadTestSummary? {
        DashboardLoadTestSummary(value: activeSummary)
    }

    var previousReportSummary: DashboardLoadTestSummary? {
        DashboardLoadTestSummary(value: previousRunSummary)
    }

    var requestCount: Int? {
        activeSummary?.numberValue(for: ["requests"]).map(Int.init)
    }

    var p95Milliseconds: Double? {
        activeSummary?.numberValue(for: ["duration", "p95"])
    }

    var failureRatePercent: Double? {
        activeSummary?.numberValue(for: ["failureRate"]).map { $0 * 100 }
    }

    var p95DeltaLabel: String? {
        guard let p95DeltaMs, p95DeltaMs != 0 else { return nil }
        return "\(p95DeltaMs >= 0 ? "faster" : "slower") \(Int(abs(p95DeltaMs).rounded()))ms"
    }

    enum CodingKeys: String, CodingKey {
        case id
        case url
        case timeout
        case status
        case logs
        case errors
        case createdAt = "created_at"
        case finishedAt = "finished_at"
        case exitCode = "exit_code"
        case visits
        case summary
        case latestRunSummary = "latest_run_summary"
        case previousRunSummary = "previous_run_summary"
        case latestRunNumber = "latest_run_number"
        case p95DeltaMs = "p95_delta_ms"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? container.decode(String.self, forKey: .id) {
            id = stringID
        } else if let intID = try? container.decode(Int.self, forKey: .id) {
            id = String(intID)
        } else {
            id = UUID().uuidString
        }
        url = (try? container.decode(String.self, forKey: .url)) ?? ""
        timeout = try? container.decode(Int.self, forKey: .timeout)
        status = (try? container.decode(String.self, forKey: .status)) ?? "unknown"
        logs = try? container.decode([String].self, forKey: .logs)
        errors = try? container.decode([String].self, forKey: .errors)
        createdAt = try? container.decode(String.self, forKey: .createdAt)
        finishedAt = try? container.decode(String.self, forKey: .finishedAt)
        exitCode = try? container.decode(Int.self, forKey: .exitCode)
        visits = try? container.decode(Int.self, forKey: .visits)
        summary = try? container.decode(JSONValue.self, forKey: .summary)
        latestRunSummary = try? container.decode(JSONValue.self, forKey: .latestRunSummary)
        previousRunSummary = try? container.decode(JSONValue.self, forKey: .previousRunSummary)
        latestRunNumber = try? container.decode(Int.self, forKey: .latestRunNumber)
        p95DeltaMs = try? container.decode(Double.self, forKey: .p95DeltaMs)
    }
}

struct DashboardLoadTestMetricPoint: Equatable, Identifiable {
    let index: Int
    let time: String
    let values: [String: Double]

    var id: Int { index }
}

struct DashboardLoadTestMetricSeries: Equatable, Identifiable {
    let name: String
    let points: [DashboardLoadTestMetricPoint]

    var id: String { name }

    var title: String {
        switch name {
        case "rps": "Requests per second"
        case "latency": "Latency · milliseconds"
        case "errors": "Errors over time"
        default: name.capitalized
        }
    }

    var metricKeys: [String] {
        switch name {
        case "rps": ["value"]
        case "latency": ["p50", "p95"]
        case "errors": ["count"]
        default: []
        }
    }

    func metricLabel(for key: String) -> String {
        switch (name, key) {
        case ("rps", "value"): "Requests / sec"
        case ("latency", "p50"): "p50"
        case ("latency", "p95"): "p95"
        case ("errors", "count"): "Errors"
        default: key
        }
    }
}

struct DashboardLoadTestSummary {
    let requests: Int?
    let checks: Int?
    let failures: Int?
    let failureRate: Double?
    let durations: [(String, Double)]
    let series: [DashboardLoadTestMetricSeries]

    var hasTimeSeries: Bool { series.contains { !$0.points.isEmpty } }

    func duration(_ key: String) -> Double? {
        durations.first { $0.0 == key }?.1
    }

    init?(value: JSONValue?) {
        guard case .object(let object) = value else { return nil }
        requests = Self.integer(object["requests"])
        checks = Self.integer(object["checks"])
        failures = Self.integer(object["failures"])
        if let rawRate = object["failureRate"]?.numberValue(for: []) , rawRate.isFinite, (0...1).contains(rawRate) {
            failureRate = rawRate
        } else {
            failureRate = nil
        }
        if case .object(let durationObject) = object["duration"] {
            durations = durationObject.keys.sorted().compactMap { key in
                guard let value = durationObject[key]?.numberValue(for: []), value.isFinite, value >= 0 else { return nil }
                return (key, value)
            }
        } else {
            durations = []
        }
        series = ["rps", "latency", "errors"].compactMap { name in
            guard case .array(let rawPoints) = object[name] else { return nil }
            let keys: [String] = name == "latency" ? ["p50", "p95"] : name == "rps" ? ["value"] : ["count"]
            let points = rawPoints.prefix(300).enumerated().compactMap { index, rawPoint -> DashboardLoadTestMetricPoint? in
                guard case .object(let point) = rawPoint,
                      let time = Self.text(point["time"]) else { return nil }
                let values = Dictionary(uniqueKeysWithValues: keys.compactMap { key -> (String, Double)? in
                    guard let number = point[key]?.numberValue(for: []), number.isFinite, number >= 0 else { return nil }
                    return (key, number)
                })
                guard !values.isEmpty else { return nil }
                return DashboardLoadTestMetricPoint(index: index, time: time, values: values)
            }
            return points.isEmpty ? nil : DashboardLoadTestMetricSeries(name: name, points: points)
        }
    }

    private static func integer(_ value: JSONValue?) -> Int? {
        guard let number = value?.numberValue(for: []), number.isFinite, number >= 0, number <= Double(Int.max) else { return nil }
        return Int(number)
    }

    private static func text(_ value: JSONValue?) -> String? {
        switch value {
        case .string(let text): String(text.prefix(100))
        case .number(let number) where number.isFinite: String(number)
        default: nil
        }
    }
}
