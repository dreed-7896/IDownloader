//
//  BrowserViews.swift
//  Drift
//
//  SwiftUI screens of the browser: the start page, the tab switcher, the list of videos
//  found on a page, and bookmarks & history.
//

import SwiftUI

// MARK: - Shared pieces

private struct SquareIconButton: View {
    let systemImage: String
    var label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.sText)
                .frame(width: 40, height: 40)
                .background(Color.sS1)
                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
        }
        .buttonStyle(PressedOpacityStyle())
        .accessibilityLabel(label)
    }
}

// MARK: - Start page

struct StartPageView: View {
    var isPrivate: Bool
    var onOpen: (URL) -> Void
    var onAdd: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: 3)

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                VStack(spacing: 8) {
                    Text(isPrivate ? "Private" : "Drift")
                        .font(.sDisplay(52, .heavy))
                        .tracking(-1.6)
                        .foregroundStyle(Color.sMint)
                        .shadow(color: Color.sMint.opacity(0.5), radius: 22)
                    Text(isPrivate ? "Nothing from this tab is kept" : "Browse · Watch · Save").sLabel(11)
                }
                .padding(.top, 44)

                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(store.favorites) { favorite in
                        Button { onOpen(favorite.url) } label: { SiteCard(title: favorite.title, url: favorite.url, iconURL: favorite.iconURL) }
                            .buttonStyle(PressedOpacityStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.favorites.removeAll { $0.id == favorite.id }
                                } label: { Label("Remove from start page", systemImage: "minus.circle") }
                            }
                    }
                    Button(action: onAdd) {
                        VStack(spacing: 7) {
                            Rectangle()
                                .strokeBorder(Color.sLine2, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                                .background(Color.sS1.opacity(0.6))
                                .aspectRatio(0.78, contentMode: .fit)
                                .overlay(Image(systemName: "plus").font(.system(size: 22, weight: .medium)).foregroundStyle(Color.sText3))
                            Text("Add site").font(.sInter(12, .medium)).foregroundStyle(Color.sText3).frame(height: 16)
                        }
                    }
                    .buttonStyle(PressedOpacityStyle())
                    .accessibilityLabel("Add to start page")
                }
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Image(systemName: "arrow.down.to.line.compact")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.sOnAccent)
                        .frame(width: 30, height: 30)
                        .background(Color.sMint)
                    Text("Play a video on any site, then tap the green button to save it.")
                        .font(.sInter(13)).foregroundStyle(Color.sText3)
                    Spacer(minLength: 0)
                }
                .padding(12)
                .background(Color.sS1.opacity(0.7))
                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
        }
        .background(
            ZStack {
                Color.sBg
                RadialGradient(colors: [Color.sMint.opacity(isPrivate ? 0.08 : 0.2), .clear], center: UnitPoint(x: 0.2, y: 0.1),
                               startRadius: 10, endRadius: 380)
                RadialGradient(colors: [Color(red: 0.36, green: 0.27, blue: 0.78).opacity(0.18), .clear],
                               center: UnitPoint(x: 0.9, y: 0.55), startRadius: 10, endRadius: 360)
            }
            .ignoresSafeArea()
        )
    }
}

/// A site preview: page snapshot with the site's icon and name underneath.
struct SiteCard: View {
    let title: String
    let url: URL
    var iconURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            PageThumbnail(title: title, url: url, iconURL: iconURL)
            HStack(spacing: 6) {
                SiteIcon(title: title, url: url, iconURL: iconURL, size: 16)
                Text(title).font(.sInter(12, .semibold)).foregroundStyle(Color.sText2).lineLimit(1)
            }
            .frame(height: 16)
        }
    }
}

// MARK: - Tabs

struct TabsView: View {
    @ObservedObject var session: BrowserSession
    var onDone: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.tabs.count == 1 ? "1 open" : "\(session.tabs.count) open").sLabel(11)
                    Text("Tabs").font(.sDisplay(30, .heavy)).tracking(-0.8).foregroundStyle(Color.sText)
                }
                Spacer()
                Button(role: .destructive) {
                    session.closeAll()
                    onDone()
                } label: {
                    Text("Close all").font(.sInter(14, .semibold)).foregroundStyle(Color.sCoral)
                        .padding(.horizontal, 12).frame(height: 36)
                        .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
                }
                .buttonStyle(PressedOpacityStyle())
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(session.tabs) { tab in
                        TabCard(tab: tab, selected: tab.id == session.selectedID,
                                onSelect: {
                                    session.select(tab.id)
                                    onDone()
                                },
                                onClose: { close(tab) })
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                BoxButton(title: "Private", systemImage: "eyeglasses") {
                    session.newTab(isPrivate: true)
                    onDone()
                }
                BoxButton(title: "New tab", systemImage: "plus", prominent: true) {
                    session.newTab()
                    onDone()
                }
                BoxButton(title: "Done", systemImage: "checkmark", action: onDone)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.sS1.ignoresSafeArea(edges: .bottom))
            .overlay(Rectangle().fill(Color.sLine2).frame(height: 1), alignment: .top)
        }
        .background(Color.sBg.ignoresSafeArea())
    }

    /// Closing the last tab leaves a fresh start page and returns to it.
    private func close(_ tab: BrowserTab) {
        if session.tabs.count <= 1 {
            session.closeAll()
            onDone()
        } else {
            withAnimation(.easeOut(duration: 0.2)) { session.close(tab.id) }
        }
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 0) {
                HStack(spacing: 7) {
                    if tab.isPrivate {
                        Image(systemName: "eyeglasses").font(.system(size: 12, weight: .bold)).foregroundStyle(Color.sText2)
                    } else if let url = tab.url, !tab.isHome {
                        SiteIcon(title: title, url: url, iconURL: tab.iconURL, size: 16)
                    }
                    Text(title).font(.sInter(12, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                    Spacer(minLength: 34)
                }
                .padding(.leading, 10)
                .frame(height: 36)
                .background(selected ? Color.sS3 : Color.sS1)

                ZStack {
                    Color.sS2
                    if let snapshot = tab.snapshot, !tab.isHome {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 6) {
                            Image(systemName: tab.url == nil || tab.isHome ? "square.grid.2x2" : "globe")
                                .font(.system(size: 22, weight: .medium)).foregroundStyle(Color.sText3)
                            Text(tab.isHome ? "Start page" : tab.url?.host ?? "Start page")
                                .font(.sMono(11, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                        }
                        .padding(8)
                    }
                }
                .aspectRatio(0.8, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .top)
                .clipped()
            }
            .overlay(Rectangle().strokeBorder(selected ? Color.sMint : Color.sLine2, lineWidth: selected ? 2 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(PressedOpacityStyle())
        // Overlaid after the card's button so it always receives its own taps.
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.sText2)
                    .frame(width: 40, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close tab")
        }
    }

    private var title: String {
        if tab.isHome || (tab.url == nil && tab.title.isEmpty) { return tab.isPrivate ? "Private tab" : "New tab" }
        if !tab.title.isEmpty { return tab.title }
        return tab.url?.host ?? "New tab"
    }
}

// MARK: - Videos on the page

struct MediaSheetView: View {
    @ObservedObject var tab: BrowserTab
    var onDownload: (DetectedMedia) -> Void
    var onClose: () -> Void

    private var sorted: [DetectedMedia] {
        tab.media.sorted { lhs, rhs in
            if lhs.canDownload != rhs.canDownload { return lhs.canDownload }
            let left = lhs.height ?? Int(lhs.quality?.dropLast() ?? "") ?? 0
            let right = rhs.height ?? Int(rhs.quality?.dropLast() ?? "") ?? 0
            if left != right { return left > right }
            return lhs.detectedAt < rhs.detectedAt
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tab.url?.host ?? "This page").sLabel(12)
                    Text(tab.media.count == 1 ? "1 video found" : "\(tab.media.count) videos found")
                        .font(.sDisplay(28, .heavy))
                        .tracking(-0.8)
                        .foregroundStyle(Color.sText)
                }
                Spacer()
                SquareIconButton(systemImage: "xmark", label: "Close", action: onClose)
            }

            if tab.media.isEmpty {
                Text("No videos found yet. Start playing the video, then tap the download button again.")
                    .font(.sInter(14)).foregroundStyle(Color.sText3)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 10) {
                        ForEach(sorted) { media in
                            MediaRow(media: media) { onDownload(media) }
                        }
                    }
                }
                Text("Streams (HLS) are saved as one video file. DASH streams and protected (DRM) videos can't be saved.")
                    .font(.sInter(12)).foregroundStyle(Color.sText3)
            }
        }
        .padding(20)
        .background(Color.sBg.ignoresSafeArea())
    }
}

private struct MediaRow: View {
    let media: DetectedMedia
    let onDownload: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: media.kind == .file ? "film" : "dot.radiowaves.left.and.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(media.canDownload ? Color.sMint : Color.sText3)
                .frame(width: 40, height: 40)
                .background(Color.sS2)
            VStack(alignment: .leading, spacing: 3) {
                Text(media.displayName).font(.sInter(15, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                Text(media.details).font(.sMono(11, .medium)).foregroundStyle(Color.sText3).lineLimit(2)
            }
            Spacer(minLength: 6)
            if media.canDownload {
                Button(action: onDownload) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.down").font(.system(size: 13, weight: .bold))
                        Text("Save").font(.sInter(14, .bold))
                    }
                    .foregroundStyle(Color.sOnAccent)
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(Color.sMint)
                }
                .buttonStyle(PressedOpacityStyle())
            } else {
                Text("Not supported").font(.sMono(10, .bold)).textCase(.uppercase).foregroundStyle(Color.sText3)
            }
        }
        .padding(10)
        .background(Color.sS1)
        .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
        .contextMenu {
            Button { UIPasteboard.general.url = media.url } label: { Label("Copy video link", systemImage: "doc.on.doc") }
        }
    }
}

// MARK: - Bookmarks & history

struct LibraryView: View {
    var onOpen: (URL) -> Void
    var onClose: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    @State private var section: Int

    init(initialSection: Int = 0, onOpen: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
        _section = State(initialValue: initialSection)
    }
    @State private var confirmClear = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Library").sLabel(12)
                    Text(section == 0 ? "Bookmarks" : "History")
                        .font(.sDisplay(30, .heavy)).tracking(-0.8).foregroundStyle(Color.sText)
                }
                Spacer()
                if section == 1, !store.history.isEmpty {
                    SquareIconButton(systemImage: "trash", label: "Clear history") { confirmClear = true }
                }
                SquareIconButton(systemImage: "xmark", label: "Close", action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)

            Picker("", selection: $section) {
                Text("Bookmarks").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            List {
                if section == 0 {
                    if store.bookmarks.isEmpty { empty("No bookmarks yet. Use Add to bookmarks in the menu.") }
                    ForEach(store.bookmarks) { bookmark in
                        bookmarkRow(bookmark)
                    }
                    .onDelete { store.bookmarks.remove(atOffsets: $0) }
                    .onMove { store.bookmarks.move(fromOffsets: $0, toOffset: $1) }
                } else {
                    if store.history.isEmpty { empty("Pages you visit appear here.") }
                    ForEach(store.history) { entry in
                        row(title: entry.title, url: entry.url, iconURL: nil)
                    }
                    .onDelete { offsets in store.removeHistory(Set(offsets.map { store.history[$0].id })) }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
        }
        .background(Color.sBg.ignoresSafeArea())
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearHistory() }
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).font(.sInter(14)).foregroundStyle(Color.sText3).listRowBackground(Color.sBg)
    }

    private func bookmarkRow(_ bookmark: BrowserBookmark) -> some View {
        Button { onOpen(bookmark.url) } label: {
            HStack(spacing: 14) {
                PageThumbnail(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL)
                    .frame(width: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text(bookmark.title).font(.sInter(15, .semibold)).foregroundStyle(Color.sText).lineLimit(2)
                    HStack(spacing: 6) {
                        SiteIcon(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL, size: 14)
                        Text(bookmark.url.host ?? bookmark.url.absoluteString).font(.sMono(11, .medium))
                            .foregroundStyle(Color.sText3).lineLimit(1)
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .listRowBackground(Color.sBg)
        .listRowSeparatorTint(Color.sLine)
    }

    private func row(title: String, url: URL, iconURL: URL?) -> some View {
        Button { onOpen(url) } label: {
            HStack(spacing: 12) {
                SiteIcon(title: title, url: url, iconURL: iconURL, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.sInter(15, .medium)).foregroundStyle(Color.sText).lineLimit(1)
                    Text(url.absoluteString).font(.sMono(11, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                }
            }
        }
        .listRowBackground(Color.sBg)
        .listRowSeparatorTint(Color.sLine)
    }
}
