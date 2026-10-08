import Combine
import Foundation
import LibTorrent
import UIKit
import UserNotifications

struct FileDownload: Codable, Identifiable {
    enum State: String, Codable { case queued, preparing, downloading, paused, assembling, completed, failed }
    var id = UUID()
    var url: URL
    var name: String
    var state: State = .preparing
    var requestedParts: Int
    var parts = 1
    var totalBytes: Int64 = 0
    var receivedBytes: Int64 = 0
    var speed: UInt64 = 0
    var generation = UUID()
    var validator: String?
    var completedParts: [Int] = []
    var error: String?
    var createdAt = Date()
    var progress: Double { totalBytes > 0 ? min(1, Double(receivedBytes) / Double(totalBytes)) : 0 }
    var isActive: Bool { [.preparing, .downloading, .assembling].contains(state) }
    var queueEligible: Bool { isActive || state == .queued }
    var listState: TorrentHandle.State {
        switch state {
        case .completed: return .finished
        case .paused, .queued: return .paused
        case .failed: return .storageError
        case .preparing: return .downloadingMetadata
        case .downloading, .assembling: return .downloading
        }
    }
    var stateTitle: String {
        switch state {
        case .queued: return "Queued"
        case .preparing: return "Connecting"
        case .downloading: return "Downloading"
        case .paused: return "Paused"
        case .assembling: return "Assembling"
        case .completed: return "Done"
        case .failed: return "Failed"
        }
    }
    var activityID: String { "file-\(id.uuidString)" }
    var timeRemaining: String {
        guard speed > 0, totalBytes > receivedBytes else { return "—" }
        let seconds = (totalBytes - receivedBytes) / Int64(speed)
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds % 3600 / 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
}

/// All mutations and URLSession delegate callbacks run on the main queue.
/// Download bodies are streamed to disk by the system, including while suspended.
final class FileDownloadService: NSObject, ObservableObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = FileDownloadService()
    static let sessionIdentifier = "com.dreed7896.IDownloader.files"
    @Published private(set) var downloads: [FileDownload] = []
    let updates = PassthroughSubject<FileDownload, Never>()
    var backgroundCompletion: (() -> Void)?

    private var tasks: [Int: URLSessionDownloadTask] = [:]
    private var bytes: [Int: Int64] = [:]
    private var samples: [UUID: (Date, Int64)] = [:]
    private var restoring = true
    private var assembling = Set<UUID>()
    private var pendingAssemblies = 0
    private var backgroundEventsFinished = false
    private let ioQueue = DispatchQueue(label: "Pulled.files.assembly", qos: .utility)
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.httpMaximumConnectionsPerHost = 16
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 7 * 24 * 60 * 60
        return URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }()
    private var root: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FileDownloads", isDirectory: true)
    }
    private var manifest: URL { root.appendingPathComponent("downloads.json") }

    private override init() {
        super.init()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: manifest), let saved = try? JSONDecoder().decode([FileDownload].self, from: data) {
            downloads = saved.map { item in
                var item = item
                if [.preparing, .downloading].contains(item.state) { item.state = .queued; item.speed = 0 }
                return item
            }
        }
        session.getAllTasks { [weak self] existing in
            DispatchQueue.main.async {
                guard let self else { return }
                for task in existing {
                    guard let task = task as? URLSessionDownloadTask,
                          let tag = Tag(task), let item = self.item(tag), item.state != .completed, item.state != .failed
                    else { task.cancel(); continue }
                    self.tasks[task.taskIdentifier] = task
                    self.bytes[task.taskIdentifier] = task.countOfBytesReceived
                    if item.state == .paused || item.state == .queued { task.suspend() } else { task.resume() }
                }
                self.restoring = false
                for item in self.downloads where item.queueEligible {
                    if item.completedParts.count == item.parts, !item.completedParts.isEmpty {
                        self.assemble(item.id)
                    } else if !self.tasks.values.contains(where: { Tag($0)?.id == item.id }) {
                        self.downloads[self.index(item.id)!].state = .queued
                    }
                }
                DownloadQueue.shared.schedule()
            }
        }
    }

    @discardableResult
    func add(_ url: URL) -> UUID? {
        guard ["http", "https"].contains(url.scheme?.lowercased()), url.host != nil else { return nil }
        if let existing = downloads.first(where: { $0.url == url && ($0.queueEligible || $0.state == .paused) }) { return existing.id }
        let item = FileDownload(url: url, name: url.lastPathComponent.isEmpty ? "Download" : url.lastPathComponent,
                                state: .queued, requestedParts: min(16, max(1, PreferencesStorage.shared.fileDownloadParts)))
        downloads.insert(item, at: 0)
        publish(item.id)
        DownloadQueue.shared.schedule()
        return item.id
    }

    func pause(_ id: UUID) {
        guard let index = index(id), [.queued, .preparing, .downloading].contains(downloads[index].state) else { return }
        downloads[index].state = .paused
        downloads[index].speed = 0
        tasks.values.filter { Tag($0)?.id == id }.forEach { $0.suspend() }
        publish(id)
    }

    func resume(_ id: UUID) {
        guard let index = index(id), [.paused, .failed].contains(downloads[index].state) else { return }
        downloads[index].state = .queued
        downloads[index].error = nil
        publish(id)
        DownloadQueue.shared.schedule()
    }

    func setQueueAllowed(_ id: UUID, _ allowed: Bool) {
        guard !restoring, let index = index(id) else { return }
        if !allowed, [.preparing, .downloading].contains(downloads[index].state) {
            downloads[index].state = .queued
            downloads[index].speed = 0
            tasks.values.filter { Tag($0)?.id == id }.forEach { $0.suspend() }
            samples[id] = nil
            publish(id)
        } else if allowed, downloads[index].state == .queued {
            let active = tasks.values.filter { Tag($0)?.id == id }
            if active.isEmpty { restart(id); return }
            downloads[index].state = .downloading
            samples[id] = nil
            active.forEach { $0.resume() }
            publish(id)
        }
    }

    struct Connection {
        let number: Int
        let received: Int64
        let total: Int64
        var progress: Double { total > 0 ? min(1, max(0, Double(received) / Double(total))) : 0 }
    }

    func connections(_ id: UUID) -> [Connection] {
        guard let item = downloads.first(where: { $0.id == id }) else { return [] }
        let chunk = item.totalBytes / Int64(max(1, item.parts))
        return (0..<item.parts).map { part in
            let length = part == item.parts - 1 ? item.totalBytes - Int64(part) * chunk : chunk
            let task = tasks.values.first { task in
                guard let tag = Tag(task), tag.id == id else { return false }
                return max(0, tag.part) == part
            }
            let received = item.state == .completed || item.state == .assembling || item.completedParts.contains(part)
                ? length : task.map { bytes[$0.taskIdentifier] ?? $0.countOfBytesReceived } ?? 0
            return Connection(number: part + 1, received: received, total: length)
        }
    }

    func remove(_ id: UUID, deleteFiles: Bool = true) {
        cancelTasks(id)
        try? FileManager.default.removeItem(at: directory(id))
        if deleteFiles, let file = fileURL(id) { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        if let index = index(id) {
            downloads[index].state = .failed
            updates.send(downloads[index])
            downloads.remove(at: index)
        }
        samples[id] = nil
        save()
    }

    func fileURL(_ id: UUID) -> URL? {
        guard let item = downloads.first(where: { $0.id == id }) else { return nil }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true).appendingPathComponent(item.name)
    }

    private struct Tag {
        var id: UUID
        var generation: UUID
        var part: Int
        var start: Int64
        var end: Int64
        // -1: capability probe, -2: single connection, >= 0: range part.
        init?(_ task: URLSessionTask) {
            guard let value = task.taskDescription else { return nil }
            let fields = value.split(separator: "|")
            guard fields.count == 5, let id = UUID(uuidString: String(fields[0])),
                  let generation = UUID(uuidString: String(fields[1])), let part = Int(fields[2]),
                  let start = Int64(fields[3]), let end = Int64(fields[4]) else { return nil }
            self.id = id; self.generation = generation; self.part = part; self.start = start; self.end = end
        }
    }

    private func index(_ id: UUID) -> Int? { downloads.firstIndex { $0.id == id } }
    private func item(_ tag: Tag) -> FileDownload? {
        downloads.first { $0.id == tag.id && $0.generation == tag.generation }
    }
    private func directory(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    private func partURL(_ id: UUID, _ part: Int) -> URL { directory(id).appendingPathComponent("\(part).part") }

    private func start(_ id: UUID) {
        guard let index = index(id) else { return }
        downloads[index].state = .preparing
        publish(id)
        createTask(downloads[index], part: downloads[index].requestedParts > 1 ? -1 : -2, start: 0, end: 0)
    }

    private func createTask(_ item: FileDownload, part: Int, start: Int64, end: Int64) {
        var request = URLRequest(url: item.url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.allowsCellularAccess = PreferencesStorage.shared.isCellularEnabled
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if part != -2 {
            request.setValue("bytes=\(start)-\(end)", forHTTPHeaderField: "Range")
            if part >= 0, let validator = item.validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
        }
        let task = session.downloadTask(with: request)
        task.taskDescription = "\(item.id.uuidString)|\(item.generation.uuidString)|\(part)|\(start)|\(end)"
        tasks[task.taskIdentifier] = task
        if item.state != .paused && item.state != .queued { task.resume() }
    }

    private func cancelTasks(_ id: UUID) {
        let obsolete = tasks.values.filter { Tag($0)?.id == id }
        for task in obsolete {
            tasks[task.taskIdentifier] = nil
            bytes[task.taskIdentifier] = nil
            task.cancel()
        }
    }

    private func restart(_ id: UUID, single: Bool = false) {
        guard let index = index(id) else { return }
        let previousState = downloads[index].state
        // Invalidate callbacks from cancelled tasks before scheduling replacements.
        downloads[index].generation = UUID()
        cancelTasks(id)
        try? FileManager.default.removeItem(at: directory(id))
        downloads[index].completedParts = []
        downloads[index].receivedBytes = 0
        downloads[index].totalBytes = 0
        downloads[index].parts = 1
        downloads[index].speed = 0
        downloads[index].error = nil
        downloads[index].validator = nil
        downloads[index].state = .preparing
        samples[id] = nil
        if restoring {
            publish(id)
        } else if single {
            if previousState == .paused || previousState == .queued { downloads[index].state = previousState }
            publish(id)
            createTask(downloads[index], part: -2, start: 0, end: 0)
        } else { start(id) }
    }

    private func fail(_ id: UUID, _ message: String) {
        guard let index = index(id) else { return }
        downloads[index].generation = UUID()
        downloads[index].state = .failed
        downloads[index].error = message
        downloads[index].speed = 0
        cancelTasks(id)
        publish(id)
    }

    private func save() {
        do { try JSONEncoder().encode(downloads).write(to: manifest, options: .atomic) }
        catch { print("File download state: \(error.localizedDescription)") }
    }
    private func publish(_ id: UUID, persist: Bool = true) {
        if persist { save() }
        if let index = index(id) { updates.send(downloads[index]) }
    }

    private static func range(_ response: HTTPURLResponse) -> (Int64, Int64, Int64)? {
        guard let header = response.value(forHTTPHeaderField: "Content-Range"), header.lowercased().hasPrefix("bytes ") else { return nil }
        let fields = header.dropFirst(6).split(whereSeparator: { $0 == "-" || $0 == "/" })
        guard fields.count == 3, let start = Int64(fields[0]), let end = Int64(fields[1]), let total = Int64(fields[2]),
              start >= 0, end >= start, total > end else { return nil }
        return (start, end, total)
    }

    private static func filename(_ response: URLResponse) -> String {
        let value = (response.suggestedFilename ?? "Download").components(separatedBy: CharacterSet(charactersIn: "/\\")).last ?? "Download"
        let cleaned = value.components(separatedBy: .controlCharacters).joined()
        var name = cleaned
        while name.utf8.count > 180 { name.removeLast() }
        return name.isEmpty || name == "." || name == ".." ? "Download" : name
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let tag = Tag(downloadTask), item(tag) != nil, let index = index(tag.id) else { return }
        let response = downloadTask.response as? HTTPURLResponse
        // A server ignoring the probe Range is already streaming the complete file: keep it.
        if tag.part == -1, response?.statusCode == 206 { return }
        if tag.part >= 0, let response, response.statusCode == 200 {
            restart(tag.id, single: true)
            return
        }
        if tag.part < 0 {
            downloads[index].totalBytes = max(0, totalBytesExpectedToWrite)
            if let response { downloads[index].name = Self.filename(response) }
        }
        bytes[downloadTask.taskIdentifier] = totalBytesWritten
        var received: Int64 = 0
        for part in downloads[index].completedParts {
            let attributes = try? FileManager.default.attributesOfItem(atPath: partURL(tag.id, part).path)
            received += (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        }
        for task in tasks.values where Tag(task)?.id == tag.id { received += bytes[task.taskIdentifier] ?? 0 }
        downloads[index].receivedBytes = received
        if downloads[index].state != .paused && downloads[index].state != .queued { downloads[index].state = .downloading }
        let now = Date()
        if let previous = samples[tag.id] {
            let elapsed = now.timeIntervalSince(previous.0)
            if elapsed >= 1 {
                downloads[index].speed = (downloads[index].state == .paused || downloads[index].state == .queued) ? 0 : UInt64(max(0, Double(received - previous.1) / elapsed))
                samples[tag.id] = (now, received)
                publish(tag.id, persist: false)
            }
        } else { samples[tag.id] = (now, received) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let tag = Tag(downloadTask), let item = item(tag), let index = index(tag.id),
              let response = downloadTask.response as? HTTPURLResponse else { return }
        tasks[downloadTask.taskIdentifier] = nil
        bytes[downloadTask.taskIdentifier] = nil
        guard (200...299).contains(response.statusCode) else {
            if response.statusCode == 416, tag.part != -2 { restart(tag.id, single: true) }
            else { fail(tag.id, "Server returned HTTP \(response.statusCode).") }
            return
        }
        let size = ((try? FileManager.default.attributesOfItem(atPath: location.path))?[.size] as? NSNumber)?.int64Value ?? -1
        let range = Self.range(response)
        let encoded = response.value(forHTTPHeaderField: "Content-Encoding").map { $0.lowercased() != "identity" } ?? false
        if tag.part == -1, response.statusCode == 206 {
            guard let range, range.0 == 0, range.1 == 0, size == 1, !encoded else { restart(tag.id, single: true); return }
            downloads[index].name = Self.filename(response)
            downloads[index].totalBytes = range.2
            let etag = response.value(forHTTPHeaderField: "ETag")
            downloads[index].validator = etag.flatMap { $0.hasPrefix("W/") ? nil : $0 } ?? response.value(forHTTPHeaderField: "Last-Modified")
            downloads[index].parts = Int(min(Int64(item.requestedParts), range.2))
            if item.state != .paused && item.state != .queued { downloads[index].state = .downloading }
            publish(tag.id)
            let updated = downloads[index]
            let chunk = range.2 / Int64(updated.parts)
            for part in 0..<updated.parts {
                let start = Int64(part) * chunk
                let end = part == updated.parts - 1 ? range.2 - 1 : start + chunk - 1
                createTask(updated, part: part, start: start, end: end)
            }
            return
        }
        if tag.part >= 0 {
            guard response.statusCode == 206, let range, range.0 == tag.start, range.1 == tag.end,
                  range.2 == item.totalBytes, size == tag.end - tag.start + 1, !encoded else { restart(tag.id, single: true); return }
            if let validator = item.validator,
               let actual = response.value(forHTTPHeaderField: validator.hasPrefix("\"") ? "ETag" : "Last-Modified"), actual != validator {
                fail(tag.id, "The file changed on the server. Retry the download.")
                return
            }
        } else {
            guard response.statusCode == 200 || (response.statusCode == 206 && range?.0 == 0 && range.map({ $0.1 == $0.2 - 1 }) == true),
                  size >= 0, response.expectedContentLength < 0 || encoded || size == response.expectedContentLength
            else { fail(tag.id, "The server returned an incomplete file."); return }
            downloads[index].name = Self.filename(response)
            downloads[index].totalBytes = size
            downloads[index].parts = 1
        }
        let part = max(0, tag.part)
        do {
            try FileManager.default.createDirectory(at: directory(tag.id), withIntermediateDirectories: true)
            let target = partURL(tag.id, part)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.moveItem(at: location, to: target)
            if !downloads[index].completedParts.contains(part) { downloads[index].completedParts.append(part) }
            downloads[index].receivedBytes = connections(tag.id).reduce(0) { $0 + $1.received }
            publish(tag.id)
            if downloads[index].completedParts.count == downloads[index].parts { assemble(tag.id) }
        } catch { fail(tag.id, error.localizedDescription) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let tag = Tag(task), item(tag) != nil, let error else { return }
        tasks[task.taskIdentifier] = nil
        bytes[task.taskIdentifier] = nil
        fail(tag.id, error.localizedDescription)
    }

    private func assemble(_ id: UUID) {
        guard let index = index(id), let destination = fileURL(id), assembling.insert(id).inserted else { return }
        downloads[index].state = .assembling
        let item = downloads[index]
        downloads[index].receivedBytes = item.totalBytes
        downloads[index].speed = 0
        publish(id)
        let parts = (0..<item.parts).map { partURL(id, $0) }
        pendingAssemblies += 1
        ioQueue.async { [weak self] in
            let temporary = destination.deletingLastPathComponent().appendingPathComponent(".\(item.generation.uuidString).assembling")
            let result: Result<Void, Error> = Result {
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: temporary.path, contents: nil)
                let output = try FileHandle(forWritingTo: temporary)
                defer { try? output.close() }
                for part in parts {
                    let input = try FileHandle(forReadingFrom: part)
                    defer { try? input.close() }
                    while let data = try input.read(upToCount: 1024 * 1024), !data.isEmpty { try output.write(contentsOf: data) }
                }
                try output.synchronize()
                let size = (try FileManager.default.attributesOfItem(atPath: temporary.path)[.size] as? NSNumber)?.int64Value
                guard size == item.totalBytes else { throw URLError(.cannotDecodeContentData) }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                defer { self.assembling.remove(id); self.pendingAssemblies -= 1; self.finishBackgroundEventsIfNeeded() }
                guard let index = self.index(id), self.downloads[index].generation == item.generation else {
                    try? FileManager.default.removeItem(at: temporary)
                    return
                }
                do {
                    try result.get()
                    if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
                    try FileManager.default.moveItem(at: temporary, to: destination)
                    self.downloads[index].state = .completed
                    self.downloads[index].receivedBytes = item.totalBytes
                    try? FileManager.default.removeItem(at: self.directory(id))
                    self.publish(id)
                    if PreferencesStorage.shared.isDownloadNotificationsEnabled {
                        let content = UNMutableNotificationContent()
                        content.title = "Download complete"
                        content.body = item.name
                        content.sound = .default
                        UNUserNotificationCenter.current().add(.init(identifier: item.activityID, content: content, trigger: nil))
                    }
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    self.fail(id, error.localizedDescription)
                }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        backgroundEventsFinished = true
        finishBackgroundEventsIfNeeded()
    }
    private func finishBackgroundEventsIfNeeded() {
        guard backgroundEventsFinished, pendingAssemblies == 0 else { return }
        backgroundEventsFinished = false
        let completion = backgroundCompletion
        backgroundCompletion = nil
        completion?()
    }
}

/// One FIFO queue for both engines. A multipart file consumes one transfer slot.
final class DownloadQueue {
    static let shared = DownloadQueue()
    let changed = PassthroughSubject<Void, Never>()
    private var subscriptions = Set<AnyCancellable>()
    private var requested = Set(UserDefaults.standard.stringArray(forKey: "downloadQueueRequestedTorrents") ?? [])
    private var manuallyPaused = Set<String>()
    private var running = Set<String>()
    private var pending = false
    private var applying = false
    private var lastCommands: [String: (Bool, Date)] = [:]

    private init() {
        TorrentService.shared.updateNotifier.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        TorrentService.shared.$torrents.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        FileDownloadService.shared.updates.sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        PreferencesStorage.shared.settingsUpdatePublisher.receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        Timer.publish(every: 1, on: .main, in: .common).autoconnect()
            .sink { [weak self] _ in self?.schedule() }.store(in: &subscriptions)
        schedule()
    }

    func enqueue(_ handle: TorrentHandle) {
        let key = handle.snapshot.infoHashes.best.hex
        manuallyPaused.remove(key)
        requested.insert(key)
        handle.clearError()
        save()
        schedule()
    }

    func pause(_ handle: TorrentHandle) {
        let key = handle.snapshot.infoHashes.best.hex
        manuallyPaused.insert(key)
        requested.remove(key)
        running.remove(key)
        handle.pause()
        save()
        changed.send()
        schedule()
    }

    func isQueued(_ handle: TorrentHandle) -> Bool {
        let key = handle.snapshot.infoHashes.best.hex
        return requested.contains(key) && !running.contains(key) && handle.snapshot.friendlyState != .storageError
    }

    func schedule() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pending = false
            self.apply()
        }
    }

    private func save() {
        let saved = Set(UserDefaults.standard.stringArray(forKey: "downloadQueueRequestedTorrents") ?? [])
        if saved != requested { UserDefaults.standard.set(Array(requested), forKey: "downloadQueueRequestedTorrents") }
    }

    private func apply() {
        guard !applying else { return }
        applying = true
        defer { applying = false }
        let service = TorrentService.shared
        let files = FileDownloadService.shared
        let handles = Array(service.torrents.values).filter { $0.snapshot.isValid }
        let existing = Set(handles.map { $0.snapshot.infoHashes.best.hex })
        requested.formIntersection(existing)
        for handle in handles where !handle.snapshot.isPaused && !manuallyPaused.contains(handle.snapshot.infoHashes.best.hex) {
            requested.insert(handle.snapshot.infoHashes.best.hex)
        }
        struct Entry {
            let key: String
            let date: Date
            let torrent: TorrentHandle?
            let file: UUID?
            let isSeed: Bool
        }
        var entries = handles.filter { requested.contains($0.snapshot.infoHashes.best.hex) && $0.snapshot.friendlyState != .storageError }.map {
            Entry(key: $0.snapshot.infoHashes.best.hex, date: $0.metadata.dateAdded, torrent: $0, file: nil,
                  isSeed: $0.snapshot.progress >= 1)
        }
        entries += files.downloads.filter { $0.queueEligible && $0.state != .assembling }.map {
            Entry(key: $0.activityID, date: $0.createdAt, torrent: nil, file: $0.id, isSeed: false)
        }
        entries.sort {
            if $0.isSeed != $1.isSeed { return !$0.isSeed }
            return $0.date == $1.date ? $0.key < $1.key : $0.date < $1.date
        }
        let preferences = PreferencesStorage.shared
        func limit(_ value: Int) -> Int { value <= 0 ? Int.max : value }
        var active = 0, downloading = 0, seeding = 0
        var selected = Set<String>()
        for entry in entries {
            guard active < limit(preferences.maxActiveTorrents),
                  entry.isSeed ? seeding < limit(preferences.maxUploadingTorrents) : downloading < limit(preferences.maxDownloadingTorrents)
            else { continue }
            selected.insert(entry.key)
            active += 1
            if entry.isSeed { seeding += 1 } else { downloading += 1 }
        }
        let old = running
        running = selected
        // Suspend outgoing transfers before starting replacements.
        for allowed in [false, true] {
            for entry in entries where selected.contains(entry.key) == allowed {
                if let handle = entry.torrent {
                    let needsCommand = handle.snapshot.isPaused == allowed
                    let last = lastCommands[entry.key]
                    if needsCommand && (last == nil || last!.0 != allowed || Date().timeIntervalSince(last!.1) >= 1) {
                        if allowed { handle.resume() } else { handle.pause() }
                        lastCommands[entry.key] = (allowed, Date())
                    }
                } else if let id = entry.file { files.setQueueAllowed(id, allowed) }
            }
        }
        save()
        if old != running { changed.send() }
    }
}

extension TorrentHandle {
    func resumeDownload() { DownloadQueue.shared.enqueue(self) }
    func pauseDownload() { DownloadQueue.shared.pause(self) }
}
