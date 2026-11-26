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
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 4)

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 34) {
                    Spacer(minLength: max(24, proxy.size.height * 0.16))
                    VStack(spacing: 10) {
                        Text(isPrivate ? "Private" : "Drift")
                            .font(.sDisplay(64, .heavy))
                            .tracking(-2)
                            .foregroundStyle(Color.sMint)
                            .shadow(color: Color.sMint.opacity(0.55), radius: 24)
                        Text(isPrivate ? "Nothing from this tab is kept" : "Browse · Watch · Save").sLabel(12)
                    }

                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(store.favorites) { favorite in
                            Button { onOpen(favorite.url) } label: {
                                VStack(spacing: 8) {
                                    SiteIcon(title: favorite.title, url: favorite.url, iconURL: favorite.iconURL, size: 62)
                                    Text(favorite.title)
                                        .font(.sInter(12, .medium))
                                        .foregroundStyle(Color.sText2)
                                        .lineLimit(1)
                                }
                            }
                            .buttonStyle(PressedOpacityStyle())
                            .contextMenu {
                                Button(role: .destructive) {
                                    store.favorites.removeAll { $0.id == favorite.id }
                                } label: { Label("Remove from start page", systemImage: "trash") }
                            }
                        }
                        Button(action: onAdd) {
                            VStack(spacing: 8) {
                                Image(systemName: "plus")
                                    .font(.system(size: 22, weight: .semibold))
                                    .foregroundStyle(Color.sText2)
                                    .frame(width: 62, height: 62)
                                    .background(Color.sS2)
                                    .overlay(Rectangle().strokeBorder(Color.sLine2, lineWidth: 1))
                                Text("Add").font(.sInter(12, .medium)).foregroundStyle(Color.sText3)
                            }
                        }
                        .buttonStyle(PressedOpacityStyle())
                        .accessibilityLabel("Add to start page")
                    }
                    .padding(.horizontal, 20)

                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "arrow.down.to.line")
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
                    .padding(.horizontal, 20)
                }
                .padding(.bottom, 24)
                .frame(minHeight: proxy.size.height)
            }
        }
        .background(
            ZStack {
                Color.sBg
                RadialGradient(colors: [Color.sMint.opacity(isPrivate ? 0.10 : 0.22), .clear], center: UnitPoint(x: 0.25, y: 0.45),
                               startRadius: 10, endRadius: 420)
                RadialGradient(colors: [Color(red: 0.35, green: 0.25, blue: 0.75).opacity(0.22), .clear],
                               center: UnitPoint(x: 0.85, y: 0.7), startRadius: 10, endRadius: 380)
            }
            .ignoresSafeArea()
        )
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
                        row(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL)
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

    private func row(title: String, url: URL, iconURL: URL?) -> some View {
        Button { onOpen(url) } label: {
            HStack(spacing: 12) {
                SiteIcon(title: title, url: url, iconURL: iconURL, size: 40)
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
