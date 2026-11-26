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

/// A square site thumbnail; shows the site's initial until its icon loads.
struct SiteIcon: View {
    let title: String
    let url: URL
    var iconURL: URL?
    var size: CGFloat = 56

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Color.white
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(image.size.width * image.scale >= 120 ? 0 : size * 0.18)
            } else {
                Color.sS2
                Text(initial)
                    .font(.sDisplay(size * 0.42, .heavy))
                    .foregroundStyle(Color.sMint)
            }
        }
        .frame(width: size, height: size)
        .clipped()
        .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
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
