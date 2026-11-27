import Combine
import MvvmFoundation
import QuickLook
import SwiftUI
import UIKit

class FileDownloadDetailsViewModel: BaseViewModelWith<UUID>, ObservableObject {
    var id: UUID!
    @Published private(set) var item: FileDownload?
    @Published private(set) var connections: [FileDownloadService.Connection] = []
    @Published private(set) var isRefetching = false
    let dismissSignal = PassthroughSubject<Void, Never>()
    /// Set by the controller for actions that present UIKit screens.
    var openFileAction: (() -> Void)?
    var shareAction: ((URL) -> Void)?
    var messageAction: ((String, String) -> Void)?
    private let service = FileDownloadService.shared

    override func prepare(with model: UUID) {
        id = model
        update()
        disposeBag.bind {
            service.updates.filter { $0.id == model }.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.update() }
            service.$downloads.map { $0.map(\.id) }.removeDuplicates().receive(on: DispatchQueue.main)
                .sink { [weak self] ids in if !ids.contains(model) { self?.dismissSignal.send() } }
        }
    }

    var canResume: Bool { item.map { [.paused, .failed].contains($0.state) } ?? false }
    var canPause: Bool { item.map { [.queued, .preparing, .downloading].contains($0.state) } ?? false }
    var isComplete: Bool { item?.state == .completed }
    var fileURL: URL? { service.fileURL(id) }
    var sourceURL: URL? { item?.url }
    var website: URL? { item?.page }

    func resume() { service.resume(id) }
    func pause() { service.pause(id) }
    func remove() {
        alert(title: "Remove download?", message: item?.name, actions: [
            .init(title: %"torrent.remove.action.dropData", style: .destructive, action: { [unowned self] in service.remove(id) }),
            .init(title: %"torrent.remove.action.keepData", style: .default, action: { [unowned self] in service.remove(id, deleteFiles: false) }),
            .init(title: %"common.cancel", style: .cancel, isPrimary: true)
        ])
    }

    func openWebsite() {
        guard let website else { return }
        if !AppRootController.openInBrowser(website) { UIApplication.shared.open(website) }
    }

    func refetch() {
        guard !isRefetching else { return }
        let restart = { [unowned self] in
            isRefetching = true
            Task { @MainActor in
                let message = await service.refetchFromWebsite(id)
                isRefetching = false
                if let message { messageAction?("Couldn't fetch again", message) }
            }
        }
        if isComplete {
            alert(title: "Download again?", message: "The saved file is replaced with a fresh copy from the website.", actions: [
                .init(title: "Download again", style: .default, isPrimary: true, action: restart),
                .init(title: %"common.cancel", style: .cancel)
            ])
        } else { restart() }
    }

    func copy(_ value: String?) { UIPasteboard.general.string = value }

    private func update() {
        guard let current = service.downloads.first(where: { $0.id == id }) else { return }
        item = current
        connections = service.connections(id)
    }
}

final class FileDownloadDetailsViewController<VM: FileDownloadDetailsViewModel>: BaseViewController<VM>, QLPreviewControllerDataSource {
    private lazy var host = UIHostingController(rootView: FileDownloadDetailsView(model: viewModel))

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = SColor.bg
        addChild(host)
        host.view.backgroundColor = SColor.bg
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)

        viewModel.openFileAction = { [weak self] in self?.openFile() }
        viewModel.shareAction = { [weak self] url in self?.share(url) }
        viewModel.messageAction = { [weak self] title, message in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            self?.present(alert, animated: true)
        }
        disposeBag.bind {
            viewModel.$item.receive(on: DispatchQueue.main).sink { [weak self] item in
                self?.title = item?.title ?? item?.name
            }
            viewModel.dismissSignal.sink { [weak self] _ in
                guard let self else { return }
                if !((splitViewController as? BaseSplitViewController)?.showEmptyDetail() ?? false) { pop(animated: true, sender: self) }
            }
        }
    }

    private func openFile() {
        guard let url = viewModel.fileURL, FileManager.default.fileExists(atPath: url.path) else { return }
        if VLCPlayerViewModel.isMediaFile(url) {
            viewModel.navigate(to: VLCPlayerViewModel.self, with: .init(url: url, torrentPair: nil),
                               by: .present(wrapInNavigation: true, from: nil, style: .fullScreen))
            return
        }
        let controller = QLPreviewController()
        controller.dataSource = self
        present(controller, animated: true)
    }

    private func share(_ url: URL) {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.popoverPresentationController?.sourceView = view
        controller.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
        present(controller, animated: true)
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { viewModel.fileURL == nil ? 0 : 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        (viewModel.fileURL ?? URL(fileURLWithPath: NSTemporaryDirectory())) as NSURL
    }
}

// MARK: - View

struct FileDownloadDetailsView: View {
    @ObservedObject var model: FileDownloadDetailsViewModel
    @State private var preview: UIImage?
    @State private var duration: Double?

    var body: some View {
        ScrollView {
            if let item = model.item {
                VStack(alignment: .leading, spacing: 18) {
                    hero(item)
                    statusCard(item)
                    primaryActions(item)
                    if item.state == .failed, let error = item.error { errorCard(error) }
                    websiteSection(item)
                    detailsSection(item)
                    if model.connections.count > 1 { connectionsSection }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 32)
                .animation(.easeInOut(duration: 0.2), value: item.state)
            }
        }
        .background(Color.sBg.ignoresSafeArea())
        .task(id: previewKey) { await loadPreview() }
    }

    // MARK: State

    private var previewKey: String { "\(model.fileURL?.path ?? "")|\(model.isComplete)" }

    /// A frame from the finished video, shown as the hero card.
    private func loadPreview() async {
        guard model.isComplete, let url = model.fileURL, ThumbnailProvider.isVideo(url),
              FileManager.default.fileExists(atPath: url.path) else {
            preview = nil
            duration = nil
            return
        }
        let image = await ThumbnailProvider.shared.thumbnail(for: url, size: CGSize(width: 640, height: 360), scale: 2)
        if Task.isCancelled { return }
        preview = image
        duration = await ThumbnailProvider.shared.duration(of: url)
    }

    private var isMedia: Bool { model.fileURL.map { VLCPlayerViewModel.isMediaFile($0) } ?? false }

    private func stateColor(_ item: FileDownload) -> Color {
        switch item.state {
        case .completed: return .sMint
        case .failed: return .sCoral
        case .paused, .queued: return .sAmber
        default: return Brand.teal
        }
    }

    private func typeIcon(_ item: FileDownload) -> Icon {
        if item.isHLS { return .video }
        let ext = (item.name as NSString).pathExtension.lowercased()
        if ThumbnailProvider.videoExtensions.contains(ext) { return .film }
        if ["mp3", "m4a", "aac", "flac", "wav", "ogg", "opus"].contains(ext) { return .music }
        if ["jpg", "jpeg", "png", "gif", "webp", "heic"].contains(ext) { return .image }
        if ["zip", "rar", "7z", "gz", "tgz", "bz2", "xz", "tar"].contains(ext) { return .fileZip }
        return .file
    }

    private func percentText(_ item: FileDownload) -> String {
        if item.state == .completed { return "100%" }
        return item.totalBytes > 0 ? String(format: "%.0f%%", item.progress * 100) : "—"
    }

    private func bytes(_ value: Int64) -> String { UInt64(max(0, value)).bitrateToHumanReadable }

    private static func durationText(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return total >= 3600 ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                             : String(format: "%d:%02d", total / 60, total % 60)
    }

    // MARK: Hero

    private func hero(_ item: FileDownload) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preview {
                Button { model.openFileAction?() } label: {
                    Color.sS2
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay(Image(uiImage: preview).resizable().scaledToFill())
                        .overlay(
                            LinearGradient(colors: [.clear, Color.black.opacity(0.45)], startPoint: .center, endPoint: .bottom)
                        )
                        .overlay(
                            Icon.play.view(26)
                                .foregroundStyle(Color.white)
                                .frame(width: 62, height: 62)
                                .background(Circle().fill(.ultraThinMaterial))
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 1))
                        )
                        .overlay(alignment: .bottomTrailing) {
                            if let duration, duration.isFinite, duration > 0 {
                                Text(Self.durationText(duration))
                                    .font(.sInter(12, .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(Color.white)
                                    .padding(.horizontal, 8)
                                    .frame(height: 24)
                                    .background(Capsule().fill(Color.black.opacity(0.55)))
                                    .padding(12)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1))
                }
                .buttonStyle(PressedOpacityStyle())
                .accessibilityLabel("Play video")
            }

            HStack(alignment: .top, spacing: 14) {
                if preview == nil {
                    typeIcon(item).view(28)
                        .foregroundStyle(stateColor(item))
                        .frame(width: 64, height: 64)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(stateColor(item).opacity(0.14)))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
                }
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 6) {
                        Text(item.stateTitle)
                            .font(.sInter(12, .semibold))
                            .foregroundStyle(stateColor(item))
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(stateColor(item).opacity(0.15)))
                        if let host = item.page?.host ?? item.url.host {
                            HStack(spacing: 5) {
                                Icon.globe.view(12)
                                Text(host.replacingOccurrences(of: "www.", with: "")).lineLimit(1)
                            }
                            .font(.sInter(12, .medium))
                            .foregroundStyle(Color.sText2)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(Capsule().fill(Color.sS2))
                        }
                    }
                    Text(item.title ?? item.name)
                        .font(.sDisplay(24, .heavy))
                        .tracking(-0.5)
                        .foregroundStyle(Color.sText)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    if item.title != nil, item.title != item.name {
                        Text(item.name)
                            .font(.sInter(13))
                            .foregroundStyle(Color.sText3)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: Status

    private func statusCard(_ item: FileDownload) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(percentText(item))
                    .font(.sDisplay(44, .heavy))
                    .monospacedDigit()
                    .foregroundStyle(Color.sText)
                Spacer(minLength: 8)
                statusTrailing(item)
            }
            SegmentedBar(values: model.connections.isEmpty || item.state == .completed ? [item.progress] : model.connections.map(\.progress),
                         complete: item.state == .completed)
                .frame(height: 8)
            HStack(alignment: .top, spacing: 12) {
                if item.state == .completed {
                    stat(.drive, "Size", item.totalBytes > 0 ? bytes(item.totalBytes) : "—")
                    stat(.calendar, "Added", DateFormatter.localizedString(from: item.createdAt, dateStyle: .short, timeStyle: .short))
                    stat(.link, "Connections", "\(item.parts)")
                } else {
                    stat(.saveVideo, "Downloaded", item.totalBytes > 0 ? "\(bytes(item.receivedBytes)) of \(bytes(item.totalBytes))" : bytes(item.receivedBytes))
                    stat(.speed, "Speed", item.speed > 0 ? "\(item.speed.bitrateToHumanReadable)/s" : "—")
                    stat(.timer, "Time left", item.state == .downloading ? item.timeRemaining : "—")
                }
            }
        }
        .padding(18)
        .background(card(20))
    }

    @ViewBuilder
    private func statusTrailing(_ item: FileDownload) -> some View {
        switch item.state {
        case .downloading:
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(item.speed.bitrateToHumanReadable)/s")
                    .font(.sInter(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Color.sMint)
                Text("\(item.timeRemaining) left")
                    .font(.sInter(12))
                    .monospacedDigit()
                    .foregroundStyle(Color.sText3)
            }
        case .completed:
            badge(.checkCircle, "Saved", .sMint)
        case .failed:
            badge(.alert, "Failed", .sCoral)
        case .paused, .queued:
            badge(.pause, item.stateTitle, .sAmber)
        case .preparing, .assembling:
            HStack(spacing: 8) {
                ProgressView().tint(Brand.teal)
                Text(item.stateTitle).font(.sInter(14, .semibold)).foregroundStyle(Brand.teal)
            }
        }
    }

    private func badge(_ icon: Icon, _ text: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            icon.view(18)
            Text(text).font(.sInter(14, .semibold))
        }
        .foregroundStyle(color)
    }

    private func stat(_ icon: Icon, _ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                icon.view(13)
                Text(title).font(.sInter(12, .medium)).lineLimit(1)
            }
            .foregroundStyle(Color.sText3)
            Text(value)
                .font(.sInter(14, .semibold))
                .monospacedDigit()
                .foregroundStyle(Color.sText)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Actions

    private func primaryActions(_ item: FileDownload) -> some View {
        HStack(spacing: 10) {
            if model.canPause {
                BoxButton(title: "Pause", systemImage: "pause.fill", prominent: true) { model.pause() }
            } else if model.canResume {
                BoxButton(title: item.state == .failed ? "Retry" : "Resume",
                          systemImage: item.state == .failed ? "arrow.clockwise" : "play.fill", prominent: true) { model.resume() }
            } else if model.isComplete {
                BoxButton(title: isMedia ? "Play" : "Open", systemImage: isMedia ? "play.fill" : "arrow.up.forward.square",
                          prominent: true) { model.openFileAction?() }
            } else {
                BoxLabel(title: item.stateTitle, systemImage: "clock").opacity(0.6)
            }
            Menu {
                if model.isComplete, let url = model.fileURL {
                    Button { model.shareAction?(url) } label: { Label("Share file", image: Icon.file.assetName) }
                }
                if let url = model.sourceURL {
                    Button { model.shareAction?(url) } label: { Label("Share link", image: Icon.link.assetName) }
                    Button { model.copy(url.absoluteString) } label: { Label("Copy link", image: Icon.copy.assetName) }
                }
                if let website = model.website {
                    Button { model.shareAction?(website) } label: { Label("Share website", image: Icon.globe.assetName) }
                }
            } label: {
                DetailCircleLabel(icon: .share)
            }
            .accessibilityLabel("Share")
            DriftCircleButton(icon: .delete, label: "Delete", size: 48, tint: .sCoral) { model.remove() }
        }
    }

    private func errorCard(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Icon.alert.view(20).foregroundStyle(Color.sCoral)
            VStack(alignment: .leading, spacing: 4) {
                Text("Download failed").font(.sInter(15, .semibold)).foregroundStyle(Color.sText)
                Text(error).font(.sInter(14)).foregroundStyle(Color.sText2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sCoral.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.sCoral.opacity(0.35), lineWidth: 1))
    }

    // MARK: Sections

    private func websiteSection(_ item: FileDownload) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionTitle("Website")
            if let website = item.page {
                VStack(spacing: 0) {
                    Button { model.openWebsite() } label: {
                        HStack(spacing: 12) {
                            SiteIcon(title: item.title ?? website.host ?? "", url: website, size: 40)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title ?? website.host ?? website.absoluteString)
                                    .font(.sInter(15, .semibold))
                                    .foregroundStyle(Color.sText)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(website.host ?? website.absoluteString)
                                    .font(.sInter(13))
                                    .foregroundStyle(Color.sText3)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(Color.sText3)
                        }
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressedOpacityStyle())
                    .contextMenu {
                        Button { model.copy(website.absoluteString) } label: { Label("Copy website", image: Icon.copy.assetName) }
                    }
                    Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 66)
                    Button { model.refetch() } label: {
                        HStack(spacing: 10) {
                            if model.isRefetching {
                                ProgressView().tint(Color.sMint).frame(width: 40)
                            } else {
                                Icon.refresh.view(18).frame(width: 40)
                            }
                            Text(model.isRefetching ? "Looking for the video…" : "Fetch again from website")
                                .font(.sInter(15, .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.sMint)
                        .padding(14)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(PressedOpacityStyle())
                    .disabled(model.isRefetching)
                }
                .background(card(18))
            } else {
                HStack(alignment: .top, spacing: 10) {
                    Icon.info.view(18).foregroundStyle(Color.sText3)
                    Text("This link was added directly, so no website was saved. Download from the browser or share a page to keep its website.")
                        .font(.sInter(13))
                        .foregroundStyle(Color.sText3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                )
            }
        }
    }

    private func detailsSection(_ item: FileDownload) -> some View {
        var rows: [(String, String)] = [
            ("Size", item.totalBytes > 0 ? bytes(item.totalBytes) : "Unknown"),
            ("Received", bytes(item.receivedBytes)),
            ("Connections", "\(item.parts)"),
            ("Added", DateFormatter.localizedString(from: item.createdAt, dateStyle: .medium, timeStyle: .short)),
            ("Host", item.url.host ?? "—"),
            ("Link", item.url.absoluteString)
        ]
        if let path = model.fileURL?.path { rows.append(("Saved in", path)) }
        return VStack(alignment: .leading, spacing: 8) {
            DetailSectionTitle("Details")
            InfoGrid(rows: rows, copy: model.copy)
        }
    }

    private var connectionsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            DetailSectionTitle("Connections · \(model.connections.count)")
            VStack(spacing: 12) {
                ForEach(model.connections, id: \.number) { connection in
                    HStack(spacing: 10) {
                        Text("\(connection.number)")
                            .font(.sInter(12, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(Color.sText3)
                            .frame(width: 22, alignment: .leading)
                        SegmentedBar(values: [connection.progress], complete: connection.progress >= 1)
                            .frame(height: 6)
                        Text("\(Int(connection.progress * 100))%")
                            .font(.sInter(12, .medium))
                            .monospacedDigit()
                            .foregroundStyle(Color.sText2)
                            .frame(width: 40, alignment: .trailing)
                    }
                }
            }
            .padding(16)
            .background(card(18))
        }
    }

    private func card(_ radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.sS1)
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}

/// A quiet section title above a card.
private struct DetailSectionTitle: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.sInter(13, .semibold))
            .foregroundStyle(Color.sText3)
            .padding(.leading, 4)
    }
}

/// The look of a round icon button, for menus that need a label instead of a Button.
private struct DetailCircleLabel: View {
    let icon: Icon
    var size: CGFloat = 48

    var body: some View {
        icon.view(size * 0.44)
            .foregroundStyle(Color.sText)
            .frame(width: size, height: size)
            .background(Circle().fill(Color.sS2))
            .overlay(Circle().strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
            .contentShape(Circle())
    }
}

// MARK: - Pieces

/// Rounded progress bar; one capsule segment per connection (a single bar once complete).
struct SegmentedBar: View {
    var values: [Double]
    var complete = false

    var body: some View {
        GeometryReader { geometry in
            let shown = complete ? [1.0] : (values.isEmpty ? [0] : values)
            let count = shown.count
            let gap: CGFloat = count > 1 ? 3 : 0
            let width = max(0, (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count))
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    let value = CGFloat(min(1, max(0, shown[index])))
                    ZStack(alignment: .leading) {
                        Color.sS3
                        Color.sMint.frame(width: width * value)
                    }
                    .frame(width: width)
                    .clipShape(Capsule())
                }
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int((values.reduce(0, +) / Double(max(1, values.count))) * 100)) percent")
    }
}

/// Hugeicons for the SF Symbol names these shared buttons are called with; SF Symbols otherwise.
private struct BoxIcon: View {
    let systemImage: String
    var size: CGFloat = 18

    private static let icons: [String: Icon] = [
        "pause.fill": .pause, "pause": .pause, "play.fill": .play, "play": .play, "arrow.clockwise": .refresh,
        "arrow.up.forward.square": .expand, "square.and.arrow.up": .share, "trash": .delete, "arrow.down": .saveVideo,
        "link": .link, "doc.on.doc": .copy, "safari": .globe, "plus": .add, "folder": .folder, "clock": .timer,
        "xmark": .stop, "checkmark": .tick, "eyeglasses": .incognito
    ]

    var body: some View {
        if let icon = Self.icons[systemImage] {
            icon.view(size)
        } else {
            Image(systemName: systemImage).font(.system(size: size * 0.8, weight: .semibold))
        }
    }
}

struct BoxLabel: View {
    let title: String
    let systemImage: String
    var prominent = false
    var destructive = false

    var body: some View {
        HStack(spacing: 7) {
            BoxIcon(systemImage: systemImage)
            Text(title).font(.sInter(15, .semibold)).lineLimit(1)
        }
        .foregroundStyle(prominent ? Color.sOnAccent : destructive ? Color.sCoral : Color.sText)
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity)
        .frame(height: 48)
        .background(Capsule().fill(prominent ? Color.sMint : destructive ? Color.sCoral.opacity(0.12) : Color.sS2))
        .overlay(Capsule().strokeBorder(Color.white.opacity(prominent ? 0 : 0.07), lineWidth: 1))
        .contentShape(Capsule())
    }
}

struct BoxButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    var destructive = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BoxLabel(title: title, systemImage: systemImage, prominent: prominent, destructive: destructive)
        }
        .buttonStyle(PressedOpacityStyle())
    }
}

/// Press feedback: a slight fade and shrink.
struct PressedOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Label/value rows in a rounded card. Long-press a row to copy its value.
struct InfoGrid: View {
    let rows: [(String, String)]
    var copy: (String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1).padding(.leading, 16) }
                let long = row.1.count > 32
                Group {
                    if long {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.0).font(.sInter(13, .medium)).foregroundStyle(Color.sText3)
                            Text(row.1).font(.sInter(14)).foregroundStyle(Color.sText2).lineLimit(4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 12) {
                            Text(row.0).font(.sInter(15)).foregroundStyle(Color.sText2)
                            Spacer(minLength: 8)
                            Text(row.1).font(.sInter(15, .semibold)).monospacedDigit().foregroundStyle(Color.sText).lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .contentShape(Rectangle())
                .contextMenu {
                    Button { copy(row.1) } label: { Label("Copy", image: Icon.copy.assetName) }
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.sS1))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Color.white.opacity(0.07), lineWidth: 1))
    }
}
