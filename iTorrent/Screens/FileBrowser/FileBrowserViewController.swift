import Combine
import LibTorrent
import MvvmFoundation
import QuickLook
import UIKit
import UniformTypeIdentifiers

/// Browses download storage without exposing transfer manifests or temporary parts.
final class FileBrowserViewController: UITableViewController, UISearchResultsUpdating,
    QLPreviewControllerDataSource, UIDocumentPickerDelegate, ToolbarHidingProtocol {
    private struct Entry {
        let url: URL
        let isDirectory: Bool
        let size: Int64
        let date: Date
        var name: String { url.lastPathComponent }
    }

    private enum Sort: String, CaseIterable { case name = "Name", date = "Date", size = "Size" }
    private let rootDirectory: URL
    private let directory: URL
    private let search = UISearchController(searchResultsController: nil)
    private var entries: [Entry] = []
    private var locations: [Entry] = []
    private var locationNames: [URL: String] = [:]
    private var sort: Sort = .name
    private var previewURL: URL?
    private var subscriptions = Set<AnyCancellable>()
    private var accessingScope = false
    private let sortButton = UIBarButtonItem(title: "Sort", image: UIImage(systemName: "arrow.up.arrow.down"))
    var isToolbarItemsHidden: Bool { false }

    init(rootDirectory: URL = TorrentService.downloadPath, directory: URL? = nil, title: String? = nil) {
        self.rootDirectory = rootDirectory
        self.directory = directory ?? rootDirectory
        super.init(style: .insetGrouped)
        self.title = title ?? (directory == nil ? "Files" : self.directory.lastPathComponent)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if accessingScope { rootDirectory.stopAccessingSecurityScopedResource() }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        accessingScope = rootDirectory.startAccessingSecurityScopedResource()
        navigationItem.largeTitleDisplayMode = .always
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search files"
        navigationItem.searchController = search
        definesPresentationContext = true
        navigationItem.rightBarButtonItem = sortButton
        configureSortMenu()

        let newFolder = UIBarButtonItem(title: "New folder", image: UIImage(systemName: "folder.badge.plus"),
                                       primaryAction: UIAction { [weak self] _ in self?.createFolder() })
        let importFiles = UIBarButtonItem(title: "Import files", image: UIImage(systemName: "square.and.arrow.down"),
                                         primaryAction: UIAction { [weak self] _ in self?.importFiles() })
        toolbarItems = [newFolder, .flexibleSpace(), importFiles]
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refreshFiles), for: .valueChanged)

        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .receive(on: DispatchQueue.main).sink { [weak self] _ in self?.reloadFiles() }.store(in: &subscriptions)
        FileDownloadService.shared.$downloads.dropFirst()
            .debounce(for: .milliseconds(300), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadFiles() }.store(in: &subscriptions)
        reloadFiles()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(false, animated: animated)
        reloadFiles()
    }

    @objc private func refreshFiles() {
        reloadFiles()
        refreshControl?.endRefreshing()
    }

    func updateSearchResults(for searchController: UISearchController) { reloadFiles() }

    private func readEntries(at url: URL) throws -> [Entry] {
        let urls = try FileManager.default.contentsOfDirectory(at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles])
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]),
                  values.isSymbolicLink != true else { return nil }
            return Entry(url: url, isDirectory: values.isDirectory == true,
                         size: Int64(values.fileSize ?? 0), date: values.contentModificationDate ?? .distantPast)
        }
    }

    private func reloadFiles() {
        do {
            var files = try readEntries(at: directory)
            if directory.standardizedFileURL == TorrentService.downloadPath.standardizedFileURL {
                files.removeAll { $0.name == "config" }
            }
            // Regular downloads have private UUID containers. Show their actual filenames.
            if directory.standardizedFileURL == TorrentService.downloadPath.appendingPathComponent("Downloads").standardizedFileURL {
                files = files.flatMap { entry in
                    if entry.isDirectory, UUID(uuidString: entry.name) != nil {
                        return (try? readEntries(at: entry.url)) ?? []
                    }
                    return [entry]
                }
            }
            let query = search.searchBar.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            entries = files.filter { query.isEmpty || $0.name.localizedStandardContains(query) }.sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                switch sort {
                case .date where $0.date != $1.date: return $0.date > $1.date
                case .size where $0.size != $1.size: return $0.size > $1.size
                default: return $0.name.localizedStandardCompare($1.name) == .orderedAscending
                }
            }
            locations = []
            locationNames = [:]
            if directory == TorrentService.downloadPath {
                for scope in PreferencesStorage.shared.storageScopes.values.sorted(by: { $0.name < $1.name }) where scope.allowed {
                    let url = scope.url
                    guard url != directory, query.isEmpty || scope.name.localizedStandardContains(query) else { continue }
                    locations.append(Entry(url: url, isDirectory: true, size: 0, date: .distantPast))
                    locationNames[url] = scope.name
                }
            }
            tableView.reloadData()
            if entries.isEmpty && locations.isEmpty {
                let label = UILabel()
                label.text = query.isEmpty ? "No files yet\nCompleted downloads appear here. You can also import files." : "No matching files"
                label.numberOfLines = 0
                label.textAlignment = .center
                label.textColor = .secondaryLabel
                label.font = .preferredFont(forTextStyle: .body)
                tableView.backgroundView = label
            } else {
                tableView.backgroundView = nil
            }
        } catch {
            entries = []
            locations = []
            tableView.reloadData()
            showError(error)
        }
    }

    private func configureSortMenu() {
        sortButton.menu = UIMenu(children: Sort.allCases.map { option in
            UIAction(title: option.rawValue, state: sort == option ? .on : .off) { [weak self] _ in
                self?.sort = option
                self?.configureSortMenu()
                self?.reloadFiles()
            }
        })
    }

    override func numberOfSections(in tableView: UITableView) -> Int { locations.isEmpty ? 1 : 2 }
    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? entries.count : locations.count
    }
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 1 ? "Other locations" : nil
    }
    private func entry(at indexPath: IndexPath) -> Entry {
        indexPath.section == 0 ? entries[indexPath.row] : locations[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "file") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "file")
        let entry = entry(at: indexPath)
        var content = cell.defaultContentConfiguration()
        content.text = locationNames[entry.url] ?? entry.name
        content.textProperties.numberOfLines = 2
        content.image = UIImage(systemName: entry.isDirectory ? "folder" : icon(for: entry.url))
        content.imageProperties.tintColor = view.tintColor
        content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
        if indexPath.section == 1 {
            content.secondaryText = "Storage location"
        } else if entry.isDirectory {
            content.secondaryText = "Folder"
        } else {
            let size = ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file)
            content.secondaryText = isIncomplete(entry.url) ? "\(size) · Downloading" : "\(size) · \(DateFormatter.localizedString(from: entry.date, dateStyle: .short, timeStyle: .none))"
        }
        cell.contentConfiguration = content
        cell.accessoryType = entry.isDirectory ? .disclosureIndicator : .none
        return cell
    }

    private func icon(for url: URL) -> String {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .audio) == true { return "music.note" }
        if VLCPlayerViewModel.isMediaFile(url) { return "play.rectangle" }
        if type?.conforms(to: .image) == true { return "photo" }
        if type?.conforms(to: .archive) == true { return "doc.zipper" }
        return "doc"
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        open(entry(at: indexPath))
    }

    private func open(_ entry: Entry) {
        if entry.isDirectory {
            let root = locationNames[entry.url] != nil ? entry.url : rootDirectory
            navigationController?.pushViewController(FileBrowserViewController(rootDirectory: root, directory: entry.url,
                title: locationNames[entry.url]), animated: true)
        } else if isIncomplete(entry.url) {
            showMessage("Download in progress", "Wait for this file to finish downloading before opening it.")
        } else if VLCPlayerViewModel.isMediaFile(entry.url) {
            let model = VLCPlayerViewModel(with: .init(url: entry.url, torrentPair: torrentPair(for: entry.url)))
            let navigation = BaseNavigationController()
            navigation.viewControllers = [model.resolveVC()]
            navigation.modalPresentationStyle = .fullScreen
            present(navigation, animated: true)
        } else {
            guard QLPreviewController.canPreview(entry.url as NSURL) else {
                share(entry)
                return
            }
            previewURL = entry.url
            let preview = QLPreviewController()
            preview.dataSource = self
            present(preview, animated: true)
        }
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath, point: CGPoint) -> UIContextMenuConfiguration? {
        let entry = entry(at: indexPath)
        let isLocation = indexPath.section == 1
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return nil }
            var actions: [UIMenuElement] = [
                UIAction(title: entry.isDirectory ? "Open folder" : "Open", image: UIImage(systemName: entry.isDirectory ? "folder" : "arrow.up.forward.app")) { [weak self] _ in self?.open(entry) },
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up"), attributes: self.isIncomplete(entry.url) ? .disabled : []) { [weak self] _ in self?.share(entry) }
            ]
            if !isLocation {
                actions.append(UIAction(title: "Rename", image: UIImage(systemName: "pencil")) { [weak self] _ in self?.rename(entry) })
                actions.append(UIAction(title: "Delete", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in self?.delete(entry) })
            }
            return UIMenu(children: actions)
        }
    }

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let entry = entry(at: indexPath)
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, completion in
            self?.delete(entry)
            completion(true)
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func share(_ entry: Entry) {
        guard !isIncomplete(entry.url) else { return }
        let controller = UIActivityViewController(activityItems: [entry.url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(controller, animated: true)
    }

    private func createFolder() {
        askForName(title: "New folder", initial: "", message: nil) { [weak self] name in
            guard let self else { return }
            do {
                let url = directory.appendingPathComponent(name, isDirectory: true)
                guard !FileManager.default.fileExists(atPath: url.path) else {
                    showMessage("Name already exists", "Choose another folder name.")
                    return
                }
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                reloadFiles()
            } catch { showError(error) }
        }
    }

    private func rename(_ entry: Entry) {
        guard canModify(entry.url) else { return }
        if entry.isDirectory, !managedDownloads(under: entry.url).isEmpty {
            showMessage("Download folder", "Rename individual downloaded files so their download records stay up to date.")
            return
        }
        askForName(title: "Rename", initial: entry.name, message: entry.isDirectory ? nil : "Keep the file extension to preserve its file type.") { [weak self] name in
            guard let self, name != entry.name else { return }
            do {
                let destination = entry.url.deletingLastPathComponent().appendingPathComponent(name, isDirectory: entry.isDirectory)
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    showMessage("Name already exists", "Choose another name.")
                    return
                }
                if let download = FileDownloadService.shared.downloads.first(where: { FileDownloadService.shared.fileURL($0.id)?.standardizedFileURL == entry.url.standardizedFileURL }) {
                    try FileDownloadService.shared.renameCompletedFile(download.id, to: name)
                } else {
                    try FileManager.default.moveItem(at: entry.url, to: destination)
                }
                reloadFiles()
            } catch { showError(error) }
        }
    }

    private func delete(_ entry: Entry) {
        guard canModify(entry.url) else { return }
        let alert = UIAlertController(title: "Delete \(entry.name)?", message: entry.isDirectory ? "This deletes the folder and everything inside it." : "This deletes the file from your device.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            guard let self, canModify(entry.url) else { return }
            do {
                let downloads = managedDownloads(under: entry.url)
                try FileManager.default.removeItem(at: entry.url)
                downloads.forEach { FileDownloadService.shared.remove($0.id, deleteFiles: false) }
                let parent = entry.url.deletingLastPathComponent()
                if UUID(uuidString: parent.lastPathComponent) != nil,
                   (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: parent)
                }
                reloadFiles()
            } catch { showError(error) }
        })
        present(alert, animated: true)
    }

    private func contains(_ parent: URL, _ child: URL) -> Bool {
        let path = parent.standardizedFileURL.path
        let childPath = child.standardizedFileURL.path
        return path == childPath || childPath.hasPrefix(path + "/")
    }

    private func managedDownloads(under url: URL) -> [FileDownload] {
        FileDownloadService.shared.downloads.filter { item in
            FileDownloadService.shared.fileURL(item.id).map { contains(url, $0) } ?? false
        }
    }

    private func canModify(_ url: URL) -> Bool {
        for handle in TorrentService.shared.torrents.values {
            guard let path = handle.snapshot.downloadPath else { continue }
            if handle.snapshot.files.contains(where: { contains(url, path.appendingPathComponent($0.path)) }) {
                showMessage("File belongs to a torrent", "Remove the torrent from Downloads and choose Keep files before renaming or deleting these files.")
                return false
            }
        }
        if managedDownloads(under: url).contains(where: { $0.state != .completed }) {
            showMessage("Download in progress", "Finish or remove the download before changing its files.")
            return false
        }
        return true
    }

    private func torrentPair(for url: URL) -> (handle: TorrentHandle, fileIndex: Int)? {
        for handle in TorrentService.shared.torrents.values {
            guard let path = handle.snapshot.downloadPath else { continue }
            if let file = handle.snapshot.files.first(where: { path.appendingPathComponent($0.path).standardizedFileURL == url.standardizedFileURL }) {
                return (handle: handle, fileIndex: Int(file.index))
            }
        }
        return nil
    }

    private func isIncomplete(_ url: URL) -> Bool {
        if let pair = torrentPair(for: url) {
            let file = pair.handle.snapshot.files[pair.fileIndex]
            return file.downloaded < file.size
        }
        return managedDownloads(under: url).contains { $0.state != .completed }
    }

    private func askForName(title: String, initial: String, message: String?, action: @escaping (String) -> Void) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addTextField { $0.text = initial; $0.autocapitalizationType = .none; $0.autocorrectionType = .no }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Save", style: .default) { [weak self, weak alert] _ in
            let name = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !name.isEmpty, name != ".", name != "..", !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"), !name.contains("\0") else {
                self?.showMessage("Invalid name", "Enter a name without slashes or a leading dot.")
                return
            }
            action(name)
        })
        present(alert, animated: true)
    }

    private func importFiles() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = self
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        do {
            for source in urls {
                let accessing = source.startAccessingSecurityScopedResource()
                defer { if accessing { source.stopAccessingSecurityScopedResource() } }
                var destination = directory.appendingPathComponent(source.lastPathComponent)
                var number = 2
                while FileManager.default.fileExists(atPath: destination.path) {
                    let name = source.deletingPathExtension().lastPathComponent + " (\(number))"
                    destination = directory.appendingPathComponent(name)
                    if !source.pathExtension.isEmpty { destination.appendPathExtension(source.pathExtension) }
                    number += 1
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
            reloadFiles()
        } catch { reloadFiles(); showError(error) }
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { previewURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { previewURL! as NSURL }
    private func showError(_ error: Error) { showMessage("Unable to access file", error.localizedDescription) }
    private func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
