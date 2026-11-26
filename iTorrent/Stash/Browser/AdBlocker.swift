//
//  AdBlocker.swift
//  Drift
//
//  Blocks ads three ways:
//  1. Network: a WebKit content blocker built from ~3,600 ad, tracker and video-ad servers
//     (bundled, refreshed weekly from the Peter Lowe list), so ad requests never load.
//  2. Cosmetic: common ad containers are hidden so pages don't keep empty boxes.
//  3. Scripts: YouTube's ad data is stripped from player responses and leftover ads are skipped.
//  Cross-site pop-ups are blocked by the browser itself (see BrowserViewController).
//  Sites the user turns it off for are exempted from all three.
//

import Foundation
import WebKit

enum AdBlocker {
    // MARK: - Hosts

    private static var updatedHostsURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Browser", isDirectory: true).appendingPathComponent("adhosts.txt")
    }

    private static func parse(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let host = line.trimmingCharacters(in: .whitespaces).lowercased()
            guard !host.isEmpty, !host.hasPrefix("#"), host.contains("."), !host.contains(" ") else { return nil }
            return host
        })
    }

    /// Bundled hosts plus the latest downloaded list.
    static let hosts: Set<String> = {
        var result = Set<String>()
        if let url = Bundle.main.url(forResource: "adhosts", withExtension: "txt")
            ?? Bundle.main.url(forResource: "adhosts", withExtension: "txt", subdirectory: "Resources"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            result = parse(text)
        }
        if let text = try? String(contentsOf: updatedHostsURL, encoding: .utf8) { result.formUnion(parse(text)) }
        return result
    }()

    /// True when `host` or one of its parent domains is an ad server.
    static func isAdHost(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        while true {
            if hosts.contains(host) { return true }
            guard let dot = host.firstIndex(of: ".") else { return false }
            host = String(host[host.index(after: dot)...])
            if !host.contains(".") { return false }
        }
    }

    /// Downloads a fresh server list at most once a week. It takes effect on the next launch.
    static func refreshListIfNeeded() {
        let key = "browser.adHostsUpdated"
        let last = UserDefaults.standard.object(forKey: key) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 7 * 24 * 3600,
              let url = URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=nohtml&showintro=0&mimetype=plaintext")
        else { return }
        Task.detached(priority: .background) {
            guard let result = try? await URLSession.shared.data(from: url),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return }
            let data = result.0
            guard let text = String(data: data, encoding: .utf8), parse(text).count > 1000 else { return }
            try? FileManager.default.createDirectory(at: updatedHostsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: updatedHostsURL, options: .atomic)
            UserDefaults.standard.set(Date(), forKey: key)
        }
    }

    // MARK: - Content rules

    private static let genericHide = [
        "ins.adsbygoogle", ".adsbygoogle", "[id^=\"google_ads_iframe\"]", "[id^=\"div-gpt-ad\"]", "div[data-ad-slot]",
        "div[data-google-query-id]", "[data-ad-unit]", "[data-adunit]", ".ad-slot", ".ad-banner", ".ad-unit", ".adsbox",
        ".advertisement", ".ad-container", "#ad-container", ".ads-container", ".banner-ad", ".top-ad", ".sticky-ad",
        ".adunit", "amp-ad", "amp-embed[type=\"taboola\"]", "amp-sticky-ad", "[id^=\"taboola-\"]", ".trc_rbox_container",
        ".OUTBRAIN", "[data-widget-id^=\"outbrain\"]", ".ob-widget", "iframe[src*=\"doubleclick.net\"]",
        "iframe[src*=\"googlesyndication.com\"]", "iframe[src*=\"amazon-adsystem.com\"]", "[aria-label=\"Advertisement\"]",
        "[aria-label=\"advertisement\"]", ".mgbox", "[id^=\"mgid_\"]", ".sponsored-ad", "#player-ads", ".video-ads"
    ]

    private static let youtubeHide = [
        "ytd-ad-slot-renderer", "ytm-ad-slot-renderer", "ad-slot-renderer", "ytm-promoted-sparkles-web-renderer",
        "ytm-promoted-video-renderer", "ytm-companion-ad-renderer", "ytd-in-feed-ad-layout-renderer", "ytd-banner-promo-renderer",
        "ytm-statement-banner-renderer", "ytd-promoted-sparkles-web-renderer", "ytd-player-legacy-desktop-watch-ads-renderer",
        ".ytp-ad-module", ".ytp-ad-overlay-container", "ytm-paid-content-overlay-renderer", "ytd-merch-shelf-renderer",
        "#masthead-ad", "ytm-mealbar-promo-renderer"
    ]

    static func rules(allowlist: [String]) -> String {
        var rules: [[String: Any]] = hosts.sorted().map { host -> [String: Any] in
            let escaped = host.replacingOccurrences(of: ".", with: "\\.").replacingOccurrences(of: "-", with: "\\-")
            return ["trigger": ["url-filter": "^https?://([^/]*\\.)?" + escaped + "[:/]"], "action": ["type": "block"]]
        }
        rules.append(["trigger": ["url-filter": ".*"], "action": ["type": "css-display-none", "selector": genericHide.joined(separator: ",")]])
        rules.append(["trigger": ["url-filter": ".*", "if-domain": ["*youtube.com"]],
                      "action": ["type": "css-display-none", "selector": youtubeHide.joined(separator: ",")]])
        if !allowlist.isEmpty {
            rules.append(["trigger": ["url-filter": ".*", "if-domain": allowlist.map { "*" + $0 }],
                          "action": ["type": "ignore-previous-rules"]])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rules)) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private static var cache: [String: WKContentRuleList] = [:]

    /// The compiled rule list for the current allowlist (compiled once, then loaded from WebKit's store).
    static func ruleList(allowlist: [String]) async -> WKContentRuleList? {
        let sortedList = allowlist.sorted()
        let signature = "\(hosts.count)-" + sortedList.joined(separator: ",")
        let identifier = "DriftAdBlock.v2." + stableHash(signature)
        if let cached = cache[identifier] { return cached }
        guard let store = WKContentRuleListStore.default() else { return nil }
        let existing: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
        if let existing { cache[identifier] = existing; return existing }
        let source = rules(allowlist: sortedList)
        let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: source) { list, error in
                if let error { print("Ad block rules: \(error)") }
                continuation.resume(returning: list)
            }
        }
        if let compiled { cache[identifier] = compiled }
        return compiled
    }

    private static func stableHash(_ text: String) -> String {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(value, radix: 36)
    }
}

/// Scripts injected into pages, rebuilt when the related settings change.
enum PageScripts {
    /// Removes YouTube's ad payload before the player sees it and skips any ad that still plays.
    static func youtube(allowlist: [String]) -> String {
        let skipped = allowlist.contains("youtube.com") ? "true" : "false"
        return """
        (function () {
          if (\(skipped) || !/(^|\\.)youtube\\.com$/.test(location.hostname)) { return; }
          var keys = ["adPlacements", "adSlots", "playerAds", "adBreakHeartbeatParams", "adBreakParams"];
          function prune(o) {
            if (!o || typeof o !== "object") { return o; }
            keys.forEach(function (k) { if (k in o) { try { delete o[k]; } catch (e) {} } });
            if (o.playerResponse) { prune(o.playerResponse); }
            if (Array.isArray(o)) { o.forEach(prune); }
            return o;
          }
          var parse = JSON.parse;
          JSON.parse = function () { var r = parse.apply(this, arguments); try { prune(r); } catch (e) {} return r; };
          var json = Response.prototype.json;
          Response.prototype.json = function () {
            return json.apply(this, arguments).then(function (r) { try { prune(r); } catch (e) {} return r; });
          };
          var initial;
          try {
            Object.defineProperty(window, "ytInitialPlayerResponse", {
              configurable: true,
              get: function () { return initial; },
              set: function (v) { initial = prune(v); }
            });
          } catch (e) {}
          setInterval(function () {
            var player = document.querySelector(".ad-showing, .ad-interrupting");
            if (player) {
              var video = player.querySelector("video");
              if (video && isFinite(video.duration) && video.duration > 0) { video.muted = true; video.currentTime = video.duration; }
            }
            var skip = document.querySelector(".ytp-ad-skip-button, .ytp-ad-skip-button-modern, .ytp-skip-ad-button, .ytm-skip-ad-button, button.ytp-ad-skip-button-container");
            if (skip) { skip.click(); }
            var overlay = document.querySelector(".ytp-ad-overlay-close-button");
            if (overlay) { overlay.click(); }
          }, 400);
        })();
        """
    }

    static let darkPages = """
    (function () {
      if (document.getElementById("drift-dark")) { return; }
      var style = document.createElement("style");
      style.id = "drift-dark";
      style.textContent = "html{filter:invert(0.9) hue-rotate(180deg)!important;background:#fff!important}" +
        "img,video,picture,canvas,iframe,embed,object,svg image,[style*='background-image']{filter:invert(1) hue-rotate(180deg)!important}";
      (document.head || document.documentElement).appendChild(style);
    })();
    """

    static let removeDarkPages = "(function(){var s=document.getElementById('drift-dark');if(s){s.remove();}})();"

    /// The page's best icon: apple-touch-icon, else the largest declared favicon.
    static let bestIcon = """
    (function () {
      var best = null, size = 0;
      document.querySelectorAll("link[rel~='icon'], link[rel~='apple-touch-icon'], link[rel='apple-touch-icon-precomposed']").forEach(function (link) {
        var declared = parseInt(((link.sizes && link.sizes.value) || "").split("x")[0], 10);
        var s = declared || (link.rel.indexOf("apple") >= 0 ? 180 : 16);
        if (link.href && s > size) { size = s; best = link.href; }
      });
      return best;
    })();
    """

    /// Installs the sniffer, ad scripts and dark pages on a content controller (replacing earlier ones).
    static func install(on controller: WKUserContentController) {
        let store = BrowserStore.shared
        controller.removeAllUserScripts()
        controller.addUserScript(MediaSniffer.userScript)
        if store.adBlockEnabled {
            controller.addUserScript(WKUserScript(source: youtube(allowlist: store.adBlockAllowlist),
                                                  injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        if store.darkPages {
            controller.addUserScript(WKUserScript(source: darkPages, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }
}

/// The rule list currently attached to web views, kept so new tabs can attach it synchronously.
enum AdBlockCache {
    static var list: WKContentRuleList?

    @discardableResult
    static func prepare() async -> WKContentRuleList? {
        list = await AdBlocker.ruleList(allowlist: BrowserStore.shared.adBlockAllowlist)
        return list
    }
}
