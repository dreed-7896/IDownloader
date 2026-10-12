import AVFoundation
import Combine
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
    private let playAll = UIBarButtonItem(title: "Play all", image: UIImage(systemName: "play.fill"))
    private var newestFirst = false
    var isToolbarItemsHidden: Bool { true }

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
        playAll.primaryAction = UIAction(title: "Play all", image: UIImage(systemName: "play.fill")) { [weak self] _ in self?.play(at: 0) }
        let sort = UIBarButtonItem(title: "Sort", image: UIImage(systemName: "arrow.up.arrow.down"))
        sort.menu = UIMenu(children: [
            UIAction(title: "Name") { [weak self] _ in self?.newestFirst = false; self?.applyFilter() },
            UIAction(title: "Newest first") { [weak self] _ in self?.newestFirst = true; self?.applyFilter() }
        ])
        navigationItem.rightBarButtonItems = [playAll, sort]
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
        navigationController?.setToolbarHidden(true, animated: false)
    }

    @objc private func reloadGallery() {
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
        playAll.isEnabled = !filtered.isEmpty
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
        return cell
    }
    override func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) { play(at: indexPath.item) }

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
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
            thumbnail.heightAnchor.constraint(equalTo: thumbnail.widthAnchor, multiplier: 9 / 16)
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
