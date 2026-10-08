import Foundation

enum SharedDownloadInbox {
    static let group = "group.com.dreed7896.IDownloader.live-activity"
    static let notification = "com.dreed7896.IDownloader.sharedURL"
    // Sideloading can replace the original group with a team-suffixed identifier.
    // Read the groups granted to this signed bundle instead of assuming the build-time ID.
    private static let signedGroups: [String] = {
        let metadataGroups = Bundle.main.object(forInfoDictionaryKey: "ALTAppGroups") as? [String] ?? []
        var provisionGroups: [String] = []
        if let profile = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: profile),
           let start = data.range(of: Data("<plist".utf8)),
           let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
           let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
           let entitlements = plist["Entitlements"] as? [String: Any] {
            provisionGroups = entitlements["com.apple.security.application-groups"] as? [String] ?? []
        }
        let candidates = provisionGroups + metadataGroups + [group]
        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }()

    private static var directory: URL? {
        for identifier in signedGroups {
            if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) {
                return container.appendingPathComponent("SharedLinks", isDirectory: true)
            }
        }
        return nil
    }

    static func link(in text: String) -> URL? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.contains(where: { $0.isWhitespace }),
              let url = URL(string: text), supported(url) else { return nil }
        if url.scheme?.lowercased() == "magnet" {
            let topics = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            guard topics.contains(where: { $0.name == "xt" && ($0.value?.lowercased().hasPrefix("urn:btih:") == true || $0.value?.lowercased().hasPrefix("urn:btmh:") == true) }) else { return nil }
        }
        return url
    }

    static func handoffURL(for urls: [URL] = []) -> URL {
        var components = URLComponents()
        components.scheme = "Pulled"
        components.host = "shared"
        if !urls.isEmpty { components.queryItems = urls.map { URLQueryItem(name: "url", value: $0.absoluteString) } }
        return components.url!
    }

    static func links(from handoff: URL) -> [URL] {
        (URLComponents(url: handoff, resolvingAgainstBaseURL: false)?.queryItems ?? [])
            .filter { $0.name == "url" }.compactMap { $0.value.flatMap { link(in: $0) } }
    }

    static func urls(in text: String) -> [URL] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmed), supported(url), !trimmed.contains(where: { $0.isWhitespace }) { return [url] }
        // Detectors don't recognize magnets; handle those separately in shared text.
        let magnets = trimmed.components(separatedBy: .whitespacesAndNewlines)
            .compactMap { URL(string: $0) }.filter { $0.scheme?.lowercased() == "magnet" }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let links = detector?.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
            .compactMap(\.url).filter(supported) ?? []
        var seen = Set<String>()
        return (magnets + links).filter { seen.insert($0.absoluteString).inserted }
    }

    static func supported(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "magnet" || (["http", "https"].contains(url.scheme?.lowercased()) && url.host != nil)
    }

    static func enqueue(_ urls: [URL]) throws {
        guard let directory else { throw CocoaError(.fileWriteNoPermission) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // One atomic file per share avoids a read/modify/write race between processes.
        let file = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        try JSONEncoder().encode(urls.map(\.absoluteString)).write(to: file, options: .atomic)
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(notification as CFString), nil, nil, true)
    }

    static func consume(_ process: (URL) -> Void) {
        guard let directory, let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let values = try? JSONDecoder().decode([String].self, from: data) else { continue }
            for value in values {
                if let url = URL(string: value), supported(url) { process(url) }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }
}
