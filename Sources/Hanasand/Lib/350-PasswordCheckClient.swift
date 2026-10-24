import CryptoKit
import Compression
import Foundation

enum PasswordCheckClient {
    static let maximumBundleBytes = 32 * 1024 * 1024
    static let maximumInflatedBytes = 64 * 1024 * 1024
    static let contentType = "application/vnd.hanasand.pwned-prefix"

    static func sha1Hash(for password: String) -> String {
        Insecure.SHA1.hash(data: Data(password.utf8))
            .map { String(format: "%02X", $0) }
            .joined()
    }

    static func normalizeHash(_ input: String) throws -> String {
        let hash = input.filter { !$0.isWhitespace }.uppercased()
        guard hash.range(of: "^[A-F0-9]{40}$", options: .regularExpression) != nil else {
            throw PasswordCheckError.invalidHash
        }
        return hash
    }

    static func request(hash input: String, apiBaseURL: URL) throws -> URLRequest {
        let hash = try normalizeHash(input)
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw PasswordCheckError.insecureEndpoint
        }
        var request = URLRequest(url: apiBaseURL.appendingAPIPath("pwned"), timeoutInterval: 30)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["prefix": String(hash.prefix(5))])
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/vnd.hanasand.pwned-prefix", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        return request
    }

    static func check(
        hash: String,
        apiBaseURL: URL,
        send: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) async throws -> PasswordCheckResult {
        let normalized = try normalizeHash(hash)
        let request = try request(hash: normalized, apiBaseURL: apiBaseURL)
        let data: Data
        let response: URLResponse
        if let send {
            (data, response) = try await send(request)
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpCookieAcceptPolicy = .never
            configuration.urlCache = nil
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            do { (data, response) = try await session.data(for: request) }
            catch is CancellationError { throw CancellationError() }
            catch { throw PasswordCheckError.unavailable }
        }
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https",
              http.url?.host?.lowercased() == request.url?.host?.lowercased() else {
            throw PasswordCheckError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw PasswordCheckError.httpStatus(http.statusCode) }
        guard http.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces).lowercased() == contentType,
              data.count <= maximumBundleBytes else { throw PasswordCheckError.invalidResponse }
        return try parseCompactRange(data, hash: normalized)
    }

    static func parseCompactRange(_ data: Data, hash input: String) throws -> PasswordCheckResult {
        let hash = try normalizeHash(input)
        guard data.count >= 16, data.count <= maximumBundleBytes else { throw PasswordCheckError.invalidResponse }
        let reader = ByteReader(data: data)
        let magic = try reader.string(at: 0, count: 8)
        if magic == "PWNPRF02" {
            let frames = try reader.uint32(at: 8)
            guard (2...16).contains(frames), try reader.uint32(at: 12) == hashPrefix(hash) else {
                throw PasswordCheckError.invalidResponse
            }
            var offset = 16
            var expanded = 0
            var parts: [Data] = []
            for _ in 0..<frames {
                let length = Int(try reader.uint32(at: offset))
                offset += 4
                guard length >= 16, offset <= data.count, length <= data.count - offset else {
                    throw PasswordCheckError.invalidResponse
                }
                let frame = data.subdata(in: offset..<(offset + length))
                let frameReader = ByteReader(data: frame)
                guard try frameReader.string(at: 0, count: 8) == "PWNPRF01" else { throw PasswordCheckError.invalidResponse }
                let catalogLength = Int(try frameReader.uint32(at: 8))
                let blockStart = 16 + catalogLength
                guard blockStart <= length else { throw PasswordCheckError.invalidResponse }
                if blockStart < length {
                    guard length - blockStart >= 5 else { throw PasswordCheckError.invalidResponse }
                    expanded += Int(try frameReader.uint32(at: blockStart))
                    guard expanded <= maximumInflatedBytes else { throw PasswordCheckError.invalidResponse }
                }
                parts.append(frame)
                offset += length
            }
            guard offset == data.count else { throw PasswordCheckError.invalidResponse }
            var files: [PasswordCheckFile] = []
            var seen = Set<String>()
            var total = 0
            for part in parts {
                let result = try parseSingleRange(part, hash: hash, seenFiles: &seen)
                total += result.count
                guard total >= 0 else { throw PasswordCheckError.invalidResponse }
                files.append(contentsOf: result.files)
            }
            return PasswordCheckResult(count: total, files: files)
        }
        var seenFiles = Set<String>()
        return try parseSingleRange(data, hash: hash, seenFiles: &seenFiles)
    }

    private static func parseSingleRange(_ data: Data, hash: String, seenFiles: inout Set<String>) throws -> PasswordCheckResult {
        let reader = ByteReader(data: data)
        guard data.count >= 16, data.count <= maximumInflatedBytes + 65_552,
              try reader.string(at: 0, count: 8) == "PWNPRF01" else { throw PasswordCheckError.invalidResponse }
        let catalogLength = Int(try reader.uint32(at: 8))
        guard try reader.uint32(at: 12) == hashPrefix(hash), catalogLength <= maximumInflatedBytes,
              catalogLength <= data.count - 16 else { throw PasswordCheckError.invalidResponse }
        let catalogData = data.subdata(in: 16..<(16 + catalogLength))
        let catalog: [String]
        do { catalog = try JSONDecoder().decode([String].self, from: catalogData) }
        catch { throw PasswordCheckError.invalidResponse }
        guard catalog.allSatisfy({ !$0.isEmpty && $0.count <= 1024 }),
              catalog.allSatisfy({ seenFiles.insert($0).inserted }) else { throw PasswordCheckError.invalidResponse }

        let blockStart = 16 + catalogLength
        if blockStart == data.count { return PasswordCheckResult(count: 0, files: []) }
        guard data.count - blockStart >= 5 else { throw PasswordCheckError.invalidResponse }
        let expectedLength = Int(try reader.uint32(at: blockStart))
        guard (8...maximumInflatedBytes).contains(expectedLength) else { throw PasswordCheckError.invalidResponse }
        let compressed = data.subdata(in: (blockStart + 4)..<data.count)
        guard compressed.count >= 8 else { throw PasswordCheckError.invalidResponse }
        let compressionMethod = compressed[0]
        let flags = compressed[1]
        guard compressionMethod & 0x0F == 8, compressionMethod >> 4 <= 7,
              (UInt16(compressionMethod) << 8 | UInt16(flags)) % 31 == 0,
              flags & 0x20 == 0 else { throw PasswordCheckError.invalidResponse }
        let deflate = compressed.subdata(in: 2..<(compressed.count - 4))
        guard !deflate.isEmpty else { throw PasswordCheckError.invalidResponse }
        var raw = Data(count: expectedLength + 1)
        let decodedCount = raw.withUnsafeMutableBytes { destination in
            deflate.withUnsafeBytes { source in
                guard let dest = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dest, expectedLength + 1, src, deflate.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard decodedCount == expectedLength else { throw PasswordCheckError.invalidResponse }
        raw.count = expectedLength
        let trailerStart = compressed.count - 4
        let recordedChecksum = UInt32(compressed[trailerStart]) << 24
            | UInt32(compressed[trailerStart + 1]) << 16
            | UInt32(compressed[trailerStart + 2]) << 8
            | UInt32(compressed[trailerStart + 3])
        guard adler32(raw) == recordedChecksum else { throw PasswordCheckError.invalidResponse }
        return try match(hash: hash, catalog: catalog, index: raw)
    }

    private static func match(hash: String, catalog: [String], index: Data) throws -> PasswordCheckResult {
        let reader = ByteReader(data: index)
        guard index.count >= 4 else { throw PasswordCheckError.invalidResponse }
        let entries = Int(try reader.uint32(at: 0))
        guard entries <= (index.count - 4) / 22 else { throw PasswordCheckError.invalidResponse }
        let offsetsStart = 4 + entries * 18
        let postingsStart = offsetsStart + (entries + 1) * 4
        guard postingsStart <= index.count else { throw PasswordCheckError.invalidResponse }
        let hashBytes = Array(hash.utf8)
        func nibble(_ value: UInt8) -> UInt8 { value <= 57 ? value - 48 : value - 55 }
        let suffix = stride(from: 4, to: 40, by: 2).map { Int((nibble(hashBytes[$0]) << 4) | nibble(hashBytes[$0 + 1])) }
        func compare(_ position: Int) -> Int {
            for byte in 0..<18 {
                let difference = Int(index[4 + position * 18 + byte]) - suffix[byte]
                if difference != 0 { return difference }
            }
            return 0
        }
        var low = 0
        var high = entries
        while low < high {
            let middle = (low + high) / 2
            if compare(middle) < 0 { low = middle + 1 } else { high = middle }
        }
        guard low < entries, compare(low) == 0 else { return PasswordCheckResult(count: 0, files: []) }
        let startOffset = Int(try reader.uint32(at: offsetsStart + low * 4))
        let endOffset = Int(try reader.uint32(at: offsetsStart + (low + 1) * 4))
        let start = postingsStart + startOffset
        let end = postingsStart + endOffset
        guard start >= postingsStart, start < end, end <= index.count else { throw PasswordCheckError.invalidResponse }
        var cursor = start
        func integer() throws -> Int {
            var result = 0
            for shift in stride(from: 0, through: 49, by: 7) {
                guard cursor < end else { throw PasswordCheckError.invalidResponse }
                let byte = Int(index[cursor]); cursor += 1
                let component = (byte & 127) << shift
                guard result <= Int.max - component else { throw PasswordCheckError.invalidResponse }
                result += component
                if byte < 128 { return result }
            }
            throw PasswordCheckError.invalidResponse
        }
        let groups = try integer()
        guard groups > 0, groups <= catalog.count else { throw PasswordCheckError.invalidResponse }
        var fileID = 0
        var total = 0
        var files: [PasswordCheckFile] = []
        for group in 0..<groups {
            let delta = try integer()
            guard (group == 0 || delta > 0), fileID <= Int.max - delta else { throw PasswordCheckError.invalidResponse }
            fileID += delta
            guard fileID < catalog.count else { throw PasswordCheckError.invalidResponse }
            let runs = try integer()
            guard runs > 0, runs <= (end - cursor) / 2 else { throw PasswordCheckError.invalidResponse }
            var line = 0
            var count = 0
            var ranges: [ClosedRange<Int>] = []
            for _ in 0..<runs {
                let step = try integer()
                let length = try integer()
                guard step > 0, length > 0, line <= Int.max - step else { throw PasswordCheckError.invalidResponse }
                let first = line + step
                guard first <= Int.max - (length - 1), count <= Int.max - length else { throw PasswordCheckError.invalidResponse }
                line = first + length - 1
                count += length
                ranges.append(first...line)
            }
            guard total <= Int.max - count else { throw PasswordCheckError.invalidResponse }
            total += count
            files.append(PasswordCheckFile(file: catalog[fileID], count: count, lineRanges: ranges))
        }
        guard cursor == end else { throw PasswordCheckError.invalidResponse }
        return PasswordCheckResult(count: total, files: files)
    }

    private static func hashPrefix(_ hash: String) -> UInt32 {
        UInt32(hash.prefix(5), radix: 16) ?? 0
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var first: UInt32 = 1
        var second: UInt32 = 0
        var start = 0
        while start < data.count {
            let end = min(start + 5_552, data.count)
            for index in start..<end {
                first += UInt32(data[index])
                second += first
            }
            first %= 65_521
            second %= 65_521
            start = end
        }
        return second << 16 | first
    }
}

private struct ByteReader {
    let data: Data

    func uint32(at offset: Int) throws -> UInt32 {
        guard offset >= 0, offset <= data.count - 4 else { throw PasswordCheckError.invalidResponse }
        return UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 | UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    func string(at offset: Int, count: Int) throws -> String {
        guard offset >= 0, count >= 0, offset <= data.count, count <= data.count - offset,
              let value = String(data: data.subdata(in: offset..<(offset + count)), encoding: .ascii) else {
            throw PasswordCheckError.invalidResponse
        }
        return value
    }
}
