//
//  BrowserMenu.swift
//  Drift
//
//  The menu sheet from the dock: the page header, its ad-block switch, quick toggles,
//  the app's places (bookmarks, history, downloads, files) and page actions.
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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                adBlockCard

                card {
                    LazyVGrid(columns: columns, spacing: 14) {
                        tile(.desktop, "Desktop", on: state.desktopMode, enabled: state.url != nil) { onAction(.desktop) }
                        tile(.moon, "Dark pages", on: state.darkPages) { onAction(.darkPages) }
                        tile(.incognito, "Private tab") { onAction(.newPrivateTab) }
                        tile(.find, "Find", enabled: state.url != nil) { onAction(.find) }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 8)
                }

                card {
                    LazyVGrid(columns: columns, spacing: 14) {
                        tile(.bookmark, "Bookmarks", accent: true) { onAction(.bookmarks) }
                        tile(.history, "History", accent: true) { onAction(.history) }
                        tile(.downloads, "Downloads", accent: true) { onAction(.downloads) }
                        tile(.folder, "Files", accent: true) { onAction(.files) }
                    }
                    .padding(.vertical, 16)
                    .padding(.horizontal, 8)
                }

                if state.url != nil {
                    card {
                        VStack(spacing: 0) {
                            row(state.isBookmarked ? .bookmarkRemove : .bookmarkAdd,
                                state.isBookmarked ? "Remove bookmark" : "Add to bookmarks") { onAction(.toggleBookmark) }
                            if !state.isFavorite {
                                divider
                                row(.grid, "Add to start page") { onAction(.addToStartPage) }
                            }
                            if !state.isPrivate {
                                divider
                                row(.incognito, "Open in private tab") { onAction(.openInPrivate) }
                            }
                            divider
                            row(.link, "Copy link") { onAction(.copyLink) }
                        }
                    }
                }

                card {
                    VStack(spacing: 0) {
                        row(.addSquare, "New tab") { onAction(.newTab) }
                        divider
                        Menu {
                            ForEach(SearchEngine.allCases) { engine in
                                Button {
                                    onAction(.searchEngine(engine))
                                } label: {
                                    if store.searchEngine == engine { Label(engine.title, systemImage: "checkmark") } else { Text(engine.title) }
                                }
                            }
                        } label: {
                            rowLabel(.search, "Search engine", detail: store.searchEngine.title)
                        }
                        divider
                        row(.settings, "Settings") { onAction(.settings) }
                        divider
                        row(.delete, "Clear browsing data", destructive: true) { onAction(.clearData) }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .background(Color.sS1.ignoresSafeArea())
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if let url = state.url {
                SiteIcon(title: state.title, url: url, iconURL: state.iconURL, size: 44, cornerRadius: 12)
            } else {
                Icon.sparkles.view(22)
                    .foregroundStyle(Color.white)
                    .frame(width: 44, height: 44)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Brand.mint, Brand.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.sInter(16, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                Text(state.url?.host ?? (state.isPrivate ? "Private tab" : "Start page"))
                    .font(.sInter(13)).foregroundStyle(Color.sText3).lineLimit(1)
            }
            Spacer(minLength: 8)
            if state.url != nil {
                DriftCircleButton(icon: .share, label: "Share", size: 40) { onAction(.share) }
            }
        }
        .padding(.horizontal, 4)
    }

    // MARK: Ad blocker

    private var adBlockCard: some View {
        let active = state.url == nil ? store.adBlockEnabled : state.adBlockOnSite
        return HStack(spacing: 12) {
            (active ? Icon.shield : Icon.shieldOff).view(22)
                .foregroundStyle(active ? Color.sOnAccent : Color.sText3)
                .frame(width: 42, height: 42)
                .background(Circle().fill(active ? Color.sMint : Color.sS3))
            VStack(alignment: .leading, spacing: 2) {
                Text("Ad blocker").font(.sInter(15, .semibold)).foregroundStyle(Color.sText)
                Text(adBlockDetail).font(.sInter(12)).foregroundStyle(Color.sText3).lineLimit(2)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { state.url == nil ? store.adBlockEnabled : state.adBlockOnSite },
                                     set: { _ in onAction(state.url == nil || !store.adBlockEnabled ? .toggleAdBlock : .toggleSiteAdBlock) }))
                .labelsHidden()
                .tint(Color.sMint)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS2))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private var adBlockDetail: String {
        if !store.adBlockEnabled { return "Off everywhere" }
        guard let host = state.url?.host else { return "Ads, trackers, video ads and pop-ups" }
        return state.adBlockOnSite ? "Blocking ads on \(host)" : "Ads allowed on \(host)"
    }

    // MARK: Building blocks

    private var divider: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 56)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS2))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }

    private func tile(_ icon: Icon, _ title: String, on: Bool = false, accent: Bool = false, enabled: Bool = true,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon.view(23)
                    .foregroundStyle(on ? Color.sOnAccent : accent ? Color.sMint : Color.sText)
                    .frame(width: 56, height: 56)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(on ? Color.sMint : Color.sS3))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(on ? 0 : 0.06), lineWidth: 1)
                    )
                Text(title)
                    .font(.sInter(12, .medium))
                    .foregroundStyle(Color.sText2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(DriftPressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    private func row(_ icon: Icon, _ title: String, destructive: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon, title, destructive: destructive) }
            .buttonStyle(DriftPressStyle())
    }

    private func rowLabel(_ icon: Icon, _ title: String, detail: String? = nil, destructive: Bool = false) -> some View {
        HStack(spacing: 14) {
            icon.view(21)
                .foregroundStyle(destructive ? Color.sCoral : Color.sText)
                .frame(width: 26)
            Text(title).font(.sInter(16, .medium)).foregroundStyle(destructive ? Color.sCoral : Color.sText)
            Spacer()
            if let detail {
                Text(detail).font(.sInter(14)).foregroundStyle(Color.sText3)
                Icon.forward.view(14).foregroundStyle(Color.sText3)
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
        .contentShape(Rectangle())
    }
}
