import Foundation
import CoreServices
import Darwin

/// Metadata only: lstat neither follows symlinks nor reads/hydrates file contents.
struct SuspectFileSample: Codable, Sendable {
    let path: String
    let date: Date
    let identity: String
    let logical: Int64
    let allocated: Int64
    let created: Date
    let modified: Date
    static var startupDevice: dev_t? {
        var info = stat()
        let path = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
        return stat(path, &info) == 0 ? info.st_dev : nil
    }
    static func read(_ path: String, device: dev_t, at date: Date = Date()) -> SuspectFileSample? {
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_dev == device else { return nil }
        return SuspectFileSample(path: path, date: date, identity: "\(info.st_dev):\(info.st_ino)",
            logical: max(0, info.st_size), allocated: max(0, Int64(info.st_blocks) * 512),
            created: Date(timeIntervalSince1970: Double(info.st_birthtimespec.tv_sec) + Double(info.st_birthtimespec.tv_nsec) / 1e9),
            modified: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9))
    }
}
struct SuspectFileObservation: Sendable {
    let path: String
    let date: Date
    let flags: UInt32
    let eventID: UInt64
    let before: SuspectFileSample?
    let after: SuspectFileSample?
}
struct SuspectFile: Codable, Sendable, Identifiable {
    var id: String { path }
    let path: String
    let kind: String
    let allocated: Int64
    let delta: Int64?
    let logical: Int64
    let observedAt: Date
    let source: String
    let eventID: UInt64?
    let flags: UInt32?
    let before: SuspectFileSample?
    let after: SuspectFileSample?
    var summary: String {
        switch kind {
        case "Grew": return "Grew " + CapacityFormat.string(delta ?? 0)
        case "Shrank": return "Shrank " + CapacityFormat.string(abs(delta ?? 0))
        case "Removed": return "Removed · " + CapacityFormat.string(allocated) + " last observed"
        default: return kind + " · " + CapacityFormat.string(allocated) + (source == "Spotlight" ? " now" : " allocated")
        }
    }
}
struct FileFindings: Codable, Sendable {
    let checkedAt: Date
    let files: [SuspectFile]
    let spotlight: String
    let tracking: String
    let trackingSince: Date?
    func preserving(_ previous: FileFindings?) -> FileFindings {
        // A later index query must not erase a saved observation of a now-deleted file.
        var byPath = Dictionary(uniqueKeysWithValues: (previous?.files ?? []).map { ($0.path, $0) })
        for file in files {
            if byPath[file.path]?.source == "FSEvents", file.source == "Spotlight" { continue }
            byPath[file.path] = file
        }
        let merged = byPath.values.sorted { ($0.delta.map(abs) ?? $0.allocated) > ($1.delta.map(abs) ?? $1.allocated) }
        return FileFindings(checkedAt: checkedAt, files: Array(merged.prefix(8)), spotlight: spotlight, tracking: tracking, trackingSince: trackingSince)
    }
}

/// One home-folder stream, coalesced at 3 seconds, drained at most once per 10 seconds.
/// All state and lstat work stay on a utility queue. No enumeration or rescan on overflow.
final class FileChangeTracker: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.diskfree.file-clues", qos: .utility)
    private let key = DispatchSpecificKey<Bool>()
    private let root: String
    private let minimum: Int64
    private var device: dev_t = 0
    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?
    private var started: Date?
    private var limitedAt: Date?
    private var unavailable = false
    private var pending: [String: (UInt32, UInt64, Date)] = [:]
    private var previous: [String: SuspectFileSample] = [:]
    private var observations: [SuspectFileObservation] = []
    init(root: String = FileManager.default.homeDirectoryForCurrentUser.path, minimum: Int64 = 100_000_000) {
        self.root = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path; self.minimum = minimum
        queue.setSpecific(key: key, value: true)
    }
    func start() { queue.async { self.startOnQueue() } }
    private func startOnQueue() {
        guard started == nil else { return }
        started = Date()
        var info = stat()
        guard stat(root, &info) == 0, info.st_dev == SuspectFileSample.startupDevice else { unavailable = true; return }
        device = info.st_dev
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, context, count, paths, flags, ids in
            guard let context else { return }
            let tracker = Unmanaged<FileChangeTracker>.fromOpaque(context).takeUnretainedValue()
            let values = unsafeBitCast(paths, to: NSArray.self)
            let now = Date()
            // The OS batch itself is not retained; even a build storm has bounded app work.
            for index in 0..<min(count, 512) {
                if let path = values[index] as? String { tracker.receive(path, flags: flags[index], id: ids[index], at: now) }
            }
            if count > 512 { tracker.limitedAt = now }
        }
        let options = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(nil, callback, &context, [root] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 3, options) else { unavailable = true; return }
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); unavailable = true; return }
        self.stream = stream
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 10, repeating: 10, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in self?.drain() }
        self.timer = timer; timer.resume()
    }
    private func receive(_ path: String, flags: UInt32, id: UInt64, at date: Date) {
        let lost = UInt32(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged)
        if flags & lost != 0 { limitedAt = date; previous.removeAll(); pending.removeAll(); return }
        guard flags & UInt32(kFSEventStreamEventFlagItemIsFile) != 0,
              path.hasPrefix(root + "/"), path.utf8.count <= 4096 else { return }
        if pending[path] == nil && pending.count >= 256 { limitedAt = date; return }
        let old = pending[path]
        pending[path] = ((old?.0 ?? 0) | flags, id, date)
    }
    private func drain() {
        let batch = pending.sorted { $0.value.2 < $1.value.2 }.prefix(128)
        for (path, event) in batch {
            pending[path] = nil
            let old = previous[path], sample = SuspectFileSample.read(path, device: device)
            guard max(old?.allocated ?? 0, sample?.allocated ?? 0) >= minimum else { previous[path] = nil; continue }
            observations.append(SuspectFileObservation(path: path, date: event.2, flags: event.0, eventID: event.1, before: old, after: sample))
            previous[path] = sample
        }
        let cutoff = Date().addingTimeInterval(-1800)
        observations = Array(observations.filter { $0.date >= cutoff }.suffix(512))
        if previous.count > 512 {
            let keep = Set(previous.values.sorted { $0.date > $1.date }.prefix(512).map(\.path))
            previous = previous.filter { keep.contains($0.key) }; limitedAt = Date()
        }
    }
    func snapshot() async -> (events: [SuspectFileObservation], since: Date?, limited: Date?, unavailable: Bool) {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: (self.observations, self.started, self.limitedAt, self.unavailable)) }
        }
    }
    private func stopOnQueue() {
        timer?.cancel(); timer = nil
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil }
    }
    deinit {
        if DispatchQueue.getSpecific(key: key) == true { stopOnQueue() }
        else { queue.sync { stopOnQueue() } }
    }
    func stop() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.stopOnQueue()
                continuation.resume()
            }
        }
    }
}

struct IndexedFileResult: Sendable { let paths: [String]; let status: String }
@MainActor private final class MilestoneSpotlight {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timeout: Task<Void, Never>?
    private var continuation: CheckedContinuation<IndexedFileResult, Never>?
    func search(from: Date, through: Date, root: String) async -> IndexedFileResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let query = NSMetadataQuery()
            query.searchScopes = [root]
            query.predicate = NSPredicate(format: "kMDItemFSSize >= %lld AND ((kMDItemFSCreationDate >= %@ AND kMDItemFSCreationDate <= %@) OR (kMDItemFSContentChangeDate >= %@ AND kMDItemFSContentChangeDate <= %@))", Int64(100_000_000), from as NSDate, through as NSDate, from as NSDate, through as NSDate)
            query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSSize", ascending: false)]
            self.query = query
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(timedOut: false) }
            }
            timeout = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                guard !Task.isCancelled else { return }
                self?.finish(timedOut: true)
            }
            if !query.start() { finish(timedOut: true) }
        }
    }
    private func finish(timedOut: Bool) {
        guard let query, let continuation else { return }
        query.disableUpdates()
        let paths = (0..<min(query.resultCount, 80)).compactMap { index in
            (query.result(at: index) as? NSMetadataItem)?.value(forAttribute: "kMDItemPath") as? String
        }
        query.stop(); self.query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timeout?.cancel(); timeout = nil; self.continuation = nil
        continuation.resume(returning: IndexedFileResult(paths: paths, status: timedOut ? "Spotlight check incomplete" : "Spotlight checked"))
    }
}

enum FileSuspectMatcher {
    static let minimum: Int64 = 100_000_000
    static func match(change: SpaceChange, events: [SuspectFileObservation], indexed: [SuspectFileSample]) -> [SuspectFile] {
        let start = change.before.date.addingTimeInterval(-15), end = change.after.date.addingTimeInterval(20)
        func near(_ date: Date) -> Bool { date >= start && date <= end }
        var candidates: [String: SuspectFile] = [:]
        // Combine multiple observations of a path over the milestone, preserving a real prior size.
        for (path, values) in Dictionary(grouping: events.filter { near($0.date) }, by: \.path) {
            let rows = values.sorted { $0.date < $1.date }
            guard let last = rows.last, let first = rows.first else { continue }
            let old = first.before, new = last.after
            var kind = "Changed", delta: Int64?
            if let old, let new, old.identity == new.identity, old.date <= end, old.date >= start.addingTimeInterval(-1800) {
                let difference = new.allocated - old.allocated
                if abs(difference) >= minimum {
                    delta = difference; kind = difference > 0 ? "Grew" : "Shrank"
                }
            } else if new == nil, let old, last.flags & UInt32(kFSEventStreamEventFlagItemRemoved) != 0,
                      last.flags & UInt32(kFSEventStreamEventFlagItemRenamed) == 0 {
                kind = "Removed"; delta = -old.allocated
            } else if let new, near(new.created) { kind = "Created" }
            guard let size = new ?? old, size.allocated >= minimum || abs(delta ?? 0) >= minimum else { continue }
            if change.bytes < 0 {
                guard kind == "Created" || kind == "Changed" || (delta ?? 0) >= minimum else { continue }
            } else {
                guard kind == "Removed" || (delta ?? 0) <= -minimum else { continue }
            }
            candidates[path] = SuspectFile(path: path, kind: kind, allocated: size.allocated, delta: delta, logical: size.logical,
                observedAt: last.date, source: "FSEvents", eventID: last.eventID, flags: last.flags, before: old, after: new)
        }
        if change.bytes < 0 {
            for sample in indexed where candidates[sample.path] == nil && sample.allocated >= minimum && (near(sample.created) || near(sample.modified)) {
                candidates[sample.path] = SuspectFile(path: sample.path, kind: near(sample.created) ? "Created" : "Changed", allocated: sample.allocated, delta: nil,
                    logical: sample.logical, observedAt: sample.date, source: "Spotlight", eventID: nil, flags: nil, before: nil, after: sample)
            }
        }
        return Array(candidates.values.sorted {
            func score(_ file: SuspectFile) -> Int64 { file.delta.map(abs) ?? (file.kind == "Created" ? file.allocated : 0) }
            let lhs = score($0), rhs = score($1)
            return lhs == rhs ? ($0.allocated == $1.allocated ? $0.path < $1.path : $0.allocated > $1.allocated) : lhs > rhs
        }.prefix(8))
    }
}

actor FileEvidenceCollector {
    static let shared = FileEvidenceCollector()
    private let tracker = FileChangeTracker()
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func start() { tracker.start() }
    func collect(_ change: SpaceChange) async -> FileFindings {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        let indexed: IndexedFileResult
        if change.bytes < 0 {
            indexed = await MilestoneSpotlight().search(from: change.before.date.addingTimeInterval(-15), through: change.after.date.addingTimeInterval(20), root: root)
        } else { indexed = IndexedFileResult(paths: [], status: "Spotlight cannot find removed files") }
        let observation = await tracker.snapshot()
        let files = await Task.detached(priority: .utility) {
            var info = stat()
            guard stat(root, &info) == 0, info.st_dev == SuspectFileSample.startupDevice else { return [SuspectFile]() }
            let samples = indexed.paths.filter { $0.hasPrefix(root + "/") }.compactMap { SuspectFileSample.read($0, device: info.st_dev) }
            return FileSuspectMatcher.match(change: change, events: observation.events, indexed: samples)
        }.value
        let status = observation.unavailable ? "File tracking unavailable" : observation.since == nil || observation.since! > change.before.date ? "Tracking began after this interval" : observation.limited.map { $0 >= change.before.date.addingTimeInterval(-1800) } == true ? "File tracking limited during busy activity" : "Changed-file tracking checked"
        return FileFindings(checkedAt: Date(), files: files, spotlight: indexed.status, tracking: status, trackingSince: observation.since)
    }
}
