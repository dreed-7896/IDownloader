import Combine
import LibTorrent
import MvvmFoundation
import SwiftUI

class TorrentListItemViewModel: BaseViewModelWith<TorrentHandle>, MvvmSelectableProtocol, ObservableObject, Identifiable {
    var torrentHandle: TorrentHandle!
    var fileID: UUID?
    var selectAction: (() -> Void)?
    var id: String { fileID?.uuidString ?? torrentHandle.snapshot.infoHashes.best.hex }
    var isFile: Bool { fileID != nil }
    var kindIcon: String { isFile ? "arrow.down.circle.fill" : "network" }
    var file: FileDownload? { FileDownloadService.shared.downloads.first { $0.id == fileID } }
    var listState: TorrentHandle.State {
        if isFile { return file?.listState ?? .finished }
        if DownloadQueue.shared.isQueued(torrentHandle) { return .paused }
        let snapshot = torrentHandle.snapshot
        if snapshot.isPaused && !snapshot.isFinished && snapshot.friendlyState != .storageError { return .paused }
        return snapshot.friendlyState
    }
    var addedDate: Date { isFile ? (file?.createdAt ?? .distantPast) : torrentHandle.metadata.dateAdded }
    var creationDate: Date { isFile ? (file?.createdAt ?? .distantPast) : (torrentHandle.snapshot.creationDate ?? addedDate) }
    var size: UInt64 { isFile ? UInt64(max(0, file?.totalBytes ?? 0)) : torrentHandle.snapshot.totalWanted }
    var canResume: Bool { isFile ? file.map { [.paused, .failed].contains($0.state) } ?? false : (torrentHandle.snapshot.canResume && !DownloadQueue.shared.isQueued(torrentHandle)) }
    var canPause: Bool { isFile ? file.map { [.queued, .preparing, .downloading].contains($0.state) } ?? false : (torrentHandle.snapshot.canPause || DownloadQueue.shared.isQueued(torrentHandle)) }

    @Published var title = ""
    @Published var progressText = ""
    @Published var statusText = ""
    @Published var progress: Double = 0
    @Published var connections: [Double] = [0]

    convenience init(fileID: UUID) {
        self.init()
        self.fileID = fileID
        updateUI()
        disposeBag.bind {
            FileDownloadService.shared.updates.filter { $0.id == fileID }
                .sink { [weak self] _ in self?.updateUI() }
        }
        selectAction = { [unowned self] in
            navigate(to: FileDownloadDetailsViewModel.self, with: fileID, by: .detail(asRoot: true))
        }
    }

    override func prepare(with model: TorrentHandle) {
        torrentHandle = model
        updateUI()
        disposeBag.bind {
            model.updatePublisher.receive(on: DispatchQueue.main).sink { [weak self] _ in self?.updateUI() }
            DownloadQueue.shared.changed.sink { [weak self] _ in self?.updateUI() }
        }
        selectAction = { [unowned self] in
            navigate(to: TorrentDetailsViewModel.self, with: model, by: .detail(asRoot: true))
        }
    }

    override func hash(into hasher: inout Hasher) { hasher.combine(id) }

    func resume() {
        if let fileID { FileDownloadService.shared.resume(fileID) } else { torrentHandle.resumeDownload() }
    }
    func pause() {
        if let fileID { FileDownloadService.shared.pause(fileID) } else { torrentHandle.pauseDownload() }
    }
    func delete(deleteFiles: Bool) {
        if let fileID { FileDownloadService.shared.remove(fileID, deleteFiles: deleteFiles) }
        else { TorrentService.shared.removeTorrent(by: torrentHandle.snapshot.infoHashes, deleteFiles: deleteFiles) }
    }
    @MainActor func previewController() -> UIViewController {
        if let fileID { return FileDownloadDetailsViewModel.resolveVC(with: fileID) }
        return TorrentDetailsViewModel.resolveVC(with: torrentHandle)
    }
    func removeTorrent() {
        alert(title: "Remove download?", message: title, actions: [
            .init(title: %"torrent.remove.action.dropData", style: .destructive, action: { [unowned self] in delete(deleteFiles: true) }),
            .init(title: %"torrent.remove.action.keepData", style: .default, action: { [unowned self] in delete(deleteFiles: false) }),
            .init(title: %"common.cancel", style: .cancel, isPrimary: true)
        ])
    }
    private func updateUI() {
        if let fileID {
            guard let file else { return }
            title = file.name
            progress = file.progress
            let received = UInt64(max(0, file.receivedBytes)).bitrateToHumanReadable
            let total = file.totalBytes > 0 ? UInt64(file.totalBytes).bitrateToHumanReadable : "Unknown size"
            progressText = file.totalBytes > 0 ? "\(received) of \(total) (\(String(format: "%.2f", progress * 100))%)" : "\(received) downloaded (size unknown)"
            statusText = file.stateTitle
            if file.state == .downloading {
                statusText += " - ↓ \(file.speed.bitrateToHumanReadable)/s - \(file.timeRemaining)"
            } else if file.state == .failed, let error = file.error { statusText += " - \(error)" }
            connections = FileDownloadService.shared.connections(fileID).map(\.progress)
        } else {
            let snapshot = torrentHandle.snapshot
            title = snapshot.name
            progress = snapshot.progress
            progressText = "\(snapshot.totalWantedDone.bitrateToHumanReadable) of \(snapshot.totalWanted.bitrateToHumanReadable) (\(String(format: "%.2f", progress * 100))%)"
            statusText = DownloadQueue.shared.isQueued(torrentHandle) ? "Queued" : snapshot.stateText
        }
    }
}
