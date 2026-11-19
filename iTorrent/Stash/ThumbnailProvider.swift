//
//  ThumbnailProvider.swift
//  Stash
//
//  Thumbnails for files and videos. Videos first try the system QuickLook thumbnail (the one
//  Files and Photos show) and any embedded cover art, then pick a bright, non-black frame
//  from inside the video instead of the first frame, which is often black or a fade-in.
//

import AVFoundation
import QuickLookThumbnailing
import UIKit
import UniformTypeIdentifiers

final class ThumbnailProvider: @unchecked Sendable {
    static let shared = ThumbnailProvider()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()
    /// Limits concurrent decoding so scrolling a large gallery cannot exhaust memory.
    private let semaphore = AsyncSemaphore(limit: 3)

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "avi", "webm", "flv", "wmv", "ts", "mts", "m2ts", "vob", "ogv", "mpeg", "mpg", "3gp"]

    static func isVideo(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return videoExtensions.contains(ext) || UTType(filenameExtension: ext)?.conforms(to: .movie) == true
    }

    private func key(_ url: URL, _ size: CGSize) -> NSString {
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stamp = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
        return "\(url.standardizedFileURL.path)|\(stamp)|\(values?.fileSize ?? 0)|\(Int(size.width))x\(Int(size.height))" as NSString
    }

    func cached(for url: URL, size: CGSize) -> UIImage? {
        cache.object(forKey: key(url, size))
    }

    /// A thumbnail at least `size` points large, or nil when the file has none.
    func thumbnail(for url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let cacheKey = key(url, size)
        if let image = cache.object(forKey: cacheKey) { return image }
        await semaphore.wait()
        defer { Task { await semaphore.signal() } }
        if Task.isCancelled { return nil }
        if let image = cache.object(forKey: cacheKey) { return image }

        let pixels = CGSize(width: size.width * scale, height: size.height * scale)
        var image: UIImage?
        if Self.isVideo(url) {
            image = await artwork(url)
            if image == nil, let quickLook = await quickLook(url, size: size, scale: scale), !Self.isMostlyDark(quickLook) {
                image = quickLook
            }
            if image == nil { image = await bestFrame(url, pixels: pixels) }
            if image == nil { image = await quickLook(url, size: size, scale: scale) }
        } else {
            image = await quickLook(url, size: size, scale: scale)
        }
        if let image {
            let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
            cache.setObject(image, forKey: cacheKey, cost: cost)
        }
        return image
    }

    // MARK: - Sources

    private func quickLook(_ url: URL, size: CGSize, scale: CGFloat) async -> UIImage? {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: size, scale: scale, representationTypes: .thumbnail)
        return await withCheckedContinuation { continuation in
            QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
                continuation.resume(returning: representation?.uiImage)
            }
        }
    }

    /// Cover art embedded in the file (common for downloaded shows and music videos).
    private func artwork(_ url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let metadata = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: metadata, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), let image = UIImage(data: data) { return image }
        }
        return nil
    }

    /// Samples frames through the video and keeps the first one that is neither black nor flat.
    private func bestFrame(_ url: URL, pixels: CGSize) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: max(320, pixels.width), height: max(320, pixels.height))
        let tolerance = CMTime(seconds: 1.5, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let seconds = duration.seconds
        // Skip intros and fades; very short clips sample from the middle.
        let fractions: [Double] = seconds < 8 ? [0.5, 0.3, 0.7] : [0.12, 0.25, 0.4, 0.55, 0.08]
        var fallback: (CGImage, Double)?
        for fraction in fractions {
            if Task.isCancelled { return nil }
            let time = CMTime(seconds: max(0.5, seconds * fraction), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image else { continue }
            let stats = Self.luminance(image)
            if stats.mean > 0.12, stats.deviation > 0.06 { return UIImage(cgImage: image) }
            let score = stats.mean + stats.deviation
            if fallback == nil || score > fallback!.1 { fallback = (image, score) }
        }
        if let fallback { return UIImage(cgImage: fallback.0) }
        // Some files report no seekable frames inside; the first frame is better than nothing.
        return (try? await generator.image(at: .zero).image).map { UIImage(cgImage: $0) }
    }

    // MARK: - Image analysis

    static func isMostlyDark(_ image: UIImage) -> Bool {
        guard let cgImage = image.cgImage else { return false }
        let stats = luminance(cgImage)
        return stats.mean < 0.08 || stats.deviation < 0.03
    }

    /// Mean and standard deviation of luminance (0...1) over a 24×24 downsample.
    static func luminance(_ image: CGImage) -> (mean: Double, deviation: Double) {
        let side = 24
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return (1, 1) }
        var values: [Double] = []
        values.reserveCapacity(side * side)
        for index in stride(from: 0, to: pixels.count, by: 4) {
            let r = Double(pixels[index]), g = Double(pixels[index + 1]), b = Double(pixels[index + 2])
            values.append((0.2126 * r + 0.7152 * g + 0.0722 * b) / 255)
        }
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count)
        return (mean, variance.squareRoot())
    }
}

/// A small counting semaphore for async code.
actor AsyncSemaphore {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { available = limit }

    func wait() async {
        if available > 0 { available -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func signal() {
        if waiters.isEmpty { available += 1 } else { waiters.removeFirst().resume() }
    }
}
