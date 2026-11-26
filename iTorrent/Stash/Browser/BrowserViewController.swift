//
//  BrowserViewController.swift
//  Drift
//
//  The whole app around the page: web content above one bottom dock. The dock holds the
//  address field (with the ad-block shield) and Back, Forward/Home, Menu, Downloads and Tabs.
//  It tucks away while scrolling down and rides on top of the keyboard while typing.
//  A floating button appears when the page has a video to save.
//

import Combine
import LibTorrent
import MvvmFoundation
import SwiftUI
import UIKit
import WebKit

final class BrowserViewController: UIViewController {
    let session = BrowserSession()
    private var tabSubscriptions = Set<AnyCancellable>()
    private var subscriptions = Set<AnyCancellable>()

    // Content
    private let contentView = UIView()
    private var startPage: UIHostingController<StartPageView>?
    private let suggestionsView = UITableView(frame: .zero, style: .plain)
    private var suggestions: [BrowserHistoryEntry] = []
    private weak var shownWebView: WKWebView?
    private var scrollObservation: NSKeyValueObservation?
    private var lastScrollOffset: CGFloat = 0

    // Dock
    private let dock = UIView()
    private let dockFill = UIView()
    private let progressView = UIProgressView(progressViewStyle: .bar)
    private let addressBox = UIView()
    private let shieldButton = UIButton(type: .system)
    private let addressField = UITextField()
    private let reloadButton = UIButton(type: .system)
    private let cancelButton = UIButton(type: .system)
    private let buttonRow = UIStackView()
    private let backButton = UIButton(type: .system)
    private let forwardButton = UIButton(type: .system)
    private let menuButton = UIButton(type: .system)
    private let downloadsButton = UIButton(type: .system)
    private let downloadsBadge = UILabel()
    private let tabsButton = UIButton(type: .system)
    private var isDockCollapsed = false

    // Video button
    private let videoButton = UIButton(type: .custom)
    private let videoBadge = UILabel()

    private var isEditingAddress = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = SColor.bg
        buildDock()
        buildContent()
        buildVideoButton()
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
        let store = BrowserStore.shared
        Publishers.CombineLatest(store.$adBlockEnabled, store.$adBlockAllowlist).dropFirst()
            .debounce(for: .milliseconds(200), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshAdBlock(reload: true) }
            .store(in: &subscriptions)
        store.$darkPages.dropFirst().removeDuplicates()
            .sink { [weak self] enabled in self?.applyDarkPages(enabled) }
            .store(in: &subscriptions)
        AppRootController.current?.$activeDownloads.receive(on: DispatchQueue.main)
            .sink { [weak self] count in self?.updateDownloadsBadge(count) }
            .store(in: &subscriptions)

        AdBlocker.refreshListIfNeeded()
        refreshAdBlock(reload: false)
    }

    override var preferredStatusBarStyle: UIStatusBarStyle { .default }

    // MARK: - Layout

    private func iconButton(_ button: UIButton, _ symbol: String, label: String, size: CGFloat = 19) {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        configuration.baseForegroundColor = SColor.text
        configuration.contentInsets = .zero
        button.configuration = configuration
        button.accessibilityLabel = label
        button.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = button.isEnabled ? SColor.text : SColor.text3.withAlphaComponent(0.45)
            button.configuration = updated
        }
    }

    private func buildDock() {
        dockFill.backgroundColor = SColor.s1
        dockFill.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dockFill)

        dock.backgroundColor = SColor.s1
        dock.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(dock)

        let line = UIView()
        line.backgroundColor = SColor.line2
        line.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(line)

        progressView.trackTintColor = .clear
        progressView.alpha = 0
        progressView.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(progressView)

        // Address box: shield | field | reload
        addressBox.backgroundColor = SColor.s2
        addressBox.layer.borderWidth = 1
        addressBox.layer.borderColor = SColor.line2.cgColor
        addressBox.translatesAutoresizingMaskIntoConstraints = false

        iconButton(shieldButton, "shield.lefthalf.filled", label: "Ad blocker", size: 16)
        shieldButton.showsMenuAsPrimaryAction = true
        shieldButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.shieldMenu() ?? [])
        }])

        let divider = UIView()
        divider.backgroundColor = SColor.line2
        divider.translatesAutoresizingMaskIntoConstraints = false

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

        iconButton(reloadButton, "arrow.clockwise", label: "Reload", size: 16)
        reloadButton.addTarget(self, action: #selector(reloadOrStop), for: .touchUpInside)

        let inner = UIStackView(arrangedSubviews: [shieldButton, divider, addressField, reloadButton])
        inner.spacing = 10
        inner.alignment = .center
        inner.translatesAutoresizingMaskIntoConstraints = false
        addressBox.addSubview(inner)

        var cancel = UIButton.Configuration.plain()
        var cancelTitle = AttributedString("Cancel")
        cancelTitle.font = SFont.ui(15, .semibold) ?? .systemFont(ofSize: 15, weight: .semibold)
        cancel.attributedTitle = cancelTitle
        cancel.contentInsets = .init(top: 0, leading: 12, bottom: 0, trailing: 2)
        cancelButton.configuration = cancel
        cancelButton.isHidden = true
        cancelButton.addTarget(self, action: #selector(cancelEditing), for: .touchUpInside)
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        cancelButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        let addressRow = UIStackView(arrangedSubviews: [addressBox, cancelButton])
        addressRow.alignment = .fill
        addressRow.isLayoutMarginsRelativeArrangement = true
        addressRow.directionalLayoutMargins = .init(top: 10, leading: 12, bottom: 6, trailing: 12)

        // Buttons: back, forward/home, menu, downloads, tabs
        iconButton(backButton, "chevron.backward", label: "Back")
        iconButton(forwardButton, "chevron.forward", label: "Forward")
        iconButton(menuButton, "line.3.horizontal", label: "Menu", size: 20)
        iconButton(downloadsButton, "arrow.down.circle", label: "Downloads", size: 20)
        backButton.addTarget(self, action: #selector(goBack), for: .touchUpInside)
        forwardButton.addTarget(self, action: #selector(goForwardOrHome), for: .touchUpInside)
        menuButton.addTarget(self, action: #selector(showMenu), for: .touchUpInside)
        downloadsButton.addTarget(self, action: #selector(showDownloads), for: .touchUpInside)
        tabsButton.addTarget(self, action: #selector(showTabs), for: .touchUpInside)
        tabsButton.accessibilityLabel = "Tabs"
        backButton.addGestureRecognizer(UILongPressGestureRecognizer(target: self, action: #selector(backLongPress(_:))))
        let tabsHold = UILongPressGestureRecognizer(target: self, action: #selector(tabsLongPress(_:)))
        tabsButton.addGestureRecognizer(tabsHold)

        downloadsBadge.font = SFont.mono(10, .bold) ?? .monospacedSystemFont(ofSize: 10, weight: .bold)
        downloadsBadge.textAlignment = .center
        downloadsBadge.isHidden = true
        downloadsBadge.translatesAutoresizingMaskIntoConstraints = false
        downloadsButton.addSubview(downloadsBadge)

        for button in [backButton, forwardButton, menuButton, downloadsButton, tabsButton] { buttonRow.addArrangedSubview(button) }
        buttonRow.distribution = .fillEqually
        buttonRow.heightAnchor.constraint(equalToConstant: 48).isActive = true

        let stack = UIStackView(arrangedSubviews: [addressRow, buttonRow])
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        dock.addSubview(stack)

        NSLayoutConstraint.activate([
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            dockFill.topAnchor.constraint(equalTo: dock.bottomAnchor),
            dockFill.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dockFill.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dockFill.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            line.topAnchor.constraint(equalTo: dock.topAnchor),
            line.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            progressView.topAnchor.constraint(equalTo: dock.topAnchor),
            progressView.leadingAnchor.constraint(equalTo: dock.leadingAnchor),
            progressView.trailingAnchor.constraint(equalTo: dock.trailingAnchor),
            progressView.heightAnchor.constraint(equalToConstant: 2),

            stack.topAnchor.constraint(equalTo: dock.topAnchor, constant: 1),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: dock.bottomAnchor, constant: -2),

            addressBox.heightAnchor.constraint(equalToConstant: 44),
            inner.leadingAnchor.constraint(equalTo: addressBox.leadingAnchor, constant: 4),
            inner.trailingAnchor.constraint(equalTo: addressBox.trailingAnchor, constant: -4),
            inner.topAnchor.constraint(equalTo: addressBox.topAnchor),
            inner.bottomAnchor.constraint(equalTo: addressBox.bottomAnchor),
            shieldButton.widthAnchor.constraint(equalToConstant: 36),
            shieldButton.heightAnchor.constraint(equalToConstant: 36),
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 22),
            reloadButton.widthAnchor.constraint(equalToConstant: 36),
            reloadButton.heightAnchor.constraint(equalToConstant: 36),

            downloadsBadge.centerXAnchor.constraint(equalTo: downloadsButton.centerXAnchor, constant: 12),
            downloadsBadge.centerYAnchor.constraint(equalTo: downloadsButton.centerYAnchor, constant: -10),
            downloadsBadge.heightAnchor.constraint(equalToConstant: 17),
            downloadsBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 17)
        ])
        updateTabsButton(count: session.tabs.count)
    }

    private func buildContent() {
        contentView.backgroundColor = SColor.bg
        contentView.translatesAutoresizingMaskIntoConstraints = false
        view.insertSubview(contentView, at: 0)
        NSLayoutConstraint.activate([
            contentView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            contentView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            contentView.bottomAnchor.constraint(equalTo: dock.topAnchor)
        ])
    }

    private func buildVideoButton() {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "arrow.down.to.line.compact", withConfiguration: UIImage.SymbolConfiguration(pointSize: 21, weight: .bold))
        configuration.cornerStyle = .fixed
        configuration.background.cornerRadius = 0
        videoButton.configuration = configuration
        videoButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseBackgroundColor = button.tintColor
            updated?.baseForegroundColor = SColor.onAccent
            button.configuration = updated
            button.alpha = button.isHighlighted ? 0.8 : 1
        }
        videoButton.accessibilityLabel = "Save video"
        videoButton.layer.shadowColor = UIColor.black.cgColor
        videoButton.layer.shadowOpacity = 0.35
        videoButton.layer.shadowRadius = 10
        videoButton.layer.shadowOffset = CGSize(width: 0, height: 4)
        videoButton.addTarget(self, action: #selector(showMedia), for: .touchUpInside)
        videoButton.translatesAutoresizingMaskIntoConstraints = false
        videoButton.isHidden = true
        view.addSubview(videoButton)

        videoBadge.font = SFont.mono(11, .bold) ?? .monospacedSystemFont(ofSize: 11, weight: .bold)
        videoBadge.textColor = SColor.bg
        videoBadge.backgroundColor = SColor.text
        videoBadge.textAlignment = .center
        videoBadge.translatesAutoresizingMaskIntoConstraints = false
        videoButton.addSubview(videoBadge)

        NSLayoutConstraint.activate([
            videoButton.widthAnchor.constraint(equalToConstant: 56),
            videoButton.heightAnchor.constraint(equalToConstant: 56),
            videoButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            videoButton.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -16),
            videoBadge.topAnchor.constraint(equalTo: videoButton.topAnchor, constant: -6),
            videoBadge.trailingAnchor.constraint(equalTo: videoButton.trailingAnchor, constant: 6),
            videoBadge.heightAnchor.constraint(equalToConstant: 20),
            videoBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 20)
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
            suggestionsView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            suggestionsView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            suggestionsView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            suggestionsView.bottomAnchor.constraint(equalTo: dock.topAnchor)
        ])
    }

    // MARK: - Dock state

    private func updateTabsButton(count: Int) {
        var configuration = UIButton.Configuration.plain()
        var title = AttributedString(count > 99 ? "∞" : "\(count)")
        title.font = SFont.mono(13, .bold) ?? .monospacedSystemFont(ofSize: 13, weight: .bold)
        configuration.attributedTitle = title
        configuration.background.strokeWidth = 2
        configuration.background.cornerRadius = 0
        configuration.cornerStyle = .fixed
        configuration.contentInsets = .init(top: 2, leading: 6, bottom: 2, trailing: 6)
        if session.selected?.isPrivate == true {
            configuration.background.backgroundColor = SColor.text
            configuration.background.strokeColor = SColor.text
            configuration.baseForegroundColor = SColor.s1
        } else {
            configuration.background.strokeColor = SColor.text
            configuration.baseForegroundColor = SColor.text
        }
        tabsButton.configuration = configuration
        tabsButton.accessibilityValue = "\(count) tabs"
    }

    private func updateDownloadsBadge(_ count: Int) {
        downloadsBadge.isHidden = count == 0
        downloadsBadge.text = count > 9 ? " 9+ " : " \(count) "
        // Fixed colors: the dock's tint isn't resolved before the view is on screen.
        downloadsBadge.backgroundColor = SColor.mint
        downloadsBadge.textColor = SColor.onAccent
        downloadsBadge.layer.borderColor = SColor.s1.cgColor
        downloadsBadge.layer.borderWidth = 1.5
    }

    private func updateShield() {
        let tab = session.selected
        let page = tab?.isHome == true ? nil : tab?.url
        let active = BrowserStore.shared.isAdBlockActive(on: page)
        shieldButton.configuration?.image = UIImage(systemName: active ? "shield.lefthalf.filled" : "shield.slash",
                                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        shieldButton.tintColor = active ? view.tintColor : SColor.text3
        shieldButton.configurationUpdateHandler = { button in
            var updated = button.configuration
            updated?.baseForegroundColor = active ? button.tintColor : SColor.text3
            button.configuration = updated
        }
        shieldButton.setNeedsUpdateConfiguration()
        shieldButton.accessibilityValue = active ? "On" : "Off"
    }

    private func updateNavigationButtons() {
        guard let tab = session.selected else { return }
        let onPage = tab.isWebViewLoaded && !tab.isHome
        backButton.isEnabled = tab.isHome ? tab.isWebViewLoaded : tab.canGoBack
        let showsForward = onPage && tab.canGoForward
        let symbol = showsForward || !onPage ? "chevron.forward" : "house"
        forwardButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 19, weight: .semibold))
        forwardButton.accessibilityLabel = symbol == "house" ? "Home" : "Forward"
        forwardButton.isEnabled = onPage || (tab.isHome && tab.canGoForward)
    }

    private func setDockCollapsed(_ collapsed: Bool, animated: Bool = true) {
        guard collapsed != isDockCollapsed, !(collapsed && isEditingAddress) else { return }
        isDockCollapsed = collapsed
        let changes = {
            self.buttonRow.isHidden = collapsed
            self.buttonRow.alpha = collapsed ? 0 : 1
            self.videoButton.alpha = collapsed ? 0.85 : 1
            self.view.layoutIfNeeded()
        }
        if animated { UIView.animate(withDuration: 0.22, delay: 0, options: [.beginFromCurrentState, .curveEaseOut], animations: changes) } else { changes() }
    }

    private func scrolled(_ scrollView: UIScrollView) {
        let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
        defer { lastScrollOffset = offset }
        guard scrollView.isDragging || scrollView.isDecelerating else { return }
        let delta = offset - lastScrollOffset
        let atBottom = offset + scrollView.bounds.height >= scrollView.contentSize.height + scrollView.adjustedContentInset.bottom - 4
        if offset <= 8 { setDockCollapsed(false) } else if atBottom { return } else if delta > 6 { setDockCollapsed(true) } else if delta < -10 { setDockCollapsed(false) }
    }

    // MARK: - Tabs

    private func showSelectedTab() {
        guard let tab = session.selected else { return }
        tabSubscriptions.removeAll()
        scrollObservation = nil
        shownWebView?.removeFromSuperview()
        shownWebView = nil
        setDockCollapsed(false, animated: false)

        if tab.isWebViewLoaded || tab.pendingURL != nil { attachWebView(of: tab) }
        updateStartPage()

        tab.$url.combineLatest(tab.$title).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.updateAddressField(); self?.updateShield() }
            .store(in: &tabSubscriptions)
        tab.$progress.combineLatest(tab.$isLoading).receive(on: DispatchQueue.main)
            .sink { [weak self] progress, loading in self?.updateProgress(progress, loading: loading) }
            .store(in: &tabSubscriptions)
        tab.$canGoBack.combineLatest(tab.$canGoForward, tab.$isHome).receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in self?.updateNavigationButtons(); self?.updateStartPage(); self?.updateAddressField() }
            .store(in: &tabSubscriptions)
        tab.$media.combineLatest(tab.$isHome).receive(on: DispatchQueue.main)
            .sink { [weak self] media, home in self?.updateVideoButton(home ? [] : media) }
            .store(in: &tabSubscriptions)
        updateTabsButton(count: session.tabs.count)
        updateShield()
    }

    /// The start page shows for a fresh tab and when Home is pressed.
    private func updateStartPage() {
        guard let tab = session.selected else { return }
        let showHome = tab.isHome || (!tab.isWebViewLoaded && tab.pendingURL == nil)
        if showHome {
            if startPage == nil {
                let host = UIHostingController(rootView: makeStartPage(isPrivate: tab.isPrivate))
                host.view.backgroundColor = SColor.bg
                addChild(host)
                host.view.translatesAutoresizingMaskIntoConstraints = false
                contentView.addSubview(host.view)
                NSLayoutConstraint.activate([
                    host.view.topAnchor.constraint(equalTo: contentView.topAnchor),
                    host.view.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                    host.view.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                    host.view.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
                ])
                host.didMove(toParent: self)
                startPage = host
            } else {
                startPage?.rootView = makeStartPage(isPrivate: tab.isPrivate)
            }
            contentView.bringSubviewToFront(startPage!.view)
        } else if let startPage {
            startPage.willMove(toParent: nil)
            startPage.view.removeFromSuperview()
            startPage.removeFromParent()
            self.startPage = nil
        }
    }

    private func makeStartPage(isPrivate: Bool) -> StartPageView {
        StartPageView(isPrivate: isPrivate,
                      onOpen: { [weak self] url in self?.open(url) },
                      onAdd: { [weak self] in self?.promptAddFavorite() })
    }

    private func attachWebView(of tab: BrowserTab) {
        let webView = tab.webView
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if webView.superview !== contentView {
            webView.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(webView)
            NSLayoutConstraint.activate([
                webView.topAnchor.constraint(equalTo: contentView.topAnchor),
                webView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                webView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
        if webView.scrollView.refreshControl == nil {
            let refresh = UIRefreshControl()
            refresh.addAction(UIAction { [weak webView, weak refresh] _ in
                webView?.reload()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refresh?.endRefreshing() }
            }, for: .valueChanged)
            webView.scrollView.refreshControl = refresh
        }
        shownWebView = webView
        lastScrollOffset = webView.scrollView.contentOffset.y
        scrollObservation = webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
            self?.scrolled(scrollView)
        }
        view.bringSubviewToFront(videoButton)
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
        tab.isHome = false
        let wasLoaded = tab.isWebViewLoaded
        if !wasLoaded {
            tab.pendingURL = url
            tab.url = url
        }
        if !wasLoaded || shownWebView !== tab.webView { attachWebView(of: tab) }
        if wasLoaded { tab.load(url) }
        updateStartPage()
        updateAddressField()
    }

    private func updateAddressField() {
        guard !isEditingAddress, let tab = session.selected else { return }
        let url = tab.isHome ? nil : tab.url
        if let url, url.scheme == "https" || url.scheme == "http" {
            var host = url.host ?? url.absoluteString
            if host.hasPrefix("www.") { host.removeFirst(4) }
            addressField.text = host
        } else {
            addressField.text = url?.absoluteString
        }
        addressField.placeholder = tab.isPrivate ? "Private · Search or enter address" : "Search \(BrowserStore.shared.searchEngine.title) or enter address"
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
        reloadButton.configuration?.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        reloadButton.accessibilityLabel = loading ? "Stop" : "Reload"
        if loading { setDockCollapsed(false) }
    }

    private func updateVideoButton(_ media: [DetectedMedia]) {
        let count = media.count
        let wasHidden = videoButton.isHidden
        videoButton.isHidden = count == 0
        videoBadge.text = count > 1 ? " \(count) " : nil
        videoBadge.isHidden = count <= 1
        if wasHidden, count > 0 {
            videoButton.transform = CGAffineTransform(scaleX: 0.4, y: 0.4)
            UIView.animate(withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.55, initialSpringVelocity: 0.8) {
                self.videoButton.transform = .identity
            }
        }
    }

    // MARK: - Actions

    @objc private func addressChanged() {
        suggestions = BrowserStore.shared.suggestions(for: addressField.text ?? "")
        suggestionsView.reloadData()
        suggestionsView.isHidden = suggestions.isEmpty
        if !suggestions.isEmpty { view.bringSubviewToFront(suggestionsView) }
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
        if tab.isHome { tab.isHome = false; updateStartPage(); return }
        if tab.webView.canGoBack { tab.webView.goBack() }
    }

    @objc private func goForwardOrHome() {
        guard let tab = session.selected else { return }
        if tab.isHome {
            tab.isHome = false
            if tab.isWebViewLoaded, tab.webView.canGoForward { tab.webView.goForward() }
        } else if tab.isWebViewLoaded, tab.webView.canGoForward {
            tab.webView.goForward()
        } else {
            tab.isHome = true
        }
        updateStartPage()
    }

    @objc private func backLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began, let tab = session.selected, tab.isWebViewLoaded else { return }
        let items = tab.webView.backForwardList.backList.reversed().prefix(12)
        guard !items.isEmpty else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        for item in items {
            sheet.addAction(UIAlertAction(title: item.title?.isEmpty == false ? item.title : item.url.host, style: .default) { _ in
                tab.isHome = false
                tab.webView.go(to: item)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = backButton
        present(sheet, animated: true)
    }

    @objc private func tabsLongPress(_ gesture: UILongPressGestureRecognizer) {
        guard gesture.state == .began else { return }
        let sheet = UIAlertController(title: nil, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "New tab", style: .default) { [weak self] _ in self?.session.newTab() })
        sheet.addAction(UIAlertAction(title: "New private tab", style: .default) { [weak self] _ in self?.session.newTab(isPrivate: true) })
        if let tab = session.selected {
            sheet.addAction(UIAlertAction(title: "Close this tab", style: .destructive) { [weak self] _ in self?.session.close(tab.id) })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = tabsButton
        present(sheet, animated: true)
    }

    @objc private func showDownloads() {
        addressField.resignFirstResponder()
        AppRootController.current?.showDownloads()
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
        if let tab = session.selected, !tab.isHome { tab.takeSnapshot(completion: present) } else { present() }
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

    // MARK: - Menu

    @objc private func showMenu() {
        addressField.resignFirstResponder()
        guard let tab = session.selected else { return }
        let page = tab.isHome ? nil : tab.url.flatMap { ["http", "https"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }
        let state = BrowserMenuState(title: page == nil ? "Drift" : (tab.title.isEmpty ? page?.host ?? "" : tab.title),
                                     url: page, iconURL: tab.iconURL, isPrivate: tab.isPrivate,
                                     desktopMode: tab.desktopMode, darkPages: BrowserStore.shared.darkPages,
                                     adBlockOnSite: BrowserStore.shared.isAdBlockActive(on: page),
                                     isBookmarked: BrowserStore.shared.isBookmarked(page),
                                     isFavorite: BrowserStore.shared.isFavorite(page))
        weak var hostRef: UIHostingController<BrowserMenuView>?
        let menu = BrowserMenuView(state: state) { [weak self] action in
            hostRef?.dismiss(animated: true) { self?.handleMenu(action, tab: tab, page: page) }
        }
        let host = UIHostingController(rootView: menu)
        hostRef = host
        host.view.backgroundColor = SColor.s1
        if let presentation = host.sheetPresentationController {
            presentation.detents = [.medium(), .large()]
            presentation.prefersGrabberVisible = true
        }
        present(host, animated: true)
    }

    private func handleMenu(_ action: BrowserMenuAction, tab: BrowserTab, page: URL?) {
        let store = BrowserStore.shared
        switch action {
        case .share:
            guard let page else { return }
            let controller = UIActivityViewController(activityItems: [page], applicationActivities: nil)
            controller.popoverPresentationController?.sourceView = menuButton
            present(controller, animated: true)
        case .toggleSiteAdBlock:
            store.setAdBlock(!store.isAdBlockActive(on: page), on: page)
            updateShield()
        case .toggleAdBlock:
            store.adBlockEnabled.toggle()
            updateShield()
        case .desktop:
            tab.setDesktopMode(!tab.desktopMode)
        case .darkPages:
            store.darkPages.toggle()
        case .find:
            if #available(iOS 16.0, *), tab.isWebViewLoaded {
                tab.webView.findInteraction?.presentFindNavigator(showingReplace: false)
            }
        case .newTab:
            session.newTab()
        case .newPrivateTab:
            session.newTab(isPrivate: true)
        case .openInPrivate:
            if let page { session.newTab(url: page, isPrivate: true) }
        case .bookmarks:
            showLibrary(section: 0)
        case .history:
            showLibrary(section: 1)
        case .files:
            openInDownloads(FileBrowserViewController())
        case .settings:
            openInDownloads(PreferencesViewModel().resolveVC())
        case .downloads:
            AppRootController.current?.showDownloads()
        case .toggleBookmark:
            if let page {
                store.toggleBookmark(title: tab.title, url: page, iconURL: tab.iconURL)
                if store.isBookmarked(page) { captureSnapshot(of: tab, for: page) }
                toast(store.isBookmarked(page) ? "Bookmarked" : "Bookmark removed")
            }
        case .addToStartPage:
            if let page {
                store.addFavorite(title: tab.title, url: page, iconURL: tab.iconURL)
                if let icon = tab.iconURL { SiteIconCache.shared.store(iconURL: icon, for: page) }
                captureSnapshot(of: tab, for: page)
                toast("Added to start page")
            }
        case .copyLink:
            if let page { UIPasteboard.general.url = page; toast("Link copied") }
        case .clearData:
            confirmClearData()
        case .searchEngine(let engine):
            store.searchEngine = engine
            updateAddressField()
        }
    }

    /// Saves what the page looks like now as the thumbnail of a bookmark or start-page site.
    private func captureSnapshot(of tab: BrowserTab, for url: URL) {
        guard tab.isWebViewLoaded, tab.webView.window != nil, tab.webView.bounds.width > 0 else { return }
        let configuration = WKSnapshotConfiguration()
        configuration.snapshotWidth = 420
        tab.webView.takeSnapshot(with: configuration) { image, _ in
            if let image { PageSnapshotStore.shared.save(image, for: url) }
        }
    }

    /// Refreshes the thumbnail of a saved site when it's visited (missing or older than three days).
    private func refreshSavedSnapshot(for tab: BrowserTab, url: URL) {
        guard !tab.isPrivate else { return }
        let snapshots = PageSnapshotStore.shared
        let key = snapshots.key(url)
        let store = BrowserStore.shared
        guard let saved = (store.favorites + store.bookmarks).map(\.url).first(where: { snapshots.key($0) == key }),
              (snapshots.age(for: saved) ?? .infinity) > 3 * 24 * 3600 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self, weak tab] in
            guard let self, let tab, tab === self.session.selected, !tab.isHome, tab.url.map(snapshots.key) == key else { return }
            self.captureSnapshot(of: tab, for: saved)
        }
    }

    /// Opens a screen inside the Downloads sheet, so Back leads to the downloads list.
    private func openInDownloads(_ controller: UIViewController) {
        guard let root = AppRootController.current else { return }
        root.showDownloads {
            let navigation = root.downloads
            if let first = navigation.viewControllers.first {
                navigation.setViewControllers([first, controller], animated: navigation.viewControllers.count == 1)
            }
        }
    }

    private func shieldMenu() -> [UIMenuElement] {
        let store = BrowserStore.shared
        let tab = session.selected
        let page = tab?.isHome == true ? nil : tab?.url
        var items: [UIMenuElement] = []
        if let page, let host = BrowserStore.siteKey(page), store.adBlockEnabled {
            let active = store.isAdBlockActive(on: page)
            items.append(UIAction(title: active ? "Allow ads on \(host)" : "Block ads on \(host)",
                                  image: UIImage(systemName: active ? "shield.slash" : "shield.lefthalf.filled")) { [weak self] _ in
                store.setAdBlock(!active, on: page)
                self?.updateShield()
            })
        }
        items.append(UIAction(title: "Ad blocker", image: UIImage(systemName: "shield"), state: store.adBlockEnabled ? .on : .off) { [weak self] _ in
            store.adBlockEnabled.toggle()
            self?.updateShield()
        })
        return [UIMenu(title: "Blocks ads, trackers, video ads and pop-ups", children: items)]
    }

    private func showLibrary(section: Int) {
        weak var hostRef: UIHostingController<LibraryView>?
        let view = LibraryView(initialSection: section, onOpen: { [weak self] url in
            hostRef?.dismiss(animated: true)
            self?.open(url)
        }, onClose: { hostRef?.dismiss(animated: true) })
        let host = UIHostingController(rootView: view)
        hostRef = host
        host.view.backgroundColor = SColor.bg
        present(host, animated: true)
    }

    private func promptAddFavorite() {
        let alert = UIAlertController(title: "Add to start page", message: nil, preferredStyle: .alert)
        alert.addTextField { $0.placeholder = "Name" }
        alert.addTextField {
            $0.placeholder = "Address"
            $0.keyboardType = .URL
            $0.autocapitalizationType = .none
            $0.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Add", style: .default) { [weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespaces) ?? ""
            let text = alert?.textFields?.last?.text ?? ""
            guard !text.isEmpty, let url = BrowserStore.shared.url(for: text), url.host != nil else { return }
            BrowserStore.shared.favorites.append(BrowserBookmark(title: name.isEmpty ? (url.host ?? text) : name, url: url))
        })
        present(alert, animated: true)
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

    // MARK: - Ad block & page scripts

    private func refreshAdBlock(reload: Bool) {
        Task { @MainActor in
            let list = await AdBlockCache.prepare()
            for tab in session.tabs where tab.isWebViewLoaded {
                let controller = tab.webView.configuration.userContentController
                controller.removeAllContentRuleLists()
                if BrowserStore.shared.adBlockEnabled, let list { controller.add(list) }
                PageScripts.install(on: controller)
                if reload, tab === session.selected, !tab.isHome { tab.webView.reload() }
            }
            updateShield()
        }
    }

    private func applyDarkPages(_ enabled: Bool) {
        for tab in session.tabs where tab.isWebViewLoaded {
            PageScripts.install(on: tab.webView.configuration.userContentController)
            tab.webView.evaluateJavaScript(enabled ? PageScripts.darkPages : PageScripts.removeDarkPages)
        }
    }

    private static func site(_ host: String?) -> String? {
        guard let parts = host?.lowercased().split(separator: "."), parts.count >= 2 else { return host?.lowercased() }
        return parts.suffix(2).joined(separator: ".")
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
                toast("Saving to Downloads", action: "View") { AppRootController.current?.showDownloads() }
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
            toast("Saving to Downloads", action: "View") { AppRootController.current?.showDownloads() }
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
            toast("Torrent added", action: "View") { AppRootController.current?.showDownloads() }
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
            box.trailingAnchor.constraint(equalTo: videoButton.isHidden ? view.safeAreaLayoutGuide.trailingAnchor : videoButton.leadingAnchor,
                                          constant: -16),
            box.bottomAnchor.constraint(equalTo: dock.topAnchor, constant: -16)
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
        setDockCollapsed(false, animated: false)
        let tab = session.selected
        textField.text = tab?.isHome == true ? nil : tab?.url?.absoluteString
        DispatchQueue.main.async { textField.selectAll(nil) }
        addressBox.layer.borderColor = view.tintColor.cgColor
        UIView.animate(withDuration: 0.2) {
            self.cancelButton.isHidden = false
            self.reloadButton.isHidden = true
            self.buttonRow.isHidden = true
            self.buttonRow.alpha = 0
            self.view.layoutIfNeeded()
        }
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        isEditingAddress = false
        addressBox.layer.borderColor = SColor.line2.cgColor
        suggestionsView.isHidden = true
        UIView.animate(withDuration: 0.2) {
            self.cancelButton.isHidden = true
            self.buttonRow.isHidden = false
            self.buttonRow.alpha = 1
            self.view.layoutIfNeeded()
        }
        isDockCollapsed = false
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
        content.image = SiteIconCache.shared.cached(for: entry.url) ?? UIImage(systemName: entry.date == .distantPast ? "star" : "clock")
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        content.imageProperties.reservedLayoutSize = CGSize(width: 28, height: 28)
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
        // Ad-network redirects in the main frame (click-jacking ads) are dropped.
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType != .linkActivated,
           BrowserStore.shared.isAdBlockActive(on: webView.url), AdBlocker.isAdHost(url.host) {
            decisionHandler(.cancel, preferences)
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
        guard let tab = session.tab(for: webView) else { return }
        tab.resetMedia()
        tab.iconURL = nil
        if tab.isHome, tab === session.selected { tab.isHome = false }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        session.tab(for: webView)?.captureUserAgent()
        if webView === shownWebView { setDockCollapsed(false) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let tab = session.tab(for: webView), let url = webView.url else { return }
        tab.captureIcon()
        if !tab.isPrivate { BrowserStore.shared.record(title: webView.title, url: url) }
        if webView === shownWebView { refreshSavedSnapshot(for: tab, url: url) }
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
        // Cancelled loads, interrupted frames (a download took over) and blocked content are not errors to show.
        if nsError.code == NSURLErrorCancelled || (nsError.domain == "WebKitErrorDomain" && [102, 104, 204].contains(nsError.code)) { return }
        guard webView === shownWebView else { return }
        toast(nsError.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        let opener = session.tab(for: webView)
        let target = navigationAction.request.url
        // Pop-up blocking: ad servers always; other sites' pop-ups unless the user tapped a link.
        if BrowserStore.shared.isAdBlockActive(on: webView.url) {
            if AdBlocker.isAdHost(target?.host) { return nil }
            let crossSite = Self.site(target?.host) != Self.site(webView.url?.host)
            if navigationAction.navigationType != .linkActivated, crossSite || target?.host == nil {
                if let target, target.host != nil {
                    toast("Pop-up blocked", action: "Open") { [weak self] in
                        self?.session.newTab(url: target, isPrivate: opener?.isPrivate ?? false, afterCurrent: true)
                    }
                } else {
                    toast("Pop-up blocked")
                }
                return nil
            }
        }
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
        let isMedia = PageMediaResolver.mediaExtensions.contains(url.pathExtension.lowercased()) || HLSDownloader.isPlaylist(url)
        completionHandler(UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] suggested in
            var actions: [UIMenuElement] = [
                UIAction(title: "Open in new tab", image: UIImage(systemName: "plus.square.on.square")) { _ in
                    self?.session.newTab(url: url, isPrivate: tab?.isPrivate ?? false, afterCurrent: true, select: false)
                    self?.toast("Opened in a new tab")
                },
                UIAction(title: "Open in private tab", image: UIImage(systemName: "eyeglasses")) { _ in
                    self?.session.newTab(url: url, isPrivate: true, afterCurrent: true, select: false)
                    self?.toast("Opened in a private tab")
                },
                UIAction(title: isMedia ? "Download video" : "Download link", image: UIImage(systemName: "arrow.down.to.line")) { _ in
                    self?.downloadLink(url, from: tab, isFile: isMedia)
                },
                UIAction(title: "Copy link", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.url = url
                }
            ]
            if BrowserStore.shared.bookmarks.contains(where: { $0.url == url }) == false {
                actions.append(UIAction(title: "Add to bookmarks", image: UIImage(systemName: "bookmark")) { _ in
                    BrowserStore.shared.toggleBookmark(title: nil, url: url, iconURL: nil)
                })
            }
            return UIMenu(children: [UIMenu(options: .displayInline, children: actions)] + suggested)
        })
    }
}
