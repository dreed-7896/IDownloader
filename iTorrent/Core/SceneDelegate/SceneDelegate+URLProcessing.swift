//
//  SceneDelegate+URLProcessing.swift
//  Pulled
//
//  Created by Даниил Виноградов on 06.04.2024.
//

import LibTorrent
import MvvmFoundation
import UIKit

extension SceneDelegate {
    func processURL(_ url: URL) {
        Task {
            if ["pulled", "idownloader"].contains(url.scheme?.lowercased() ?? ""), url.host == "shared" {
                consumeSharedLinks()
                return
            }
            let filePrefix = url.absoluteString.hasPrefix("IDownloader:hash:file-") ? "IDownloader:hash:file-" : "Pulled:hash:file-"
            if url.absoluteString.hasPrefix(filePrefix),
               let id = UUID(uuidString: String(url.absoluteString.dropFirst(filePrefix.count))) {
                showFileDownloads(selected: id)
                return
            }
            if tryOpenTorrentDetails(with: url) { return }
            if tryOpenAddTorrent(with: url) { return }
            if tryOpenAddMagnet(with: url) { return }
            if url.pathExtension.lowercased() == "torrent", await tryOpenRemoteAddTorrent(with: url) { return }
            if let id = FileDownloadService.shared.add(url) { showFileDownloads(selected: id) }
        }
    }

    func consumeSharedLinks() {
        SharedDownloadInbox.consume { processURL($0) }
    }

    func showFileDownloads(selected: UUID? = nil) {
        guard let root = window?.rootViewController?.topPresented else { return }
        let navigation = root as? UINavigationController ?? root.navigationController
            ?? (root as? UISplitViewController)?.viewControllers.first as? UINavigationController
        guard let selected else { navigation?.popToRootViewController(animated: true); return }
        let controller = FileDownloadDetailsViewModel.resolveVC(with: selected)
        window?.rootViewController?.navigate(to: controller, by: .detail(asRoot: true))
    }
}

private extension SceneDelegate {
    // Open torrent details by hash from Life Activity
    func tryOpenTorrentDetails(with url: URL) -> Bool {
        let prefix = ["Pulled:hash:", "IDownloader:hash:", "iTorrent:hash:"].first { url.absoluteString.hasPrefix($0) } ?? "Pulled:hash:"

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
