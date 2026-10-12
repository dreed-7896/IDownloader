//
//  SceneDelegate+BackgroundDownload.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 05.04.2024.
//

import Combine
import LibTorrent
import UIKit

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
            .map { _ in () }
            .merge(with: FileDownloadService.shared.updates.map { _ in () })
            .merge(with: DownloadQueue.shared.changed)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                if UIApplication.shared.applicationState == .background { self?.startBackgroundIfNeeded() }
                guard !BackgroundService.isBackgroundNeeded else { return }
                BackgroundService.shared.stop()
            }
    }
}
