import Foundation
import XCTest
@testable import Hanasand

final class NativeCDNUploadClientTests: XCTestCase {
    @MainActor
    func testGuestUploadOmitsCredentialsCookiesAndCustomPathAndUsesServerIDURL() async throws {
        let file = try temporaryFile(bytes: Data([1, 2, 3, 4]))
        defer { try? FileManager.default.removeItem(at: file) }
        var captured: URLRequest?
        let client = try NativeCDNUploadClient(
            cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
            userID: "",
            token: "",
            send: { request in
                captured = request
                return (Data(#"{"id":"a7037045-4a5f-4ac0-b2c7-3dbb4c651bc1","path":"a7037045-4a5f-4ac0-b2c7-3dbb4c651bc1","owner":null}"#.utf8), Self.response(for: request, status: 200))
            }
        )

        let uploaded = try await client.upload(fileURL: file, name: "public photo.png", description: "A public photo", path: "private-name.png", type: "image/png")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "https://cdn.synthetic.invalid/files")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertFalse(request.httpShouldHandleCookies)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(request.value(forHTTPHeaderField: "x-cdn-upload-key"))
        let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        let multipart = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(multipart.contains("name=\"name\"\r\n\r\npublic photo.png"))
        XCTAssertTrue(multipart.contains("name=\"description\"\r\n\r\nA public photo"))
        XCTAssertTrue(multipart.contains("name=\"type\"\r\n\r\nimage/png"))
        XCTAssertFalse(multipart.contains("name=\"path\""))
        XCTAssertFalse(multipart.contains("private-name.png"))
        XCTAssertTrue(multipart.hasSuffix("--\(boundary)--\r\n"))
        XCTAssertEqual(uploaded.id, "a7037045-4a5f-4ac0-b2c7-3dbb4c651bc1")
        XCTAssertEqual(NativeCDNUploadClient.publicURL(cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!, uploaded: uploaded, preferCustomPath: false),
                       "https://cdn.synthetic.invalid/files/a7037045-4a5f-4ac0-b2c7-3dbb4c651bc1")
        XCTAssertTrue(NativeAccountRoutePanel.supports(path: "/upload"))
    }

    func testAuthenticatedUploadRetainsBearerAndCustomPathAndUsesServerPath() async throws {
        let file = try temporaryFile(bytes: Data([9, 8, 7]))
        defer { try? FileManager.default.removeItem(at: file) }
        var captured: URLRequest?
        let client = try NativeCDNUploadClient(
            cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
            userID: "user-1",
            token: "token-1",
            send: { request in
                captured = request
                return (Data(#"{"id":"server-file-2","path":"brand-logo.png","owner":"user-1"}"#.utf8), Self.response(for: request, status: 200))
            }
        )

        let uploaded = try await client.upload(fileURL: file, name: "logo.png", description: "", path: "brand-logo.png", type: "image/png")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        let multipart = try XCTUnwrap(String(data: request.httpBody ?? Data(), encoding: .utf8))
        XCTAssertTrue(multipart.contains("name=\"path\"\r\n\r\nbrand-logo.png"))
        XCTAssertEqual(NativeCDNUploadClient.publicURL(cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!, uploaded: uploaded, preferCustomPath: true),
                       "https://cdn.synthetic.invalid/files/path/brand-logo.png")
    }

    func testGuestUploadRejectsPartialCredentialsUnsafeValuesAndInvalidServerPath() async throws {
        XCTAssertThrowsError(try NativeCDNUploadClient(cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!, userID: "user-1", token: "")) {
            XCTAssertEqual($0 as? NativePublicMediaImportError, .invalidCredentials)
        }
        let file = try temporaryFile(bytes: Data([1]))
        defer { try? FileManager.default.removeItem(at: file) }
        let client = try NativeCDNUploadClient(
            cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
            userID: "",
            token: "",
            send: { request in
                (Data(#"{"id":"../bad","path":"../../private"}"#.utf8), Self.response(for: request, status: 200))
            }
        )
        do {
            _ = try await client.upload(fileURL: file, name: "file.png", description: "", path: "../private.png", type: "image/png")
            XCTFail("Unsafe custom guest path must be rejected")
        } catch {
            XCTAssertEqual(error as? NativePublicMediaImportError, .invalidUploadMetadata)
        }
        let safePathClient = try NativeCDNUploadClient(
            cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
            userID: "",
            token: "",
            send: { request in
                (Data(#"{"id":"../bad","path":"../../private"}"#.utf8), Self.response(for: request, status: 200))
            }
        )
        do {
            _ = try await safePathClient.upload(fileURL: file, name: "file.png", description: "", path: "private.png", type: "image/png")
            XCTFail("Unsafe server receipt must be rejected")
        } catch {
            XCTAssertEqual(error as? NativePublicMediaImportError, .invalidResponse)
        }
    }

    func testUploadRejectsOversizedFilesAndMalformedMetadataBeforeNetworkRequest() async throws {
        let smallFile = try temporaryFile(bytes: Data([1]))
        let oversizedFile = try temporaryFile(bytes: Data(repeating: 0, count: NativePublicMediaImportLimits.maxBytes + 1))
        defer {
            try? FileManager.default.removeItem(at: smallFile)
            try? FileManager.default.removeItem(at: oversizedFile)
        }
        var requests = 0
        let client = try NativeCDNUploadClient(
            cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
            userID: "",
            token: "",
            send: { request in
                requests += 1
                return (Data(#"{"id":"file-1","path":"file-1"}"#.utf8), Self.response(for: request, status: 200))
            }
        )

        do {
            _ = try await client.upload(fileURL: oversizedFile, name: "large.png", description: "", path: "", type: "image/png")
            XCTFail("Expected oversized file to be rejected")
        } catch {
            XCTAssertEqual(error as? NativePublicMediaImportError, .tooLarge)
        }
        do {
            _ = try await client.upload(fileURL: smallFile, name: "bad\r\nname", description: "", path: "", type: "image/png")
            XCTFail("Expected invalid metadata to be rejected")
        } catch {
            XCTAssertEqual(error as? NativePublicMediaImportError, .invalidUploadMetadata)
        }
        do {
            _ = try await client.upload(fileURL: smallFile, name: "valid.png", description: "", path: "", type: "not a mime")
            XCTFail("Expected invalid MIME type to be rejected")
        } catch {
            XCTAssertEqual(error as? NativePublicMediaImportError, .invalidUploadType)
        }
        XCTAssertEqual(requests, 0)
    }

    func testUploadMapsServiceLimitsRedirectsAndStorageFailures() async throws {
        let file = try temporaryFile(bytes: Data([1]))
        defer { try? FileManager.default.removeItem(at: file) }
        for (status, expected) in [(413, NativePublicMediaImportError.tooLarge),
                                   (429, NativePublicMediaImportError.uploadRateLimited),
                                   (507, NativePublicMediaImportError.storageFull),
                                   (503, NativePublicMediaImportError.requestFailed(503)),
                                   (302, NativePublicMediaImportError.redirectBlocked)] {
            let client = try NativeCDNUploadClient(
                cdnBaseURL: URL(string: "https://cdn.synthetic.invalid")!,
                userID: "",
                token: "",
                send: { request in (Data("{}".utf8), Self.response(for: request, status: status)) }
            )
            do {
                _ = try await client.upload(fileURL: file, name: "file.png", description: "", path: "", type: "image/png")
                XCTFail("Expected HTTP \(status) to fail")
            } catch {
                XCTAssertEqual(error as? NativePublicMediaImportError, expected, "HTTP \(status)")
            }
        }
    }

    private func temporaryFile(bytes: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("native-cdn-upload-\(UUID().uuidString).png")
        try bytes.write(to: url)
        return url
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
