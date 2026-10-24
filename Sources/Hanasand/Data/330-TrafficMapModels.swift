import Foundation

struct TrafficMapCoordinate: Equatable {
    let latitude: Double
    let longitude: Double
}

enum TrafficMapGeography {
    static let capitalNames: [String: String] = [
        "NO": "Oslo", "GB": "London", "FR": "Paris", "DE": "Berlin", "ES": "Madrid",
        "IT": "Rome", "US": "Washington", "CA": "Ottawa", "BR": "Brasilia",
        "AR": "Buenos Aires", "JP": "Tokyo", "CN": "Beijing", "IN": "New Delhi",
        "AU": "Canberra", "ZA": "Cape Town",
    ]

    static let centroids: [String: TrafficMapCoordinate] = [
        "AD": TrafficMapCoordinate(latitude: 42.5, longitude: 1.5),
        "AE": TrafficMapCoordinate(latitude: 24.0, longitude: 54.0),
        "AF": TrafficMapCoordinate(latitude: 33.0, longitude: 65.0),
        "AG": TrafficMapCoordinate(latitude: 17.05, longitude: -61.8),
        "AI": TrafficMapCoordinate(latitude: 18.25, longitude: -63.1667),
        "AL": TrafficMapCoordinate(latitude: 41.0, longitude: 20.0),
        "AM": TrafficMapCoordinate(latitude: 40.0, longitude: 45.0),
        "AO": TrafficMapCoordinate(latitude: -12.5, longitude: 18.5),
        "AQ": TrafficMapCoordinate(latitude: -90.0, longitude: 0.0),
        "AR": TrafficMapCoordinate(latitude: -34.0, longitude: -64.0),
        "AS": TrafficMapCoordinate(latitude: -14.3333, longitude: -170.0),
        "AT": TrafficMapCoordinate(latitude: 47.3333, longitude: 13.3333),
        "AU": TrafficMapCoordinate(latitude: -27.0, longitude: 133.0),
        "AW": TrafficMapCoordinate(latitude: 12.5, longitude: -69.9667),
        "AX": TrafficMapCoordinate(latitude: 60.1167, longitude: 19.9),
        "AZ": TrafficMapCoordinate(latitude: 40.5, longitude: 47.5),
        "BA": TrafficMapCoordinate(latitude: 44.0, longitude: 18.0),
        "BB": TrafficMapCoordinate(latitude: 13.1667, longitude: -59.5333),
        "BD": TrafficMapCoordinate(latitude: 24.0, longitude: 90.0),
        "BE": TrafficMapCoordinate(latitude: 50.8333, longitude: 4.0),
        "BF": TrafficMapCoordinate(latitude: 13.0, longitude: -2.0),
        "BG": TrafficMapCoordinate(latitude: 43.0, longitude: 25.0),
        "BH": TrafficMapCoordinate(latitude: 26.0, longitude: 50.55),
        "BI": TrafficMapCoordinate(latitude: -3.5, longitude: 30.0),
        "BJ": TrafficMapCoordinate(latitude: 9.5, longitude: 2.25),
        "BL": TrafficMapCoordinate(latitude: 17.9667, longitude: -62.85),
        "BM": TrafficMapCoordinate(latitude: 32.3333, longitude: -64.75),
        "BN": TrafficMapCoordinate(latitude: 4.5, longitude: 114.6667),
        "BO": TrafficMapCoordinate(latitude: -17.0, longitude: -65.0),
        "BQ": TrafficMapCoordinate(latitude: 12.15, longitude: -68.2667),
        "BR": TrafficMapCoordinate(latitude: -10.0, longitude: -55.0),
        "BS": TrafficMapCoordinate(latitude: 24.25, longitude: -76.0),
        "BT": TrafficMapCoordinate(latitude: 27.5, longitude: 90.5),
        "BV": TrafficMapCoordinate(latitude: -54.4333, longitude: 3.4),
        "BW": TrafficMapCoordinate(latitude: -22.0, longitude: 24.0),
        "BY": TrafficMapCoordinate(latitude: 53.0, longitude: 28.0),
        "BZ": TrafficMapCoordinate(latitude: 17.25, longitude: -88.75),
        "CA": TrafficMapCoordinate(latitude: 60.0, longitude: -95.0),
        "CC": TrafficMapCoordinate(latitude: -12.5, longitude: 96.8333),
        "CD": TrafficMapCoordinate(latitude: 0.0, longitude: 25.0),
        "CF": TrafficMapCoordinate(latitude: 7.0, longitude: 21.0),
        "CG": TrafficMapCoordinate(latitude: -1.0, longitude: 15.0),
        "CH": TrafficMapCoordinate(latitude: 47.0, longitude: 8.0),
        "CI": TrafficMapCoordinate(latitude: 8.0, longitude: -5.0),
        "CK": TrafficMapCoordinate(latitude: -21.2333, longitude: -159.7667),
        "CL": TrafficMapCoordinate(latitude: -30.0, longitude: -71.0),
        "CM": TrafficMapCoordinate(latitude: 6.0, longitude: 12.0),
        "CN": TrafficMapCoordinate(latitude: 35.0, longitude: 105.0),
        "CO": TrafficMapCoordinate(latitude: 4.0, longitude: -72.0),
        "CR": TrafficMapCoordinate(latitude: 10.0, longitude: -84.0),
        "CU": TrafficMapCoordinate(latitude: 21.5, longitude: -80.0),
        "CV": TrafficMapCoordinate(latitude: 16.0, longitude: -24.0),
        "CW": TrafficMapCoordinate(latitude: 12.1167, longitude: -68.9333),
        "CX": TrafficMapCoordinate(latitude: -10.5, longitude: 105.6667),
        "CY": TrafficMapCoordinate(latitude: 35.0, longitude: 33.0),
        "CZ": TrafficMapCoordinate(latitude: 49.75, longitude: 15.5),
        "DE": TrafficMapCoordinate(latitude: 51.0, longitude: 9.0),
        "DJ": TrafficMapCoordinate(latitude: 11.5, longitude: 43.0),
        "DK": TrafficMapCoordinate(latitude: 56.0, longitude: 10.0),
        "DM": TrafficMapCoordinate(latitude: 15.4167, longitude: -61.3333),
        "DO": TrafficMapCoordinate(latitude: 19.0, longitude: -70.6667),
        "DZ": TrafficMapCoordinate(latitude: 28.0, longitude: 3.0),
        "EC": TrafficMapCoordinate(latitude: -2.0, longitude: -77.5),
        "EE": TrafficMapCoordinate(latitude: 59.0, longitude: 26.0),
        "EG": TrafficMapCoordinate(latitude: 27.0, longitude: 30.0),
        "EH": TrafficMapCoordinate(latitude: 24.5, longitude: -13.0),
        "ER": TrafficMapCoordinate(latitude: 15.0, longitude: 39.0),
        "ES": TrafficMapCoordinate(latitude: 40.0, longitude: -4.0),
        "ET": TrafficMapCoordinate(latitude: 8.0, longitude: 38.0),
        "FI": TrafficMapCoordinate(latitude: 64.0, longitude: 26.0),
        "FJ": TrafficMapCoordinate(latitude: -18.0, longitude: 175.0),
        "FK": TrafficMapCoordinate(latitude: -51.75, longitude: -59.0),
        "FM": TrafficMapCoordinate(latitude: 6.9167, longitude: 158.25),
        "FO": TrafficMapCoordinate(latitude: 62.0, longitude: -7.0),
        "FR": TrafficMapCoordinate(latitude: 46.0, longitude: 2.0),
        "GA": TrafficMapCoordinate(latitude: -1.0, longitude: 11.75),
        "GB": TrafficMapCoordinate(latitude: 54.0, longitude: -2.0),
        "GD": TrafficMapCoordinate(latitude: 12.1167, longitude: -61.6667),
        "GE": TrafficMapCoordinate(latitude: 42.0, longitude: 43.5),
        "GF": TrafficMapCoordinate(latitude: 4.0, longitude: -53.0),
        "GG": TrafficMapCoordinate(latitude: 49.4667, longitude: -2.5833),
        "GH": TrafficMapCoordinate(latitude: 8.0, longitude: -2.0),
        "GI": TrafficMapCoordinate(latitude: 36.1333, longitude: -5.35),
        "GL": TrafficMapCoordinate(latitude: 72.0, longitude: -40.0),
        "GM": TrafficMapCoordinate(latitude: 13.4667, longitude: -16.5667),
        "GN": TrafficMapCoordinate(latitude: 11.0, longitude: -10.0),
        "GP": TrafficMapCoordinate(latitude: 16.25, longitude: -61.5833),
        "GQ": TrafficMapCoordinate(latitude: 2.0, longitude: 10.0),
        "GR": TrafficMapCoordinate(latitude: 39.0, longitude: 22.0),
        "GS": TrafficMapCoordinate(latitude: -54.5, longitude: -37.0),
        "GT": TrafficMapCoordinate(latitude: 15.5, longitude: -90.25),
        "GU": TrafficMapCoordinate(latitude: 13.4667, longitude: 144.7833),
        "GW": TrafficMapCoordinate(latitude: 12.0, longitude: -15.0),
        "GY": TrafficMapCoordinate(latitude: 5.0, longitude: -59.0),
        "HK": TrafficMapCoordinate(latitude: 22.25, longitude: 114.1667),
        "HM": TrafficMapCoordinate(latitude: -53.1, longitude: 72.5167),
        "HN": TrafficMapCoordinate(latitude: 15.0, longitude: -86.5),
        "HR": TrafficMapCoordinate(latitude: 45.1667, longitude: 15.5),
        "HT": TrafficMapCoordinate(latitude: 19.0, longitude: -72.4167),
        "HU": TrafficMapCoordinate(latitude: 47.0, longitude: 20.0),
        "ID": TrafficMapCoordinate(latitude: -5.0, longitude: 120.0),
        "IE": TrafficMapCoordinate(latitude: 53.0, longitude: -8.0),
        "IL": TrafficMapCoordinate(latitude: 31.5, longitude: 34.75),
        "IM": TrafficMapCoordinate(latitude: 54.2333, longitude: -4.55),
        "IN": TrafficMapCoordinate(latitude: 20.0, longitude: 77.0),
        "IO": TrafficMapCoordinate(latitude: -6.0, longitude: 71.5),
        "IQ": TrafficMapCoordinate(latitude: 33.0, longitude: 44.0),
        "IR": TrafficMapCoordinate(latitude: 32.0, longitude: 53.0),
        "IS": TrafficMapCoordinate(latitude: 65.0, longitude: -18.0),
        "IT": TrafficMapCoordinate(latitude: 42.8333, longitude: 12.8333),
        "JE": TrafficMapCoordinate(latitude: 49.2167, longitude: -2.1333),
        "JM": TrafficMapCoordinate(latitude: 18.25, longitude: -77.5),
        "JO": TrafficMapCoordinate(latitude: 31.0, longitude: 36.0),
        "JP": TrafficMapCoordinate(latitude: 36.0, longitude: 138.0),
        "KE": TrafficMapCoordinate(latitude: 1.0, longitude: 38.0),
        "KG": TrafficMapCoordinate(latitude: 41.0, longitude: 75.0),
        "KH": TrafficMapCoordinate(latitude: 13.0, longitude: 105.0),
        "KI": TrafficMapCoordinate(latitude: 1.4167, longitude: 173.0),
        "KM": TrafficMapCoordinate(latitude: -12.1667, longitude: 44.25),
        "KN": TrafficMapCoordinate(latitude: 17.3333, longitude: -62.75),
        "KP": TrafficMapCoordinate(latitude: 40.0, longitude: 127.0),
        "KR": TrafficMapCoordinate(latitude: 37.0, longitude: 127.5),
        "KW": TrafficMapCoordinate(latitude: 29.5, longitude: 45.75),
        "KY": TrafficMapCoordinate(latitude: 19.5, longitude: -80.5),
        "KZ": TrafficMapCoordinate(latitude: 48.0, longitude: 68.0),
        "LA": TrafficMapCoordinate(latitude: 18.0, longitude: 105.0),
        "LB": TrafficMapCoordinate(latitude: 33.8333, longitude: 35.8333),
        "LC": TrafficMapCoordinate(latitude: 13.8833, longitude: -60.9667),
        "LI": TrafficMapCoordinate(latitude: 47.1667, longitude: 9.5333),
        "LK": TrafficMapCoordinate(latitude: 7.0, longitude: 81.0),
        "LR": TrafficMapCoordinate(latitude: 6.5, longitude: -9.5),
        "LS": TrafficMapCoordinate(latitude: -29.5, longitude: 28.5),
        "LT": TrafficMapCoordinate(latitude: 56.0, longitude: 24.0),
        "LU": TrafficMapCoordinate(latitude: 49.75, longitude: 6.1667),
        "LV": TrafficMapCoordinate(latitude: 57.0, longitude: 25.0),
        "LY": TrafficMapCoordinate(latitude: 25.0, longitude: 17.0),
        "MA": TrafficMapCoordinate(latitude: 32.0, longitude: -5.0),
        "MC": TrafficMapCoordinate(latitude: 43.7333, longitude: 7.4),
        "MD": TrafficMapCoordinate(latitude: 47.0, longitude: 29.0),
        "ME": TrafficMapCoordinate(latitude: 42.5, longitude: 19.3),
        "MF": TrafficMapCoordinate(latitude: 18.0833, longitude: -63.05),
        "MG": TrafficMapCoordinate(latitude: -20.0, longitude: 47.0),
        "MH": TrafficMapCoordinate(latitude: 9.0, longitude: 168.0),
        "MK": TrafficMapCoordinate(latitude: 41.8333, longitude: 22.0),
        "ML": TrafficMapCoordinate(latitude: 17.0, longitude: -4.0),
        "MM": TrafficMapCoordinate(latitude: 22.0, longitude: 98.0),
        "MN": TrafficMapCoordinate(latitude: 46.0, longitude: 105.0),
        "MO": TrafficMapCoordinate(latitude: 22.1667, longitude: 113.55),
        "MP": TrafficMapCoordinate(latitude: 15.2, longitude: 145.75),
        "MQ": TrafficMapCoordinate(latitude: 14.6667, longitude: -61.0),
        "MR": TrafficMapCoordinate(latitude: 20.0, longitude: -12.0),
        "MS": TrafficMapCoordinate(latitude: 16.75, longitude: -62.2),
        "MT": TrafficMapCoordinate(latitude: 35.8333, longitude: 14.5833),
        "MU": TrafficMapCoordinate(latitude: -20.2833, longitude: 57.55),
        "MV": TrafficMapCoordinate(latitude: 3.25, longitude: 73.0),
        "MW": TrafficMapCoordinate(latitude: -13.5, longitude: 34.0),
        "MX": TrafficMapCoordinate(latitude: 23.0, longitude: -102.0),
        "MY": TrafficMapCoordinate(latitude: 2.5, longitude: 112.5),
        "MZ": TrafficMapCoordinate(latitude: -18.25, longitude: 35.0),
        "NA": TrafficMapCoordinate(latitude: -22.0, longitude: 17.0),
        "NC": TrafficMapCoordinate(latitude: -21.5, longitude: 165.5),
        "NE": TrafficMapCoordinate(latitude: 16.0, longitude: 8.0),
        "NF": TrafficMapCoordinate(latitude: -29.0333, longitude: 167.95),
        "NG": TrafficMapCoordinate(latitude: 10.0, longitude: 8.0),
        "NI": TrafficMapCoordinate(latitude: 13.0, longitude: -85.0),
        "NL": TrafficMapCoordinate(latitude: 52.5, longitude: 5.75),
        "NO": TrafficMapCoordinate(latitude: 62.0, longitude: 10.0),
        "NP": TrafficMapCoordinate(latitude: 28.0, longitude: 84.0),
        "NR": TrafficMapCoordinate(latitude: -0.5333, longitude: 166.9167),
        "NU": TrafficMapCoordinate(latitude: -19.0333, longitude: -169.8667),
        "NZ": TrafficMapCoordinate(latitude: -41.0, longitude: 174.0),
        "OM": TrafficMapCoordinate(latitude: 21.0, longitude: 57.0),
        "PA": TrafficMapCoordinate(latitude: 9.0, longitude: -80.0),
        "PE": TrafficMapCoordinate(latitude: -10.0, longitude: -76.0),
        "PF": TrafficMapCoordinate(latitude: -15.0, longitude: -140.0),
        "PG": TrafficMapCoordinate(latitude: -6.0, longitude: 147.0),
        "PH": TrafficMapCoordinate(latitude: 13.0, longitude: 122.0),
        "PK": TrafficMapCoordinate(latitude: 30.0, longitude: 70.0),
        "PL": TrafficMapCoordinate(latitude: 52.0, longitude: 20.0),
        "PM": TrafficMapCoordinate(latitude: 46.8333, longitude: -56.3333),
        "PN": TrafficMapCoordinate(latitude: -25.0667, longitude: -130.1),
        "PR": TrafficMapCoordinate(latitude: 18.25, longitude: -66.5),
        "PS": TrafficMapCoordinate(latitude: 32.0, longitude: 35.25),
        "PT": TrafficMapCoordinate(latitude: 39.5, longitude: -8.0),
        "PW": TrafficMapCoordinate(latitude: 7.5, longitude: 134.5),
        "PY": TrafficMapCoordinate(latitude: -23.0, longitude: -58.0),
        "QA": TrafficMapCoordinate(latitude: 25.5, longitude: 51.25),
        "RE": TrafficMapCoordinate(latitude: -21.1, longitude: 55.6),
        "RO": TrafficMapCoordinate(latitude: 46.0, longitude: 25.0),
        "RS": TrafficMapCoordinate(latitude: 44.0, longitude: 21.0),
        "RU": TrafficMapCoordinate(latitude: 60.0, longitude: 100.0),
        "RW": TrafficMapCoordinate(latitude: -2.0, longitude: 30.0),
        "SA": TrafficMapCoordinate(latitude: 25.0, longitude: 45.0),
        "SB": TrafficMapCoordinate(latitude: -8.0, longitude: 159.0),
        "SC": TrafficMapCoordinate(latitude: -4.5833, longitude: 55.6667),
        "SD": TrafficMapCoordinate(latitude: 15.0, longitude: 30.0),
        "SE": TrafficMapCoordinate(latitude: 62.0, longitude: 15.0),
        "SG": TrafficMapCoordinate(latitude: 1.3667, longitude: 103.8),
        "SH": TrafficMapCoordinate(latitude: -15.9333, longitude: -5.7),
        "SI": TrafficMapCoordinate(latitude: 46.0, longitude: 15.0),
        "SJ": TrafficMapCoordinate(latitude: 78.0, longitude: 20.0),
        "SK": TrafficMapCoordinate(latitude: 48.6667, longitude: 19.5),
        "SL": TrafficMapCoordinate(latitude: 8.5, longitude: -11.5),
        "SM": TrafficMapCoordinate(latitude: 43.9333, longitude: 12.4167),
        "SN": TrafficMapCoordinate(latitude: 14.0, longitude: -14.0),
        "SO": TrafficMapCoordinate(latitude: 10.0, longitude: 49.0),
        "SR": TrafficMapCoordinate(latitude: 4.0, longitude: -56.0),
        "SS": TrafficMapCoordinate(latitude: 8.0, longitude: 30.0),
        "ST": TrafficMapCoordinate(latitude: 1.0, longitude: 7.0),
        "SV": TrafficMapCoordinate(latitude: 13.8333, longitude: -88.9167),
        "SX": TrafficMapCoordinate(latitude: 18.0333, longitude: -63.05),
        "SY": TrafficMapCoordinate(latitude: 35.0, longitude: 38.0),
        "SZ": TrafficMapCoordinate(latitude: -26.5, longitude: 31.5),
        "TC": TrafficMapCoordinate(latitude: 21.75, longitude: -71.5833),
        "TD": TrafficMapCoordinate(latitude: 15.0, longitude: 19.0),
        "TF": TrafficMapCoordinate(latitude: -43.0, longitude: 67.0),
        "TG": TrafficMapCoordinate(latitude: 8.0, longitude: 1.1667),
        "TH": TrafficMapCoordinate(latitude: 15.0, longitude: 100.0),
        "TJ": TrafficMapCoordinate(latitude: 39.0, longitude: 71.0),
        "TK": TrafficMapCoordinate(latitude: -9.0, longitude: -172.0),
        "TL": TrafficMapCoordinate(latitude: 8.8333, longitude: 125.75),
        "TM": TrafficMapCoordinate(latitude: 40.0, longitude: 60.0),
        "TN": TrafficMapCoordinate(latitude: 34.0, longitude: 9.0),
        "TO": TrafficMapCoordinate(latitude: -20.0, longitude: -175.0),
        "TR": TrafficMapCoordinate(latitude: 39.0, longitude: 35.0),
        "TT": TrafficMapCoordinate(latitude: 11.0, longitude: -61.0),
        "TV": TrafficMapCoordinate(latitude: -8.0, longitude: 178.0),
        "TW": TrafficMapCoordinate(latitude: 23.5, longitude: 121.0),
        "TZ": TrafficMapCoordinate(latitude: -6.0, longitude: 35.0),
        "UA": TrafficMapCoordinate(latitude: 49.0, longitude: 32.0),
        "UG": TrafficMapCoordinate(latitude: 1.0, longitude: 32.0),
        "UM": TrafficMapCoordinate(latitude: 19.2833, longitude: 166.6),
        "US": TrafficMapCoordinate(latitude: 38.0, longitude: -97.0),
        "UY": TrafficMapCoordinate(latitude: -33.0, longitude: -56.0),
        "UZ": TrafficMapCoordinate(latitude: 41.0, longitude: 64.0),
        "VA": TrafficMapCoordinate(latitude: 41.9, longitude: 12.45),
        "VC": TrafficMapCoordinate(latitude: 13.25, longitude: -61.2),
        "VE": TrafficMapCoordinate(latitude: 8.0, longitude: -66.0),
        "VG": TrafficMapCoordinate(latitude: 18.4333, longitude: -64.6333),
        "VI": TrafficMapCoordinate(latitude: 18.3333, longitude: -64.8333),
        "VN": TrafficMapCoordinate(latitude: 16.0, longitude: 106.0),
        "VU": TrafficMapCoordinate(latitude: -16.0, longitude: 167.0),
        "WF": TrafficMapCoordinate(latitude: -13.3, longitude: -176.2),
        "WS": TrafficMapCoordinate(latitude: -13.5833, longitude: -172.3333),
        "XK": TrafficMapCoordinate(latitude: 42.6666, longitude: 21.1666),
        "YE": TrafficMapCoordinate(latitude: 15.0, longitude: 48.0),
        "YT": TrafficMapCoordinate(latitude: -12.8333, longitude: 45.1667),
        "ZA": TrafficMapCoordinate(latitude: -29.0, longitude: 24.0),
        "ZM": TrafficMapCoordinate(latitude: -15.0, longitude: 30.0),
        "ZW": TrafficMapCoordinate(latitude: -20.0, longitude: 30.0),
    ]

    static func point(iso: String, size: CGSize) -> CGPoint? {
        guard let coordinate = centroids[iso] else { return nil }
        return CGPoint(x: (coordinate.longitude + 180) / 360 * size.width, y: (90 - coordinate.latitude) / 180 * size.height)
    }

    static func distanceFromNorwayKilometers(iso: String) -> Int? {
        guard let coordinate = centroids[iso], let norway = centroids["NO"] else { return nil }
        let radians = Double.pi / 180
        let latitudeDelta = (coordinate.latitude - norway.latitude) * radians
        let longitudeDelta = (coordinate.longitude - norway.longitude) * radians
        let a = sin(latitudeDelta / 2) * sin(latitudeDelta / 2)
            + cos(norway.latitude * radians) * cos(coordinate.latitude * radians)
            * sin(longitudeDelta / 2) * sin(longitudeDelta / 2)
        return Int((6_371 * 2 * atan2(sqrt(a), sqrt(1 - a))).rounded())
    }
}

struct TrafficMapLivePing: Identifiable, Equatable {
    let id: Int
    let iso: String
    let count: Int
    let receivedAt: Date
}

struct TrafficMapCountryLiveDelta: Equatable {
    var requestCount: Int
    var lastSeen: Date
}

enum TrafficMapLiveAggregation {
    static let expiry: TimeInterval = 5 * 60

    static func applying(
        _ batches: [TrafficMapLiveBatch],
        to current: [String: TrafficMapCountryLiveDelta],
        receivedAt: Date
    ) -> [String: TrafficMapCountryLiveDelta] {
        var next = current.filter { receivedAt.timeIntervalSince($0.value.lastSeen) < expiry }
        for batch in batches where TrafficMapGeography.centroids[batch.iso] != nil {
            let existing = next[batch.iso]?.requestCount ?? 0
            let (sum, overflow) = existing.addingReportingOverflow(batch.count)
            next[batch.iso] = TrafficMapCountryLiveDelta(requestCount: overflow ? Int.max : sum, lastSeen: receivedAt)
        }
        return next
    }
}

struct TrafficMapLiveBatch: Decodable, Equatable, Identifiable {
    let iso: String
    let count: Int
    let maxID: String
    let timestamp: String

    var id: String { iso }

    private enum CodingKeys: String, CodingKey {
        case iso, count, timestamp
        case maxID = "max_id"
    }

    func validate() throws {
        guard iso.range(of: "^[A-Z]{2}$", options: .regularExpression) != nil,
              count > 0, count <= 1000,
              maxID.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
              let numericID = UInt64(maxID), numericID <= 9_007_199_254_740_991,
              TrafficMapLiveClient.isValidTimestamp(timestamp) else {
            throw TrafficMapLiveError.invalidEvent
        }
    }
}

enum TrafficMapLiveError: LocalizedError, Equatable {
    case signInRequired
    case invalidEndpoint
    case invalidRequest
    case unauthorized
    case forbidden
    case requestFailed(Int)
    case invalidEvent
    case serverError
    case disconnected

    var isAuthorizationFailure: Bool { self == .unauthorized || self == .forbidden }

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view live traffic."
        case .invalidEndpoint: "Live traffic requires a valid HTTPS API address."
        case .invalidRequest: "Choose a valid traffic domain or cursor."
        case .unauthorized: "Sign in again to view live traffic."
        case .forbidden: "Live traffic is unavailable for this account."
        case let .requestFailed(status): "Live traffic is unavailable (HTTP \(status))."
        case .invalidEvent: "The live traffic feed returned an invalid event."
        case .serverError: "The live traffic feed reported an error."
        case .disconnected: "The live traffic connection closed."
        }
    }
}

struct TrafficMapCountry: Identifiable, Equatable {
    let iso: String
    let requestCount: Int
    let lastSeen: Date

    var id: String { iso }
    var name: String { Locale.current.localizedString(forRegionCode: iso) ?? iso }

    private init(iso: String, requestCount: Int, lastSeen: Date) {
        self.iso = iso
        self.requestCount = requestCount
        self.lastSeen = lastSeen
    }

    static func summarize(
        _ records: [TrafficRecentRecord],
        liveDeltas: [String: TrafficMapCountryLiveDelta] = [:]
    ) -> [TrafficMapCountry] {
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]

        for record in records {
            guard let iso = record.countryISO?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                  iso.count == 2, iso.allSatisfy(\.isASCII), iso.allSatisfy(\.isLetter),
                  TrafficMapGeography.centroids[iso] != nil else { continue }
            counts[iso, default: 0] += 1
            if latest[iso].map({ record.timestamp > $0 }) ?? true {
                latest[iso] = record.timestamp
            }
        }

        for (iso, delta) in liveDeltas where TrafficMapGeography.centroids[iso] != nil && delta.requestCount > 0 {
            let (sum, overflow) = (counts[iso] ?? 0).addingReportingOverflow(delta.requestCount)
            counts[iso] = overflow ? Int.max : sum
            if latest[iso].map({ delta.lastSeen > $0 }) ?? true { latest[iso] = delta.lastSeen }
        }

        return counts.compactMap { iso, count in
            guard let lastSeen = latest[iso] else { return nil }
            return TrafficMapCountry(iso: iso, requestCount: count, lastSeen: lastSeen)
        }
        .sorted { lhs, rhs in
            lhs.requestCount == rhs.requestCount ? lhs.iso < rhs.iso : lhs.requestCount > rhs.requestCount
        }
    }
}
