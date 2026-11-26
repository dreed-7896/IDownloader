//
//  AppRootController.swift
//  Drift
//
//  The browser fills the app. Downloads opens as a sheet over it (like Aloha): a navigation
//  stack with the downloads list at its root, from which details, files, the player and
//  settings push in. Swipe it down or tap ⌄ to get back to the page.
//

import Combine
import LibTorrent
import MvvmFoundation
import UIKit

/// The Downloads sheet. Screens that ask for a "detail" (built for the old split view) push here.
final class DownloadsNavigationController: BaseNavigationController {
    override func showDetailViewController(_ vc: UIViewController, sender: Any?) {
        // A wrapped controller is a new detail "root": it replaces whatever detail is open.
        if let navigation = vc as? UINavigationController, let top = navigation.topViewController {
            navigation.setViewControllers([], animated: false)
            if let root = viewControllers.first, viewControllers.count > 1 {
                setViewControllers([root, top], animated: true)
            } else {
                pushViewController(top, animated: true)
            }
        } else {
            pushViewController(vc, animated: true)
        }
    }
}

final class AppRootController: UIViewController {
    private(set) static weak var current: AppRootController?

    let browser = BrowserViewController()
    let downloads: DownloadsNavigationController
    /// Running downloads, shown as a badge on the browser's Downloads button.
    @Published private(set) var activeDownloads = 0
    private var subscriptions = Set<AnyCancellable>()

    init(downloadsRoot: UIViewController) {
        downloads = DownloadsNavigationController()
        downloads.viewControllers = [downloadsRoot]
        super.init(nibName: nil, bundle: nil)
        Self.current = self
        downloads.modalPresentationStyle = .pageSheet
        if let sheet = downloads.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        let close = UIBarButtonItem(image: UIImage(systemName: "chevron.down"), primaryAction: UIAction { [weak self] _ in
            self?.hideDownloads()
        })
        close.accessibilityLabel = "Back to browser"
        downloadsRoot.navigationItem.leadingItemGroups.insert(.fixedGroup(items: [close]), at: 0)
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

    // Download screens open inside the Downloads sheet.
    override func showDetailViewController(_ vc: UIViewController, sender: Any?) {
        showDownloads { [weak self] in self?.downloads.showDetailViewController(vc, sender: sender) }
    }
}

extension UIWindow {
    /// The Downloads navigation stack.
    var downloadsNavigationController: UINavigationController? {
        (rootViewController as? AppRootController)?.downloads
    }
}
