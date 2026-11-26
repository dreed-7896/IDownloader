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

private struct SiteTile: View {
    let title: String
    let url: URL

    var body: some View {
        VStack(spacing: 8) {
            Text(initial)
                .font(.sDisplay(24, .heavy))
                .foregroundStyle(Color.sMint)
                .frame(maxWidth: .infinity)
                .aspectRatio(1, contentMode: .fit)
                .background(Color.sS1)
                .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
            Text(title)
                .font(.sInter(12, .medium))
                .foregroundStyle(Color.sText2)
                .lineLimit(1)
        }
    }

    private var initial: String {
        let source = title.isEmpty ? (url.host ?? "?") : title
        return String(source.prefix(1)).uppercased()
    }
}

// MARK: - Start page

struct StartPageView: View {
    var isPrivate: Bool
    var onOpen: (URL) -> Void
    var onSearch: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 14), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(isPrivate ? "Private tab" : "Browse · Watch · Save").sLabel(12)
                    Text(isPrivate ? "Nothing is kept." : "Drift")
                        .font(.sDisplay(isPrivate ? 34 : 52, .heavy))
                        .tracking(-1.2)
                        .foregroundStyle(Color.sText)
                    if isPrivate {
                        Text("History, cookies and site data from private tabs are forgotten when you close them.")
                            .font(.sInter(14))
                            .foregroundStyle(Color.sText3)
                    }
                }

                Button(action: onSearch) {
                    HStack(spacing: 10) {
                        Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .semibold))
                        Text("Search \(store.searchEngine.title) or enter address")
                            .font(.sInter(15, .medium))
                        Spacer()
                    }
                    .foregroundStyle(Color.sText3)
                    .padding(.horizontal, 14)
                    .frame(height: 52)
                    .background(Color.sS1)
                    .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
                }
                .buttonStyle(PressedOpacityStyle())

                if !store.bookmarks.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Favorites").sLabel(12)
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(store.bookmarks) { bookmark in
                                Button { onOpen(bookmark.url) } label: { SiteTile(title: bookmark.title, url: bookmark.url) }
                                    .buttonStyle(PressedOpacityStyle())
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            store.bookmarks.removeAll { $0.id == bookmark.id }
                                        } label: { Label("Remove", systemImage: "trash") }
                                    }
                            }
                        }
                    }
                }

                if !isPrivate, !store.history.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Recent").sLabel(12).padding(.bottom, 10)
                        ForEach(Array(store.history.prefix(6))) { entry in
                            Button { onOpen(entry.url) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "clock").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.sText3)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(entry.title).font(.sInter(15, .medium)).foregroundStyle(Color.sText).lineLimit(1)
                                        Text(entry.url.host ?? entry.url.absoluteString).font(.sMono(11, .medium))
                                            .foregroundStyle(Color.sText3).lineLimit(1)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(PressedOpacityStyle())
                            Rectangle().fill(Color.sLine).frame(height: 1)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(Color.sOnAccent)
                        .frame(width: 34, height: 34)
                        .background(Color.sMint)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Save any video").font(.sInter(15, .bold)).foregroundStyle(Color.sText)
                        Text("Play a video on any site. When the download button appears, tap it to save the video to Downloads.")
                            .font(.sInter(13)).foregroundStyle(Color.sText3)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sS1)
                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
            }
            .padding(20)
        }
        .background(Color.sBg.ignoresSafeArea())
    }
}

// MARK: - Tabs

struct TabsView: View {
    @ObservedObject var session: BrowserSession
    var onDone: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(session.tabs.count) open").sLabel(12)
                    Text("Tabs").font(.sDisplay(30, .heavy)).tracking(-0.8).foregroundStyle(Color.sText)
                }
                Spacer()
                Menu {
                    Button(role: .destructive) { session.closeAll(); onDone() } label: {
                        Label("Close all tabs", systemImage: "xmark.square")
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.sText)
                        .frame(width: 40, height: 40)
                        .background(Color.sS1)
                        .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
                }
                .accessibilityLabel("More")
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(session.tabs) { tab in
                        TabCard(tab: tab, selected: tab.id == session.selectedID,
                                onSelect: { session.select(tab.id); onDone() },
                                onClose: { withAnimation(.easeOut(duration: 0.2)) { session.close(tab.id) } })
                    }
                }
                .padding(.horizontal, 20)
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
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.sS1.ignoresSafeArea(edges: .bottom))
            .overlay(Rectangle().fill(Color.sLine2).frame(height: 1), alignment: .top)
        }
        .background(Color.sBg.ignoresSafeArea())
    }
}

private struct TabCard: View {
    @ObservedObject var tab: BrowserTab
    var selected: Bool
    var onSelect: () -> Void
    var onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                if tab.isPrivate {
                    Image(systemName: "eyeglasses").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.sText2)
                }
                Text(title).font(.sInter(12, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                Spacer(minLength: 4)
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Color.sText2)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close tab")
            }
            .padding(.leading, 10)
            .frame(height: 34)
            .background(selected ? Color.sS3 : Color.sS1)

            ZStack {
                Color.sS2
                if let snapshot = tab.snapshot {
                    Image(uiImage: snapshot).resizable().scaledToFill()
                } else {
                    VStack(spacing: 6) {
                        Image(systemName: tab.url == nil ? "sparkles" : "globe")
                            .font(.system(size: 22, weight: .semibold)).foregroundStyle(Color.sText3)
                        Text(tab.url?.host ?? "Start page").font(.sMono(11, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                    }
                    .padding(8)
                }
            }
            .frame(height: 190)
            .clipped()
        }
        .overlay(Rectangle().strokeBorder(selected ? Color.sMint : Color.sLine2, lineWidth: selected ? 2 : 1))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
    }

    private var title: String {
        if !tab.title.isEmpty { return tab.title }
        return tab.url?.host ?? (tab.isPrivate ? "Private tab" : "New tab")
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
    @State private var section = 0
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
                    if store.bookmarks.isEmpty { empty("No bookmarks yet. Use Add bookmark in the menu.") }
                    ForEach(store.bookmarks) { bookmark in
                        row(title: bookmark.title, url: bookmark.url, symbol: "star")
                    }
                    .onDelete { store.bookmarks.remove(atOffsets: $0) }
                    .onMove { store.bookmarks.move(fromOffsets: $0, toOffset: $1) }
                } else {
                    if store.history.isEmpty { empty("Pages you visit appear here.") }
                    ForEach(store.history) { entry in
                        row(title: entry.title, url: entry.url, symbol: "clock")
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

    private func row(title: String, url: URL, symbol: String) -> some View {
        Button { onOpen(url) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.sText3)
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
