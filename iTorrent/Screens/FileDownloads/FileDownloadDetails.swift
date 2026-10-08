import Combine
import MvvmFoundation
import QuickLook
import UIKit

class FileDownloadDetailsViewModel: BaseCollectionViewModelWith<UUID> {
    var id: UUID!
    @Published var title = ""
    @Published var canResume = false
    @Published var canPause = false
    @Published var isComplete = false
    let dismissSignal = PassthroughSubject<Void, Never>()
    private let state = DetailCellViewModel(title: "State")
    private let speed = DetailCellViewModel(title: "Download")
    private let eta = DetailCellViewModel(title: "Time remains")
    private let progress = TorrentDetailProgressCellViewModel(title: "Progress")
    private let parts = DetailCellViewModel(title: "Connections")
    private let source = DetailCellViewModel(title: "URL")
    private let host = DetailCellViewModel(title: "Host")
    private let added = DetailCellViewModel(title: "Added")
    private let total = DetailCellViewModel(title: "Total")
    private let received = DetailCellViewModel(title: "Completed")
    private let percentage = DetailCellViewModel(title: "Progress")
    private let location = DetailCellViewModel(title: "Location")
    private let error = DetailCellViewModel(title: "Error")
    private var connectionRows: [DetailCellViewModel] = []
    private var layoutKey = ""
    private let service = FileDownloadService.shared

    override func prepare(with model: UUID) {
        id = model
        progress.showsConnections = true
        source.longPressAction = { [weak self] in UIPasteboard.general.string = self?.source.detail }
        location.longPressAction = { [weak self] in UIPasteboard.general.string = self?.location.detail }
        update()
        disposeBag.bind {
            service.updates.filter { $0.id == model }.sink { [weak self] _ in self?.update() }
            service.$downloads.map { $0.map(\.id) }.removeDuplicates().receive(on: DispatchQueue.main)
                .sink { [weak self] ids in if !ids.contains(model) { self?.dismissSignal.send() } }
        }
    }

    func resume() { service.resume(id) }
    func pause() { service.pause(id) }
    func remove() {
        alert(title: "Remove download?", message: title, actions: [
            .init(title: %"torrent.remove.action.dropData", style: .destructive, action: { [unowned self] in service.remove(id) }),
            .init(title: %"torrent.remove.action.keepData", style: .default, action: { [unowned self] in service.remove(id, deleteFiles: false) }),
            .init(title: %"common.cancel", style: .cancel, isPrimary: true)
        ])
    }
    var fileURL: URL? { service.fileURL(id) }
    var sourceURL: URL? { service.downloads.first { $0.id == id }?.url }
    private func bytes(_ value: Int64) -> String { UInt64(max(0, value)).bitrateToHumanReadable }

    private func update() {
        guard let item = service.downloads.first(where: { $0.id == id }) else { return }
        title = item.name
        state.detail = item.stateTitle
        canResume = [.paused, .failed].contains(item.state)
        canPause = [.queued, .preparing, .downloading].contains(item.state)
        isComplete = item.state == .completed
        speed.detail = "\(item.speed.bitrateToHumanReadable)/s"
        eta.detail = item.timeRemaining
        progress.progress = item.progress
        let connections = service.connections(id)
        progress.segmentedProgress = connections.map(\.progress)
        parts.detail = "\(item.parts)"
        source.detail = item.url.absoluteString
        host.detail = item.url.host ?? "—"
        added.detail = DateFormatter.localizedString(from: item.createdAt, dateStyle: .medium, timeStyle: .short)
        total.detail = item.totalBytes > 0 ? bytes(item.totalBytes) : "Unknown size"
        received.detail = bytes(item.receivedBytes)
        percentage.detail = item.totalBytes > 0 ? String(format: "%.2f%%", item.progress * 100) : "—"
        location.detail = fileURL?.path ?? "—"
        error.detail = item.error ?? ""
        if connectionRows.count != connections.count {
            connectionRows = connections.map { DetailCellViewModel(title: "Connection \($0.number)") }
        }
        for (row, connection) in zip(connectionRows, connections) {
            row.detail = "\(bytes(connection.received)) / \(connection.total > 0 ? bytes(connection.total) : "—") (\(Int(connection.progress * 100))%)"
        }
        let key = "\(connections.count)|\(item.state == .failed)"
        guard key != layoutKey else { return }
        layoutKey = key
        sections = [
            .init(id: "state", items: [state]),
            .init(id: "speed", header: "Speed", items: [speed, eta]),
            .init(id: "downloading", header: "Downloading", items: [parts, progress]),
            .init(id: "connections", header: "Connections", items: connectionRows),
            .init(id: "info", header: "Primary info", items: [host, source, added]),
            .init(id: "transfer", header: "Transfer", items: [total, received, percentage]),
            .init(id: "location", header: "Download path", items: [location])
        ]
        if item.state == .failed { sections.append(.init(id: "error", header: "Error", items: [error])) }
    }
}

final class FileDownloadDetailsViewController<VM: FileDownloadDetailsViewModel>: BaseCollectionViewController<VM>, QLPreviewControllerDataSource {
    private let share = UIBarButtonItem(title: "Share", image: .init(systemName: "square.and.arrow.up"))
    private let play = UIBarButtonItem(title: "Resume", image: .init(systemName: "play.fill"))
    private let pause = UIBarButtonItem(title: "Pause", image: .init(systemName: "pause.fill"))
    private let preview = UIBarButtonItem(title: "Open file", image: .init(systemName: "doc.text.magnifyingglass"))
    private let delete = UIBarButtonItem(title: "Delete", image: .init(systemName: "trash"))
    override var useMarqueeLabel: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        play.primaryAction = UIAction(title: "Resume", image: .init(systemName: "play.fill")) { [weak self] _ in self?.viewModel.resume() }
        pause.primaryAction = UIAction(title: "Pause", image: .init(systemName: "pause.fill")) { [weak self] _ in self?.viewModel.pause() }
        delete.primaryAction = UIAction(title: "Delete", image: .init(systemName: "trash")) { [weak self] _ in self?.viewModel.remove() }
        preview.primaryAction = UIAction(title: "Open file", image: .init(systemName: "doc.text.magnifyingglass")) { [weak self] _ in
            guard let self, let url = viewModel.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
            let controller = QLPreviewController()
            controller.dataSource = self
            present(controller, animated: true)
        }
        share.menu = UIMenu(children: [
            UIAction(title: "Share file", image: .init(systemName: "doc")) { [weak self] _ in
                guard let self, viewModel.isComplete, let url = viewModel.fileURL else { return }
                shareItem(url)
            },
            UIAction(title: "Share link", image: .init(systemName: "link")) { [weak self] _ in
                guard let self, let url = viewModel.sourceURL else { return }
                shareItem(url)
            },
            UIAction(title: "Copy link", image: .init(systemName: "doc.on.doc")) { [weak self] _ in
                UIPasteboard.general.url = self?.viewModel.sourceURL
            }
        ])
        navigationItem.trailingItemGroups = [.fixedGroup(items: [share])]
        disposeBag.bind {
            viewModel.$title.sink { [weak self] _ in self?.title = $0 }
            Publishers.CombineLatest3(viewModel.$canResume, viewModel.$canPause, viewModel.$isComplete)
                .receive(on: DispatchQueue.main).sink { [weak self] resume, pausable, complete in
                    guard let self else { return }
                    play.isEnabled = resume
                    pause.isEnabled = pausable
                    preview.isEnabled = complete
                    if let action = share.menu?.children.first as? UIAction {
                        action.attributes = complete ? [] : .disabled
                    }
                    toolbarItems = [resume ? play : nil, pausable ? pause : nil, complete ? preview : nil, .flexibleSpace(), delete].compactMap { $0 }
                }
            viewModel.dismissSignal.sink { [weak self] _ in
                guard let self else { return }
                if !((splitViewController as? BaseSplitViewController)?.showEmptyDetail() ?? false) { pop(animated: true, sender: self) }
            }
        }
    }
    private func shareItem(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = share
        present(controller, animated: true)
    }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { viewModel.fileURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { viewModel.fileURL! as NSURL }
}
