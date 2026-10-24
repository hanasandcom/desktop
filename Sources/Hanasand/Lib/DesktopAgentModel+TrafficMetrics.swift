import Foundation

extension DesktopAgentModel {

    func loadHanasandTrafficMetrics(loadID: UUID) async {
        isLoadingNativeDashboard = true
        nativeDashboardStatus = "Loading traffic metrics"
        defer {
            if nativeDashboardLoadID == loadID {
                isLoadingNativeDashboard = false
            }
        }

        do {
            let domain = selectedNativeDashboardQuery["domain"] ?? ""
            let url = try TrafficRecentClient.metricsURL(
                apiBaseURL: settings.apiBaseURL.normalizedBaseURL,
                domain: domain
            )
            let request = try TrafficRecentClient.request(
                url: url,
                userID: userIDForRequests,
                authToken: authTokenForRequests,
                impersonationToken: settings.impersonationToken,
                timeoutInterval: 60
            )
            let metrics = try TrafficMetricSnapshot.decode(await TrafficRecentClient.fetch(request))
            guard !Task.isCancelled, nativeDashboardLoadID == loadID, selectedDashboardPath == "/traffic" else { return }

            let topDomains = metrics.topDomains.prefix(10).map {
                DashboardTrafficMetrics.Metric(key: $0.key, count: $0.count)
            }
            trafficMetrics = DashboardTrafficMetrics(
                totalRequests: metrics.totalRequests,
                avgRequestTime: metrics.averageRequestTime,
                errorRate: metrics.errorRate,
                topDomains: Array(topDomains)
            )
            nativeDashboardStatus = "Loaded traffic metrics"
            nativeDashboardPayload = trafficPayload(total: metrics.totalRequests, domains: Array(topDomains))
        } catch {
            guard !Task.isCancelled, nativeDashboardLoadID == loadID, selectedDashboardPath == "/traffic" else { return }
            nativeDashboardStatus = error.localizedDescription
            nativeDashboardPayload = "Could not load Hanasand traffic metrics: \(error.localizedDescription)"
        }
    }

    func trafficPayload(total: Int, domains: [DashboardTrafficMetrics.Metric]) -> String {
        let lines = domains.map { "  { \"key\": \"\($0.key)\", \"count\": \($0.count) }" }.joined(separator: ",\n")
        return """
        {
          "source": "Hanasand",
          "total_requests": \(total),
          "top_domains": [
        \(lines)
          ]
        }
        """
    }
}
