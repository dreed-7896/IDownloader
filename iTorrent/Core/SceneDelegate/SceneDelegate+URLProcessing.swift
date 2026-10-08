//
//  SceneDelegate+URLProcessing.swift
//  IDownloader
//
//  Created by Даниил Виноградов on 06.04.2024.
//

import LibTorrent
import UIKit

extension SceneDelegate {
    func processURL(_ url: URL) {
        Task {
            if url.scheme?.lowercased() == "idownloader", url.host == "shared" {
                consumeSharedLinks()
                return
            }
            if url.absoluteString.hasPrefix("IDownloader:hash:file-"),
               let id = UUID(uuidString: String(url.absoluteString.dropFirst("IDownloader:hash:file-".count))) {
                showFileDownloads(selected: id)
                return
            }
            if tryOpenTorrentDetails(with: url) { return }
            if tryOpenAddTorrent(with: url) { return }
            if tryOpenAddMagnet(with: url) { return }
            if url.pathExtension.lowercased() == "torrent", await tryOpenRemoteAddTorrent(with: url) { return }
            if FileDownloadService.shared.add(url) != nil { showFileDownloads() }
        }
    }

    func consumeSharedLinks() {
        SharedDownloadInbox.consume { processURL($0) }
    }

    func showFileDownloads(selected: UUID? = nil) {
        guard let root = window?.rootViewController?.topPresented else { return }
        let navigation = root as? UINavigationController ?? root.navigationController
            ?? (root as? UISplitViewController)?.viewControllers.first as? UINavigationController
        if let existing = navigation?.viewControllers.last as? FileDownloadsViewController {
            existing.selectedDownload = selected
            return
        }
        let controller = FileDownloadsViewController()
        controller.selectedDownload = selected
        if let navigation { navigation.pushViewController(controller, animated: true) }
        else {
            controller.showsCloseButton = true
            root.present(UINavigationController(rootViewController: controller), animated: true)
        }
    }
}

private extension SceneDelegate {
    // Open torrent details by hash from Life Activity
    func tryOpenTorrentDetails(with url: URL) -> Bool {
        let prefix = url.absoluteString.hasPrefix("iTorrent:hash:") ? "iTorrent:hash:" : "IDownloader:hash:"

        guard url.absoluteString.hasPrefix(prefix) else { return false }
        let hash = url.absoluteString.replacingOccurrences(of: prefix, with: "")

        guard let torrent = TorrentService.shared.torrents.values.first(where: { $0.snapshot.infoHashes.best.hex == hash })
        else { return false }

        AppDelegate.showTorrentDetailScreen(with: torrent)
        return true
    }

    // Add new torrent flow by file URL
    func tryOpenAddTorrent(with url: URL) -> Bool {
        guard url.isFileURL, url.pathExtension.lowercased() == "torrent",
              let rootViewController = window?.rootViewController?.topPresented
        else {
            return false
        }

        TorrentAddViewModel.present(with: url, from: rootViewController)
        return true
    }

    // Add new torrent by Magnet URL
    func tryOpenAddMagnet(with url: URL) -> Bool {
        guard url.scheme?.lowercased() == "magnet",
              let magnet = MagnetURI(with: url)
        else { return false }

        TorrentService.shared.addTorrent(by: magnet)
        return true
    }

    // Add new torrent flow by file remote URL
    func tryOpenRemoteAddTorrent(with url: URL) async -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased()),
              let rootViewController = window?.rootViewController?.topPresented
        else { return false }

        do {
            let torrentFile = try await TorrentFile.download(from: url)
            TorrentAddViewModel.present(with: torrentFile, from: rootViewController)
        } catch {
            rootViewController.presentRemoteTorrentDownloadError(error, url: url)
        }
        return true
    }
}

extension UIViewController {
    func presentRemoteTorrentDownloadError(_ error: Error, url: URL) {
        let message: String
        switch error {
        case RemoteTorrentFileError.httpStatus(let status) where status == 401 || status == 403:
            message = %"list.add.url.error.authentication"
        case RemoteTorrentFileError.httpStatus(let status):
            message = String(format: %"list.add.url.error.http", status)
        case RemoteTorrentFileError.invalidTorrent:
            message = %"list.add.url.error.invalidTorrent"
        case RemoteTorrentFileError.invalidResponse:
            message = %"list.add.url.error"
        default:
            message = error.localizedDescription
        }

        let alert = UIAlertController(title: %"common.error", message: message, preferredStyle: .alert)
        alert.addAction(.init(title: %"common.close", style: .cancel))
#if canImport(SafariServices)
        alert.addAction(.init(title: %"list.add.url.openInBrowser", style: .default) { [weak self] _ in
            self?.present(BaseSafariViewController(url: url), animated: true)
        })
#endif
        present(alert, animated: true)
    }
}
