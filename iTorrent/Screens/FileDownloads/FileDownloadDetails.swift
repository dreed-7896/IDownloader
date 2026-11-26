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

    var body: some View {
        ScrollView {
            if let item = model.item {
                VStack(alignment: .leading, spacing: 22) {
                    header(item)
                    actions(item)
                    if item.state == .failed, let error = item.error { errorBox(error) }
                    websiteSection(item)
                    transferSection(item)
                    if model.connections.count > 1 { connectionsSection }
                    locationSection
                }
                .padding(16)
                .padding(.bottom, 24)
            }
        }
        .background(Color.sBg.ignoresSafeArea())
    }

    private func stateColor(_ item: FileDownload) -> Color {
        switch item.state {
        case .completed: return .sMint
        case .failed: return .sCoral
        case .paused, .queued: return .sAmber
        default: return .sText
        }
    }

    private func header(_ item: FileDownload) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(item.stateTitle)
                    .font(.sMono(12, .bold)).textCase(.uppercase).tracking(1)
                    .foregroundStyle(Color.sOnAccent)
                    .padding(.horizontal, 6).frame(height: 22)
                    .background(stateColor(item))
                Text(item.page?.host ?? item.url.host ?? "")
                    .sLabel()
                    .lineLimit(1)
            }
            Text(item.name)
                .font(.sDisplay(26, .heavy))
                .tracking(-0.6)
                .foregroundStyle(Color.sText)
                .lineLimit(4)
                .textSelection(.enabled)
            HStack(alignment: .firstTextBaseline) {
                Text(item.totalBytes > 0 ? String(format: "%.0f%%", item.progress * 100) : "—")
                    .font(.sDisplay(40, .heavy))
                    .foregroundStyle(Color.sText)
                Spacer()
                if item.state == .downloading {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(item.speed.bitrateToHumanReadable)/s").font(.sMono(14, .bold)).foregroundStyle(Color.sMint)
                        Text(item.timeRemaining).font(.sMono(12, .medium)).foregroundStyle(Color.sText3)
                    }
                }
            }
            SegmentedBar(values: model.connections.isEmpty ? [item.progress] : model.connections.map(\.progress),
                         complete: item.state == .completed)
                .frame(height: 8)
        }
    }

    private func actions(_ item: FileDownload) -> some View {
        HStack(spacing: 8) {
            if model.canPause {
                BoxButton(title: "Pause", systemImage: "pause.fill", prominent: true) { model.pause() }
            } else if model.canResume {
                BoxButton(title: item.state == .failed ? "Retry" : "Resume", systemImage: item.state == .failed ? "arrow.clockwise" : "play.fill", prominent: true) { model.resume() }
            } else if model.isComplete {
                BoxButton(title: "Open", systemImage: "arrow.up.forward.square", prominent: true) { model.openFileAction?() }
            }
            Menu {
                if model.isComplete, let url = model.fileURL {
                    Button { model.shareAction?(url) } label: { Label("Share file", systemImage: "doc") }
                }
                if let url = model.sourceURL {
                    Button { model.shareAction?(url) } label: { Label("Share link", systemImage: "link") }
                    Button { model.copy(url.absoluteString) } label: { Label("Copy link", systemImage: "doc.on.doc") }
                }
                if let website = model.website {
                    Button { model.shareAction?(website) } label: { Label("Share website", systemImage: "safari") }
                }
            } label: {
                BoxLabel(title: "Share", systemImage: "square.and.arrow.up", prominent: false)
            }
            BoxButton(title: "Delete", systemImage: "trash", prominent: false, destructive: true) { model.remove() }
        }
    }

    private func errorBox(_ error: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.sCoral)
            Text(error).font(.sInter(14)).foregroundStyle(Color.sText)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(Color.sCoral.opacity(0.1))
        .overlay(Rectangle().strokeBorder(Color.sCoral.opacity(0.6), lineWidth: 1))
    }

    @ViewBuilder
    private func websiteSection(_ item: FileDownload) -> some View {
        Section {
            if let website = item.page {
                VStack(spacing: 0) {
                    Button { model.openWebsite() } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "safari").font(.system(size: 18, weight: .medium)).foregroundStyle(Color.sMint)
                                .frame(width: 36, height: 36).background(Color.sS2)
                                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title ?? website.host ?? website.absoluteString)
                                    .font(.sInter(15, .semibold)).foregroundStyle(Color.sText).lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(website.absoluteString).font(.sMono(12, .medium)).foregroundStyle(Color.sText3).lineLimit(1)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "arrow.up.right").font(.system(size: 13, weight: .bold)).foregroundStyle(Color.sText3)
                        }
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button { model.copy(website.absoluteString) } label: { Label("Copy website", systemImage: "doc.on.doc") }
                    }
                    Rectangle().fill(Color.sLine).frame(height: 1)
                    Button { model.refetch() } label: {
                        HStack(spacing: 8) {
                            if model.isRefetching { ProgressView().tint(Color.sMint) }
                            else { Image(systemName: "arrow.triangle.2.circlepath") }
                            Text(model.isRefetching ? "Looking for the video…" : "Fetch again from website")
                                .font(.sInter(14, .semibold))
                            Spacer()
                        }
                        .foregroundStyle(Color.sMint)
                        .padding(12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isRefetching)
                }
                .background(Color.sS1)
                .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
            } else {
                Text("This link was added directly, so no website was saved. Share a page from Safari to keep its website.")
                    .font(.sInter(13)).foregroundStyle(Color.sText3)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(Color.sLine, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
        } header: {
            Text("Website").sLabel()
        }
        Section {
            InfoGrid(rows: [
                ("Host", item.url.host ?? "—"),
                ("Link", item.url.absoluteString)
            ], copy: model.copy)
        } header: {
            Text("Download link").sLabel()
        }
    }

    private func transferSection(_ item: FileDownload) -> some View {
        Section {
            InfoGrid(rows: [
                ("Size", item.totalBytes > 0 ? UInt64(item.totalBytes).bitrateToHumanReadable : "Unknown"),
                ("Received", UInt64(max(0, item.receivedBytes)).bitrateToHumanReadable),
                ("Connections", "\(item.parts)"),
                ("Added", DateFormatter.localizedString(from: item.createdAt, dateStyle: .medium, timeStyle: .short))
            ], copy: model.copy)
        } header: {
            Text("Transfer").sLabel()
        }
    }

    private var connectionsSection: some View {
        Section {
            VStack(spacing: 0) {
                ForEach(model.connections, id: \.number) { connection in
                    HStack(spacing: 10) {
                        Text(String(format: "%02d", connection.number)).font(.sMono(12, .bold)).foregroundStyle(Color.sText3)
                        SegmentedBar(values: [connection.progress], complete: connection.progress >= 1).frame(height: 6)
                        Text("\(Int(connection.progress * 100))%").font(.sMono(12, .medium)).foregroundStyle(Color.sText2)
                            .frame(width: 44, alignment: .trailing)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 9)
                }
            }
            .background(Color.sS1)
            .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
        } header: {
            Text("Connections").sLabel()
        }
    }

    @ViewBuilder
    private var locationSection: some View {
        if let path = model.fileURL?.path {
            Section {
                InfoGrid(rows: [("Saved in", path)], copy: model.copy)
            } header: {
                Text("Location").sLabel()
            }
        }
    }
}

// MARK: - Pieces

/// Square progress bar; one segment per connection.
struct SegmentedBar: View {
    var values: [Double]
    var complete = false

    var body: some View {
        GeometryReader { geometry in
            let count = max(1, values.count)
            let gap: CGFloat = count > 1 ? 2 : 0
            let width = (geometry.size.width - gap * CGFloat(count - 1)) / CGFloat(count)
            HStack(spacing: gap) {
                ForEach(0..<count, id: \.self) { index in
                    let value = values.indices.contains(index) ? min(1, max(0, values[index])) : 0
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.sS3)
                        Rectangle().fill(complete ? Color.sMint : Color.sText).frame(width: width * value)
                    }
                    .frame(width: width)
                }
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int((values.reduce(0, +) / Double(max(1, values.count))) * 100)) percent")
    }
}

struct BoxLabel: View {
    let title: String
    let systemImage: String
    var prominent = false
    var destructive = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 13, weight: .semibold))
            Text(title).font(.sInter(14, .semibold)).lineLimit(1)
        }
        .foregroundStyle(prominent ? Color.sOnAccent : destructive ? Color.sCoral : Color.sText)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(prominent ? Color.sMint : Color.sS1)
        .overlay(Rectangle().strokeBorder(prominent ? Color.sMint : Color.sLine2, lineWidth: 1))
        .contentShape(Rectangle())
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

struct PressedOpacityStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.65 : 1)
    }
}

/// Label/value rows inside a hairline box. Long-press a row to copy its value.
struct InfoGrid: View {
    let rows: [(String, String)]
    var copy: (String?) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                if index > 0 { Rectangle().fill(Color.sLine).frame(height: 1) }
                let long = row.1.count > 32
                Group {
                    if long {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.0).sLabel(11)
                            Text(row.1).font(.sMono(13, .medium)).foregroundStyle(Color.sText2).lineLimit(4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack {
                            Text(row.0).font(.sInter(15)).foregroundStyle(Color.sText2)
                            Spacer()
                            Text(row.1).font(.sMono(14, .semibold)).foregroundStyle(Color.sText)
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 11)
                .contentShape(Rectangle())
                .contextMenu {
                    Button { copy(row.1) } label: { Label("Copy", systemImage: "doc.on.doc") }
                }
            }
        }
        .background(Color.sS1)
        .overlay(Rectangle().strokeBorder(Color.sLine, lineWidth: 1))
    }
}
