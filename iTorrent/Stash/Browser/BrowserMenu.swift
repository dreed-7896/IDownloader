//
//  BrowserMenu.swift
//  Drift
//
//  The menu sheet from the dock: the page header, its ad-block switch, quick toggles,
//  the app's places (bookmarks, history, downloads, files, settings) and page actions.
//

import SwiftUI

struct BrowserMenuState {
    var title: String
    var url: URL?
    var iconURL: URL?
    var isPrivate: Bool
    var desktopMode: Bool
    var darkPages: Bool
    var adBlockOnSite: Bool
    var isBookmarked: Bool
    var isFavorite: Bool
}

enum BrowserMenuAction {
    case share, toggleSiteAdBlock, toggleAdBlock, desktop, darkPages, find
    case newTab, newPrivateTab, openInPrivate
    case bookmarks, history, files, settings, downloads
    case toggleBookmark, addToStartPage, copyLink, clearData
    case searchEngine(SearchEngine)
}

struct BrowserMenuView: View {
    let state: BrowserMenuState
    let onAction: (BrowserMenuAction) -> Void

    @ObservedObject private var store = BrowserStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                divider
                adBlockRow
                section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        tile("desktopcomputer", "Desktop", on: state.desktopMode, enabled: state.url != nil) { onAction(.desktop) }
                        tile("moon", "Dark pages", on: state.darkPages) { onAction(.darkPages) }
                        tile("eyeglasses", "Private tab", on: false) { onAction(.newPrivateTab) }
                        tile("doc.text.magnifyingglass", "Find", on: false, enabled: state.url != nil) { onAction(.find) }
                    }
                }
                section {
                    LazyVGrid(columns: columns, spacing: 14) {
                        tile("bookmark", "Bookmarks", accent: true) { onAction(.bookmarks) }
                        tile("clock.arrow.circlepath", "History", accent: true) { onAction(.history) }
                        tile("arrow.down.circle", "Downloads", accent: true) { onAction(.downloads) }
                        tile("folder", "Files", accent: true) { onAction(.files) }
                    }
                }
                VStack(spacing: 0) {
                    if state.url != nil {
                        row(state.isBookmarked ? "bookmark.slash" : "bookmark", state.isBookmarked ? "Remove bookmark" : "Add to bookmarks") {
                            onAction(.toggleBookmark)
                        }
                        if !state.isFavorite {
                            row("square.grid.2x2", "Add to start page") { onAction(.addToStartPage) }
                        }
                        if !state.isPrivate {
                            row("eyeglasses", "Open in private tab") { onAction(.openInPrivate) }
                        }
                        row("link", "Copy link") { onAction(.copyLink) }
                    }
                    row("plus.square", "New tab") { onAction(.newTab) }
                    Menu {
                        ForEach(SearchEngine.allCases) { engine in
                            Button {
                                onAction(.searchEngine(engine))
                            } label: {
                                if store.searchEngine == engine { Label(engine.title, systemImage: "checkmark") } else { Text(engine.title) }
                            }
                        }
                    } label: {
                        rowLabel("magnifyingglass", "Search engine", detail: store.searchEngine.title)
                    }
                    row("gearshape", "Settings") { onAction(.settings) }
                    row("trash", "Clear browsing data", destructive: true) { onAction(.clearData) }
                }
                .padding(.top, 6)
            }
            .padding(.bottom, 20)
        }
        .background(Color.sS1.ignoresSafeArea())
    }

    private var header: some View {
        HStack(spacing: 12) {
            if let url = state.url {
                SiteIcon(title: state.title, url: url, iconURL: state.iconURL, size: 36)
            } else {
                Image(systemName: "sparkles")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.sOnAccent)
                    .frame(width: 36, height: 36)
                    .background(Color.sMint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.sInter(16, .bold)).foregroundStyle(Color.sText).lineLimit(1)
                if let host = state.url?.host {
                    Text(host).font(.sMono(11, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                }
            }
            Spacer()
            if state.url != nil {
                Button { onAction(.share) } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color.sText)
                        .frame(width: 40, height: 40)
                        .background(Color.sS2)
                        .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
                }
                .buttonStyle(PressedOpacityStyle())
                .accessibilityLabel("Share")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 14)
    }

    private var adBlockRow: some View {
        HStack(spacing: 12) {
            Image(systemName: state.adBlockOnSite ? "shield.lefthalf.filled" : "shield.slash")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(state.adBlockOnSite ? Color.sMint : Color.sText3)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text("Ad blocker").font(.sInter(15, .semibold)).foregroundStyle(Color.sText)
                Text(adBlockDetail).font(.sInter(12)).foregroundStyle(Color.sText3)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { state.url == nil ? store.adBlockEnabled : state.adBlockOnSite },
                                     set: { _ in onAction(state.url == nil || !store.adBlockEnabled ? .toggleAdBlock : .toggleSiteAdBlock) }))
                .labelsHidden()
                .tint(Color.sMint)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var adBlockDetail: String {
        if !store.adBlockEnabled { return "Off everywhere" }
        guard let host = state.url?.host else { return "Ads, trackers, video ads and pop-ups" }
        return state.adBlockOnSite ? "Blocking ads on \(host)" : "Ads allowed on \(host)"
    }

    private var divider: some View { Rectangle().fill(Color.sLine).frame(height: 1) }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.sBg).frame(height: 8)
            content().padding(.horizontal, 16).padding(.vertical, 16)
        }
        .background(Color.sS1)
    }

    private func tile(_ symbol: String, _ title: String, on: Bool = false, accent: Bool = false, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(on ? Color.sOnAccent : accent ? Color.sMint : Color.sText)
                    .frame(width: 58, height: 58)
                    .background(on ? Color.sMint : Color.sS2)
                    .overlay(Rectangle().strokeBorder(on ? Color.sMint : Color.sLine2, lineWidth: 1))
                Text(title).font(.sInter(12, .medium)).foregroundStyle(Color.sText2).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .buttonStyle(PressedOpacityStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func row(_ symbol: String, _ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(symbol, title, destructive: destructive) }
            .buttonStyle(PressedOpacityStyle())
    }

    private func rowLabel(_ symbol: String, _ title: String, detail: String? = nil, destructive: Bool = false) -> some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(destructive ? Color.sCoral : Color.sText)
                .frame(width: 24)
            Text(title).font(.sInter(16, .medium)).foregroundStyle(destructive ? Color.sCoral : Color.sText)
            Spacer()
            if let detail { Text(detail).font(.sInter(14)).foregroundStyle(Color.sText3) }
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
}
