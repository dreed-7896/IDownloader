import Combine
import QuickLook
import UIKit

final class FileDownloadsViewController: UITableViewController, QLPreviewControllerDataSource {
    private let service = FileDownloadService.shared
    private var subscription: AnyCancellable?
    private var previewURL: URL?
    var showsCloseButton = false
    var selectedDownload: UUID? { didSet { if isViewLoaded, view.window != nil { focusSelection() } } }

    init() { super.init(style: .insetGrouped) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Files"
        if showsCloseButton { navigationItem.leftBarButtonItem = .init(barButtonSystemItem: .done, target: self, action: #selector(close)) }
        navigationItem.rightBarButtonItem = .init(barButtonSystemItem: .add, target: self, action: #selector(addURL))
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "download")
        subscription = service.$downloads.receive(on: DispatchQueue.main).sink { [weak self] _ in
            self?.tableView.reloadData()
            self?.updateEmptyState()
        }
        updateEmptyState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        focusSelection()
    }

    @objc private func close() { dismiss(animated: true) }

    private func focusSelection() {
        if let id = selectedDownload, let row = service.downloads.firstIndex(where: { $0.id == id }) {
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .middle, animated: true)
            selectedDownload = nil
        }
    }

    private func updateEmptyState() {
        let label = UILabel()
        label.text = "No file downloads yet.\nTap + or share a link to IDownloader."
        label.textColor = .secondaryLabel
        label.numberOfLines = 0
        label.textAlignment = .center
        tableView.backgroundView = service.downloads.isEmpty ? label : nil
    }

    @objc private func addURL() {
        let alert = UIAlertController(title: "Download file", message: "Enter a direct HTTP or HTTPS file link.", preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com/file.zip"
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(.init(title: "Cancel", style: .cancel))
        alert.addAction(.init(title: "Download", style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let text = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let url = URL(string: text), self.service.add(url) != nil else {
                let error = UIAlertController(title: "Invalid link", message: "Enter a valid HTTP or HTTPS URL.", preferredStyle: .alert)
                error.addAction(.init(title: "OK", style: .default))
                self.present(error, animated: true)
                return
            }
        })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { service.downloads.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let item = service.downloads[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "download", for: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = item.name
        content.image = UIImage(systemName: item.state == .completed ? "doc.fill" : "arrow.down.circle.fill")
        content.imageProperties.tintColor = .tintColor
        content.secondaryTextProperties.numberOfLines = 3
        let received = ByteCountFormatter.string(fromByteCount: item.receivedBytes, countStyle: .file)
        let total = item.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: item.totalBytes, countStyle: .file) : "Unknown size"
        let parts = "\(item.parts) \(item.parts == 1 ? "part" : "parts")"
        switch item.state {
        case .preparing: content.secondaryText = "Connecting…"
        case .downloading:
            let speed = ByteCountFormatter.string(fromByteCount: Int64(item.speed), countStyle: .file)
            content.secondaryText = "\(received) / \(total) · \(Int(item.progress * 100))%\n\(speed)/s · \(parts) · \(item.timeRemaining)"
        case .paused: content.secondaryText = "Paused · \(received) / \(total)"
        case .assembling: content.secondaryText = "Saving file…"
        case .completed: content.secondaryText = "Completed · \(total) · \(parts)"
        case .failed: content.secondaryText = item.error ?? "Download failed. Tap to retry."
        }
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let item = service.downloads[indexPath.row]
        if item.state == .completed, let url = service.fileURL(item.id) {
            guard FileManager.default.fileExists(atPath: url.path) else {
                let alert = UIAlertController(title: "File unavailable", message: "The downloaded file has been moved or deleted.", preferredStyle: .alert)
                alert.addAction(.init(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            previewURL = url
            let preview = QLPreviewController()
            preview.dataSource = self
            navigationController?.pushViewController(preview, animated: true)
        } else { showActions(item, source: tableView.cellForRow(at: indexPath)) }
    }

    private func showActions(_ item: FileDownload, source: UIView?) {
        let alert = UIAlertController(title: item.name, message: item.error ?? item.url.absoluteString, preferredStyle: .actionSheet)
        if [.preparing, .downloading].contains(item.state) {
            alert.addAction(.init(title: "Pause", style: .default) { [service] _ in service.pause(item.id) })
        }
        if [.paused, .failed].contains(item.state) {
            alert.addAction(.init(title: item.state == .failed ? "Retry" : "Resume", style: .default) { [service] _ in service.resume(item.id) })
        }
        alert.addAction(.init(title: "Copy link", style: .default) { _ in UIPasteboard.general.url = item.url })
        alert.addAction(.init(title: "Delete download", style: .destructive) { [weak self] _ in self?.confirmDelete(item) })
        alert.addAction(.init(title: "Cancel", style: .cancel))
        alert.popoverPresentationController?.sourceView = source ?? view
        alert.popoverPresentationController?.sourceRect = (source ?? view).bounds
        present(alert, animated: true)
    }

    private func confirmDelete(_ item: FileDownload) {
        let alert = UIAlertController(title: "Delete download?", message: "\(item.name) and its downloaded data will be removed.", preferredStyle: .alert)
        alert.addAction(.init(title: "Cancel", style: .cancel))
        alert.addAction(.init(title: "Delete", style: .destructive) { [service] _ in service.remove(item.id) })
        present(alert, animated: true)
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        let item = service.downloads[indexPath.row]
        let delete = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            completion(true)
            self?.confirmDelete(item)
        }
        var actions = [delete]
        if [.paused, .failed, .preparing, .downloading].contains(item.state) {
            let paused = item.state == .paused || item.state == .failed
            let toggle = UIContextualAction(style: .normal, title: paused ? "Resume" : "Pause") { [service] _, _, completion in
                if paused { service.resume(item.id) } else { service.pause(item.id) }
                completion(true)
            }
            toggle.backgroundColor = .systemBlue
            actions.append(toggle)
        }
        let configuration = UISwipeActionsConfiguration(actions: actions)
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }
}
