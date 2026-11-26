# Drift

A minimal iOS web browser that saves the videos you watch, maintained by Raahat. The browser fills the app; one bottom dock holds the address bar and Back, Forward/Home, Menu, Downloads and Tabs. Downloads (everything the app did before: files, videos, torrents) slides up from the dock. Formerly Stash.

## Install

Add the combined source in **SideStore**, **AltStore** or **LiveContainer**. It lists both Drift and Midoku:

```
https://github.com/dreed-7896/Midoku/releases/download/source/apps.json
```

The Drift-only source still works:

```
https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json
```

Every successful build on `main` publishes a new IPA; the combined source picks it up within 30 minutes. iOS/iPadOS 16 or later is required. Updating from Stash keeps your downloads and settings.

## Browser

- One bottom dock: address bar with the ad-block shield, then Back, Forward/Home, Menu, Downloads (with a running-downloads badge) and Tabs. It tucks away while you scroll down and sits on the keyboard while you type
- Start page with your favorite sites as icon tiles; bookmarks and history with site icons
- Menu sheet: ad blocker for this site, desktop site, dark pages, private tab, find on page, bookmarks, history, downloads, files, settings, search engine (Google, DuckDuckGo, Bing, Brave), clear browsing data
- Tabs and private tabs (hold the tabs button for quick actions), long-press Back for history, pull to refresh
- Long-press a link to open it in a new or private tab, download it or bookmark it

### Ad blocker

On by default; turn it off per site from the shield or the menu.

- Blocks requests to ~3,600 ad, tracker and video-ad servers (bundled list, refreshed weekly from Peter Lowe's list), including video ad networks such as Google IMA, FreeWheel and SpotX
- Hides common ad containers and YouTube ad slots, strips ads from YouTube's player data and skips any that still play
- Blocks pop-ups and pop-unders from other sites (with an option to open one you wanted) and ad-network redirects

### Saving videos

Play a video on any site. When Drift sees it, a download button appears above the bottom bar; tap it to list the videos on the page and **Save** one. Drift watches `<video>` elements, media requests the page makes (including inside embedded players) and video URLs opened directly.

- **Files** (MP4, WebM, MOV…) download with parallel connections, using the page's cookies and referrer.
- **HLS streams** (`.m3u8`) download segment by segment at the best quality, decrypt AES-128 streams, and save as one `.ts` (or `.mp4` for fMP4 streams) that the built-in player opens. They pause and resume where they stopped.
- DASH streams and DRM-protected video can't be saved; they are listed as not supported.

## Sharing to Drift

Share a web page, a file link or a magnet link from any app and choose **Drift**. Drift opens and starts the download without a confirmation sheet.

- **Safari pages:** the share runs a small script on the page that finds the video playing on it. Drift downloads that video and saves the page as the download's **Website**.
- **Links from other apps:** if the link is a web page, Drift loads it and looks for its video (Open Graph video tags, `<video>`/`<source>` tags, embedded video links). Direct file links download as they are.
- **Expired links:** open the download and tap **Fetch again from website**. Drift finds the video on the saved page again and restarts the download from the fresh link. **Open website** opens the page in your browser.

Streaming-only videos (HLS/DASH or browser `blob:` players) have no single file to save. Drift lists the page as failed and keeps its website so you can open it.

iOS lets a share extension open its app only through a workaround. If iOS refuses, the share card shows **Open Drift** and the link stays queued. A LiveContainer guest cannot register its own share extension; install Drift through SideStore/AltStore for its own share-sheet entry.

## Downloads tab

- Web page video detection, with the source website saved for every download
- Direct HTTP/HTTPS downloads with up to 16 parallel connections (4 by default) and automatic single-connection fallback
- Torrents and magnet links
- Files browser with thumbnails, and a video gallery with duration badges
- Built-in VLC player with AirPlay and Picture in Picture
- Live Activities and Dynamic Island progress
- RSS feeds, WebDAV sharing and Files app integration
- Background downloads, app lock, iPhone and iPad layouts

## Development

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/dreed-7896/IDownloader.git
cd IDownloader
brew install boost
./Submodules/LibTorrent-Swift/make.sh
open iTorrent.xcworkspace
```

Use Xcode 26.6 and the `iTorrent` scheme. The inherited workspace and target names are retained as internal build identifiers. The installed app is named `Drift` (formerly Stash) (the built product is still `Pulled.app`). Its existing bundle identity (`com.dreed7896.IDownloader`), App Group, and background session identifiers are retained so updates preserve downloads, settings, sharing, and Live Activities. The repository and source URL stay stable.

The **Build and publish Stash** workflow (the IPA is still named `Stash.ipa`) builds each push to `main` and `claude/**` branches; only `main` publishes. Each build gets its own version (`1.0.<run number>`) and permanent release download URL. The source metadata reads the version, bundle identifier, minimum iOS version, and size from the actual packaged IPA.

## Credits and license

Drift is based on [iTorrent by XITRIX (Daniil Vinogradov)](https://github.com/XITRIX/iTorrent), distributed under the [MIT license](LICENSE.txt). The original copyright notice is preserved. This is an independently maintained project and does not automatically synchronize with upstream.

Includes LibTorrent, LibTorrent-Swift, MVVMFoundation, GCDWebServer, SwiftVLC, and other dependencies under their respective licenses.
