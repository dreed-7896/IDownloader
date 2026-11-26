//
//  BrowserTab.swift
//  Drift
//
//  One browser tab: its web view (created when first shown), loading state and the videos
//  the media sniffer found on its page.
//

import Combine
import UIKit
import WebKit

struct DetectedMedia: Identifiable, Hashable {
    enum Kind: String { case file, hls, dash }

    var id: URL { url }
    var url: URL
    var kind: Kind
    /// The frame that played it, used as the Referer.
    var frame: URL?
    var pageTitle: String?
    var duration: Double?
    var width: Int?
    var height: Int?
    var size: Int64?
    var quality: String?
    var detectedAt = Date()

    var canDownload: Bool { kind != .dash }

    var displayName: String {
        let name = url.deletingPathExtension().lastPathComponent
        if name.isEmpty || name == "/" || ["index", "master", "playlist", "video", "manifest"].contains(name.lowercased()) {
            return url.host ?? "Video"
        }
        return name.removingPercentEncoding ?? name
    }

    var details: String {
        var parts: [String] = []
        switch kind {
        case .file: parts.append(url.pathExtension.isEmpty ? "VIDEO" : url.pathExtension.uppercased())
        case .hls: parts.append("HLS")
        case .dash: parts.append("DASH")
        }
        if let quality { parts.append(quality) } else if let height, height > 0 { parts.append("\(height)p") }
        if let duration, duration.isFinite, duration > 0 {
            let total = Int(duration)
            parts.append(total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                                       : String(format: "%d:%02d", total / 60, total % 60))
        }
        if let size, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let host = url.host { parts.append(host) }
        return parts.joined(separator: " · ")
    }
}

/// Routes sniffer messages to the tab that owns the posting web view (popups share their opener's controller).
final class MediaMessageRouter: NSObject, WKScriptMessageHandler {
    static let shared = MediaMessageRouter()
    private let tabs = NSMapTable<WKWebView, BrowserTab>.weakToWeakObjects()

    func register(_ tab: BrowserTab, for webView: WKWebView) { tabs.setObject(tab, forKey: webView) }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let webView = message.webView, let tab = tabs.object(forKey: webView),
              let body = message.body as? [String: Any] else { return }
        tab.receive(body)
    }
}

final class BrowserTab: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    let isPrivate: Bool

    @Published var title: String
    @Published var url: URL?
    @Published var progress: Double = 0
    @Published var isLoading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published private(set) var media: [DetectedMedia] = []
    @Published var hasNewMedia = false

    var snapshot: UIImage?
    var desktopMode = false
    /// The page's own icon, for bookmarks and favorites.
    @Published var iconURL: URL?
    /// The start page is shown over this tab's page.
    @Published var isHome = false
    private(set) var userAgent: String?
    /// The URL to load when the web view is first created (restored tabs load lazily).
    var pendingURL: URL?

    private var providedConfiguration: WKWebViewConfiguration?
    private var hiddenVariants = Set<URL>()
    private var observations: [NSKeyValueObservation] = []
    private(set) var isWebViewLoaded = false

    static let desktopUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    private static let privateStore = WKWebsiteDataStore.nonPersistent()

    init(url: URL? = nil, title: String? = nil, isPrivate: Bool = false, configuration: WKWebViewConfiguration? = nil) {
        self.isPrivate = isPrivate
        self.title = title ?? ""
        self.url = url
        self.pendingURL = url
        self.providedConfiguration = configuration
        super.init()
    }

    lazy var webView: WKWebView = makeWebView()

    private func makeWebView() -> WKWebView {
        let configuration = providedConfiguration ?? Self.makeConfiguration(isPrivate: isPrivate)
        providedConfiguration = nil
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsLinkPreview = true
        webView.backgroundColor = SColor.bg
        webView.isOpaque = false
        webView.scrollView.backgroundColor = SColor.bg
        if #available(iOS 16.0, *) { webView.isFindInteractionEnabled = true }
        if #available(iOS 16.4, *) { webView.isInspectable = true }
        MediaMessageRouter.shared.register(self, for: webView)
        observe(webView)
        isWebViewLoaded = true
        if let pendingURL {
            self.pendingURL = nil
            webView.load(URLRequest(url: pendingURL))
        }
        return webView
    }

    static func makeConfiguration(isPrivate: Bool) -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.allowsInlineMediaPlayback = true
        configuration.allowsPictureInPictureMediaPlayback = true
        configuration.allowsAirPlayForMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = .audio
        configuration.websiteDataStore = isPrivate ? privateStore : .default()
        let controller = WKUserContentController()
        PageScripts.install(on: controller)
        controller.add(MediaMessageRouter.shared, name: MediaSniffer.handlerName)
        configuration.userContentController = controller
        if BrowserStore.shared.adBlockEnabled, let list = AdBlockCache.list { controller.add(list) }
        return configuration
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
                guard let self else { return }
                let title = webView.title ?? ""
                if !title.isEmpty { self.title = title }
                if !self.isPrivate, let url = webView.url { BrowserStore.shared.updateTitle(title, for: url) }
            },
            webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
                if let url = webView.url { self?.url = url }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] webView, _ in
                self?.progress = webView.estimatedProgress
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] webView, _ in
                self?.isLoading = webView.isLoading
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] webView, _ in
                self?.canGoBack = webView.canGoBack
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] webView, _ in
                self?.canGoForward = webView.canGoForward
            }
        ]
    }

    func load(_ url: URL) {
        self.url = url
        if isWebViewLoaded { webView.load(URLRequest(url: url)) } else { pendingURL = url; _ = webView }
    }

    func setDesktopMode(_ enabled: Bool) {
        desktopMode = enabled
        webView.customUserAgent = enabled ? Self.desktopUserAgent : nil
        userAgent = nil
        webView.reload()
    }

    func captureUserAgent() {
        guard userAgent == nil, isWebViewLoaded else { return }
        if let custom = webView.customUserAgent { userAgent = custom; return }
        webView.evaluateJavaScript("navigator.userAgent") { [weak self] value, _ in self?.userAgent = value as? String }
    }

    func captureIcon() {
        guard isWebViewLoaded else { return }
        webView.evaluateJavaScript(PageScripts.bestIcon) { [weak self] value, _ in
            self?.iconURL = (value as? String).flatMap(URL.init(string:))
        }
    }

    func takeSnapshot(completion: (() -> Void)? = nil) {
        guard isWebViewLoaded, webView.window != nil, webView.bounds.width > 0 else { completion?(); return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 360
        webView.takeSnapshot(with: configuration) { [weak self] image, _ in
            if let image { self?.snapshot = image }
            completion?()
        }
    }

    // MARK: - Media

    func resetMedia() {
        media = []
        hiddenVariants = []
        hasNewMedia = false
    }

    /// Adds media the page is playing directly (a video URL opened in the tab).
    func addDirectMedia(_ url: URL) {
        receive(["url": url.absoluteString, "kind": HLSDownloader.isPlaylist(url) ? "hls" : "file", "frame": url.absoluteString])
    }

    func receive(_ body: [String: Any]) {
        guard let raw = body["url"] as? String, let url = URL(string: raw),
              let kind = (body["kind"] as? String).flatMap(DetectedMedia.Kind.init(rawValue:)),
              !hiddenVariants.contains(url) else { return }
        let width = (body["width"] as? NSNumber)?.intValue
        let height = (body["height"] as? NSNumber)?.intValue
        let duration = (body["duration"] as? NSNumber)?.doubleValue
        if let index = media.firstIndex(where: { $0.url == url }) {
            if let width, width > 0 { media[index].width = width; media[index].height = height }
            if let duration, media[index].duration == nil { media[index].duration = duration }
            return
        }
        var item = DetectedMedia(url: url, kind: kind)
        item.frame = (body["frame"] as? String).flatMap(URL.init(string:))
        item.pageTitle = (body["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        item.width = width
        item.height = height
        item.duration = duration
        media.append(item)
        hasNewMedia = true
        switch kind {
        case .hls: probePlaylist(url)
        case .file: probeSize(url)
        case .dash: break
        }
    }

    private func update(_ url: URL, _ change: (inout DetectedMedia) -> Void) {
        guard let index = media.firstIndex(where: { $0.url == url }) else { return }
        change(&media[index])
    }

    private func probePlaylist(_ url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let headers = await self.downloadHeaders(for: self.media.first { $0.url == url }, includeCookies: false)
            guard let playlist = try? await HLSDownloader.text(url, headers: headers) else { return }
            let (text, base) = playlist
            let variants = HLSDownloader.variants(in: text, base: base)
            if let best = variants.first {
                let urls = Set(variants.map(\.url))
                self.hiddenVariants.formUnion(urls)
                self.media.removeAll { urls.contains($0.url) && $0.url != url }
                self.update(url) { item in
                    if let resolution = best.resolution, let height = resolution.split(separator: "x").last.flatMap({ Int($0) }) {
                        item.quality = "\(height)p"
                    }
                }
            } else {
                let duration = text.components(separatedBy: .newlines)
                    .filter { $0.hasPrefix("#EXTINF:") }
                    .compactMap { Double($0.dropFirst(8).split(separator: ",").first ?? "") }
                    .reduce(0, +)
                if duration > 0 { self.update(url) { if $0.duration == nil { $0.duration = duration } } }
            }
        }
    }

    private func probeSize(_ url: URL) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            var request = URLRequest(url: url, timeoutInterval: 15)
            request.httpMethod = "HEAD"
            await self.downloadHeaders(for: self.media.first { $0.url == url }, includeCookies: false)
                .forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
            guard let result = try? await URLSession.shared.data(for: request),
                  let http = result.1 as? HTTPURLResponse, (200...299).contains(http.statusCode) else { return }
            let type = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
            if type.contains("mpegurl") { self.update(url) { $0.kind = .hls }; self.probePlaylist(url); return }
            if http.expectedContentLength > 0 { self.update(url) { $0.size = http.expectedContentLength } }
        }
    }

    // MARK: - Downloading

    private func cookies() async -> [HTTPCookie] {
        guard isWebViewLoaded else { return [] }
        let store = webView.configuration.websiteDataStore.httpCookieStore
        return await withCheckedContinuation { continuation in
            store.getAllCookies { continuation.resume(returning: $0) }
        }
    }

    /// Referer and User-Agent of the page, plus its cookies for `media` when the request can't share the cookie jar.
    func downloadHeaders(for media: DetectedMedia?, includeCookies: Bool) async -> [String: String] {
        captureUserAgent()
        var headers: [String: String] = [:]
        if let referer = media?.frame ?? url, ["http", "https"].contains(referer.scheme?.lowercased() ?? "") {
            headers["Referer"] = referer.absoluteString
        }
        headers["User-Agent"] = userAgent ?? (isWebViewLoaded ? webView.customUserAgent : nil) ?? PageMediaResolver.userAgent
        let cookies = await cookies()
        if !isPrivate { cookies.forEach { HTTPCookieStorage.shared.setCookie($0) } }
        if includeCookies || isPrivate, let target = media?.url {
            let matching = cookies.filter { cookie in
                guard let host = target.host?.lowercased() else { return false }
                let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return host == domain || host.hasSuffix("." + domain)
            }
            HTTPCookie.requestHeaderFields(with: matching).forEach { headers[$0.key] = $0.value }
        }
        return headers
    }
}
