//
//  PageMediaResolver.swift
//  Stash
//
//  Finds the downloadable video on a web page so sharing a page saves its video
//  instead of the page's HTML, and so an expired video link can be fetched again
//  from the page it came from.
//

import Foundation

enum PageMediaResolver {
    struct Result {
        var media: URL?
        var title: String?
        /// The shared URL serves a web page rather than a file.
        var isPage: Bool
    }

    static let mediaExtensions: Set<String> = ["mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "wmv", "3gp", "ts", "mpg", "mpeg", "ogv"]
    private static let fileExtensions: Set<String> = mediaExtensions.union([
        "zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar", "dmg", "ipa", "apk", "pkg", "exe", "msi", "iso", "img", "bin",
        "pdf", "epub", "cbz", "cbr", "mobi", "azw3", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "csv", "txt",
        "mp3", "m4a", "aac", "flac", "wav", "ogg", "opus", "jpg", "jpeg", "png", "gif", "webp", "heic", "torrent", "srt", "vtt"
    ])

    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"

    /// A link whose path already names a file; it can be downloaded without looking at the page.
    static func looksLikeFile(_ url: URL) -> Bool {
        fileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Fetches `page` and returns the best video on it. A URL that serves a file reports `isPage == false`.
    static func resolve(_ page: URL) async -> Result {
        var request = URLRequest(url: page, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        do {
            let (bytes, response) = try await URLSession.shared.bytes(for: request)
            let type = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            guard type.contains("html") else {
                return Result(media: nil, title: nil, isPage: false)
            }
            // Pages carry their media tags near the top; 3 MB bounds slow or endless pages.
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count >= 3_000_000 { break }
            }
            let html = String(decoding: data, as: UTF8.self)
            let base = response.url ?? page
            return Result(media: bestMedia(in: html, base: base), title: title(in: html), isPage: true)
        } catch {
            return Result(media: nil, title: nil, isPage: false)
        }
    }

    // MARK: - Parsing

    static func bestMedia(in html: String, base: URL) -> URL? {
        var candidates: [(URL, Int)] = []
        func add(_ raw: String, score: Int) {
            let cleaned = unescape(raw)
            guard !cleaned.hasPrefix("blob:"), !cleaned.hasPrefix("data:"),
                  let url = URL(string: cleaned, relativeTo: base)?.absoluteURL,
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            let ext = url.pathExtension.lowercased()
            // HLS/DASH playlists are not single files.
            guard ext != "m3u8", ext != "mpd" else { return }
            var bonus = mediaExtensions.contains(ext) ? 20 : 0
            if ext == "mp4" { bonus += 5 }
            candidates.append((url, score + bonus))
        }
        for meta in ["og:video:secure_url", "og:video:url", "og:video", "twitter:player:stream"] {
            for value in metaContents(html, key: meta) { add(value, score: 100) }
        }
        for tag in matches(html, #"<(?:video|source)\b[^>]*>"#) {
            if let src = attribute(tag, "src") { add(src, score: 90) }
            if let src = attribute(tag, "data-src") { add(src, score: 80) }
        }
        for value in matches(html, #""contentUrl"\s*:\s*"([^"]+)""#, group: 1) { add(value, score: 85) }
        let extensions = mediaExtensions.joined(separator: "|")
        for value in matches(html, #"https?:(?:\\?/){2}[^"'\s<>()]+?\.(?:"# + extensions + #")(?:\?[^"'\s<>()]*)?"#) {
            add(value, score: 40)
        }
        return candidates.max { $0.1 < $1.1 }?.0
    }

    static func title(in html: String) -> String? {
        let value = metaContents(html, key: "og:title").first ?? matches(html, #"<title[^>]*>([^<]{1,300})</title>"#, group: 1).first
        return value.map { decodeEntities($0).trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    private static func metaContents(_ html: String, key: String) -> [String] {
        matches(html, #"<meta\b[^>]*>"#).compactMap { tag -> String? in
            let name = attribute(tag, "property") ?? attribute(tag, "name") ?? attribute(tag, "itemprop")
            guard name?.lowercased() == key else { return nil }
            return attribute(tag, "content")
        }
    }

    private static func attribute(_ tag: String, _ name: String) -> String? {
        matches(tag, "\\b" + name + #"\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#, group: 1...3).first.map(decodeEntities)
    }

    private static func matches(_ text: String, _ pattern: String, group: Int = 0) -> [String] {
        matches(text, pattern, group: group...group)
    }

    /// Returns the first non-empty group in `groups` for each match.
    private static func matches(_ text: String, _ pattern: String, group groups: ClosedRange<Int>) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            for index in groups where index < match.numberOfRanges {
                if let r = Range(match.range(at: index), in: text), !r.isEmpty { return String(text[r]) }
            }
            return nil
        }
    }

    private static func unescape(_ value: String) -> String {
        decodeEntities(value)
            .replacingOccurrences(of: "\\/", with: "/")
            .replacingOccurrences(of: "\\u0026", with: "&")
            .replacingOccurrences(of: "\\u002F", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ value: String) -> String {
        value.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }
}
