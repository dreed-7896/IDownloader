# Stash

An iOS downloader for videos, files and torrents, maintained by Raahat. It shares Midoku's boxy dark design.

## Install

Add the combined source in **SideStore**, **AltStore** or **LiveContainer**. It lists both Stash and Midoku:

```
https://github.com/dreed-7896/Midoku/releases/download/source/apps.json
```

The Stash-only source still works:

```
https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json
```

Every successful build on `main` publishes a new IPA; the combined source picks it up within 30 minutes. iOS/iPadOS 16 or later is required.

## Sharing to Stash

Share a web page, a file link or a magnet link from any app and choose **Stash**. Stash opens and starts the download without a confirmation sheet.

- **Safari pages:** the share runs a small script on the page that finds the video playing on it. Stash downloads that video and saves the page as the download's **Website**.
- **Links from other apps:** if the link is a web page, Stash loads it and looks for its video (Open Graph video tags, `<video>`/`<source>` tags, embedded video links). Direct file links download as they are.
- **Expired links:** open the download and tap **Fetch again from website**. Stash finds the video on the saved page again and restarts the download from the fresh link. **Open website** opens the page in your browser.

Streaming-only videos (HLS/DASH or browser `blob:` players) have no single file to save. Stash lists the page as failed and keeps its website so you can open it.

iOS lets a share extension open its app only through a workaround. If iOS refuses, the share card shows **Open Stash** and the link stays queued. A LiveContainer guest cannot register its own share extension; install Stash through SideStore/AltStore for its own share-sheet entry.

## Features

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

Use Xcode 26.6 and the `iTorrent` scheme. The inherited workspace and target names are retained as internal build identifiers. The installed app is named `Stash` (the built product is still `Pulled.app`). Its existing bundle identity (`com.dreed7896.IDownloader`), App Group, and background session identifiers are retained so updates preserve downloads, settings, sharing, and Live Activities. The repository and source URL stay stable.

The **Build and publish Stash** workflow builds each push to `main` and `claude/**` branches; only `main` publishes. Each build gets its own version (`1.0.<run number>`) and permanent release download URL. The source metadata reads the version, bundle identifier, minimum iOS version, and size from the actual packaged IPA.

## Credits and license

Stash is based on [iTorrent by XITRIX (Daniil Vinogradov)](https://github.com/XITRIX/iTorrent), distributed under the [MIT license](LICENSE.txt). The original copyright notice is preserved. This is an independently maintained project and does not automatically synchronize with upstream.

Includes LibTorrent, LibTorrent-Swift, MVVMFoundation, GCDWebServer, SwiftVLC, and other dependencies under their respective licenses.
