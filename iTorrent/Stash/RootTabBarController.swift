//
//  RootTabBarController.swift
//  Drift
//
//  Two tabs: Browser (the default) and Downloads (the original downloads app, unchanged).
//

import Combine
import LibTorrent
import UIKit

final class RootTabBarController: UITabBarController {
    private(set) static weak var current: RootTabBarController?

    let browser = BrowserViewController()
    let downloads: UISplitViewController
    private var subscriptions = Set<AnyCancellable>()

    init(downloads: UISplitViewController) {
        self.downloads = downloads
        super.init(nibName: nil, bundle: nil)
        Self.current = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        browser.tabBarItem = UITabBarItem(title: "Browser", image: UIImage(systemName: "globe"), tag: 0)
        downloads.tabBarItem = UITabBarItem(title: "Downloads", image: UIImage(systemName: "arrow.down.circle"),
                                            selectedImage: UIImage(systemName: "arrow.down.circle.fill"))
        downloads.tabBarItem.tag = 1
        viewControllers = [browser, downloads]
        selectedIndex = 0
        styleTabBar()
        bindBadge()
    }

    private func styleTabBar() {
        let appearance = UITabBarAppearance()
        appearance.configureWithOpaqueBackground()
        appearance.backgroundColor = SColor.s1
        appearance.shadowColor = SColor.line2
        let font = SFont.mono(10, .bold) ?? .monospacedSystemFont(ofSize: 10, weight: .bold)
        for layout in [appearance.stackedLayoutAppearance, appearance.inlineLayoutAppearance, appearance.compactInlineLayoutAppearance] {
            layout.normal.iconColor = SColor.text3
            layout.normal.titleTextAttributes = [.font: font, .foregroundColor: SColor.text3, .kern: 0.6]
            layout.selected.titleTextAttributes = [.font: font, .kern: 0.6]
            layout.normal.badgeBackgroundColor = SColor.text
            layout.normal.badgeTextAttributes = [.foregroundColor: SColor.bg, .font: font]
        }
        tabBar.standardAppearance = appearance
        tabBar.scrollEdgeAppearance = appearance
    }

    /// The Downloads tab shows how many downloads are running.
    private func bindBadge() {
        let files = FileDownloadService.shared.updates.map { _ in () }
        let torrents = TorrentService.shared.updateNotifier.map { _ in () }
        Publishers.Merge(files, torrents)
            .prepend(())
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] in self?.updateBadge() }
            .store(in: &subscriptions)
    }

    private func updateBadge() {
        let files = FileDownloadService.shared.downloads.filter { $0.isActive }.count
        let torrents = TorrentService.shared.torrents.values.filter { $0.snapshot.friendlyState == .downloading }.count
        let count = files + torrents
        downloads.tabBarItem.badgeValue = count > 0 ? "\(count)" : nil
    }

    func showDownloads() {
        selectedViewController = downloads
    }

    /// Opens `url` in the in-app browser. Returns false if there's no browser to open it in.
    @discardableResult
    static func openInBrowser(_ url: URL) -> Bool {
        guard let current else { return false }
        current.presentedViewController?.dismiss(animated: true)
        current.selectedViewController = current.browser
        current.browser.loadViewIfNeeded()
        current.browser.open(url, inNewTab: true)
        return true
    }

    // Downloads screens are shown in the Downloads split view.
    override func showDetailViewController(_ vc: UIViewController, sender: Any?) {
        selectedViewController = downloads
        downloads.showDetailViewController(vc, sender: sender)
    }
}

extension UIWindow {
    /// The Downloads split view, wherever it sits in the hierarchy.
    var downloadsSplitViewController: UISplitViewController? {
        (rootViewController as? RootTabBarController)?.downloads ?? rootViewController as? UISplitViewController
    }
}
