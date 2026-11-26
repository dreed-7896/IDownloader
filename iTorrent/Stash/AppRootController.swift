//
//  AppRootController.swift
//  Drift
//
//  The browser fills the app. Downloads (the downloads list, files, torrents, settings) slides up
//  over it from the browser's Downloads button and closes back to the page.
//

import Combine
import LibTorrent
import UIKit

final class AppRootController: UIViewController {
    private(set) static weak var current: AppRootController?

    let browser = BrowserViewController()
    let downloads: UISplitViewController
    /// Running downloads, shown as a badge on the browser's Downloads button.
    @Published private(set) var activeDownloads = 0
    private var subscriptions = Set<AnyCancellable>()

    init(downloads: UISplitViewController) {
        self.downloads = downloads
        super.init(nibName: nil, bundle: nil)
        Self.current = self
        downloads.modalPresentationStyle = .fullScreen
        addCloseButton()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SColor.bg
        addChild(browser)
        browser.view.frame = view.bounds
        browser.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(browser.view)
        browser.didMove(toParent: self)

        let files = FileDownloadService.shared.updates.map { _ in () }
        let torrents = TorrentService.shared.updateNotifier.map { _ in () }
        Publishers.Merge(files, torrents)
            .prepend(())
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in
                let files = FileDownloadService.shared.downloads.filter { $0.isActive || $0.state == .queued }.count
                let torrents = TorrentService.shared.torrents.values.filter { $0.snapshot.friendlyState == .downloading }.count
                self?.activeDownloads = files + torrents
            }
            .store(in: &subscriptions)
    }

    override var childForStatusBarStyle: UIViewController? { browser }
    override var childForHomeIndicatorAutoHidden: UIViewController? { browser }

    /// A "Browser" button on the downloads list closes Downloads.
    private func addCloseButton() {
        guard let list = (downloads.viewControllers.first as? UINavigationController)?.viewControllers.first else { return }
        let close = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in
            self?.hideDownloads()
        })
        close.accessibilityLabel = "Back to browser"
        list.navigationItem.leadingItemGroups.insert(.fixedGroup(items: [close]), at: 0)
    }

    var isShowingDownloads: Bool { downloads.presentingViewController != nil }

    func showDownloads(completion: (() -> Void)? = nil) {
        if isShowingDownloads {
            completion?()
            return
        }
        let present = { [weak self] in
            guard let self else { return }
            self.present(self.downloads, animated: true, completion: completion)
        }
        if presentedViewController != nil { dismiss(animated: false, completion: present) } else { present() }
    }

    func hideDownloads() {
        guard isShowingDownloads else { return }
        downloads.dismiss(animated: true)
    }

    /// Opens `url` in a new browser tab, closing Downloads. Returns false if there's no browser.
    @discardableResult
    static func openInBrowser(_ url: URL) -> Bool {
        guard let current else { return false }
        current.dismiss(animated: true)
        current.browser.loadViewIfNeeded()
        current.browser.open(url, inNewTab: true)
        return true
    }

    // Download screens open inside Downloads.
    override func showDetailViewController(_ vc: UIViewController, sender: Any?) {
        showDownloads { [weak self] in self?.downloads.showDetailViewController(vc, sender: sender) }
    }
}

extension UIWindow {
    /// The Downloads split view, wherever it sits in the hierarchy.
    var downloadsSplitViewController: UISplitViewController? {
        (rootViewController as? AppRootController)?.downloads ?? rootViewController as? UISplitViewController
    }
}
