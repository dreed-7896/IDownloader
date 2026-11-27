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
    var kindIcon: String {
        guard isFile else { return "point.3.connected.trianglepath.dotted" }
        let ext = (file?.name as NSString?)?.pathExtension.lowercased() ?? ""
        if ThumbnailProvider.videoExtensions.contains(ext) { return "film" }
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) { return "waveform" }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) { return "photo" }
        if ["zip", "rar", "7z", "gz", "tar", "xz"].contains(ext) { return "shippingbox" }
        if file?.state == .failed, file?.page == file?.url { return "safari" }
        return "doc"
    }
    private var fileExtension: String { (file?.name as NSString?)?.pathExtension.lowercased() ?? "" }
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"]
    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic"]
    private static let archiveExtensions: Set<String> = ["zip", "rar", "7z", "gz", "tar", "xz"]

    var isVideoFile: Bool { isFile && ThumbnailProvider.videoExtensions.contains(fileExtension) }

    /// The Hugeicon for the download's kind (shown until a thumbnail is available).
    var kindHugeIcon: Icon {
        guard isFile else { return .magnet }
        let ext = fileExtension
        if ThumbnailProvider.videoExtensions.contains(ext) { return .film }
        if Self.audioExtensions.contains(ext) { return .music }
        if Self.imageExtensions.contains(ext) { return .image }
        if Self.archiveExtensions.contains(ext) { return .fileZip }
        if file?.state == .failed, file?.page == file?.url { return .globe }
        return .file
    }

    /// The tint of the kind tile.
    var kindTint: Color {
        guard isFile else { return Brand.teal }
        let ext = fileExtension
        if ThumbnailProvider.videoExtensions.contains(ext) { return Brand.violet }
        if Self.audioExtensions.contains(ext) { return Brand.ember }
        if Self.imageExtensions.contains(ext) { return Brand.teal }
        if Self.archiveExtensions.contains(ext) { return Color.sAmber }
        if file?.state == .failed { return Color.sCoral }
        return Color.sText2
    }

    /// The saved file, for a thumbnail: completed videos and images only.
    var thumbnailURL: URL? {
        guard let fileID, let file, file.state == .completed else { return nil }
        let ext = fileExtension
        guard ThumbnailProvider.videoExtensions.contains(ext) || Self.imageExtensions.contains(ext) else { return nil }
        return FileDownloadService.shared.fileURL(fileID)
    }

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
    @Published var stateLabel = ""
    @Published var stateColor = Color.sText
    @Published var metaText = ""
    @Published var detailText = ""
    /// A small icon in the status pill (done, failed, paused).
    @Published var stateIcon: Icon?
    /// The progress bar shows while a download is unfinished.
    @Published var showsProgress = true

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
            stateLabel = file.stateTitle
            switch file.state {
            case .completed:
                stateColor = .sMint
                stateIcon = .checkCircle
            case .failed:
                stateColor = .sCoral
                stateIcon = .alert
            case .paused:
                stateColor = .sAmber
                stateIcon = .pause
            case .queued, .preparing:
                stateColor = .sText2
                stateIcon = nil
            case .downloading, .assembling:
                stateColor = .sMint
                stateIcon = nil
            }
            showsProgress = file.state != .completed && file.state != .failed
            let host = file.page?.host ?? file.url.host ?? ""
            if file.state == .downloading {
                metaText = "\(Int(progress * 100))% · \(file.speed.bitrateToHumanReadable)/s · \(file.timeRemaining)"
            } else if file.state == .completed {
                metaText = [total, host].filter { !$0.isEmpty && $0 != "Unknown size" }.joined(separator: " · ")
            } else {
                metaText = file.totalBytes > 0 ? "\(received) / \(total)" : host
            }
            detailText = file.state == .failed ? (file.error ?? "") : ""
        } else {
            let snapshot = torrentHandle.snapshot
            title = snapshot.name
            progress = snapshot.progress
            progressText = "\(snapshot.totalWantedDone.bitrateToHumanReadable) of \(snapshot.totalWanted.bitrateToHumanReadable) (\(String(format: "%.2f", progress * 100))%)"
            let queued = DownloadQueue.shared.isQueued(torrentHandle)
            statusText = queued ? "Queued" : snapshot.stateText
            stateLabel = queued ? "Queued" : snapshot.friendlyState.name
            switch snapshot.friendlyState {
            case .finished:
                stateColor = .sMint
                stateIcon = .checkCircle
            case .seeding:
                stateColor = Brand.teal
                stateIcon = .upload
            case .storageError:
                stateColor = .sCoral
                stateIcon = .alert
            case .paused:
                stateColor = .sAmber
                stateIcon = .pause
            default:
                stateColor = queued ? .sText2 : .sMint
                stateIcon = nil
            }
            showsProgress = !snapshot.isFinished && snapshot.friendlyState != .storageError
            let speed = snapshot.downloadRate > 0 ? " · ↓ \(snapshot.downloadRate.bitrateToHumanReadable)/s" : ""
            metaText = "\(Int(progress * 100))% · \(snapshot.totalWantedDone.bitrateToHumanReadable) / \(snapshot.totalWanted.bitrateToHumanReadable)\(speed)"
            detailText = ""
        }
    }
}
