//
//  SiteIcon.swift
//  Drift
//
//  Thumbnails for favorites, bookmarks and history: the site's own icon (the one the page
//  declares, else its apple-touch-icon, else a favicon service), cached on disk by host.
//

import SwiftUI
import UIKit

final class SiteIconCache {
    static let shared = SiteIconCache()

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL = {
        let url = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SiteIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private func key(_ url: URL) -> String? {
        guard var host = url.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    func cached(for url: URL) -> UIImage? {
        guard let key = key(url) else { return nil }
        if let image = memory.object(forKey: key as NSString) { return image }
        if let image = UIImage(contentsOfFile: directory.appendingPathComponent(key + ".png").path) {
            memory.setObject(image, forKey: key as NSString)
            return image
        }
        return nil
    }

    func image(for url: URL, iconURL: URL?) async -> UIImage? {
        if let image = cached(for: url) { return image }
        guard let key = key(url), let host = url.host else { return nil }
        var candidates: [URL] = []
        if let iconURL { candidates.append(iconURL) }
        candidates += [
            URL(string: "https://\(host)/apple-touch-icon.png"),
            URL(string: "https://www.google.com/s2/favicons?domain=\(host)&sz=128")
        ].compactMap { $0 }
        for candidate in candidates {
            var request = URLRequest(url: candidate, timeoutInterval: 10)
            request.setValue(PageMediaResolver.userAgent, forHTTPHeaderField: "User-Agent")
            guard let result = try? await URLSession.shared.data(for: request),
                  ((result.1 as? HTTPURLResponse)?.statusCode ?? 200) == 200,
                  let image = UIImage(data: result.0), image.size.width * image.scale >= 32 else { continue }
            memory.setObject(image, forKey: key as NSString)
            if let png = image.pngData() { try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic) }
            return image
        }
        return nil
    }

    /// Replaces the cached icon (a page reported a better one).
    func store(iconURL: URL, for url: URL) {
        guard let key = key(url) else { return }
        Task {
            guard let result = try? await URLSession.shared.data(from: iconURL),
                  let image = UIImage(data: result.0), image.size.width * image.scale >= 64 else { return }
            memory.setObject(image, forKey: key as NSString)
            if let png = image.pngData() { try? png.write(to: directory.appendingPathComponent(key + ".png"), options: .atomic) }
        }
    }
}

/// A rounded site tile; shows the site's initial until its icon loads.
/// Large icons (apple-touch-icons) fill the tile; small favicons sit on white.
struct SiteIcon: View {
    let title: String
    let url: URL
    var iconURL: URL?
    var size: CGFloat = 56
    var cornerRadius: CGFloat?

    @State private var image: UIImage?

    var body: some View {
        let radius = cornerRadius ?? size * 0.24
        ZStack {
            if let image {
                if image.size.width * image.scale >= 96 {
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFill()
                } else {
                    Color.white
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.2)
                }
            } else {
                LinearGradient(colors: [Color.sS3, Color.sS2], startPoint: .top, endPoint: .bottom)
                Text(initial)
                    .font(.sDisplay(size * 0.42, .heavy))
                    .foregroundStyle(Color.sText2)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
        .task(id: url) {
            if image == nil { image = SiteIconCache.shared.cached(for: url) }
            if image == nil { image = await SiteIconCache.shared.image(for: url, iconURL: iconURL) }
        }
    }

    private var initial: String {
        let source = title.isEmpty ? (url.host ?? "?") : title
        return String(source.replacingOccurrences(of: "www.", with: "").prefix(1)).uppercased()
    }
}

// MARK: - Page snapshots

/// Snapshots of bookmarked and start-page sites, taken when you bookmark a page and refreshed
/// when you visit it again, so their tiles show the page itself.
final class PageSnapshotStore {
    static let shared = PageSnapshotStore()
    static let updated = Notification.Name("DriftPageSnapshotUpdated")

    private let memory = NSCache<NSString, UIImage>()
    private let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser/Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Host and path without "www."/"m." or a trailing slash; the query is ignored.
    func key(_ url: URL) -> String {
        var host = url.host?.lowercased() ?? ""
        for prefix in ["www.", "m.", "mobile."] where host.hasPrefix(prefix) { host.removeFirst(prefix.count) }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in (host + path).utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(value, radix: 36)
    }

    private func file(_ key: String) -> URL { directory.appendingPathComponent(key + ".jpg") }

    func image(for url: URL) -> UIImage? {
        let key = key(url)
        if let image = memory.object(forKey: key as NSString) { return image }
        guard let image = UIImage(contentsOfFile: file(key).path) else { return nil }
        memory.setObject(image, forKey: key as NSString)
        return image
    }

    func age(for url: URL) -> TimeInterval? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: file(key(url)).path)
        return (attributes?[.modificationDate] as? Date).map { Date().timeIntervalSince($0) }
    }

    func save(_ image: UIImage, for url: URL) {
        let key = key(url)
        memory.setObject(image, forKey: key as NSString)
        if let data = image.jpegData(compressionQuality: 0.72) { try? data.write(to: file(key), options: .atomic) }
        NotificationCenter.default.post(name: Self.updated, object: key)
    }
}

/// A page preview card: the page's snapshot, or its icon until one is taken.
struct PageThumbnail: View {
    let title: String
    let url: URL
    var iconURL: URL?
    var aspectRatio: CGFloat = 0.78
    var cornerRadius: CGFloat = 14

    @State private var image: UIImage?

    var body: some View {
        Color.sS2
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay(alignment: .top) {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                } else {
                    GeometryReader { proxy in
                        SiteIcon(title: title, url: url, iconURL: iconURL, size: min(56, proxy.size.width * 0.42))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
            .onAppear { image = PageSnapshotStore.shared.image(for: url) }
            .onReceive(NotificationCenter.default.publisher(for: PageSnapshotStore.updated)) { note in
                if note.object as? String == PageSnapshotStore.shared.key(url) { image = PageSnapshotStore.shared.image(for: url) }
            }
    }
}
