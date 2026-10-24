import Foundation
import XCTest
@testable import Hanasand

private actor ExposureActivityFixtureTransport {
    private var responses: [(Data, Int)]
    private var captured: [URLRequest] = []

    init(_ responses: [(Data, Int)]) { self.responses = responses }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        captured.append(request)
        let fixture = responses.isEmpty ? (Data("{}".utf8), 200) : responses.removeFirst()
        return (fixture.0, HTTPURLResponse(url: request.url!, statusCode: fixture.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func requests() -> [URLRequest] { captured }
}

final class PublicExposureActivityTests: XCTestCase {
    private let first = Data(#"{"generatedAt":"2026-10-24T10:00:00Z","status":"live","counts":{"visible":1,"total":2,"needsReview":1,"metadataOnly":0},"freshness":{"latestClaimAt":"2026-10-24T09:00:00Z","ageMinutes":60},"page":{"limit":1,"offset":0,"total":2,"nextOffset":1,"hasMore":true},"items":[{"id":"one","actor":"Example actor","company":"Acme%20Inc","claimedData":"emails","claimedDataSize":"2 GB","country":"NO","claimTime":"2026-10-24T09:00:00Z","collectedAt":"2026-10-24T09:10:00Z","status":"unverified","confidence":0.7,"sourceName":"Public report"}]}"#.utf8)
    private let second = Data(#"{"generatedAt":"2026-10-24T10:00:00Z","status":"live","counts":{"total":2},"page":{"limit":1,"offset":1,"total":2,"nextOffset":null,"hasMore":false},"items":[{"id":"two","actor":"Other actor","company":"Beta","claimedData":"documents","claimedDataSize":"unknown"}]}"#.utf8)

    func testClientBuildsAllSupportedFilterParametersAndDecodesPage() async throws {
        let transport = ExposureActivityFixtureTransport([(first, 200)])
        let client = PublicExposureActivityClient(send: { request in try await transport.send(request) })
        let filters = PublicExposureActivityFilters(q: "leak report", company: "Acme Inc", actor: "Example actor", category: "finance", size: "large", country: "NO", from: "2026-10-01", to: "2026-10-24")

        let page = try await client.load(filters: filters, offset: 5, limit: 20)

        XCTAssertEqual(page.status, "live")
        XCTAssertEqual(page.items.first?.company, "Acme Inc")
        XCTAssertEqual(page.items.first?.actor, "Example actor")
        XCTAssertEqual(page.items.first?.confidence, 0.7)
        XCTAssertEqual(page.nextOffset, 1)
        let capturedRequests = await transport.requests()
        let request = try XCTUnwrap(capturedRequests.first)
        XCTAssertEqual(request.url?.host, "hanasand.com")
        XCTAssertEqual(request.url?.path, "/api/public/exposure-queue")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "limit", value: "20"), URLQueryItem(name: "offset", value: "5"),
            URLQueryItem(name: "q", value: "leak report"), URLQueryItem(name: "company", value: "Acme Inc"),
            URLQueryItem(name: "actor", value: "Example actor"), URLQueryItem(name: "category", value: "finance"),
            URLQueryItem(name: "size", value: "large"), URLQueryItem(name: "country", value: "NO"),
            URLQueryItem(name: "from", value: "2026-10-01"), URLQueryItem(name: "to", value: "2026-10-24"),
        ])
    }

    func testPaginationLoadsNextOffsetAndDeduplicatesItems() async throws {
        let transport = ExposureActivityFixtureTransport([(first, 200), (second, 200)])
        let client = PublicExposureActivityClient(send: { request in try await transport.send(request) })
        let model = await MainActor.run { PublicExposureActivityViewModel(client: client) }

        await model.refresh(filters: PublicExposureActivityFilters())
        await model.loadMore(filters: PublicExposureActivityFilters())

        let items = await model.items
        let nextOffset = await model.nextOffset
        let requests = await transport.requests()
        XCTAssertEqual(items.map(\.id), ["one", "two"])
        XCTAssertNil(nextOffset)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(requests.last?.url), resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "offset" })?.value, "1")

        let merged = PublicExposureActivityPage.Item.merge(items, [try XCTUnwrap(items.first)], appending: true)
        XCTAssertEqual(merged.map(\.id), ["one", "two"])
    }

    func testEmptyPayloadAndHttpErrorAreDistinguishable() async throws {
        let empty = Data(#"{"status":"empty","items":[],"page":{"limit":50,"offset":0,"total":0,"hasMore":false}}"#.utf8)
        let emptyClient = PublicExposureActivityClient(send: { request in
            (empty, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        let emptyPage = try await emptyClient.load(filters: PublicExposureActivityFilters())
        XCTAssertTrue(emptyPage.items.isEmpty)

        let failed = PublicExposureActivityClient(send: { request in
            (Data("{}".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: nil, headerFields: nil)!)
        })
        do {
            _ = try await failed.load(filters: PublicExposureActivityFilters())
            XCTFail("Expected HTTP status failure")
        } catch let error as PublicExposureActivityClient.ClientError {
            XCTAssertEqual(error.errorDescription, "The public activity service returned HTTP 503.")
        }
    }

    func testQueryBoundsAndEmptyFilters() {
        XCTAssertEqual(PublicExposureActivityFilters().queryItems(limit: 1000, offset: -10), [
            URLQueryItem(name: "limit", value: "100"), URLQueryItem(name: "offset", value: "0"),
        ])
    }
}
