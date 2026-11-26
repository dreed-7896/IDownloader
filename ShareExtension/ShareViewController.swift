import UIKit
import UniformTypeIdentifiers

/// Queues the shared links and opens Stash straight away; Stash starts the download.
/// A small card is shown only while reading, or if iOS refuses to open the app.
final class ShareViewController: UIViewController {
    private let card = UIView()
    private let kicker = UILabel()
    private let statusLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private let closeButton = UIButton(type: .system)
    private var links: [SharedLink] = []
    private var finished = false

    private static let mint = UIColor(red: 0x3D / 255, green: 0xD6 / 255, blue: 0xA3 / 255, alpha: 1)
    private static let surface = UIColor(red: 0x11 / 255, green: 0x11 / 255, blue: 0x14 / 255, alpha: 1)
    private static let line = UIColor(red: 0x2E / 255, green: 0x2E / 255, blue: 0x37 / 255, alpha: 1)
    private static let text = UIColor(red: 0xF4 / 255, green: 0xF4 / 255, blue: 0xF6 / 255, alpha: 1)
    private static let text2 = UIColor(red: 0xB4 / 255, green: 0xB4 / 255, blue: 0xBE / 255, alpha: 1)

    override func viewDidLoad() {
        super.viewDidLoad()
        overrideUserInterfaceStyle = .dark
        view.backgroundColor = UIColor.black.withAlphaComponent(0.35)
        buildCard()
        readItems()
    }

    private func buildCard() {
        card.backgroundColor = Self.surface
        card.layer.borderColor = Self.line.cgColor
        card.layer.borderWidth = 1
        card.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(card)

        kicker.text = "STASH"
        kicker.font = .monospacedSystemFont(ofSize: 12, weight: .bold)
        kicker.textColor = Self.mint
        statusLabel.text = "Reading link…"
        statusLabel.numberOfLines = 6
        statusLabel.font = .systemFont(ofSize: 16, weight: .medium)
        statusLabel.textColor = Self.text

        var primary = UIButton.Configuration.filled()
        primary.baseBackgroundColor = Self.mint
        primary.baseForegroundColor = .black
        primary.cornerStyle = .fixed
        primary.background.cornerRadius = 0
        primary.title = "Open Drift"
        actionButton.configuration = primary
        actionButton.isHidden = true
        actionButton.addTarget(self, action: #selector(openAgain), for: .touchUpInside)

        var secondary = UIButton.Configuration.plain()
        secondary.baseForegroundColor = Self.text2
        secondary.title = "Cancel"
        closeButton.configuration = secondary
        closeButton.addTarget(self, action: #selector(done), for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [kicker, statusLabel, actionButton, closeButton])
        stack.axis = .vertical
        stack.spacing = 14
        stack.setCustomSpacing(8, after: kicker)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            card.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            card.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 24),
            card.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -24),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -12),
            actionButton.heightAnchor.constraint(equalToConstant: 46)
        ])
        let width = card.widthAnchor.constraint(equalToConstant: 380)
        width.priority = .defaultHigh
        width.isActive = true
    }

    // MARK: - Reading

    private func readItems() {
        let items = extensionContext?.inputItems as? [NSExtensionItem] ?? []
        let providers = items.flatMap { $0.attachments ?? [] }
        let sharedTitle = items.lazy.compactMap { $0.attributedContentText?.string }.first { !$0.isEmpty }
        let group = DispatchGroup()
        let collected = Collected()

        for provider in providers {
            // Safari runs StashPage.js on the page and hands back its URL, title and videos.
            if provider.hasItemConformingToTypeIdentifier(UTType.propertyList.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.propertyList.identifier, options: nil) { value, _ in
                    defer { group.leave() }
                    let results = (value as? NSDictionary)?["NSExtensionJavaScriptPreprocessingResultsKey"] as? [String: Any]
                    guard let results, let page = (results["url"] as? String).flatMap(URL.init(string:)),
                          SharedDownloadInbox.supported(page) else { return }
                    let media = (results["media"] as? [String] ?? []).compactMap(URL.init(string:))
                        .filter { SharedDownloadInbox.supported($0) }
                    let title = (results["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    collected.add(page: (page, title, media))
                }
                continue
            }
            let type: String
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) { type = UTType.url.identifier }
            else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) { type = UTType.plainText.identifier }
            else { continue }
            group.enter()
            provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                defer { group.leave() }
                var found: [URL] = []
                if let url = value as? URL, SharedDownloadInbox.supported(url) { found = [url] }
                else if let text = value as? String { found = SharedDownloadInbox.urls(in: text) }
                else if let data = value as? Data, let text = String(data: data, encoding: .utf8) { found = SharedDownloadInbox.urls(in: text) }
                collected.add(plain: found)
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else { return }
            let pages = collected.pages
            let plain = collected.plain
            var result: [SharedLink] = []
            for entry in pages {
                // The first video on the page; Stash searches the page itself when none was playable here.
                if let media = entry.media.first {
                    result.append(SharedLink(url: media, page: entry.page, title: entry.title))
                } else {
                    result.append(SharedLink(url: entry.page, page: entry.page, title: entry.title))
                }
            }
            let pageURLs = Set(pages.map(\.page.absoluteString))
            for url in plain where !pageURLs.contains(url.absoluteString) {
                result.append(SharedLink(url: url, page: nil, title: sharedTitle))
            }
            var seen = Set<String>()
            self.links = result.filter { seen.insert($0.url.absoluteString).inserted }
            self.start()
        }
    }

    // MARK: - Handing off

    private func start() {
        guard !links.isEmpty else {
            statusLabel.text = "Share a web page, a file link or a magnet link to save it with Drift."
            closeButton.configuration?.title = "Close"
            return
        }
        var handoff = SharedDownloadInbox.handoffURL()
        do {
            try SharedDownloadInbox.enqueue(links)
        } catch {
            // No shared container: carry the links in the URL instead.
            handoff = SharedDownloadInbox.handoffURL(for: links)
        }
        statusLabel.text = links.count == 1 ? "Opening Drift…" : "Opening Drift with \(links.count) links…"
        openApp(handoff) { [weak self] opened in
            guard let self else { return }
            if opened {
                // Give iOS a moment to bring Stash forward before dismissing the share sheet.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.done() }
            } else {
                self.showFallback(handoff)
            }
        }
    }

    private var pendingHandoff: URL?

    private func showFallback(_ handoff: URL) {
        pendingHandoff = handoff
        statusLabel.text = "Saved to Drift. Open Drift to start the download."
        actionButton.isHidden = false
        closeButton.configuration?.title = "Done"
    }

    @objc private func openAgain() {
        guard let pendingHandoff else { return }
        openApp(pendingHandoff) { [weak self] opened in
            if opened { self?.done() }
            else {
                UIPasteboard.general.string = self?.links.map(\.url.absoluteString).joined(separator: "\n")
                self?.statusLabel.text = "iOS didn't open Drift. The link is copied: open Drift and tap +."
            }
        }
    }

    /// Share extensions cannot call `UIApplication.open`, so walk the responder chain to the
    /// application and send it `openURL:options:completionHandler:` directly.
    private func openApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if current is UIApplication, current.responds(to: selector), let implementation = current.method(for: selector) {
                typealias Open = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let open = unsafeBitCast(implementation, to: Open.self)
                let handler: @convention(block) (Bool) -> Void = { opened in
                    DispatchQueue.main.async { completion(opened) }
                }
                open(current, selector, url as NSURL, NSDictionary(), handler)
                return
            }
            responder = current.next
        }
        // Fall back to the official API (works for some extension types).
        extensionContext?.open(url) { opened in DispatchQueue.main.async { completion(opened) } } ?? completion(false)
    }

    @objc private func done() {
        guard !finished else { return }
        finished = true
        extensionContext?.completeRequest(returningItems: nil)
    }
}

/// Results from item providers, which call back on arbitrary queues.
private final class Collected: @unchecked Sendable {
    private let lock = NSLock()
    private var _pages: [(page: URL, title: String?, media: [URL])] = []
    private var _plain: [URL] = []

    var pages: [(page: URL, title: String?, media: [URL])] { lock.lock(); defer { lock.unlock() }; return _pages }
    var plain: [URL] { lock.lock(); defer { lock.unlock() }; return _plain }

    func add(page: (page: URL, title: String?, media: [URL])) { lock.lock(); _pages.append(page); lock.unlock() }
    func add(plain urls: [URL]) { lock.lock(); _plain.append(contentsOf: urls); lock.unlock() }
}
