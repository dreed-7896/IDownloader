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
    /// Torrent files under storage, read once per reload. Reading `handle.snapshot` for every row
    /// raced the engine updating snapshots in the background and crashed the Files screen.
    private struct IndexedTorrentFile {
        let handle: TorrentHandle
        let index: Int
        let incomplete: Bool
    }
    private var torrentFiles: [String: IndexedTorrentFile] = [:]
    private var subscriptions = Set<AnyCancellable>()
    private var accessingScope = false
    private let sortButton = UIBarButtonItem(title: "Sort", image: Icon.sort.image(22))
    /// Item counts of the folders shown, read once per reload.
    private var folderCounts: [URL: Int] = [:]
    var isToolbarItemsHidden: Bool { false }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    init(rootDirectory: URL = TorrentService.downloadPath, directory: URL? = nil, title: String? = nil) {
        self.rootDirectory = rootDirectory
        self.directory = directory ?? rootDirectory
        super.init(style: .plain)
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
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = SColor.bg
        tableView.separatorColor = SColor.line
        tableView.tableFooterView = UIView()
        tableView.register(FileRowCell.self, forCellReuseIdentifier: FileRowCell.reuseIdentifier)
        tableView.register(StashSectionHeader.self, forHeaderFooterViewReuseIdentifier: StashSectionHeader.reuseIdentifier)
        tableView.sectionHeaderTopPadding = 0
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search files"
        navigationItem.searchController = search
        definesPresentationContext = true
        let videos = UIBarButtonItem(title: "Videos", image: Icon.film.image(22),
                                    primaryAction: UIAction(title: "Videos", image: Icon.film.image(22)) { [weak self] _ in
            self?.navigationController?.pushViewController(VideoGalleryViewController(), animated: true)
        })
        videos.accessibilityLabel = "Video gallery"
        navigationItem.rightBarButtonItems = [sortButton, videos]
        configureSortMenu()

        let newFolder = StashBarItem.make(title: "New folder", systemImage: "folder.badge.plus") { [weak self] in self?.createFolder() }
        // Hugeicons glyph for the button (its style stays StashBarItem's).
        if let button = newFolder.customView as? UIButton, let image = Icon.folderAdd.image(21) {
            button.configuration?.image = image
        }
        toolbarItems = [
            newFolder,
            StashBarItem.gap(),
            StashBarItem.make(title: "Import", systemImage: "square.and.arrow.down") { [weak self] in self?.importFiles() },
            .flexibleSpace()
        ]
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

    private func indexTorrentFiles() {
        var index: [String: IndexedTorrentFile] = [:]
        for handle in Array(TorrentService.shared.torrents.values) {
            let snapshot = handle.snapshot
            guard let path = snapshot.downloadPath else { continue }
            for file in snapshot.files {
                let url = path.appendingPathComponent(file.path).standardizedFileURL
                index[url.path] = IndexedTorrentFile(handle: handle, index: Int(file.index), incomplete: file.downloaded < file.size)
            }
        }
        torrentFiles = index
    }

    private func reloadFiles() {
        indexTorrentFiles()
        folderCounts = [:]
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
                tableView.backgroundView = query.isEmpty
                    ? StashEmptyView(icon: .folderOpen, title: "No files yet",
                                     message: "Finished downloads appear here. You can also bring in files from the Files app.",
                                     actionTitle: "Import files", action: { [weak self] in self?.importFiles() })
                    : StashEmptyView(icon: .search, title: "No matches", message: "No files match “\(query)”.")
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
        sortButton.menu = UIMenu(title: "Sort by", children: Sort.allCases.map { option in
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
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard let header = tableView.dequeueReusableHeaderFooterView(withIdentifier: StashSectionHeader.reuseIdentifier) as? StashSectionHeader else { return nil }
        let files = entries.filter { !$0.isDirectory }.count
        let folders = entries.count - files
        var parts: [String] = []
        if folders > 0 { parts.append(folders == 1 ? "1 folder" : "\(folders) folders") }
        if files > 0 { parts.append(files == 1 ? "1 file" : "\(files) files") }
        header.label.text = section == 1 ? "Other locations" : parts.joined(separator: " · ")
        return header
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        section == 0 && entries.isEmpty ? 0 : UITableView.automaticDimension
    }
    private func entry(at indexPath: IndexPath) -> Entry {
        indexPath.section == 0 ? entries[indexPath.row] : locations[indexPath.row]
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: FileRowCell.reuseIdentifier, for: indexPath) as! FileRowCell
        let entry = entry(at: indexPath)
        let incomplete = !entry.isDirectory && isIncomplete(entry.url)
        let detail: String
        if indexPath.section == 1 {
            detail = "Storage location"
        } else if entry.isDirectory {
            let count = itemCount(entry.url)
            detail = count == 0 ? "Empty folder" : count == 1 ? "1 item" : "\(count) items"
        } else {
            var parts: [String] = []
            let ext = entry.url.pathExtension.uppercased()
            if !ext.isEmpty { parts.append(ext) }
            parts.append(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
            parts.append(incomplete ? "Downloading…" : Self.dateFormatter.string(from: entry.date))
            detail = parts.joined(separator: " · ")
        }
        let rowKind: FileRowCell.Kind = indexPath.section == 1 ? .location : entry.isDirectory ? .folder : fileKind(for: entry.url)
        cell.configure(url: entry.url, title: locationNames[entry.url] ?? entry.name, detail: detail,
                       kind: rowKind, loadsThumbnail: !incomplete)
        return cell
    }

    private func fileKind(for url: URL) -> FileRowCell.Kind {
        let type = UTType(filenameExtension: url.pathExtension)
        if type?.conforms(to: .audio) == true { return .audio }
        if VLCPlayerViewModel.isMediaFile(url) { return .video }
        if type?.conforms(to: .image) == true { return .image }
        if type?.conforms(to: .archive) == true { return .archive }
        return .document
    }

    private func itemCount(_ url: URL) -> Int {
        if let count = folderCounts[url] { return count }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        let count = names.filter { !$0.hasPrefix(".") }.count
        folderCounts[url] = count
        return count
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
            let isMedia = !entry.isDirectory && VLCPlayerViewModel.isMediaFile(entry.url)
            let openTitle = entry.isDirectory ? "Open folder" : isMedia ? "Play" : "Open"
            let openIcon: Icon = entry.isDirectory ? .folderOpen : isMedia ? .play : .expand
            var actions: [UIMenuElement] = [
                UIAction(title: openTitle, image: openIcon.image(22)) { [weak self] _ in self?.open(entry) },
                UIAction(title: "Share", image: Icon.share.image(22), attributes: self.isIncomplete(entry.url) ? .disabled : []) { [weak self] _ in self?.share(entry) }
            ]
            if !isLocation {
                actions.append(UIAction(title: "Rename", image: Icon.edit.image(22)) { [weak self] _ in self?.rename(entry) })
                actions.append(UIMenu(options: .displayInline, children: [
                    UIAction(title: "Delete", image: Icon.delete.image(22), attributes: .destructive) { [weak self] _ in self?.delete(entry) }
                ]))
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
        action.image = Icon.delete.image(22)
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    override func tableView(_ tableView: UITableView, leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard indexPath.section == 0 else { return nil }
        let entry = entry(at: indexPath)
        guard !entry.isDirectory, !isIncomplete(entry.url) else { return nil }
        let action = UIContextualAction(style: .normal, title: "Share") { [weak self] _, _, completion in
            self?.share(entry)
            completion(true)
        }
        action.image = Icon.share.image(22)
        action.backgroundColor = SColor.mint
        return UISwipeActionsConfiguration(actions: [action])
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
        indexTorrentFiles()
        let parent = url.standardizedFileURL.path
        if torrentFiles.keys.contains(where: { $0 == parent || $0.hasPrefix(parent + "/") }) {
            showMessage("File belongs to a torrent", "Remove the torrent from Downloads and choose Keep files before renaming or deleting these files.")
            return false
        }
        if managedDownloads(under: url).contains(where: { $0.state != .completed }) {
            showMessage("Download in progress", "Finish or remove the download before changing its files.")
            return false
        }
        return true
    }

    private func torrentPair(for url: URL) -> (handle: TorrentHandle, fileIndex: Int)? {
        torrentFiles[url.standardizedFileURL.path].map { (handle: $0.handle, fileIndex: $0.index) }
    }

    private func isIncomplete(_ url: URL) -> Bool {
        if let file = torrentFiles[url.standardizedFileURL.path] { return file.incomplete }
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
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (previewURL ?? directory) as NSURL
    }
    private func showError(_ error: Error) { showMessage("Unable to access file", error.localizedDescription) }
    private func showMessage(_ title: String, _ message: String) {
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
