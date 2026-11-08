import Foundation
import Darwin

struct HistorySample: Sendable {
    let date: Date
    let freeBytes: Int64
    let totalBytes: Int64
}

struct HistoryPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var lastDate: Date
    var lastGB: Double
    var minGB: Double
    var maxGB: Double
    var samples: Int
    var totalBytes: Int64? = nil
    var freeBytes: Int64? = nil
    var sourceID: String? = nil
    var seriesID: String? = nil
}

struct HistoryResult: Sendable {
    let points: [HistoryPoint]
    let sampleCount: Int
    let skippedLines: Int
    let bucketSeconds: TimeInterval
}

/// Serializes append, streaming reads and cleanup; never executes file I/O on the UI actor.
actor HistoryStore {
    nonisolated let directory: URL
    nonisolated let consumers: ConsumerHistoryStore
    nonisolated let docker: DockerHistoryStore
    nonisolated let system: SystemHistoryStore
    nonisolated let backups: BackupEventStore
    nonisolated let space: SpaceChangeStore
    static let header = "timestamp_utc,free_bytes,total_bytes\n"
    private let formatter: ISO8601DateFormatter
    init(directory: URL = HistoryStore.defaultDirectory) {
        self.directory = directory
        consumers = ConsumerHistoryStore(directory: directory.appendingPathComponent("Consumers", isDirectory: true))
        system = SystemHistoryStore(directory: directory.appendingPathComponent("System", isDirectory: true))
        docker = DockerHistoryStore(directory: directory.appendingPathComponent("Docker", isDirectory: true))
        space = SpaceChangeStore(directory: directory.appendingPathComponent("SpaceChanges", isDirectory: true))
        backups = BackupEventStore(directory: directory.appendingPathComponent("Backups", isDirectory: true))
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskFree/History", isDirectory: true)
    }
    func append(_ snapshot: DiskSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = formatter.string(from: snapshot.refreshedAt)
        let url = directory.appendingPathComponent(String(timestamp.prefix(7)) + ".csv")
        // Atomic creation prevents an incomplete header. Later samples are append-only.
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(Self.header.utf8).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        // A interrupted write must not join a new sample to a partial old row.
        var prefix = ""
        if length > 0 {
            try handle.seek(toOffset: length - 1)
            if try handle.read(upToCount: 1)?.first != 10 { prefix = "\n" }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(prefix)\(timestamp),\(snapshot.freeBytes),\(snapshot.totalBytes)\n".utf8))
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.csv$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func sample(_ line: String) -> HistorySample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3, let date = formatter.date(from: String(fields[0])),
              let free = Int64(fields[1]), let total = Int64(fields[2]), free >= 0, total >= free else { return nil }
        return HistorySample(date: date, freeBytes: free, totalBytes: total)
    }
    /// Reads one bounded chunk at a time, rather than loading years of logs into memory.
    nonisolated static func forEachLine(in url: URL, _ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try body(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            HistoryReadContext.current?.processed(chunk.count)
            if pending.count > 65_536 {
                throw NSError(domain: "DiskFree.History", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "An oversized history row was found in \(url.lastPathComponent)."])
            }
        }
        // Only newline-terminated records are committed; a partial tail is ignored.
        if !pending.isEmpty { try body("[incomplete row]") }
    }
    /// JSON system journals have whole-second timestamps; CSV journals retain
    /// milliseconds. Share an integer-second origin so same-refresh samples
    /// cannot land on opposite sides of a fractional query-window boundary.
    nonisolated static func bucketOrigin(for start: Date) -> Date {
        Date(timeIntervalSince1970: floor(start.timeIntervalSince1970))
    }
    func load(from start: Date, through end: Date, bucketSeconds: TimeInterval) throws -> HistoryResult {
        let origin = HistoryStore.bucketOrigin(for: start)
        let width = max(60, bucketSeconds)
        var buckets: [Int: HistoryPoint] = [:]
        var count = 0
        var skipped = 0
        let firstMonth = String(formatter.string(from: start).prefix(7))
        let lastMonth = String(formatter.string(from: end).prefix(7))
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month >= firstMonth && month <= lastMonth else { continue }
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: 64, parse: { line -> ParsedHistoryLine<HistorySample>? in
                if line == Self.header.trimmingCharacters(in: .newlines) || line.isEmpty { return nil }
                return sample(line).map { .value($0) } ?? .invalid
            }) { entry in
                guard case let .value(record) = entry else { skipped += 1; return }
                guard record.date >= start && record.date <= end else { return }
                count += 1
                let index = Int(record.date.timeIntervalSince(origin) / width)
                let gb = Double(record.freeBytes) / 1_000_000_000
                if var point = buckets[index] {
                    point.minGB = min(point.minGB, gb)
                    point.maxGB = max(point.maxGB, gb)
                    point.samples += 1
                    if record.date >= point.lastDate { point.lastDate = record.date; point.lastGB = gb; point.totalBytes = record.totalBytes; point.freeBytes = record.freeBytes }
                    buckets[index] = point
                } else {
                    buckets[index] = HistoryPoint(date: origin.addingTimeInterval(Double(index) * width),
                        lastDate: record.date, lastGB: gb, minGB: gb, maxGB: gb, samples: 1, totalBytes: record.totalBytes, freeBytes: record.freeBytes)
                }
            }
        }
        return HistoryResult(points: buckets.keys.sorted().compactMap { buckets[$0] },
                             sampleCount: count, skippedLines: skipped, bucketSeconds: width)
    }
    /// Deletes full old months and rewrites the cutoff month atomically, preserving newer rows.
    /// Other files and unreadable/malformed data are never silently deleted.
    func removeSamples(olderThan cutoff: Date) async throws -> Int {
        let cutoffMonth = String(formatter.string(from: cutoff).prefix(7))
        var removed = 0
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month <= cutoffMonth else { continue }
            var retained = Data(Self.header.utf8)
            var oldCount = 0
            var unknown = false
            try Self.forEachLine(in: url) { line in
                if line == Self.header.trimmingCharacters(in: .newlines) || line.isEmpty { return }
                guard let record = sample(line) else { unknown = true; return }
                if record.date < cutoff { oldCount += 1 }
                else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !unknown else {
                throw NSError(domain: "DiskFree.History", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cleanup stopped to preserve malformed data in \(url.lastPathComponent). Earlier months may already have been cleaned."])
            }
            if oldCount > 0 {
                if retained.count == Self.header.utf8.count { try FileManager.default.removeItem(at: url) }
                else { try retained.write(to: url, options: .atomic) }
                removed += oldCount
            }
        }
        removed += try await docker.removeSamples(olderThan: cutoff)
        removed += try await consumers.removeSamples(olderThan: cutoff)
        removed += try await backups.removeSamples(olderThan: cutoff)
        removed += try await space.removeSamples(olderThan: cutoff)
        removed += try await Task.detached(priority: .utility) { try self.system.removeSamples(olderThan: cutoff) }.value
        return removed
    }
}

/// Deduplicate repeating session IDs and Docker metadata across journal rows.
/// This pool is tiny and independent of the bounded parsed-record cache.
final class JournalStrings: @unchecked Sendable {
    static let shared = JournalStrings()
    private let lock = NSLock()
    private var values: [String: String] = [:]
    func intern(_ value: String) -> String {
        lock.lock(); defer { lock.unlock() }
        if let existing = values[value] { return existing }
        if values.count >= 1024 { values.removeAll(keepingCapacity: true) }
        values[value] = value; return value
    }
}

enum ParsedHistoryLine<Value: Sendable>: Sendable {
    case value(Value), invalid
}

/// A bounded, shared cache of parsed append-only journals. Unchanged files need
/// only stat; append growth verifies the old prefix/boundary and parses the tail.
/// The lock serializes readers, and no parser or callback escapes this method.
final class ParsedHistoryJournalCache: @unchecked Sendable {
    static let shared = ParsedHistoryJournalCache()
    private struct Stamp: Equatable {
        let device: Int32, inode: UInt64, size: Int64, modified: Int64, nanoseconds: Int64, changed: Int64, changedNanoseconds: Int64
        init(_ info: stat) {
            device = info.st_dev; inode = info.st_ino; size = info.st_size
            modified = Int64(info.st_mtimespec.tv_sec); nanoseconds = Int64(info.st_mtimespec.tv_nsec)
            changed = Int64(info.st_ctimespec.tv_sec); changedNanoseconds = Int64(info.st_ctimespec.tv_nsec)
        }
    }
    private struct Entry {
        let stamp: Stamp
        let payload: Any
        let offset: Int64
        let head: Data, boundary: Data
        let partial: Bool
        let cost: Int
    }
    private let lock = NSLock()
    private let budget: Int
    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private var bytesRead: Int64 = 0
    private var decoded = 0
    init(budget: Int = 24 * 1024 * 1024) { self.budget = max(1, budget) }
    var statistics: (bytesRead: Int64, decoded: Int, retainedBytes: Int) {
        lock.lock(); defer { lock.unlock() }
        return (bytesRead, decoded, entries.values.reduce(0) { $0 + $1.cost })
    }
    func clear() { lock.lock(); entries.removeAll(); order.removeAll(); lock.unlock() }
    func forEach<Value: Sendable>(in url: URL, entryCost: Int,
        parse: (String) -> ParsedHistoryLine<Value>?, body: (ParsedHistoryLine<Value>) throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        try Task.checkCancellation()
        var info = stat()
        guard stat(url.path, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let stamp = Stamp(info), key = url.path + "|" + String(reflecting: Value.self)
        let old = entries[key]
        if let old, old.stamp == stamp, let rows = old.payload as? [ParsedHistoryLine<Value>] {
            touch(key)
            HistoryReadContext.current?.processed(Int(stamp.size))
            for (index, row) in rows.enumerated() { if index % 256 == 0 { try Task.checkCancellation() }; try body(row) }
            if old.partial { try body(.invalid) }
            return
        }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        func read(_ count: Int) throws -> Data {
            let data = try handle.read(upToCount: max(0, count)) ?? Data(); bytesRead += Int64(data.count); return data
        }
        var rows: [ParsedHistoryLine<Value>] = [], position: Int64 = 0
        if let old, stamp.device == old.stamp.device, stamp.inode == old.stamp.inode, stamp.size > old.stamp.size,
           let previous = old.payload as? [ParsedHistoryLine<Value>] {
            try handle.seek(toOffset: 0); let head = try read(old.head.count)
            try handle.seek(toOffset: UInt64(max(0, old.offset - Int64(old.boundary.count))))
            let boundary = try read(old.boundary.count)
            if head == old.head && boundary == old.boundary {
                rows = previous; position = old.offset
                HistoryReadContext.current?.processed(Int(position))
                for (index, row) in previous.enumerated() { if index % 256 == 0 { try Task.checkCancellation() }; try body(row) }
            }
        }
        try handle.seek(toOffset: UInt64(position))
        var pending = Data(), committed = position
        var cacheable = 4096 + rows.count * max(1, entryCost) <= budget
        while position < stamp.size {
            try Task.checkCancellation()
            let chunk = try read(Int(min(65536, stamp.size - position)))
            if chunk.isEmpty { break }
            position += Int64(chunk.count); pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                let line = String(decoding: pending[..<newline], as: UTF8.self)
                let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                committed += Int64(consumed)
                pending.removeSubrange(...newline)
                decoded += 1
                if let row = parse(line) {
                    try body(row)
                    if cacheable {
                        if 4096 + (rows.count + 1) * max(1, entryCost) > budget { cacheable = false; rows.removeAll(keepingCapacity: false) }
                        else { rows.append(row) }
                    }
                }
            }
            HistoryReadContext.current?.processed(chunk.count)
            if pending.count > 65536 { throw CocoaError(.fileReadCorruptFile) }
        }
        if !pending.isEmpty { try body(.invalid) }
        guard cacheable, position == stamp.size else { entries[key] = nil; order.removeAll { $0 == key }; return }
        try handle.seek(toOffset: 0); let head = try read(Int(min(256, committed)))
        try handle.seek(toOffset: UInt64(max(0, committed - 256))); let boundary = try read(Int(min(256, committed)))
        let entry = Entry(stamp: stamp, payload: rows, offset: committed, head: head, boundary: boundary,
                          partial: !pending.isEmpty, cost: 4096 + rows.count * max(1, entryCost))
        entries[key] = entry; touch(key)
        while entries.values.reduce(0, { $0 + $1.cost }) > budget || order.count > 48 {
            entries[order.removeFirst()] = nil
        }
    }
    private func touch(_ key: String) { order.removeAll { $0 == key }; order.append(key) }
}

struct HistoryLoadStatus: Sendable {
    let stage: String
    let source: Int
    let completedBytes: Int64
    let totalBytes: Int64
    var fraction: Double? { totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : nil }
    var overallFraction: Double? { fraction.map { (Double(max(1, source) - 1) + $0) / 5 } }
}

/// Per-request progress, inherited by the journal actors. Counts processed bytes,
/// not a time estimate. Subscribers can join an already-running prefetch.
final class HistoryReadContext: @unchecked Sendable {
    @TaskLocal static var current: HistoryReadContext?
    private let lock = NSLock()
    private var status = HistoryLoadStatus(stage: "Preparing history…", source: 0, completedBytes: 0, totalBytes: 0)
    private var subscribers: [UUID: @Sendable (HistoryLoadStatus) -> Void] = [:]
    private var lastEmission = Date.distantPast
    func subscribe(_ callback: @escaping @Sendable (HistoryLoadStatus) -> Void) -> UUID {
        lock.lock(); let id = UUID(); subscribers[id] = callback; let value = status; lock.unlock()
        callback(value); return id
    }
    func unsubscribe(_ id: UUID) { lock.lock(); subscribers[id] = nil; lock.unlock() }
    func stage(_ name: String, source: Int, files: [URL]) {
        let total = files.reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        lock.lock(); status = HistoryLoadStatus(stage: name, source: source, completedBytes: 0, totalBytes: total)
        let value = status, callbacks = Array(subscribers.values); lastEmission = Date(); lock.unlock()
        callbacks.forEach { $0(value) }
    }
    func processed(_ bytes: Int) {
        lock.lock()
        status = HistoryLoadStatus(stage: status.stage, source: status.source, completedBytes: status.completedBytes + Int64(bytes), totalBytes: status.totalBytes)
        guard Date().timeIntervalSince(lastEmission) >= 0.1 || status.completedBytes >= status.totalBytes else { lock.unlock(); return }
        let value = status, callbacks = Array(subscribers.values); lastEmission = Date(); lock.unlock()
        callbacks.forEach { $0(value) }
    }
    static func files(_ root: URL, suffix: String, from: Date? = nil, through: Date? = nil) -> [URL] {
        let format = ISO8601DateFormatter()
        let first = from.map { String(format.string(from: $0).prefix(7)) }, last = through.map { String(format.string(from: $0).prefix(7)) }
        return ((try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.fileSizeKey])) ?? []).filter {
            let month = $0.deletingPathExtension().lastPathComponent
            return $0.pathExtension == suffix && month.range(of: #"^\d{4}-(0[1-9]|1[0-2])$"#, options: .regularExpression) != nil
                && (first == nil || month >= first!) && (last == nil || month <= last!)
        }
    }
}

struct HistoryPageKey: Hashable, Sendable {
    let start: Date
    let end: Date
    let bucket: TimeInterval
}

/// A complete window: readers finish before any part is published to the chart.
private struct HistoryPageValues: Sendable {
    var disk: HistoryResult?
    var docker: HistoryResult?
    var backups: BackupHistoryResult?
    var system: SystemHistoryResult?
    var storage: StorageTimeline?
    var diskError: String?
    var dockerError: String?
    var backupError: String?
    var systemError: String?
    var storageError: String?
}

final class HistoryPage: Sendable {
    let key: HistoryPageKey
    private let values: HistoryPageValues
    var disk: HistoryResult? { values.disk }
    var docker: HistoryResult? { values.docker }
    var backups: BackupHistoryResult? { values.backups }
    var system: SystemHistoryResult? { values.system }
    var storage: StorageTimeline? { values.storage }
    var diskError: String? { values.diskError }
    var dockerError: String? { values.dockerError }
    var backupError: String? { values.backupError }
    var systemError: String? { values.systemError }
    var storageError: String? { values.storageError }
    init(key: HistoryPageKey) { self.key = key; self.values = HistoryPageValues() }
    private init(key: HistoryPageKey, values: HistoryPageValues) { self.key = key; self.values = values }

    /// A narrower, grid-aligned suffix can reuse every source without touching disk.
    /// Truncated event archives are reloaded instead of silently omitting evidence.
    func suffix(_ target: HistoryPageKey) -> HistoryPage? {
        let shift = target.start.timeIntervalSince(key.start) / key.bucket
        guard target.bucket == key.bucket, target.start >= key.start, target.end == key.end,
              abs(shift - shift.rounded()) < 0.000001,
              (system?.totalEvents ?? 0) <= (system?.events.count ?? 0),
              (backups?.totalCount ?? 0) <= (backups?.spans.count ?? 0),
              (storage?.events.count ?? 0) < 500 else { return nil }
        func cropped(_ result: HistoryResult?) -> HistoryResult? {
            guard let result else { return nil }
            let points = result.points.filter { $0.date >= HistoryStore.bucketOrigin(for: target.start) && $0.lastDate >= target.start && $0.lastDate <= target.end }
            return HistoryResult(points: points, sampleCount: points.reduce(0) { $0 + $1.samples }, skippedLines: result.skippedLines, bucketSeconds: result.bucketSeconds)
        }
        func included(_ event: ActivityEvent) -> Bool { event.date <= target.end && (event.end ?? event.date) >= target.start }
        var copy = values
        copy.disk = cropped(disk); copy.docker = cropped(docker)
        if let system {
            let events = system.events.filter(included)
            copy.system = SystemHistoryResult(points: system.points.filter { $0.date >= target.start && $0.record.date <= target.end }, events: events, skipped: system.skipped, totalEvents: events.count)
        }
        if let backups {
            let spans = backups.spans.filter { $0.start <= target.end && $0.bandEnd(through: target.end) >= target.start }
            copy.backups = BackupHistoryResult(spans: spans, totalCount: spans.count, skippedLines: backups.skippedLines)
        }
        if let storage {
            copy.storage = StorageTimeline(frames: storage.frames.filter { $0.date >= target.start && $0.date <= target.end }, skipped: storage.skipped, events: storage.events.filter(included))
        }
        return HistoryPage(key: target, values: copy)
    }

    // Page estimates cover aggregates; the shared parsed-journal cache has its own budget.
    var estimatedBytes: Int {
        4096 + ((disk?.points.count ?? 0) + (docker?.points.count ?? 0)) * 256
            + (system?.points.count ?? 0) * 1536
            + (system?.events.count ?? 0) * 4096
            + (storage?.frames.reduce(0) { $0 + 512 + $1.consumers.count * 768 + ($1.portions.count + $1.estimatedPortions.count) * 64 } ?? 0)
            + (storage?.events.count ?? 0) * 4096 + (backups?.spans.count ?? 0) * 16384
    }
    static func load(store: HistoryStore, key: HistoryPageKey) async throws -> HistoryPage {
        var values = HistoryPageValues()
        let reader = HistoryReadContext.current
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let context = calendar.date(byAdding: .month, value: -1, to: key.start) ?? key.start
        reader?.stage("Reading free-space history", source: 1,
            files: HistoryReadContext.files(store.directory, suffix: "csv", from: key.start, through: key.end))
        do { values.disk = try await store.load(from: key.start, through: key.end, bucketSeconds: key.bucket) }
        catch { values.diskError = "Could not read history: " + error.localizedDescription }
        try Task.checkCancellation()
        reader?.stage("Reading Docker history", source: 2,
            files: HistoryReadContext.files(store.docker.directory, suffix: "csv", from: key.start, through: key.end))
        do { values.docker = try await store.docker.load(from: key.start, through: key.end, bucketSeconds: key.bucket) }
        catch { values.dockerError = "Could not read Docker history: " + error.localizedDescription }
        try Task.checkCancellation()
        reader?.stage("Reading backup history", source: 3,
            files: HistoryReadContext.files(store.backups.directory, suffix: "csv", from: context, through: key.end)
                + HistoryReadContext.files(store.backups.directory.appendingPathComponent("TimeMachine"), suffix: "jsonl"))
        do {
            let result = try await store.backups.load(from: key.start, through: key.end)
            values.backups = result
            if result.skippedLines > 0 { values.backupError = "Some saved observations were unreadable." }
        } catch { values.backupError = error.localizedDescription }
        try Task.checkCancellation()
        reader?.stage("Reading system history", source: 4,
            files: HistoryReadContext.files(store.system.directory, suffix: "jsonl", from: context, through: key.end))
        do {
            let result = try store.system.load(from: key.start, through: key.end, bucketSeconds: key.bucket,
                limit: key.end.timeIntervalSince(key.start) <= 86400 ? 8192 : 500)
            values.system = result
            if result.skipped > 0 { values.systemError = "Some system records were unreadable." }
        } catch { values.systemError = error.localizedDescription }
        try Task.checkCancellation()
        var storageFiles: [URL] = []
        if let first = values.disk?.points.first, let last = values.disk?.points.last {
            storageFiles = HistoryReadContext.files(store.consumers.directory, suffix: "jsonl", from: first.lastDate.addingTimeInterval(-172800), through: last.lastDate)
        }
        reader?.stage(storageFiles.isEmpty ? "Preparing composition…" : "Reading folder history", source: 5, files: storageFiles)
        do {
            if storageFiles.isEmpty {
                // No folder journal is a normal first-run case; native disk/swap/Docker
                // history still supplies a complete chart without an empty actor read.
                var frames: [StorageFrame] = [], nativeIndex = 0
                let points = values.disk?.points ?? [], system = values.system?.points ?? []
                var native: SystemRecord?, segment = 0, previous: Date?
                for point in points {
                    while nativeIndex < system.count && system[nativeIndex].record.date <= point.lastDate {
                        native = system[nativeIndex].record; nativeIndex += 1
                    }
                    var current = native
                    if let record = current, point.lastDate.timeIntervalSince(record.date) > Double(record.interval ?? 60) * 2.5 { current = nil }
                    if let previous, point.lastDate.timeIntervalSince(previous) > max(key.bucket * 1.5, Double(current?.interval ?? 60) * 2.5) { segment += 1 }
                    previous = point.lastDate
                    if let total = point.totalBytes, let free = point.freeBytes {
                        frames.append(StorageFrame.make(date: point.lastDate, total: total, free: free, measurements: [], native: current, segment: segment))
                    }
                }
                values.storage = StorageTimeline(frames: frames, skipped: 0, events: [])
            } else {
                values.storage = try await store.consumers.timeline(points: values.disk?.points ?? [], system: values.system?.points ?? [], bucket: key.bucket)
            }
            if (values.storage?.skipped ?? 0) > 0 { values.storageError = "Some category records were unreadable." }
        } catch {
            values.storage = StorageTimeline(frames: (values.disk?.points ?? []).compactMap { point in
                guard let total = point.totalBytes, let free = point.freeBytes else { return nil }
                return StorageFrame.make(date: point.lastDate, total: total, free: free, measurements: [], native: nil)
            }, skipped: 0, events: [])
            values.storageError = "Category history unavailable. " + error.localizedDescription
        }
        try Task.checkCancellation()
        return HistoryPage(key: key, values: values)
    }
}

/// App-session bounded LRU. Duplicate requests share one read; no timer or disk writes.
actor HistoryPageCache {
    private let capacity: Int
    private let estimatedBudget: Int
    private var readers: [HistoryPageKey: HistoryReadContext] = [:]
    private let loader: @Sendable (HistoryPageKey) async throws -> HistoryPage
    private var pages: [HistoryPageKey: HistoryPage] = [:]
    private var order: [HistoryPageKey] = []
    private var pending: [HistoryPageKey: Task<HistoryPage, Error>] = [:]
    private var generation = 0
    init(store: HistoryStore, capacity: Int = 12, estimatedBudget: Int = 24 * 1024 * 1024) {
        self.capacity = max(1, capacity); self.estimatedBudget = max(1, estimatedBudget)
        self.loader = { try await HistoryPage.load(store: store, key: $0) }
    }
    init(capacity: Int, estimatedBudget: Int = 24 * 1024 * 1024, loader: @escaping @Sendable (HistoryPageKey) async throws -> HistoryPage) {
        self.capacity = max(1, capacity); self.estimatedBudget = max(1, estimatedBudget); self.loader = loader
    }
    func cancelPending() {
        generation += 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll(); readers.removeAll()
    }
    func clear(reloadJournals: Bool = false) async {
        cancelPending(); pages.removeAll(); order.removeAll()
        if reloadJournals { await Task.detached(priority: .utility) { ParsedHistoryJournalCache.shared.clear() }.value }
    }
    func page(_ key: HistoryPageKey, progress: (@Sendable (HistoryLoadStatus) -> Void)? = nil) async throws -> HistoryPage {
        try Task.checkCancellation()
        if let page = reusable(key) { return page }
        // Bound I/O even if the user clicks through many windows before reads finish.
        while pending[key] == nil && pending.count >= 3 {
            if let (waitingKey, task) = pending.first {
                let epoch = generation
                let loaded = try? await task.value
                if generation == epoch {
                    pending.removeValue(forKey: waitingKey); readers[waitingKey] = nil
                    if let loaded { remember(loaded, for: waitingKey) }
                }
            }
            try Task.checkCancellation()
        }
        if let page = reusable(key) { return page }
        let epoch = generation
        let task: Task<HistoryPage, Error>
        if let existing = pending[key] { task = existing }
        else {
            let read = loader
            let reader = HistoryReadContext(); readers[key] = reader
            task = Task.detached(priority: .utility) {
                try await HistoryReadContext.$current.withValue(reader) { try await read(key) }
            }
            pending[key] = task
        }
        let reader = readers[key]
        let subscription = progress.flatMap { reader?.subscribe($0) }
        defer { if let subscription { reader?.unsubscribe(subscription) } }
        do {
            let page = try await task.value
            guard generation == epoch else { throw CancellationError() }
            pending.removeValue(forKey: key); readers[key] = nil
            remember(page, for: key)
            try Task.checkCancellation()
            return page
        } catch {
            if generation == epoch { pending.removeValue(forKey: key); readers[key] = nil }
            throw error
        }
    }
    private func reusable(_ key: HistoryPageKey) -> HistoryPage? {
        if let page = pages[key] { touch(key); return page }
        for parent in order.reversed() {
            if let page = pages[parent]?.suffix(key) { touch(parent); return page }
        }
        return nil
    }
    private func remember(_ page: HistoryPage, for key: HistoryPageKey) {
        // Stable malformed-row notices do not make the successfully read data
        // uncacheable. Actual I/O failures still retry on the next request.
        guard page.diskError == nil, page.dockerError == nil,
              page.backupError == nil || (page.backups?.skippedLines ?? 0) > 0,
              page.systemError == nil || (page.system?.skipped ?? 0) > 0,
              page.storageError == nil || (page.storage?.skipped ?? 0) > 0,
              page.estimatedBytes <= estimatedBudget else { return }
        pages[key] = page; touch(key)
        while order.count > capacity || pages.values.reduce(0, { $0 + $1.estimatedBytes }) > estimatedBudget {
            pages.removeValue(forKey: order.removeFirst())
        }
    }
    private func touch(_ key: HistoryPageKey) { order.removeAll { $0 == key }; order.append(key) }
}
