//
//  SceneDelegate+BackgroundDownload.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 05.04.2024.
//

import Combine
import LibTorrent

extension SceneDelegate {
    func startBackgroundIfNeeded() {
        if PreferencesStorage.shared.isBackgroundDownloadEnabled, BackgroundService.isBackgroundNeeded {
            BackgroundService.shared.start()
        }
    }

    func stopBackground() {
        BackgroundService.shared.stop()
    }

    var backgroundStateObserverBind: AnyCancellable {
        TorrentService.shared.updateNotifier
            .filter { _ in BackgroundService.shared.isRunning }
            .filter { $0.oldSnapshot.friendlyState != $0.handle?.snapshot.friendlyState }
            .map { _ in () }
            .merge(with: FileDownloadService.shared.updates.map { _ in () })
            .sink { _ in
                guard !BackgroundService.isBackgroundNeeded else { return }
                BackgroundService.shared.stop()
            }
    }
}
