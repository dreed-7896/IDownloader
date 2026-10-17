import AVFoundation
import Combine
@preconcurrency import LibTorrent
import MvvmFoundation
import UIKit
import UniformTypeIdentifiers

private struct GalleryVideo: Sendable {
    let url: URL
    let size: Int64
    let modified: Date
}

final class VideoGalleryViewController: UICollectionViewController, UISearchResultsUpdating, ToolbarHidingProtocol {
    private let search = UISearchController(searchResultsController: nil)
    private var videos: [GalleryVideo] = []
    private var filtered: [GalleryVideo] = []
    private var scopedURLs: [URL] = []
    private var subscriptions = Set<AnyCancellable>()
    private var scanGeneration = UUID()
    private let selectButton = UIBarButtonItem(title: "Select")
    private let deleteAllButton = UIBarButtonItem(title: "Delete all", image: UIImage(systemName: "trash"))
    private let optionsButton = UIBarButtonItem(title: "Options", image: UIImage(systemName: "ellipsis.circle"))
    private let selectAllButton = UIBarButtonItem(title: "Select all")
    private let selectionCount = UIBarButtonItem(title: "Select videos")
    private let shareButton = UIBarButtonItem(title: "Share", image: UIImage(systemName: "square.and.arrow.up"))
    private let deleteButton = UIBarButtonItem(title: "Delete", image: UIImage(systemName: "trash"))
    private var selectedURLs = Set<URL>()
    private var isSelecting = false
    private var isSharing = false
    private var newestFirst = false
    var isToolbarItemsHidden: Bool { !isSelecting }

    init() {
        let layout = UICollectionViewCompositionalLayout { _, environment in
            let count = environment.container.effectiveContentSize.width > 600 ? 3 : 2
            let item = NSCollectionLayoutItem(layoutSize: .init(widthDimension: .fractionalWidth(1 / CGFloat(count)), heightDimension: .fractionalHeight(1)))
            item.contentInsets = .init(top: 6, leading: 6, bottom: 6, trailing: 6)
            let group = NSCollectionLayoutGroup.horizontal(layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .absolute(environment.container.effectiveContentSize.width / CGFloat(count) * 0.56 + 76)), subitem: item, count: count)
            let section = NSCollectionLayoutSection(group: group)
            section.contentInsets = .init(top: 8, leading: 10, bottom: 16, trailing: 10)
            return section
        }
        super.init(collectionViewLayout: layout)
        title = "Videos"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }

    override func viewDidLoad() {
        super.viewDidLoad()
        collectionView.backgroundColor = .systemBackground
        collectionView.register(VideoGalleryCell.self, forCellWithReuseIdentifier: "video")
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search all videos"
        navigationItem.searchController = search
        definesPresentationContext = true
        navigationItem.largeTitleDisplayMode = .always
        selectButton.primaryAction = UIAction(title: "Select") { [weak self] _ in self?.toggleSelection() }
        deleteAllButton.tintColor = .systemRed
        deleteAllButton.accessibilityLabel = "Delete all videos"
        deleteAllButton.primaryAction = UIAction(title: "Delete all", image: UIImage(systemName: "trash")) { [weak self] _ in
            guard let self else { return }
            self.confirmDelete(self.videos, all: true)
        }
        selectAllButton.primaryAction = UIAction(title: "Select all") { [weak self] _ in self?.toggleSelectAll() }
        selectionCount.isEnabled = false
        shareButton.primaryAction = UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareSelected() }
        deleteButton.tintColor = .systemRed
        deleteButton.primaryAction = UIAction(title: "Delete", image: UIImage(systemName: "trash")) { [weak self] _ in
            guard let self else { return }
            self.confirmDelete(self.selectedVideos, all: false)
        }
        toolbarItems = [selectAllButton, .flexibleSpace(), selectionCount, .flexibleSpace(), shareButton, deleteButton]
        navigationItem.rightBarButtonItems = [selectButton, deleteAllButton, optionsButton]
        let refresh = UIRefreshControl()
        refresh.addTarget(self, action: #selector(reloadGallery), for: .valueChanged)
        collectionView.refreshControl = refresh
        NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.reloadGallery() }.store(in: &subscriptions)
        FileDownloadService.shared.$downloads.map { $0.filter { $0.state == .completed }.map(\.id) }
            .removeDuplicates().dropFirst().receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.reloadGallery() }.store(in: &subscriptions)
        reloadGallery()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setToolbarHidden(!isSelecting, animated: false)
    }

    @objc private func reloadGallery() {
        guard !isSharing else { return }
        scopedURLs.forEach { $0.stopAccessingSecurityScopedResource() }
        scopedURLs = []
        var roots = [TorrentService.downloadPath]
        for scope in PreferencesStorage.shared.storageScopes.values where scope.allowed {
            if scope.url.startAccessingSecurityScopedResource() { scopedURLs.append(scope.url) }
            roots.append(scope.url)
        }
        var incomplete = Set<String>()
        for handle in TorrentService.shared.torrents.values {
            guard let root = handle.snapshot.downloadPath else { continue }
            for file in handle.snapshot.files where file.downloaded < file.size {
                incomplete.insert(root.appendingPathComponent(file.path).standardizedFileURL.path)
            }
        }
        for file in FileDownloadService.shared.downloads where file.state != .completed {
            if let url = FileDownloadService.shared.fileURL(file.id) { incomplete.insert(url.standardizedFileURL.path) }
        }
        let generation = UUID()
        scanGeneration = generation
        let scanRoots = roots
        let excluded = incomplete
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let found = Self.scan(roots: scanRoots, excluded: excluded)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.scanGeneration == generation else { return }
                self.videos = found
                self.selectedURLs.formIntersection(found.map { $0.url.standardizedFileURL })
                self.applyFilter()
                self.collectionView.refreshControl?.endRefreshing()
            }
        }
    }

    nonisolated private static func scan(roots: [URL], excluded: Set<String>) -> [GalleryVideo] {
        var result: [GalleryVideo] = []
        var seen = Set<String>()
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "config" || (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    enumerator.skipDescendants()
                    continue
                }
                let ext = url.pathExtension.lowercased()
                guard UTType(filenameExtension: ext)?.conforms(to: .movie) == true
                    || ["mp4", "m4v", "mov", "mkv", "avi", "webm", "flv", "wmv", "ts", "mts", "m2ts", "vob", "ogv", "mpeg", "mpg", "3gp"].contains(ext) else { continue }
                let path = url.standardizedFileURL.path
                guard !excluded.contains(path), seen.insert(path).inserted,
                      let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
                      info.isRegularFile == true else { continue }
                result.append(GalleryVideo(url: url, size: Int64(info.fileSize ?? 0), modified: info.contentModificationDate ?? .distantPast))
            }
        }
        return result
    }

    func updateSearchResults(for searchController: UISearchController) { applyFilter() }

    private func applyFilter() {
        let query = search.searchBar.text ?? ""
        filtered = videos.filter { query.isEmpty || $0.url.lastPathComponent.localizedStandardContains(query) }.sorted {
            if newestFirst, $0.modified != $1.modified { return $0.modified > $1.modified }
            return $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
        updateActions()
        collectionView.reloadData()
        if filtered.isEmpty {
            let label = UILabel()
            label.text = query.isEmpty ? "No videos yet\nCompleted videos from all download folders appear here." : "No matching videos"
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .secondaryLabel
            collectionView.backgroundView = label
        } else { collectionView.backgroundView = nil }
    }

    override func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int { filtered.count }
    override func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(withReuseIdentifier: "video", for: indexPath) as! VideoGalleryCell
        let video = filtered[indexPath.item]
        cell.configure(url: video.url, size: video.size)
        cell.setSelectionMode(isSelecting, selected: selectedURLs.contains(video.url.standardizedFileURL))
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: false)
        guard isSelecting else { play(at: indexPath.item); return }
        let url = filtered[indexPath.item].url.standardizedFileURL
        if !selectedURLs.insert(url).inserted { selectedURLs.remove(url) }
        (collectionView.cellForItem(at: indexPath) as? VideoGalleryCell)?.setSelectionMode(true, selected: selectedURLs.contains(url))
        updateActions()
    }

    private var selectedVideos: [GalleryVideo] {
        videos.filter { selectedURLs.contains($0.url.standardizedFileURL) }
    }

    private func toggleSelection() {
        isSelecting.toggle()
        selectedURLs.removeAll()
        navigationController?.setToolbarHidden(!isSelecting, animated: true)
        applyFilter()
    }

    private func toggleSelectAll() {
        let visible = Set(filtered.map { $0.url.standardizedFileURL })
        if visible.isSubset(of: selectedURLs) { selectedURLs.subtract(visible) }
        else { selectedURLs.formUnion(visible) }
        applyFilter()
    }

    private func updateActions() {
        selectButton.title = isSelecting ? "Done" : "Select"
        selectButton.isEnabled = isSelecting || !videos.isEmpty
        deleteAllButton.isEnabled = !videos.isEmpty
        selectAllButton.isEnabled = !filtered.isEmpty
        let visible = Set(filtered.map { $0.url.standardizedFileURL })
        selectAllButton.title = !visible.isEmpty && visible.isSubset(of: selectedURLs) ? "Deselect all" : "Select all"
        selectionCount.title = selectedURLs.isEmpty ? "Select videos" : "\(selectedURLs.count) selected"
        shareButton.isEnabled = !selectedURLs.isEmpty
        deleteButton.isEnabled = !selectedURLs.isEmpty
        optionsButton.menu = UIMenu(children: [
            UIAction(title: "Play all", image: UIImage(systemName: "play.fill"), attributes: filtered.isEmpty || isSelecting ? .disabled : []) { [weak self] _ in self?.play(at: 0) },
            UIMenu(title: "Sort", image: UIImage(systemName: "arrow.up.arrow.down"), children: [
                UIAction(title: "Name", state: newestFirst ? .off : .on) { [weak self] _ in self?.newestFirst = false; self?.applyFilter() },
                UIAction(title: "Newest first", state: newestFirst ? .on : .off) { [weak self] _ in self?.newestFirst = true; self?.applyFilter() }
            ])
        ])
    }

    private func shareSelected() {
        let urls = selectedVideos.map(\.url)
        guard !urls.isEmpty else { return }
        isSharing = true
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.popoverPresentationController?.barButtonItem = shareButton
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            DispatchQueue.main.async { [weak self] in
                self?.isSharing = false
                self?.reloadGallery()
            }
        }
        present(controller, animated: true)
    }

    private func confirmDelete(_ targets: [GalleryVideo], all: Bool) {
        guard !targets.isEmpty else { return }
        let paths = Set(targets.map { $0.url.standardizedFileURL })
        let hasTorrents = TorrentService.shared.torrents.values.contains { handle in
            guard let root = handle.snapshot.downloadPath else { return false }
            return handle.snapshot.files.contains { paths.contains(root.appendingPathComponent($0.path).standardizedFileURL) }
        }
        var message = all
            ? "Permanently delete all \(targets.count) videos in the gallery, including videos outside the current search?"
            : "Permanently delete \(targets.count) selected video\(targets.count == 1 ? "" : "s") from your device?"
        if hasTorrents {
            message += "\n\nTorrents containing these videos will be removed from Downloads to prevent them being downloaded again. Any in-progress downloads in those torrents will stop. Other files in those torrents will be kept."
        }
        let alert = UIAlertController(title: all ? "Delete all videos?" : "Delete selected videos?", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: all ? "Delete all" : "Delete", style: .destructive) { [weak self] _ in
            self?.deleteVideos(targets)
        })
        present(alert, animated: true)
    }

    private func deleteVideos(_ targets: [GalleryVideo]) {
        let paths = Set(targets.map { $0.url.standardizedFileURL })
        // Detach owning torrents before deleting individual files. Keeping their
        // other files avoids deleting an entire series for one selected episode.
        let hashes = TorrentService.shared.torrents.values.compactMap { handle in
            guard let root = handle.snapshot.downloadPath,
                  handle.snapshot.files.contains(where: { paths.contains(root.appendingPathComponent($0.path).standardizedFileURL) }) else { return nil as TorrentHashes? }
            return handle.snapshot.infoHashes
        }
        for hash in hashes { TorrentService.shared.removeTorrent(by: hash, deleteFiles: false) }
        var failures: [String] = []
        for video in targets {
            let url = video.url.standardizedFileURL
            let downloads = FileDownloadService.shared.downloads.filter {
                FileDownloadService.shared.fileURL($0.id)?.standardizedFileURL == url
            }
            do {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                downloads.forEach { FileDownloadService.shared.remove($0.id, deleteFiles: false) }
                selectedURLs.remove(url)
                videos.removeAll { $0.url.standardizedFileURL == url }
                let parent = url.deletingLastPathComponent()
                if UUID(uuidString: parent.lastPathComponent) != nil,
                   (try? FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty) == true {
                    try? FileManager.default.removeItem(at: parent)
                }
            } catch { failures.append("\(url.lastPathComponent): \(error.localizedDescription)") }
        }
        if failures.isEmpty && isSelecting { toggleSelection() }
        else { applyFilter() }
        reloadGallery()
        if !failures.isEmpty {
            var message = failures.prefix(4).joined(separator: "\n\n")
            if failures.count > 4 { message += "\n\nAnd \(failures.count - 4) more." }
            let alert = UIAlertController(title: "Some videos could not be deleted", message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    private func play(at index: Int) {
        guard filtered.indices.contains(index) else { return }
        let model = VLCPlayerViewModel(with: .init(url: filtered[index].url, torrentPair: nil, playlist: filtered.map(\.url)))
        let navigation = BaseNavigationController()
        navigation.viewControllers = [model.resolveVC()]
        navigation.modalPresentationStyle = .fullScreen
        present(navigation, animated: true)
    }
}

private final class VideoGalleryCell: UICollectionViewCell {
    private let thumbnail = UIImageView()
    private let name = UILabel()
    private let detail = UILabel()
    private let selectionBadge = UIImageView()
    private var generator: AVAssetImageGenerator?
    private var representedURL: URL?
    private static let images: NSCache<NSURL, UIImage> = {
        let cache = NSCache<NSURL, UIImage>()
        cache.countLimit = 150
        return cache
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        thumbnail.backgroundColor = .secondarySystemBackground
        thumbnail.contentMode = .scaleAspectFill
        thumbnail.clipsToBounds = true
        thumbnail.layer.cornerRadius = 10
        name.font = .preferredFont(forTextStyle: .subheadline)
        name.numberOfLines = 2
        detail.font = .preferredFont(forTextStyle: .caption1)
        detail.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [thumbnail, name, detail])
        stack.axis = .vertical
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        selectionBadge.translatesAutoresizingMaskIntoConstraints = false
        selectionBadge.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 24, weight: .semibold)
        selectionBadge.layer.shadowColor = UIColor.black.cgColor
        selectionBadge.layer.shadowOpacity = 0.5
        selectionBadge.layer.shadowRadius = 3
        selectionBadge.layer.shadowOffset = .zero
        selectionBadge.isHidden = true
        contentView.addSubview(selectionBadge)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9 / 16),
            selectionBadge.topAnchor.constraint(equalTo: thumbnail.topAnchor, constant: 8),
            selectionBadge.trailingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: -8),
            selectionBadge.widthAnchor.constraint(equalToConstant: 28),
            selectionBadge.heightAnchor.constraint(equalToConstant: 28)
        ])
        thumbnail.setContentHuggingPriority(.defaultLow, for: .vertical)
        name.setContentCompressionResistancePriority(.required, for: .vertical)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func prepareForReuse() {
        super.prepareForReuse()
        generator?.cancelAllCGImageGeneration()
        generator = nil
        representedURL = nil
        thumbnail.image = nil
        setSelectionMode(false, selected: false)
    }

    func setSelectionMode(_ enabled: Bool, selected: Bool) {
        selectionBadge.isHidden = !enabled
        selectionBadge.image = UIImage(systemName: selected ? "checkmark.circle.fill" : "circle")
        selectionBadge.tintColor = selected ? .systemBlue : .white
        thumbnail.layer.borderWidth = selected ? 3 : 0
        thumbnail.layer.borderColor = UIColor.systemBlue.cgColor
        accessibilityTraits = selected ? [.button, .selected] : [.button]
        accessibilityHint = enabled ? "Double tap to \(selected ? "deselect" : "select") video" : "Double tap to play video"
    }

    func configure(url: URL, size: Int64) {
        representedURL = url
        name.text = url.lastPathComponent
        detail.text = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        accessibilityLabel = url.lastPathComponent
        thumbnail.image = Self.images.object(forKey: url as NSURL) ?? UIImage(systemName: "play.rectangle.fill")
        if Self.images.object(forKey: url as NSURL) != nil { return }
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 500, height: 300)
        self.generator = generator
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: .zero)]) { [weak self] _, image, _, _, _ in
            guard let image else { return }
            let thumbnail = UIImage(cgImage: image)
            DispatchQueue.main.async {
                Self.images.setObject(thumbnail, forKey: url as NSURL)
                guard self?.representedURL == url else { return }
                self?.thumbnail.image = thumbnail
            }
        }
    }
}
