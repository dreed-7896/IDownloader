//
//  BrowserSession.swift
//  Drift
//
//  The open tabs and the selected one. Regular tabs are restored on the next launch.
//

import Combine
import Foundation
import WebKit

final class BrowserSession: ObservableObject {
    @Published private(set) var tabs: [BrowserTab] = []
    @Published private(set) var selectedID: UUID?

    var selected: BrowserTab? { tabs.first { $0.id == selectedID } ?? tabs.first }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedID } }

    init() {
        let saved = BrowserStore.shared.savedTabs
        tabs = saved.map { BrowserTab(url: $0.url, title: $0.title) }
        if tabs.isEmpty { tabs = [BrowserTab()] }
        let index = min(max(0, BrowserStore.shared.savedSelection), tabs.count - 1)
        selectedID = tabs[index].id
    }

    @discardableResult
    func newTab(url: URL? = nil, isPrivate: Bool = false, configuration: WKWebViewConfiguration? = nil,
                afterCurrent: Bool = false, select: Bool = true) -> BrowserTab {
        let tab = BrowserTab(url: url, isPrivate: isPrivate, configuration: configuration)
        if afterCurrent, let index = selectedIndex { tabs.insert(tab, at: index + 1) } else { tabs.append(tab) }
        if select { selectedID = tab.id }
        save()
        return tab
    }

    func select(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedID = id
        save()
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: index)
        if tab.isWebViewLoaded { tab.webView.stopLoading() }
        if tabs.isEmpty { tabs = [BrowserTab()] }
        if selectedID == id { selectedID = tabs[min(index, tabs.count - 1)].id }
        save()
    }

    func closeAll() {
        tabs.forEach { if $0.isWebViewLoaded { $0.webView.stopLoading() } }
        let fresh = BrowserTab()
        tabs = [fresh]
        selectedID = fresh.id
        save()
    }

    func tab(for webView: WKWebView) -> BrowserTab? {
        tabs.first { $0.isWebViewLoaded && $0.webView === webView }
    }

    func save() {
        let regular = tabs.filter { !$0.isPrivate }
        BrowserStore.shared.savedTabs = regular.map { SavedBrowserTab(url: $0.url, title: $0.title) }
        BrowserStore.shared.savedSelection = regular.firstIndex { $0.id == selectedID } ?? max(0, regular.count - 1)
    }
}
