//
//  BrowserStore.swift
//  Drift
//
//  Bookmarks, history, search engine, open tabs and browser switches, kept in UserDefaults.
//

import Combine
import Foundation

struct BrowserBookmark: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
}

struct BrowserHistoryEntry: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var url: URL
    var date = Date()
}

struct SavedBrowserTab: Codable {
    var url: URL?
    var title: String?
}

enum SearchEngine: String, Codable, CaseIterable, Identifiable {
    case google, duckDuckGo, bing, brave

    var id: String { rawValue }
    var title: String {
        switch self {
        case .google: return "Google"
        case .duckDuckGo: return "DuckDuckGo"
        case .bing: return "Bing"
        case .brave: return "Brave Search"
        }
    }

    func url(for query: String) -> URL? {
        var components: URLComponents?
        switch self {
        case .google: components = URLComponents(string: "https://www.google.com/search")
        case .duckDuckGo: components = URLComponents(string: "https://duckduckgo.com/")
        case .bing: components = URLComponents(string: "https://www.bing.com/search")
        case .brave: components = URLComponents(string: "https://search.brave.com/search")
        }
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        return components?.url
    }
}

final class BrowserStore: ObservableObject {
    static let shared = BrowserStore()

    @Published var bookmarks: [BrowserBookmark] { didSet { save(bookmarks, "browser.bookmarks") } }
    @Published private(set) var history: [BrowserHistoryEntry] { didSet { save(history, "browser.history") } }
    @Published var searchEngine: SearchEngine { didSet { save(searchEngine, "browser.searchEngine") } }
    @Published var adBlockEnabled: Bool { didSet { UserDefaults.standard.set(adBlockEnabled, forKey: "browser.adBlock") } }

    private let defaults = UserDefaults.standard

    private init() {
        bookmarks = Self.load("browser.bookmarks") ?? Self.defaultBookmarks
        history = Self.load("browser.history") ?? []
        searchEngine = Self.load("browser.searchEngine") ?? .google
        adBlockEnabled = UserDefaults.standard.object(forKey: "browser.adBlock") as? Bool ?? true
    }

    static let defaultBookmarks: [BrowserBookmark] = [
        ("Google", "https://www.google.com"),
        ("YouTube", "https://m.youtube.com"),
        ("Vimeo", "https://vimeo.com"),
        ("Dailymotion", "https://www.dailymotion.com"),
        ("Reddit", "https://www.reddit.com"),
        ("X", "https://x.com"),
        ("Wikipedia", "https://www.wikipedia.org"),
        ("Archive", "https://archive.org")
    ].compactMap { title, link in URL(string: link).map { BrowserBookmark(title: title, url: $0) } }

    // MARK: - Address bar

    /// A URL for typed text: a web address as is (https added when missing), anything else as a search.
    func url(for text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
           ["http", "https", "about", "file", "data", "magnet"].contains(scheme) {
            return url
        }
        let looksLikeHost = !trimmed.contains(" ") && (trimmed.contains(".") || trimmed.hasPrefix("localhost"))
            && !trimmed.hasSuffix(".")
        if looksLikeHost, let url = URL(string: "https://" + trimmed), url.host != nil { return url }
        return searchEngine.url(for: trimmed)
    }

    func suggestions(for text: String, limit: Int = 8) -> [BrowserHistoryEntry] {
        let query = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return [] }
        var seen = Set<URL>()
        let marks = bookmarks.map { BrowserHistoryEntry(title: $0.title, url: $0.url, date: .distantPast) }
        return (marks + history).filter { entry in
            (entry.title.lowercased().contains(query) || entry.url.absoluteString.lowercased().contains(query))
                && seen.insert(entry.url).inserted
        }.prefix(limit).map { $0 }
    }

    // MARK: - Bookmarks

    func isBookmarked(_ url: URL?) -> Bool {
        guard let url else { return false }
        return bookmarks.contains { $0.url == url }
    }

    func toggleBookmark(title: String?, url: URL) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) {
            bookmarks.remove(at: index)
        } else {
            let name = (title?.isEmpty == false ? title : nil) ?? url.host ?? url.absoluteString
            bookmarks.append(BrowserBookmark(title: name, url: url))
        }
    }

    // MARK: - History

    func record(title: String?, url: URL) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        let name = (title?.isEmpty == false ? title : nil) ?? url.host ?? url.absoluteString
        if let first = history.first, first.url == url {
            history[0].title = name
            history[0].date = Date()
            return
        }
        history.insert(BrowserHistoryEntry(title: name, url: url), at: 0)
        if history.count > 1000 { history.removeLast(history.count - 1000) }
    }

    func updateTitle(_ title: String, for url: URL) {
        guard !title.isEmpty, let index = history.prefix(5).firstIndex(where: { $0.url == url }), history[index].title != title else { return }
        history[index].title = title
    }

    func removeHistory(_ ids: Set<UUID>) { history.removeAll { ids.contains($0.id) } }
    func clearHistory() { history = [] }

    // MARK: - Tabs

    var savedTabs: [SavedBrowserTab] {
        get { Self.load("browser.tabs") ?? [] }
        set { save(newValue, "browser.tabs") }
    }

    var savedSelection: Int {
        get { defaults.integer(forKey: "browser.selectedTab") }
        set { defaults.set(newValue, forKey: "browser.selectedTab") }
    }

    // MARK: - Persistence

    private static func load<T: Decodable>(_ key: String) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) }
    }
}
