//
//  MediaSniffer.swift
//  Drift
//
//  A user script injected into every frame. It reports video it sees on the page to the app:
//  <video>/<source> elements, media and HLS/DASH playlists requested through fetch or XHR,
//  and resources the page loaded (Performance API). The app lists them under the download button.
//

import WebKit

enum MediaSniffer {
    static let handlerName = "driftMedia"

    static var userScript: WKUserScript {
        WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    private static let source = #"""
    (function () {
      if (window.__driftSniffer) { return; }
      window.__driftSniffer = true;
      var seen = {};
      var mediaExt = /\.(mp4|m4v|mov|webm|mkv|flv|avi|3gp|ogv|mpg|mpeg|wmv)(\?|#|$)/i;
      var hlsExt = /\.m3u8(\?|#|$)/i;
      var dashExt = /\.mpd(\?|#|$)/i;
      var segment = /\.(ts|m4s|m4a|m4v\.part|aac|vtt|webvtt|key)(\?|#|$)/i;

      function abs(u) { try { return new URL(u, document.baseURI).href; } catch (e) { return null; } }

      function post(url, kind, extra) {
        url = abs(url);
        if (!url || url.indexOf("http") !== 0) { return; }
        var level = extra && extra.width ? 2 : 1;
        var key = kind + "|" + url;
        if ((seen[key] || 0) >= level) { return; }
        seen[key] = level;
        var message = { url: url, kind: kind, frame: location.href, title: document.title };
        if (extra) { for (var k in extra) { message[k] = extra[k]; } }
        try { window.webkit.messageHandlers.driftMedia.postMessage(message); } catch (e) {}
      }

      function classify(url, type, extra) {
        if (!url || typeof url !== "string") { return; }
        if (url.indexOf("blob:") === 0 || url.indexOf("data:") === 0) { return; }
        type = (type || "").toLowerCase();
        if (hlsExt.test(url) || type.indexOf("mpegurl") >= 0) { return post(url, "hls", extra); }
        if (dashExt.test(url) || type.indexOf("dash+xml") >= 0) { return post(url, "dash", extra); }
        if (segment.test(url) || type.indexOf("mp2t") >= 0) { return; }
        if (mediaExt.test(url) || type.indexOf("video/") === 0) { return post(url, "file", extra); }
      }

      function scanVideo(video) {
        if (!video || video.tagName !== "VIDEO") { return; }
        var extra = {};
        if (isFinite(video.duration) && video.duration > 0) { extra.duration = video.duration; }
        if (video.videoWidth) { extra.width = video.videoWidth; extra.height = video.videoHeight; }
        if (video.poster) { extra.poster = abs(video.poster); }
        var sources = [video.currentSrc, video.src];
        Array.prototype.forEach.call(video.querySelectorAll("source"), function (s) { sources.push(s.src); });
        sources.forEach(function (src) {
          if (!src || src.indexOf("blob:") === 0 || src.indexOf("data:") === 0) { return; }
          if (hlsExt.test(src)) { post(src, "hls", extra); }
          else if (dashExt.test(src)) { post(src, "dash", extra); }
          else { post(src, "file", extra); }
        });
      }

      function scanAll() {
        Array.prototype.forEach.call(document.querySelectorAll("video"), scanVideo);
        try {
          performance.getEntriesByType("resource").forEach(function (entry) { classify(entry.name, ""); });
        } catch (e) {}
      }

      var originalFetch = window.fetch;
      if (originalFetch) {
        window.fetch = function (input) {
          var url = typeof input === "string" ? input : (input && input.url);
          classify(url ? abs(url) : null, "");
          return originalFetch.apply(this, arguments).then(function (response) {
            try { classify(response.url, response.headers.get("content-type")); } catch (e) {}
            return response;
          });
        };
      }

      var originalOpen = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function (method, url) {
        this.__driftURL = url ? abs(String(url)) : null;
        classify(this.__driftURL, "");
        return originalOpen.apply(this, arguments);
      };
      var originalSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function () {
        var request = this;
        request.addEventListener("load", function () {
          try { classify(request.responseURL || request.__driftURL, request.getResponseHeader("content-type")); } catch (e) {}
        });
        return originalSend.apply(this, arguments);
      };

      ["loadedmetadata", "play", "playing", "durationchange"].forEach(function (name) {
        document.addEventListener(name, function (event) { scanVideo(event.target); }, true);
      });

      try {
        new PerformanceObserver(function (list) {
          list.getEntries().forEach(function (entry) { classify(entry.name, ""); });
        }).observe({ entryTypes: ["resource"] });
      } catch (e) {}

      document.addEventListener("DOMContentLoaded", scanAll);
      window.addEventListener("load", scanAll);
      setInterval(scanAll, 3000);
    })();
    """#
}

/// A small content blocker for common ad and pop-under networks.
enum AdBlocker {
    static let identifier = "DriftAdBlock.v1"

    private static let hosts = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "adnxs.com", "adsrvr.org", "advertising.com", "taboola.com", "outbrain.com", "criteo.com", "criteo.net",
        "amazon-adsystem.com", "pubmatic.com", "rubiconproject.com", "openx.net", "casalemedia.com", "moatads.com",
        "popads.net", "popcash.net", "propellerads.com", "propellerclick.com", "exoclick.com", "exosrv.com",
        "juicyads.com", "trafficjunky.net", "trafficjunky.com", "adsterra.com", "adsterratools.com", "hilltopads.net",
        "clickadu.com", "onclickads.net", "onclkds.com", "adcash.com", "admaven.com", "ad-maven.com", "mgid.com",
        "revcontent.com", "zedo.com", "yllix.com", "a-ads.com", "bidvertiser.com", "adform.net", "smartadserver.com",
        "media.net", "33across.com", "sharethrough.com", "teads.tv", "spotxchange.com", "springserve.com",
        "scorecardresearch.com", "quantserve.com", "zergnet.com", "realsrv.com", "tsyndicate.com", "adspyglass.com"
    ]

    static var rules: String {
        let entries = hosts.map { host -> String in
            let escaped = host.replacingOccurrences(of: ".", with: "\\\\.")
            return #"{"trigger":{"url-filter":"^https?://([^/]+\\.)?"# + escaped + #"[:/]"},"action":{"type":"block"}}"#
        }
        return "[" + entries.joined(separator: ",") + "]"
    }

    private static var cached: WKContentRuleList?

    static func ruleList() async -> WKContentRuleList? {
        if let cached { return cached }
        guard let store = WKContentRuleListStore.default() else { return nil }
        let existing: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, _ in continuation.resume(returning: list) }
        }
        if let existing { cached = existing; return existing }
        let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: rules) { list, _ in
                continuation.resume(returning: list)
            }
        }
        cached = compiled
        return compiled
    }
}
