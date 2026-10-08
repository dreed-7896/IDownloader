# Pulled

An iOS download manager maintained by Raahat. Download files over HTTP/HTTPS and torrents, subscribe to RSS feeds, manage files, and play videos.

## Install and test

Add this source URL in **LiveContainer** or **SideStore**:

```
https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json
```

Refresh the source and install **Pulled**. After later changes, refresh it again and update the app. A successful build on `main` publishes a new IPA and refreshes the catalog automatically; a failed build keeps the previous working download available.

You can also download the IPA from [GitHub Releases](https://github.com/dreed-7896/IDownloader/releases). The IPA is unsigned, ready for LiveContainer import or signing by SideStore/AltStore. iOS/iPadOS 16 or later is required.

## Features

- Torrent and magnet link downloads
- Direct HTTP/HTTPS file downloads with up to 16 parallel parts (4 by default)
- Automatic single-connection fallback when a server does not support byte ranges
- Share HTTP/HTTPS or magnet links to Pulled from other apps
- File download history, pause/resume, retry, preview, and deletion
- Pause, resume, download priorities, and speed limits
- RSS feed subscriptions
- Files app integration and WebDAV sharing
- Built-in VLC playback with AirPlay and Picture in Picture
- Background download modes
- Live Activities and Dynamic Island progress
- iPhone and iPad layouts, themes, and alternate icons

## Downloads and sharing

Files and torrents appear together on the main download list, with an icon identifying each type. Choose **Download from URL** from the add menu. Tap any download for its details, including state, speed, time remaining, size, progress, source, and save location. File downloads show one progress segment per connection and individual connection byte counts. Magnet links start torrents; `.torrent` URLs keep the torrent import flow; other HTTP/HTTPS links download files. Use a direct file link: sharing a webpage downloads that page, rather than extracting its videos or attachments.

Set **Settings → Download queue → Download parts** to a number from 1 to 16. The downloader probes actual byte-range support, validates each part, and uses one connection if the server ignores ranges. The setting applies to new downloads. Files are saved in **On My iPhone → Pulled → Downloads**, in separate folders to prevent name collisions. Download progress uses the existing Live Activity/Dynamic Island layout, including speed, percentage, and time remaining.

The share extension queues links in an App Group and attempts to open Pulled. If iOS declines the handoff, open Pulled to start the queued downloads; the extension shows this instruction. Share extensions must be included when signing/installing the app. A LiveContainer guest cannot register its own share extension with iOS, so install Pulled directly through SideStore/AltStore to use its own entry in the system share sheet. With recent LiveContainer versions, you can instead select **LiveContainer → Pulled** from the share sheet to forward a URL to the guest app; see [LiveContainer's sharing guide](https://github.com/LiveContainer/LiveContainer#open-in-app-support).

**Settings → Download queue** controls active transfers and concurrent downloads across both torrents and file downloads. Each multipart file uses one queue slot, regardless of its connection count. Downloads are processed oldest first; waiting items show **Queued**, and pausing an item takes it out of the queue. Seeding has its own torrent-only limit and uses remaining active slots. Zero means unlimited.

File transfers use background URLSession tasks. Pausing suspends active connections; retrying a failed transfer restarts it. iOS controls scheduling while the app is suspended, and user force-quit stops background work until the app is reopened.

## Development

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/dreed-7896/IDownloader.git
cd IDownloader
brew install boost
./Submodules/LibTorrent-Swift/make.sh
open iTorrent.xcworkspace
```

Use Xcode 26.6 and the `iTorrent` scheme. The inherited workspace and target names are retained as internal build identifiers. The installed app is named `Pulled`. Its existing bundle identity (`com.dreed7896.IDownloader`), App Group, and background session identifiers are retained so updates preserve downloads, settings, sharing, and Live Activities. The repository and source URL stay stable.

The **Build and publish Pulled** workflow builds each push to `main`. Each build gets its own version (`1.0.<run number>`) and permanent release download URL. The source metadata reads the version, bundle identifier, minimum iOS version, and size from the actual packaged IPA.

## Credits and license

Pulled is based on [iTorrent by XITRIX (Daniil Vinogradov)](https://github.com/XITRIX/iTorrent), distributed under the [MIT license](LICENSE.txt). The original copyright notice is preserved. This is an independently maintained project and does not automatically synchronize with upstream.

Includes LibTorrent, LibTorrent-Swift, MVVMFoundation, GCDWebServer, SwiftVLC, and other dependencies under their respective licenses.
