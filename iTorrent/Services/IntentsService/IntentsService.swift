//
//  IntentsService.swift
//  Pulled
//
//  Created by Даниил Виноградов on 30.06.2024.
//

import MvvmFoundation
import Foundation

actor IntentsService {
    init() {
        disposeBag.bind {
            NotificationCenter.default.publisher(for: .pauseTorrent)
                .receive(on: DispatchQueue.main).sink { notification in
                    guard let hash = notification.object as? String else { return }
                    if hash.hasPrefix("file-"), let id = UUID(uuidString: String(hash.dropFirst(5))) {
                        FileDownloadService.shared.pause(id)
                    } else if let torrentHandle = TorrentService.shared.torrents.values.first(where: { $0.snapshot.infoHashes.best.hex == hash }) {
                        torrentHandle.pauseDownload()
                    }
                }
        }
    }

    private let disposeBag = DisposeBag()
}
