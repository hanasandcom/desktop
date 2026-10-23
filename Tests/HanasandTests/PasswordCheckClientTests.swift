import Compression
import Foundation
import XCTest
@testable import Hanasand

final class PasswordCheckClientTests: XCTestCase {
    private var sha1Hash: String { "ABCDE" + String(repeating: "1", count: 35) }
    private let baseURL = URL(string: "https://api.hanasand.com/api")!

    func testNormalizesAndValidatesCompleteSHA1Hash() throws {
        XCTAssertEqual(try PasswordCheckClient.normalizeHash(" \(sha1Hash.prefix(10)) \(sha1Hash.suffix(30))\n"), sha1Hash)
        XCTAssertThrowsError(try PasswordCheckClient.normalizeHash("ABCDE"))
        XCTAssertThrowsError(try PasswordCheckClient.normalizeHash(String(repeating: "Z", count: 40)))
    }

    func testRequestSendsOnlyFiveCharacterPrefixWithoutCredentialsOrCookies() throws {
        let request = try PasswordCheckClient.request(hash: sha1Hash.lowercased(), apiBaseURL: baseURL)
        XCTAssertEqual(request.url?.path, "/api/pwned")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String], ["prefix": "ABCDE"])
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "id"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(request.httpShouldHandleCookies, false)
        XCTAssertThrowsError(try PasswordCheckClient.request(hash: sha1Hash, apiBaseURL: URL(string: "http://api.hanasand.com/api")!))
    }

    func testChecksExactMatchAndPreservesBreachFileRanges() async throws {
        let payload = try compactRange(hash: sha1Hash, catalog: ["leak.txt"], postings: [1, 0, 2, 1, 2, 5, 1])
        let result = try await PasswordCheckClient.check(hash: sha1Hash, apiBaseURL: baseURL) { request in
            XCTAssertEqual(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: String], ["prefix": "ABCDE"])
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": PasswordCheckClient.contentType])!
            return (payload, response)
        }
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.files, [PasswordCheckFile(file: "leak.txt", count: 3, lineRanges: [1...2, 7...7])])
    }

    func testReportsNoMatchAndRejectsWrongPrefixOrMalformedIndex() throws {
        let noMatch = try compactRange(hash: sha1Hash, catalog: ["leak.txt"], postings: [1, 0, 1, 1, 1])
        let otherHash = "ABCDE" + String(repeating: "F", count: 35)
        XCTAssertEqual(try PasswordCheckClient.parseCompactRange(noMatch, hash: otherHash).count, 0)

        var wrongPrefix = noMatch
        wrongPrefix.replaceSubrange(12..<16, with: littleEndian(0))
        XCTAssertThrowsError(try PasswordCheckClient.parseCompactRange(wrongPrefix, hash: sha1Hash))
        var invalidChecksum = noMatch
        invalidChecksum[invalidChecksum.count - 1] ^= 0x01
        XCTAssertThrowsError(try PasswordCheckClient.parseCompactRange(invalidChecksum, hash: sha1Hash))
        XCTAssertThrowsError(try PasswordCheckClient.parseCompactRange(Data("not-an-index".utf8), hash: sha1Hash))
    }

    func testSupportsBundledRangeFramesAndRejectsDuplicateCatalogEntries() throws {
        let matching = try compactRange(hash: sha1Hash, catalog: ["first.txt"], postings: [1, 0, 1, 1, 4])
        let empty = try compactRange(hash: sha1Hash, catalog: ["second.txt"], postings: nil)
        let bundled = bundle([matching, empty], hash: sha1Hash)
        XCTAssertEqual(try PasswordCheckClient.parseCompactRange(bundled, hash: sha1Hash).count, 4)
        XCTAssertThrowsError(try PasswordCheckClient.parseCompactRange(bundle([matching, matching], hash: sha1Hash), hash: sha1Hash))
    }

    func testRejectsResponseWithUnexpectedContentType() async {
        do {
            _ = try await PasswordCheckClient.check(hash: sha1Hash, apiBaseURL: baseURL) { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
                return (Data(), response)
            }
            XCTFail("Expected invalid content type to be rejected")
        } catch {
            XCTAssertEqual(error as? PasswordCheckError, .invalidResponse)
        }
    }

    private func compactRange(hash: String, catalog: [String], postings: [UInt8]?) throws -> Data {
        var index = Data()
        if let postings {
            append(UInt32(1), to: &index)
            let bytes = Array(hash.utf8)
            func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 55 }
            index.append(contentsOf: stride(from: 4, to: 40, by: 2).map { (nibble(bytes[$0]) << 4) | nibble(bytes[$0 + 1]) })
            append(UInt32(0), to: &index)
            append(UInt32(postings.count), to: &index)
            index.append(contentsOf: postings)
        }
        let catalogData = try JSONEncoder().encode(catalog)
        var data = Data("PWNPRF01".utf8)
        append(UInt32(catalogData.count), to: &data)
        append(UInt32(hash.prefix(5), radix: 16)!, to: &data)
        data.append(catalogData)
        if postings != nil {
            let compressed = try compress(index)
            append(UInt32(index.count), to: &data)
            data.append(compressed)
        }
        return data
    }

    private func bundle(_ frames: [Data], hash: String) -> Data {
        var data = Data("PWNPRF02".utf8)
        append(UInt32(frames.count), to: &data)
        append(UInt32(hash.prefix(5), radix: 16)!, to: &data)
        for frame in frames {
            append(UInt32(frame.count), to: &data)
            data.append(frame)
        }
        return data
    }

    private func compress(_ data: Data) throws -> Data {
        let capacity = data.count + data.count / 4 + 128
        var output = Data(count: capacity)
        let count = output.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compression_encode_buffer(
                    destination.bindMemory(to: UInt8.self).baseAddress!, capacity,
                    source.bindMemory(to: UInt8.self).baseAddress!, data.count, nil, COMPRESSION_ZLIB
                )
            }
        }
        guard count > 0 else { throw PasswordCheckError.invalidResponse }
        output.count = count
        var wrapped = Data([0x78, 0x9c])
        wrapped.append(output)
        let checksum = adler32(data)
        wrapped.append(UInt8(truncatingIfNeeded: checksum >> 24))
        wrapped.append(UInt8(truncatingIfNeeded: checksum >> 16))
        wrapped.append(UInt8(truncatingIfNeeded: checksum >> 8))
        wrapped.append(UInt8(truncatingIfNeeded: checksum))
        return wrapped
    }

    private func adler32(_ data: Data) -> UInt32 {
        var first: UInt32 = 1
        var second: UInt32 = 0
        for byte in data {
            first = (first + UInt32(byte)) % 65_521
            second = (second + first) % 65_521
        }
        return second << 16 | first
    }

    private func append(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private func littleEndian(_ value: UInt32) -> Data {
        var data = Data()
        append(value, to: &data)
        return data
    }
}
