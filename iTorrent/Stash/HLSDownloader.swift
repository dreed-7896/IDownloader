//
//  HLSDownloader.swift
//  Drift
//
//  Turns an HLS stream into one file: picks the best variant, lists its segments (with byte
//  ranges, fMP4 init sections and AES-128 keys) and decrypts each segment as it arrives.
//  MPEG-TS streams save as .ts, fMP4 streams as .mp4.
//

import CommonCrypto
import Foundation

enum HLSDownloader {
    struct Key {
        var url: URL
        var iv: Data?
    }

    struct Part {
        var url: URL
        var range: ClosedRange<Int64>?
        var key: Key?
        var sequence: Int
    }

    struct Plan {
        var parts: [Part]
        var fragmented: Bool
    }

    struct Variant {
        var url: URL
        var bandwidth: Int
        var resolution: String?
    }

    enum Failure: LocalizedError {
        case http(Int)
        case notPlaylist
        case empty
        case unsupportedEncryption(String)

        var errorDescription: String? {
            switch self {
            case .http(let status): return "Server returned HTTP \(status)."
            case .notPlaylist: return "The stream playlist could not be read."
            case .empty: return "The stream has no segments."
            case .unsupportedEncryption(let method): return "This stream is protected (\(method)) and cannot be saved."
            }
        }
    }

    static func isPlaylist(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "m3u8" || url.path.lowercased().hasSuffix(".m3u8")
    }

    static func fileName(title: String?, url: URL, fragmented: Bool) -> String {
        var base = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if base.isEmpty { base = url.deletingPathExtension().lastPathComponent }
        if base.isEmpty || base == "/" || base.lowercased() == "index" || base.lowercased() == "master" || base.lowercased() == "playlist" {
            base = url.host.map { "Video from \($0)" } ?? "Video"
        }
        base = base.components(separatedBy: CharacterSet(charactersIn: "/\\:?%*|\"<>").union(.controlCharacters)).joined(separator: " ")
        while base.count > 120 { base.removeLast() }
        return base + (fragmented ? ".mp4" : ".ts")
    }

    // MARK: - Network

    static func fetch(_ url: URL, headers: [String: String], range: ClosedRange<Int64>? = nil) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        if let range { request.setValue("bytes=\(range.lowerBound)-\(range.upperBound)", forHTTPHeaderField: "Range") }
        var lastError: Error = URLError(.unknown)
        let retryable: Set<Int> = [408, 429, 500, 502, 503, 504]
        for attempt in 0..<3 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200...299).contains(status) else { throw Failure.http(status) }
                return data
            } catch let error as Failure {
                if case .http(let status) = error, !retryable.contains(status) { throw error }
                lastError = error
            } catch {
                if Task.isCancelled { throw CancellationError() }
                lastError = error
            }
            if attempt < 2 { try await Task.sleep(nanoseconds: UInt64(attempt + 1) * 1_000_000_000) }
        }
        throw lastError
    }

    static func text(_ url: URL, headers: [String: String]) async throws -> (String, URL) {
        let data = try await fetch(url, headers: headers)
        guard let text = String(data: data, encoding: .utf8), text.contains("#EXT") else { throw Failure.notPlaylist }
        return (text, url)
    }

    // MARK: - Playlists

    /// Variants of a master playlist, best first. Empty for a media playlist.
    static func variants(in text: String, base: URL) -> [Variant] {
        var result: [Variant] = []
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        for (index, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            let attributes = attributes(line)
            guard let uri = lines[(index + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
            result.append(Variant(url: url, bandwidth: Int(attributes["BANDWIDTH"] ?? "") ?? 0, resolution: attributes["RESOLUTION"]))
        }
        return result.sorted { $0.bandwidth > $1.bandwidth }
    }

    static func plan(for url: URL, headers: [String: String]) async throws -> Plan {
        var playlist = try await text(url, headers: headers)
        if let best = variants(in: playlist.0, base: playlist.1).first {
            playlist = try await text(best.url, headers: headers)
        }
        return try mediaPlan(playlist.0, base: playlist.1)
    }

    static func mediaPlan(_ text: String, base: URL) throws -> Plan {
        var parts: [Part] = []
        var sequence = 0
        var key: Key?
        var pendingRange: (Int64, Int64?)?
        var lastEnd: [URL: Int64] = [:]
        var mapURI: String?
        var fragmented = false
        var expectSegment = false

        func range(for url: URL, _ value: (Int64, Int64?)?) -> ClosedRange<Int64>? {
            guard let value else { return nil }
            let start = value.1 ?? lastEnd[url] ?? 0
            lastEnd[url] = start + value.0
            return start...(start + value.0 - 1)
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                sequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = attributes(line)
                let method = attributes["METHOD"] ?? "NONE"
                switch method {
                case "NONE": key = nil
                case "AES-128":
                    guard let uri = attributes["URI"], let url = URL(string: uri, relativeTo: base)?.absoluteURL else { key = nil; break }
                    key = Key(url: url, iv: attributes["IV"].flatMap(hexData))
                default: throw Failure.unsupportedEncryption(method)
                }
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attributes = attributes(line)
                guard let uri = attributes["URI"], uri != mapURI, let url = URL(string: uri, relativeTo: base)?.absoluteURL else { continue }
                if mapURI != nil { continue } // A second init section would corrupt the joined file.
                mapURI = uri
                fragmented = true
                let byteRange = attributes["BYTERANGE"].flatMap(parseRange)
                parts.append(Part(url: url, range: range(for: url, byteRange), key: nil, sequence: sequence))
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXTINF") {
                expectSegment = true
            } else if !line.hasPrefix("#"), expectSegment {
                expectSegment = false
                guard let url = URL(string: line, relativeTo: base)?.absoluteURL else { continue }
                if url.pathExtension.lowercased() == "m4s" || url.pathExtension.lowercased() == "mp4" { fragmented = fragmented || mapURI != nil }
                parts.append(Part(url: url, range: range(for: url, pendingRange), key: key, sequence: sequence))
                pendingRange = nil
                sequence += 1
            }
        }
        guard parts.count > (mapURI == nil ? 0 : 1) else { throw Failure.empty }
        return Plan(parts: parts, fragmented: fragmented)
    }

    private static func parseRange(_ value: String) -> (Int64, Int64?)? {
        let fields = value.split(separator: "@")
        guard let length = fields.first.flatMap({ Int64($0) }) else { return nil }
        return (length, fields.count > 1 ? Int64(fields[1]) : nil)
    }

    static func attributes(_ line: String) -> [String: String] {
        guard let colon = line.firstIndex(of: ":") else { return [:] }
        var result: [String: String] = [:]
        var key = "", value = "", readingKey = true, quoted = false
        for character in line[line.index(after: colon)...] {
            if readingKey {
                if character == "=" { readingKey = false } else if character != "," { key.append(character) }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                result[key.trimmingCharacters(in: .whitespaces).uppercased()] = value
                key = ""; value = ""; readingKey = true
            } else {
                value.append(character)
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces).uppercased()] = value }
        return result
    }

    // MARK: - AES-128

    static func iv(sequence: Int) -> Data {
        var data = Data(count: 16)
        var value = UInt64(max(0, sequence)).bigEndian
        withUnsafeBytes(of: &value) { data.replaceSubrange(8..<16, with: $0) }
        return data
    }

    private static func hexData(_ value: String) -> Data? {
        var hex = value.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        while hex.count < 32 { hex = "0" + hex }
        var data = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        return data.count == 16 ? data : nil
    }

    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128 else { throw Failure.unsupportedEncryption("key size") }
        var output = Data(count: data.count + kCCBlockSizeAES128)
        var written = 0
        let outputCount = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count, ivBytes.baseAddress,
                                input.baseAddress, data.count, out.baseAddress, outputCount, &written)
                    }
                }
            }
        }
        guard Int(status) == kCCSuccess else { throw Failure.unsupportedEncryption("AES-128 decrypt failed") }
        output.removeSubrange(written..<output.count)
        return output
    }
}
