# IDownloader

An iOS download manager maintained by Raahat. The app currently supports torrent downloads, RSS feeds, file management, and video playback. Direct HTTP/HTTPS file downloads are planned.

## Install and test

Add this source URL in **LiveContainer** or **SideStore**:

```
https://github.com/dreed-7896/IDownloader/releases/download/nightly/source.json
```

Refresh the source and install **IDownloader**. After later changes, refresh it again and update the app. A successful build on `main` publishes a new IPA and refreshes the catalog automatically; a failed build keeps the previous working download available.

You can also download the IPA from [GitHub Releases](https://github.com/dreed-7896/IDownloader/releases). The IPA is unsigned, ready for LiveContainer import or signing by SideStore/AltStore. iOS/iPadOS 16 or later is required.

## Features

- Torrent and magnet link downloads
- Pause, resume, download priorities, and speed limits
- RSS feed subscriptions
- Files app integration and WebDAV sharing
- Built-in VLC playback with AirPlay and Picture in Picture
- Background download modes
- Live Activities and Dynamic Island progress
- iPhone and iPad layouts, themes, and alternate icons

## Development

Clone with submodules:

```sh
git clone --recurse-submodules https://github.com/dreed-7896/IDownloader.git
cd IDownloader
brew install boost
./Submodules/LibTorrent-Swift/make.sh
open iTorrent.xcworkspace
```

Use Xcode 26.6 and the `iTorrent` scheme. The inherited workspace and target names are retained as internal build identifiers. The installed app name and bundle identifier are `IDownloader` and `com.dreed7896.IDownloader`.

The **Build and publish IDownloader** workflow builds each push to `main`. Each build gets its own version (`1.0.<run number>`) and permanent release download URL. The source metadata reads the version, bundle identifier, minimum iOS version, and size from the actual packaged IPA.

## Credits and license

IDownloader is based on [iTorrent by XITRIX (Daniil Vinogradov)](https://github.com/XITRIX/iTorrent), distributed under the [MIT license](LICENSE.txt). The original copyright notice is preserved. This is an independently maintained project and does not automatically synchronize with upstream.

Includes LibTorrent, LibTorrent-Swift, MVVMFoundation, GCDWebServer, SwiftVLC, and other dependencies under their respective licenses.
