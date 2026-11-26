//
//  BrowserViewController.swift
//  Drift
//
//  The Browser tab: address bar, web content, a bottom bar (back, forward, share, tabs, menu)
//  and a floating download button that lists the videos found on the page.
//

import Combine
import LibTorrent
import SwiftUI
import UIKit
import WebKit

final class BrowserViewController: UIViewController {
    let session = BrowserSession()
    private var tabSubscriptions = Set<AnyCancellable>()
    private var subscriptions = Set<AnyCancellable>()

    // Top bar
    private let topBar = UIView()
    private let addressBox = UIView()
    private let addressIcon = UIImageView()
    private let addressField = UITextField()
    private let reloadButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let progressView = UIProgressView(progressViewStyle: .bar)

    // Content
    private let contentView = UIView()
    private var startPage: UIHostingController<StartPageView>?
    private let suggestionsView = UITableView(frame: .zero, style: .plain)
    private var suggestions: [BrowserHistoryEntry] = []

    // Bottom bar
    private let bottomBar = UIView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let shareButton = UIButton(type: .system)
    private let tabsButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)

    // Download button
    private let downloadButton = UIButton(type: .custom)
    private let downloadBadge = UILabel()

    private weak var shownWebView: WKWebView?
    private var isEditingAddress = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SColor.bg
        buildTopBar()
        buildBottomBar()
        buildContent()
        buildDownloadButton()
        buildSuggestions()

        session.$selectedID.removeDuplicates().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showSelectedTab() }
            .store(in: &subscriptions)
        session.$tabs.receive(on: DispatchQueue.main)
            .sink { [weak self] tabs in self?.updateTabsButton(count: tabs.count) }
            .store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)
            .sink { [weak self] _ in self?.session.save() }
            .store(in: &subscriptions)
        BrowserStore.shared.$adBlockEnabled.dropFirst().removeDuplicates()
            .sink { [weak self] enabled in self?.applyAdBlock(enabled) }
            .store(in: &subscriptions)

        Task { @MainActor in
            await AdBlockCache.prepare()
            if BrowserStore.shared.adBlockEnabled { applyAdBlock(true, reload: false) }
        }
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }

    // MARK: - Layout

    private func buildTopBar() {
        topBar.backgroundColor = SColor.bg
        topBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(topBar)

        addressBox.backgroundColor = SColor.s1
        addressBox.layer.borderWidth = 1
        addressBox.layer.borderColor = SColor.line2.cgColor
        addressBox.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(addressBox)

        addressIcon.image = UIImage(systemName: "magnifyingglass")
        addressIcon.tintColor = SColor.text3
        addressIcon.contentMode = .scaleAspectFit
        addressIcon.preferredSymbolConfiguration = .init(pointSize: 14, weight: .semibold)
        addressIcon.translatesAutoresizingMaskIntoConstraints = false

        addressField.placeholder = "Search or enter address"
        addressField.font = SFont.ui(16, .medium) ?? .systemFont(ofSize: 16, weight: .medium)
        addressField.textColor = SColor.text
        addressField.keyboardType = .webSearch
        addressField.returnKeyType = .go
        addressField.autocapitalizationType = .none
        addressField.autocorrectionType = .no
        addressField.spellCheckingType = .no
        addressField.clearButtonMode = .whileEditing
        addressField.textContentType = .URL
        addressField.delegate = self
        addressField.addTarget(self, action: #selector(addressChanged), for: .editingChanged)
        addressField.translatesAutoresizingMaskIntoConstraints = false

        configureIconButton(reloadButton, "arrow.clockwise", label: "Reload")
        reloadButton.addTarget(self, action: #selector(reloadOrStop), for: .touchUpInside)

        var cancel = UIButton.Configuration.plain()
        var cancelTitle = AttributedString("Cancel")
        cancelTitle.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
        cancel.attributedTitle = cancelTitle
        cancel.contentInsets = .init(top: 0, leading: 10, bottom: 0, trailing: 2)
        cancelButton.configuration = cancel
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let inner = UIStackView(arrangedSubviews: [addressIcon, addressField, reloadButton])
        inner.spacing = 8
        inner.alignment = .center
        inner.translatesAutoresizingMaskIntoConstraints = false
        addressBox.addSubview(inner)

        let row = UIStackView(arrangedSubviews: [addressBox, cancelButton])
        row.spacing = 4
        row.alignment = .fill
        row.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(row)

        progressView.progressTintColor = view.tintColor
        progressView.trackTintColor = .clear
        progressView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(progressView)

        let line = UIView()
        line.backgroundColor = SColor.line
        line.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(line)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: view.topAnchor),
            topBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            row.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 6),
            row.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            row.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -8),
            addressBox.heightAnchor.constraint(equalToConstant: 44),

            inner.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 12),
            inner.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -4),
            inner.topAnchor.constraint(equalTo: addressBox.topAnchor),
            inner.bottomAnchor.constraint(equalTo: addressBox.bottomAnchor),
            addressIcon.widthAnchor.constraint(equalToConstant: 18),
            reloadButton.widthAnchor.constraint(equalToConstant: 36),
            reloadButton.heightAnchor.constraint(equalToConstant: 36),

            line.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            line.bottomAnchor.constraint(equalTo: topBar.bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),

            progressView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            progressView.topAnchor.constraint(equalTo: topBar.bottomAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2)
        ])
    }

    private func configureIconButton(_ button: UIButton, _ symbol: String, label: String) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold))
        configuration.baseForegroundColor = SColor.text
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = label
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isEnabled ? SColor.text : SColor.text3.withAlphaComponent(0.5)
            button.configuration = updated
        }
    }

    private func buildBottomBar() {
        bottomBar.backgroundColor = SColor.s1
        bottomBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bottomBar)

        let line = UIView()
        line.backgroundColor = SColor.line2
        line.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(line)

        configureIconButton(backButton, "chevron.left", label: "Back")
        configureIconButton(forwardButton, "chevron.right", label: "Forward")
        configureIconButton(shareButton, "square.and.arrow.up", label: "Share")
        configureIconButton(menuButton, "ellipsis", label: "Menu")
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(goForward), for: .touchUpInside)
        shareButton.addTarget(self, action: #selector(shareTapped), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(showTabs), for: .touchUpInside)
        tabsButton.accessibilityLabel = "Tabs"
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.menuElements() ?? [])
        }])

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(backLongPress(_:)))
        backButton.addGestureRecognizer(longPress)

        let stack = UIStackView(arrangedSubviews: [backButton, forwardButton, shareButton, tabsButton, menuButton])
        stack.distribution = .fillEqually
        stack.translatesAutoresizingMaskIntoConstraints = false
        bottomBar.addSubview(stack)

        NSLayoutConstraint.activate([
            bottomBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bottomBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            bottomBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            line.topAnchor.constraint(equalTo: bottomBar.topAnchor),
            line.leadingAnchor.constraint(equalTo: bottomBar.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: bottomBar.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            stack.topAnchor.constraint(equalTo: bottomBar.topAnchor, constant: 1),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.heightAnchor.constraint(equalToConstant: 48),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        ])
    }

    private func updateTabsButton(count: Int) {
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(count > 99 ? ":D" : "\(count)")
        title.font = SFont.mono(13, .bold) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
        configuration.attributedTitle = title
        configuration.baseForegroundColor = SColor.text
        configuration.background.strokeColor = SColor.text
        configuration.background.strokeWidth = 1.5
        configuration.background.cornerRadius = 0
        configuration.cornerStyle = .fixed
        configuration.contentInsets = .init(top: 3, leading: 6, bottom: 3, trailing: 6)
        let isPrivate = session.selected?.isPrivate == true
        if isPrivate {
            configuration.background.backgroundColor = SColor.text
            configuration.baseForegroundColor = SColor.bg
        }
        tabsButton.configuration = configuration
        tabsButton.accessibilityValue = "\(count) tabs"
    }

    private func buildContent() {
        contentView.backgroundColor = SColor.bg
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(contentView, at: 0)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: progressView.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomBar.topAnchor)
        ])
    }

    private func buildDownloadButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "arrow.down.to.line", withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .bold))
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        downloadButton.configuration = configuration
        downloadButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseBackgroundColor = button.tintColor
            updated?.baseForegroundColor = SColor.onAccent
            button.configuration = updated
            button.alpha = button.isHighlighted ? 0.8 : 1
        }
        downloadButton.accessibilityLabel = "Download video"
        downloadButton.layer.shadowColor = UIColor.black.cgColor
        downloadButton.layer.shadowOpacity = 0.35
        downloadButton.layer.shadowRadius = 10
        downloadButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        downloadButton.addTarget(self, action: #selector(showMedia), for: .touchUpInside)
        downloadButton.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.isHidden = true
        view.addSubview(downloadButton)

        downloadBadge.font = SFont.mono(11, .bold) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)
        downloadBadge.textColor = SColor.bg
        downloadBadge.backgroundColor = SColor.text
        downloadBadge.textAlignment = .center
        downloadBadge.translatesAutoresizingMaskIntoConstraints = false
        downloadButton.addSubview(downloadBadge)

        NSLayoutConstraint.activate([
            downloadButton.widthAnchor.constraint(equalToConstant: 56),
            downloadButton.heightAnchor.constraint(equalToConstant: 56),
            downloadButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            downloadButton.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -16),
            downloadBadge.topAnchor.constraint(equalTo: downloadButton.topAnchor, constant: -6),
            downloadBadge.trailingAnchor.constraint(equalTo: downloadButton.trailingAnchor, constant: 6),
            downloadBadge.heightAnchor.constraint(equalToConstant: 20),
            downloadBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
        ])
    }

    private func buildSuggestions() {
        suggestionsView.backgroundColor = SColor.bg
        suggestionsView.separatorColor = SColor.line
        suggestionsView.keyboardDismissMode = .onDrag
        suggestionsView.dataSource = self
        suggestionsView.delegate = self
        suggestionsView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        suggestionsView.isHidden = true
        suggestionsView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(suggestionsView)
        NSLayoutConstraint.activate([
            suggestionsView.topAnchor.constraint(equalTo: progressView.bottomAnchor),
            suggestionsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    // MARK: - Tabs

    private func showSelectedTab() {
        guard let tab = session.selected else { return }
        tabSubscriptions.removeAll()
        shownWebView?.removeFromSuperview()
        shownWebView = nil

        if tab.url == nil && tab.pendingURL == nil && !tab.isWebViewLoaded {
            showStartPage(for: tab)
        } else {
            attachWebView(of: tab)
        }

        tab.$url.combineLatest(tab.$title).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateAddressField() }
            .store(in: &tabSubscriptions)
        tab.$progress.combineLatest(tab.$isLoading).receive(on: DispatchQueue.main)
            .sink { [weak self] progress, loading in self?.updateProgress(progress, loading: loading) }
            .store(in: &tabSubscriptions)
        tab.$canGoBack.combineLatest(tab.$canGoForward).receive(on: DispatchQueue.main)
            .sink { [weak self] back, forward in
                guard let self else { return }
                self.backButton.isEnabled = back
                self.forwardButton.isEnabled = forward
            }
            .store(in: &tabSubscriptions)
        tab.$media.receive(on: DispatchQueue.main)
            .sink { [weak self] media in self?.updateDownloadButton(media) }
            .store(in: &tabSubscriptions)
        updateTabsButton(count: session.tabs.count)
    }

    private func showStartPage(for tab: BrowserTab) {
        if startPage == nil {
            let host = UIHostingController(rootView: makeStartPage(isPrivate: tab.isPrivate))
            host.view.backgroundColor = SColor.bg
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
                host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
            host.didMove(toParent: self)
            startPage = host
        } else {
            startPage?.rootView = makeStartPage(isPrivate: tab.isPrivate)
        }
        startPage?.view.isHidden = false
    }

    private func makeStartPage(isPrivate: Bool) -> StartPageView {
        StartPageView(isPrivate: isPrivate, onOpen: { [weak self] url in self?.open(url) },
                      onSearch: { [weak self] in self?.addressField.becomeFirstResponder() })
    }

    private func hideStartPage() {
        guard let startPage else { return }
        startPage.willMove(toParent: nil)
        startPage.view.removeFromSuperview()
        startPage.removeFromParent()
        self.startPage = nil
    }

    private func attachWebView(of tab: BrowserTab) {
        hideStartPage()
        let webView = tab.webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
        if webView.scrollView.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak webView, weak refresh] _ in
                webView?.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh?.endRefreshing() }
            }, for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        shownWebView = webView
        view.bringSubviewToFront(downloadButton)
        view.bringSubviewToFront(suggestionsView)
    }

    /// Opens `url` in the selected tab (or a new tab).
    func open(_ url: URL, inNewTab: Bool = false) {
        if url.scheme?.lowercased() == "magnet" {
            handleExternal(url)
            return
        }
        if inNewTab {
            session.newTab(url: url, afterCurrent: true)
            return
        }
        guard let tab = session.selected else { return }
        let wasLoaded = tab.isWebViewLoaded
        if !wasLoaded {
            tab.pendingURL = url
            tab.url = url
        }
        if !wasLoaded || shownWebView !== tab.webView { attachWebView(of: tab) }
        if wasLoaded { tab.load(url) }
        updateAddressField()
    }

    // MARK: - State

    private func updateAddressField() {
        guard !isEditingAddress, let tab = session.selected else { return }
        let url = tab.url
        if let url, url.scheme == "https" || url.scheme == "http" {
            var host = url.host ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            addressField.text = host
            addressIcon.image = UIImage(systemName: url.scheme == "https" ? "lock.fill" : "exclamationmark.triangle")
        } else {
            addressField.text = url?.absoluteString
            addressIcon.image = UIImage(systemName: tab.isPrivate ? "eyeglasses" : "magnifyingglass")
        }
        addressField.placeholder = tab.isPrivate ? "Private · Search or enter address" : "Search or enter address"
        shareButton.isEnabled = url != nil
        reloadButton.isHidden = url == nil
    }

    private func updateProgress(_ progress: Double, loading: Bool) {
        progressView.progressTintColor = view.tintColor
        if loading {
            progressView.alpha = 1
            progressView.setProgress(Float(max(0.08, progress)), animated: progress > 0.1)
        } else {
            progressView.setProgress(1, animated: true)
            UIView.animate(withDuration: 0.25, delay: 0.2) { self.progressView.alpha = 0 } completion: { _ in
                self.progressView.setProgress(0, animated: false)
            }
        }
        let symbol = loading ? "xmark" : "arrow.clockwise"
        reloadButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        reloadButton.accessibilityLabel = loading ? "Stop" : "Reload"
    }

    private func updateDownloadButton(_ media: [DetectedMedia]) {
        let count = media.count
        let wasHidden = downloadButton.isHidden
        downloadButton.isHidden = count == 0
        downloadBadge.text = count > 1 ? " \(count) " : nil
        downloadBadge.isHidden = count <= 1
        if wasHidden, count > 0 {
            downloadButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8) {
                self.downloadButton.transform = .identity
            }
        }
    }

    // MARK: - Actions

    @objc private func addressChanged() {
        suggestions = BrowserStore.shared.suggestions(for: addressField.text ?? "")
        suggestionsView.reloadData()
        suggestionsView.isHidden = suggestions.isEmpty
    }

    @objc private func cancelEditing() {
        addressField.resignFirstResponder()
    }

    @objc private func reloadOrStop() {
        guard let tab = session.selected, tab.isWebViewLoaded else { return }
        if tab.isLoading { tab.webView.stopLoading() } else { tab.webView.reload() }
    }

    @objc private func goBack() {
        guard let tab = session.selected, tab.isWebViewLoaded else { return }
        if tab.webView.canGoBack { tab.webView.goBack() }
    }

    @objc private func goForward() {
        guard let tab = session.selected, tab.isWebViewLoaded else { return }
        tab.webView.goForward()
    }

    @objc private func backLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let tab = session.selected, tab.isWebViewLoaded else { return }
        let items = tab.webView.backForwardList.backList.reversed().prefix(12)
        guard !items.isEmpty else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for item in items {
            sheet.addAction(UIAlertAction(title: item.title?.isEmpty == false ? item.title : item.url.host, style: .default) { _ in
                tab.webView.go(to: item)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = backButton
        present(sheet, animated: true)
    }

    @objc private func shareTapped() {
        guard let url = session.selected?.url else { return }
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = shareButton
        present(controller, animated: true)
    }

    @objc private func showTabs() {
        addressField.resignFirstResponder()
        let present = { [weak self] in
            guard let self else { return }
            let view = TabsView(session: self.session, onDone: { [weak self] in self?.dismiss(animated: true) })
            let host = UIHostingController(rootView: view)
            host.view.backgroundColor = SColor.bg
            host.modalPresentationStyle = .fullScreen
            self.present(host, animated: true)
        }
        if let tab = session.selected { tab.takeSnapshot(completion: present) } else { present() }
    }

    @objc private func showMedia() {
        guard let tab = session.selected else { return }
        tab.hasNewMedia = false
        weak var hostRef: UIHostingController<MediaSheetView>?
        let sheet = MediaSheetView(tab: tab, onDownload: { [weak self] media in
            self?.download(media, from: tab)
            hostRef?.dismiss(animated: true)
        }, onClose: { hostRef?.dismiss(animated: true) })
        let host = UIHostingController(rootView: sheet)
        hostRef = host
        host.view.backgroundColor = SColor.bg
        if let presentation = host.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    private func menuElements() -> [UIMenuElement] {
        let store = BrowserStore.shared
        let tab = session.selected
        let url = tab?.url
        var elements: [UIMenuElement] = []

        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "New tab", image: UIImage(systemName: "plus.square")) { [weak self] _ in
                self?.session.newTab()
            },
            UIAction(title: "New private tab", image: UIImage(systemName: "eyeglasses")) { [weak self] _ in
                self?.session.newTab(isPrivate: true)
            }
        ]))

        var pageActions: [UIMenuElement] = []
        if let url, let tab {
            let bookmarked = store.isBookmarked(url)
            pageActions.append(UIAction(title: bookmarked ? "Remove bookmark" : "Add bookmark",
                                        image: UIImage(systemName: bookmarked ? "star.slash" : "star")) { _ in
                store.toggleBookmark(title: tab.title, url: url)
            })
            if #available(iOS 16.0, *) {
                pageActions.append(UIAction(title: "Find on page", image: UIImage(systemName: "doc.text.magnifyingglass")) { _ in
                    tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
                })
            }
            pageActions.append(UIAction(title: "Desktop site", image: UIImage(systemName: "desktopcomputer"),
                                        state: tab.desktopMode ? .on : .off) { _ in
                tab.setDesktopMode(!tab.desktopMode)
            })
            pageActions.append(UIAction(title: "Copy link", image: UIImage(systemName: "link")) { _ in
                UIPasteboard.general.url = url
            })
        }
        pageActions.append(UIAction(title: "Bookmarks & history", image: UIImage(systemName: "book")) { [weak self] _ in
            self?.showLibrary()
        })
        elements.append(UIMenu(options: .displayInline, children: pageActions))

        let engines = SearchEngine.allCases.map { engine in
            UIAction(title: engine.title, state: store.searchEngine == engine ? .on : .off) { _ in store.searchEngine = engine }
        }
        elements.append(UIMenu(options: .displayInline, children: [
            UIAction(title: "Block ads", image: UIImage(systemName: "shield.lefthalf.filled"),
                     state: store.adBlockEnabled ? .on : .off) { _ in store.adBlockEnabled.toggle() },
            UIMenu(title: "Search engine", image: UIImage(systemName: "magnifyingglass"), children: engines),
            UIAction(title: "Clear browsing data", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
                self?.confirmClearData()
            }
        ]))
        return elements
    }

    private func showLibrary() {
        weak var hostRef: UIHostingController<LibraryView>?
        let view = LibraryView(onOpen: { [weak self] url in
            hostRef?.dismiss(animated: true)
            self?.open(url)
        }, onClose: { hostRef?.dismiss(animated: true) })
        let host = UIHostingController(rootView: view)
        hostRef = host
        host.view.backgroundColor = SColor.bg
        present(host, animated: true)
    }

    private func confirmClearData() {
        let alert = UIAlertController(title: "Clear browsing data?",
                                      message: "History, cookies, cache and site data are removed. Bookmarks and downloads stay.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            BrowserStore.shared.clearHistory()
            WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
            HTTPCookieStorage.shared.removeCookies(since: .distantPast)
            self?.toast("Browsing data cleared")
        })
        present(alert, animated: true)
    }

    private func applyAdBlock(_ enabled: Bool, reload: Bool = true) {
        guard let list = AdBlockCache.list else { return }
        for tab in session.tabs where tab.isWebViewLoaded {
            let controller = tab.webView.configuration.userContentController
            controller.remove(list)
            if enabled { controller.add(list) }
            if reload, tab === session.selected { tab.webView.reload() }
        }
    }

    // MARK: - Downloads

    private func download(_ media: DetectedMedia, from tab: BrowserTab) {
        guard media.canDownload else { return }
        Task { @MainActor in
            let headers = await tab.downloadHeaders(for: media, includeCookies: media.kind == .file)
            let title = tab.title.isEmpty ? media.pageTitle : tab.title
            let page = tab.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
            let id = FileDownloadService.shared.add(media.url, page: tab.isPrivate ? nil : page, title: title,
                                                    kind: media.kind == .hls ? .hls : .file, headers: headers)
            if id != nil {
                toast("Saving to Downloads", action: "View") { RootTabBarController.current?.showDownloads() }
            } else {
                toast("This video can't be downloaded")
            }
        }
    }

    /// Downloads a link the page asked to download (or the user picked from a link's menu).
    private func downloadLink(_ url: URL, from tab: BrowserTab?, isFile: Bool) {
        if url.scheme?.lowercased() == "magnet" { handleExternal(url); return }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        Task { @MainActor in
            let probe = DetectedMedia(url: url, kind: .file, frame: tab?.url)
            let headers = await tab?.downloadHeaders(for: probe, includeCookies: true)
            let page = tab?.isPrivate == true ? nil : tab?.url
            if isFile || PageMediaResolver.looksLikeFile(url) {
                FileDownloadService.shared.add(url, page: page, title: nil, headers: headers)
            } else {
                await FileDownloadService.shared.add(SharedLink(url: url, page: nil, title: nil))
            }
            toast("Saving to Downloads", action: "View") { RootTabBarController.current?.showDownloads() }
        }
    }

    private func offerDownload(_ url: URL, name: String?, from tab: BrowserTab?) {
        let alert = UIAlertController(title: "Download file?", message: name ?? url.lastPathComponent, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Download", style: .default) { [weak self] _ in
            self?.downloadLink(url, from: tab, isFile: true)
        })
        present(alert, animated: true)
    }

    private func handleExternal(_ url: URL) {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "magnet" {
            (view.window?.windowScene?.delegate as? SceneDelegate)?.processURL(url)
            toast("Torrent added", action: "View") { RootTabBarController.current?.showDownloads() }
            return
        }
        UIApplication.shared.open(url)
    }

    // MARK: - Toast

    private var toastView: UIView?

    func toast(_ message: String, action: String? = nil, handler: (() -> Void)? = nil) {
        toastView?.removeFromSuperview()
        let box = UIView()
        box.backgroundColor = SColor.text
        box.translatesAutoresizingMaskIntoConstraints = false
        let label = UILabel()
        label.text = message
        label.font = SFont.ui(14, .semibold) ?? .systemFont(ofSize: 14, weight: .semibold)
        label.textColor = SColor.bg
        label.numberOfLines = 2
        let stack = UIStackView(arrangedSubviews: [label])
        stack.spacing = 12
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let action {
            let button = UIButton(type: .system)
            var configuration = UIButton.Configuration.plain()
            var title = AttributedString(action.uppercased())
            title.font = SFont.mono(13, .bold) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
            configuration.attributedTitle = title
            configuration.baseForegroundColor = view.tintColor
            configuration.contentInsets = .init(top: 4, leading: 8, bottom: 4, trailing: 0)
            button.configuration = configuration
            button.addAction(UIAction { [weak box] _ in
                handler?()
                box?.removeFromSuperview()
            }, for: .touchUpInside)
            button.setContentHuggingPriority(.required, for: .horizontal)
            stack.addArrangedSubview(button)
        }
        box.addSubview(stack)
        view.addSubview(box)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: box.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: box.bottomAnchor, constant: -12),
            stack.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -14),
            box.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            box.trailingAnchor.constraint(equalTo: downloadButton.isHidden ? view.safeAreaLayoutGuide.trailingAnchor : downloadButton.leadingAnchor,
                                          constant: -16),
            box.bottomAnchor.constraint(equalTo: bottomBar.topAnchor, constant: -16)
        ])
        toastView = box
        box.alpha = 0
        UIView.animate(withDuration: 0.2) { box.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { [weak box] in
            UIView.animate(withDuration: 0.25, animations: { box?.alpha = 0 }) { _ in box?.removeFromSuperview() }
        }
    }
}

// MARK: - Address field

extension BrowserViewController: UITextFieldDelegate {
    func textFieldDidBeginEditing(_ textField: UITextField) {
        isEditingAddress = true
        textField.text = session.selected?.url?.absoluteString
        DispatchQueue.main.async { textField.selectAll(nil) }
        addressBox.layer.borderColor = view.tintColor.cgColor
        UIView.animate(withDuration: 0.2) {
            self.cancelButton.isHidden = false
            self.reloadButton.isHidden = true
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        isEditingAddress = false
        addressBox.layer.borderColor = SColor.line2.cgColor
        suggestionsView.isHidden = true
        UIView.animate(withDuration: 0.2) { self.cancelButton.isHidden = true }
        updateAddressField()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        if let url = BrowserStore.shared.url(for: textField.text ?? "") {
            textField.resignFirstResponder()
            open(url)
        }
        return false
    }
}

extension BrowserViewController: UITableViewDataSource, UITableViewDelegate {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { suggestions.count }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        let entry = suggestions[indexPath.row]
        var content = UIListContentConfiguration.subtitleCell()
        content.text = entry.title
        content.secondaryText = entry.url.absoluteString
        content.textProperties.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
        content.textProperties.color = SColor.text
        content.secondaryTextProperties.font = SFont.mono(12, .medium) ?? .monospacedSystemFont(ofSize: 12, weight: .medium)
        content.secondaryTextProperties.color = SColor.text3
        content.image = UIImage(systemName: entry.date == .distantPast ? "star" : "clock")
        content.imageProperties.tintColor = SColor.text3
        cell.contentConfiguration = content
        cell.backgroundColor = SColor.bg
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let url = suggestions[indexPath.row].url
        addressField.resignFirstResponder()
        open(url)
    }
}

// MARK: - WebKit

extension BrowserViewController: WKNavigationDelegate, WKUIDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences,
                 decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel, preferences); return }
        let scheme = url.scheme?.lowercased() ?? ""
        if !["http", "https", "about", "data", "blob", "file", "javascript"].contains(scheme) {
            decisionHandler(.cancel, preferences)
            handleExternal(url)
            return
        }
        if navigationAction.shouldPerformDownload {
            decisionHandler(.cancel, preferences)
            offerDownload(url, name: nil, from: session.tab(for: webView))
            return
        }
        preferences.preferredContentMode = session.tab(for: webView)?.desktopMode == true ? .desktop : .mobile
        decisionHandler(.allow, preferences)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        let response = navigationResponse.response
        let tab = session.tab(for: webView)
        let mime = response.mimeType?.lowercased() ?? ""
        let disposition = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if let url = response.url, mime.hasPrefix("video/") || mime.contains("mpegurl") {
            tab?.addDirectMedia(url)
            if navigationResponse.canShowMIMEType, !disposition.hasPrefix("attachment") {
                decisionHandler(.allow)
                return
            }
        }
        if let url = response.url, navigationResponse.isForMainFrame,
           !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.cancel)
            offerDownload(url, name: response.suggestedFilename, from: tab)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        session.tab(for: webView)?.resetMedia()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        session.tab(for: webView)?.captureUserAgent()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = session.tab(for: webView), let url = webView.url else { return }
        if !tab.isPrivate { BrowserStore.shared.record(title: webView.title, url: url) }
        session.save()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showLoadError(error, in: webView)
    }

    private func showLoadError(_ error: Error, in webView: WKWebView) {
        let nsError = error as NSError
        // Cancelled loads and "frame load interrupted" (a download took over) are not errors.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && [102, 204].contains(nsError.code)) { return }
        guard webView === shownWebView else { return }
        toast(nsError.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let opener = session.tab(for: webView)
        let tab = session.newTab(isPrivate: opener?.isPrivate ?? false, configuration: configuration, afterCurrent: true, select: false)
        let newWebView = tab.webView
        session.select(tab.id)
        return newWebView
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = session.tab(for: webView) { session.close(tab.id) }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping () -> Void) {
        guard webView === shownWebView, presentedViewController == nil else { completionHandler(); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler() })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (Bool) -> Void) {
        guard webView === shownWebView, presentedViewController == nil else { completionHandler(false); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(false) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in completionHandler(true) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        guard webView === shownWebView, presentedViewController == nil else { completionHandler(nil); return }
        let alert = UIAlertController(title: frame.request.url?.host, message: prompt, preferredStyle: .alert)
        alert.addTextField { $0.text = defaultText }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
        alert.addAction(UIAlertAction(title: "OK", style: .default) { [weak alert] _ in completionHandler(alert?.textFields?.first?.text) })
        present(alert, animated: true)
    }

    func webView(_ webView: WKWebView, contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
                 completionHandler: @escaping (UIContextMenuConfiguration?) -> Void) {
        guard let url = elementInfo.linkURL else { completionHandler(nil); return }
        let tab = session.tab(for: webView)
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            let actions: [UIMenuElement] = [
                UIAction(title: "Open in new tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self?.session.newTab(url: url, isPrivate: tab?.isPrivate ?? false, afterCurrent: true, select: false)
                    self?.toast("Opened in a new tab")
                },
                UIAction(title: "Download link", image: UIImage(systemName: "arrow.down.circle")) { _ in
                    self?.downloadLink(url, from: tab, isFile: false)
                },
                UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                }
            ]
            return UIMenu(children: [UIMenu(options: .displayInline, children: actions)] + suggested)
        })
    }
}
