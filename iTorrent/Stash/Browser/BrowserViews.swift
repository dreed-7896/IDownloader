//
//  BrowserViews.swift
//  Drift
//
//  SwiftUI screens of the browser: the start page, the tab switcher, the list of videos
//  found on a page, and bookmarks & history. Rounded, dark-first, Hugeicons throughout.
//

import SwiftUI

// MARK: - Shared pieces

/// Slight press feedback: fades and shrinks a touch.
struct DriftPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// A round icon button on a soft surface (close, share, clear…).
struct DriftCircleButton: View {
    let icon: Icon
    var label: String
    var size: CGFloat = 38
    var tint: Color = .sText
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            icon.view(size * 0.48)
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(Circle().fill(Color.sS2))
                .overlay(Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(DriftPressStyle())
        .accessibilityLabel(label)
    }
}

/// A capsule button: accent-filled when prominent, soft surface otherwise.
struct DriftCapsuleButton: View {
    let title: String
    var icon: Icon?
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let icon { icon.view(18) }
                Text(title).font(.sInter(15, .semibold)).lineLimit(1)
            }
            .foregroundStyle(prominent ? Color.sOnAccent : Color.sText)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(Capsule().fill(prominent ? Color.sMint : Color.sS2))
            .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.07), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(DriftPressStyle())
    }
}

/// Soft colored light behind a screen.
private struct GlowBackground: View {
    var muted = false

    var body: some View {
        ZStack {
            Color.sBg
            Circle()
                .fill(Brand.violet.opacity(muted ? 0.16 : 0.30))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: 150, y: -40)
            Circle()
                .fill(Brand.mint.opacity(muted ? 0.10 : 0.22))
                .frame(width: 380, height: 380)
                .blur(radius: 110)
                .offset(x: -170, y: -260)
            Circle()
                .fill(Brand.ember.opacity(muted ? 0.08 : 0.16))
                .frame(width: 360, height: 360)
                .blur(radius: 120)
                .offset(x: -120, y: 300)
        }
        .ignoresSafeArea()
    }
}

private struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.sInter(13, .semibold))
            .foregroundStyle(Color.sText3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Start page

struct StartPageView: View {
    var isPrivate: Bool
    var onOpen: (URL) -> Void
    var onAdd: () -> Void

    @ObservedObject private var store = BrowserStore.shared
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8, alignment: .top), count: 4)

    var body: some View {
        ScrollView {
            VStack(spacing: 30) {
                logo.padding(.top, 52)

                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(store.favorites) { favorite in
                        Button { onOpen(favorite.url) } label: {
                            VStack(spacing: 8) {
                                SiteIcon(title: favorite.title, url: favorite.url, iconURL: favorite.iconURL, size: 60, cornerRadius: 17)
                                    .shadow(color: .black.opacity(0.25), radius: 8, y: 4)
                                Text(favorite.title)
                                    .font(.sInter(12, .medium))
                                    .foregroundStyle(Color.sText2)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(DriftPressStyle())
                        .contextMenu {
                            Button(role: .destructive) {
                                store.favorites.removeAll { $0.id == favorite.id }
                            } label: { Label("Remove from start page", systemImage: "minus.circle") }
                        }
                    }
                    Button(action: onAdd) {
                        VStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 17, style: .continuous)
                                .strokeBorder(Color.sText3.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                                .frame(width: 60, height: 60)
                                .overlay(Icon.add.view(24).foregroundStyle(Color.sText2))
                            Text("Add").font(.sInter(12, .medium)).foregroundStyle(Color.sText3)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(DriftPressStyle())
                    .accessibilityLabel("Add to start page")
                }
                .padding(.horizontal, 14)

                if !store.bookmarks.isEmpty {
                    VStack(spacing: 12) {
                        SectionHeader(title: "Bookmarks").padding(.horizontal, 20)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(store.bookmarks.prefix(20)) { bookmark in
                                    Button { onOpen(bookmark.url) } label: {
                                        VStack(alignment: .leading, spacing: 8) {
                                            PageThumbnail(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL,
                                                          aspectRatio: 0.75, cornerRadius: 14)
                                            HStack(spacing: 6) {
                                                SiteIcon(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL,
                                                         size: 16, cornerRadius: 4)
                                                Text(bookmark.title)
                                                    .font(.sInter(12, .medium))
                                                    .foregroundStyle(Color.sText2)
                                                    .lineLimit(1)
                                            }
                                        }
                                        .frame(width: 120)
                                    }
                                    .buttonStyle(DriftPressStyle())
                                }
                            }
                            .padding(.horizontal, 20)
                        }
                    }
                }

                tipCard.padding(.horizontal, 16)
            }
            .padding(.bottom, 28)
        }
        .background(GlowBackground(muted: isPrivate))
    }

    private var logo: some View {
        VStack(spacing: 6) {
            if isPrivate {
                Icon.incognito.view(34)
                    .foregroundStyle(Color.sText2)
                    .padding(.bottom, 4)
            }
            Text(isPrivate ? "Private" : "Drift")
                .font(.sDisplay(56, .heavy))
                .tracking(-1.8)
                .foregroundStyle(LinearGradient(colors: isPrivate ? [Color.sText, Color.sText2] : [Brand.mint, Brand.teal],
                                                startPoint: .topLeading, endPoint: .bottomTrailing))
                .shadow(color: (isPrivate ? Color.clear : Brand.mint).opacity(0.25), radius: 18)
            Text(isPrivate ? "History and cookies from this tab are forgotten" : "Browse, watch and save")
                .font(.sInter(13, .medium))
                .foregroundStyle(Color.sText3)
        }
    }

    private var tipCard: some View {
        HStack(spacing: 14) {
            Icon.saveVideo.view(20)
                .foregroundStyle(Color.sOnAccent)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color.sMint))
            VStack(alignment: .leading, spacing: 2) {
                Text("Save any video").font(.sInter(14, .semibold)).foregroundStyle(Color.sText)
                Text("Play it, then tap the round download button.").font(.sInter(13)).foregroundStyle(Color.sText3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS1.opacity(0.75)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

// MARK: - Tabs

struct TabsView: View {
    @ObservedObject var session: BrowserSession
    var onDone: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tabs").font(.sDisplay(30, .heavy)).tracking(-0.8).foregroundStyle(Color.sText)
                    Text(session.tabs.count == 1 ? "1 open tab" : "\(session.tabs.count) open tabs")
                        .font(.sInter(13, .medium)).foregroundStyle(Color.sText3)
                }
                Spacer()
                Button {
                    session.closeAll()
                    onDone()
                } label: {
                    Text("Close all")
                        .font(.sInter(14, .semibold))
                        .foregroundStyle(Color.sCoral)
                        .padding(.horizontal, 14)
                        .frame(height: 36)
                        .background(Capsule().fill(Color.sCoral.opacity(0.12)))
                }
                .buttonStyle(DriftPressStyle())
            }
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 14)

            ScrollView {
                LazyVGrid(columns: columns, spacing: 16) {
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
                .padding(.top, 4)
                .padding(.bottom, 20)
            }

            HStack(spacing: 10) {
                DriftCapsuleButton(title: "Private", icon: .incognito) {
                    session.newTab(isPrivate: true)
                    onDone()
                }
                DriftCapsuleButton(title: "New tab", icon: .add, prominent: true) {
                    session.newTab()
                    onDone()
                }
                DriftCapsuleButton(title: "Done", action: onDone)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(Color.sS1.ignoresSafeArea(edges: .bottom))
            .overlay(Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1), alignment: .top)
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
                        Icon.incognito.view(15).foregroundStyle(Color.sText2)
                    } else if let url = tab.url, !tab.isHome {
                        SiteIcon(title: title, url: url, iconURL: tab.iconURL, size: 16, cornerRadius: 4)
                    } else {
                        Icon.grid.view(15).foregroundStyle(Color.sText3)
                    }
                    Text(title).font(.sInter(12, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                    Spacer(minLength: 34)
                }
                .padding(.leading, 11)
                .frame(height: 38)
                .background(selected ? Color.sS3 : Color.sS2)

                ZStack {
                    Color.sS1
                    if let snapshot = tab.snapshot, !tab.isHome {
                        Image(uiImage: snapshot).resizable().scaledToFill()
                    } else {
                        VStack(spacing: 8) {
                            (tab.url == nil || tab.isHome ? Icon.sparkles : Icon.globe).view(26)
                                .foregroundStyle(Color.sText3)
                            Text(tab.isHome || tab.url == nil ? "Start page" : tab.url?.host ?? "Start page")
                                .font(.sInter(12, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                        }
                        .padding(8)
                    }
                }
                .aspectRatio(0.78, contentMode: .fit)
                .frame(maxWidth: .infinity, alignment: .top)
                .clipped()
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(selected ? Color.sMint : Color.white.opacity(0.08), lineWidth: selected ? 2.5 : 1)
            )
            .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(DriftPressStyle())
        // Overlaid after the card's button so it always receives its own taps.
        .overlay(alignment: .topTrailing) {
            Button(action: onClose) {
                Icon.stop.view(12)
                    .foregroundStyle(Color.sText)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.sBg.opacity(0.65)))
                    .frame(width: 46, height: 38)
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
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Icon.video.view(22)
                    .foregroundStyle(Color.sOnAccent)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Color.sMint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(tab.media.count == 1 ? "1 video found" : "\(tab.media.count) videos found")
                        .font(.sDisplay(22, .heavy))
                        .tracking(-0.4)
                        .foregroundStyle(Color.sText)
                    Text(tab.url?.host ?? "This page")
                        .font(.sInter(13, .medium))
                        .foregroundStyle(Color.sText3)
                        .lineLimit(1)
                }
                Spacer()
                DriftCircleButton(icon: .stop, label: "Close", action: onClose)
            }

            if tab.media.isEmpty {
                VStack(spacing: 12) {
                    Icon.video.view(34).foregroundStyle(Color.sText3)
                    Text("No videos yet").font(.sInter(16, .semibold)).foregroundStyle(Color.sText)
                    Text("Start playing the video, then tap the download button again.")
                        .font(.sInter(14)).foregroundStyle(Color.sText3).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            (media.kind == .file ? Icon.video : Icon.globe).view(20)
                .foregroundStyle(media.canDownload ? Color.sMint : Color.sText3)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.sS2))
            VStack(alignment: .leading, spacing: 3) {
                Text(media.displayName).font(.sInter(15, .semibold)).foregroundStyle(Color.sText).lineLimit(1)
                Text(media.details).font(.sInter(12)).foregroundStyle(Color.sText3).lineLimit(2)
            }
            Spacer(minLength: 6)
            if media.canDownload {
                Button(action: onDownload) {
                    HStack(spacing: 6) {
                        Icon.saveVideo.view(16)
                        Text("Save").font(.sInter(14, .semibold))
                    }
                    .foregroundStyle(Color.sOnAccent)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(Capsule().fill(Color.sMint))
                }
                .buttonStyle(DriftPressStyle())
            } else {
                Text("Not supported")
                    .font(.sInter(11, .semibold))
                    .foregroundStyle(Color.sText3)
                    .padding(.horizontal, 10)
                    .frame(height: 26)
                    .background(Capsule().fill(Color.sS2))
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS1))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
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
    @State private var confirmClear = false

    init(initialSection: Int = 0, onOpen: @escaping (URL) -> Void, onClose: @escaping () -> Void) {
        self.onOpen = onOpen
        self.onClose = onClose
        _section = State(initialValue: initialSection)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                Text(section == 0 ? "Bookmarks" : "History")
                    .font(.sDisplay(30, .heavy)).tracking(-0.8).foregroundStyle(Color.sText)
                Spacer()
                if section == 1, !store.history.isEmpty {
                    DriftCircleButton(icon: .delete, label: "Clear history", tint: .sCoral) { confirmClear = true }
                }
                DriftCircleButton(icon: .stop, label: "Close", action: onClose)
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)

            Picker("", selection: $section) {
                Text("Bookmarks").tag(0)
                Text("History").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)

            if section == 0, store.bookmarks.isEmpty {
                emptyState(.bookmark, "No bookmarks yet", "Open the menu on any page and choose Add to bookmarks.")
            } else if section == 1, store.history.isEmpty {
                emptyState(.history, "No history", "Pages you visit appear here.")
            } else {
                List {
                    if section == 0 {
                        ForEach(store.bookmarks) { bookmark in
                            bookmarkRow(bookmark)
                        }
                        .onDelete { store.bookmarks.remove(atOffsets: $0) }
                        .onMove { store.bookmarks.move(fromOffsets: $0, toOffset: $1) }
                    } else {
                        ForEach(store.history) { entry in
                            historyRow(entry)
                        }
                        .onDelete { offsets in store.removeHistory(Set(offsets.map { store.history[$0].id })) }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
        .background(Color.sBg.ignoresSafeArea())
        .alert("Clear history?", isPresented: $confirmClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) { store.clearHistory() }
        }
    }

    private func emptyState(_ icon: Icon, _ title: String, _ detail: String) -> some View {
        VStack(spacing: 12) {
            icon.view(28)
                .foregroundStyle(Color.sText2)
                .frame(width: 64, height: 64)
                .background(Circle().fill(Color.sS2))
            Text(title).font(.sInter(17, .semibold)).foregroundStyle(Color.sText)
            Text(detail).font(.sInter(14)).foregroundStyle(Color.sText3).multilineTextAlignment(.center)
        }
        .padding(.horizontal, 40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, 60)
    }

    private func bookmarkRow(_ bookmark: BrowserBookmark) -> some View {
        Button { onOpen(bookmark.url) } label: {
            HStack(spacing: 14) {
                PageThumbnail(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL, aspectRatio: 0.8, cornerRadius: 10)
                    .frame(width: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text(bookmark.title).font(.sInter(15, .semibold)).foregroundStyle(Color.sText).lineLimit(2)
                    HStack(spacing: 6) {
                        SiteIcon(title: bookmark.title, url: bookmark.url, iconURL: bookmark.iconURL, size: 14, cornerRadius: 3.5)
                        Text(bookmark.url.host ?? bookmark.url.absoluteString)
                            .font(.sInter(12))
                            .foregroundStyle(Color.sText3)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(DriftPressStyle())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.white.opacity(0.06))
    }

    private func historyRow(_ entry: BrowserHistoryEntry) -> some View {
        Button { onOpen(entry.url) } label: {
            HStack(spacing: 12) {
                SiteIcon(title: entry.title, url: entry.url, size: 34, cornerRadius: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title).font(.sInter(15, .medium)).foregroundStyle(Color.sText).lineLimit(1)
                    Text(entry.url.host ?? entry.url.absoluteString).font(.sInter(12)).foregroundStyle(Color.sText3).lineLimit(1)
                }
                Spacer(minLength: 0)
                Text(entry.date, style: .time).font(.sInter(12)).foregroundStyle(Color.sText3)
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(DriftPressStyle())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Color.white.opacity(0.06))
    }
}
