import Foundation

enum SharedDownloadInbox {
    static let group = "group.com.dreed7896.IDownloader.live-activity"
    static let notification = "com.dreed7896.IDownloader.sharedURL"
    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("SharedLinks", isDirectory: true)
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
