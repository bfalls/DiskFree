import Foundation

struct SpaceChange: Codable, Sendable, Identifiable {
    var id: String { before.id }
    let before: SystemRecord
    let after: SystemRecord
    var bytes: Int64 { (after.free ?? 0) - (before.free ?? 0) }
    var title: String { (bytes > 0 ? "Freed " : "Used ") + CapacityFormat.string(abs(bytes)) }
    var event: ActivityEvent {
        ActivityEvent(id: id + "space", date: before.date, end: after.date, category: .space,
            title: title, detail: ActivityEvent.timeRange(from: before.date, through: after.date),
            records: [before, after], spaceChange: self)
    }
    var valid: Bool { before.valid() && after.valid() && before.kind == .sample && after.kind == .sample && before.free != nil && after.free != nil && after.date > before.date && after.date.timeIntervalSince(before.date) <= 300 && before.runID == after.runID && before.boot == after.boot && abs(bytes) >= SpaceChangeDetector.threshold }
}
/// Streaming, constant-memory detector. A burst ends after 90 quiet seconds, a reversal,
/// five minutes, or lost coverage. Tiny counter jitter does not split a burst.
struct SpaceChangeDetector: Sendable {
    static let threshold: Int64 = 5_000_000_000
    private var previous: SystemRecord?
    private var burst: SpaceChange?
    mutating func finish() -> SpaceChange? {
        defer { burst = nil }
        return burst.flatMap { $0.valid ? $0 : nil }
    }
    mutating func consume(_ row: SystemRecord) -> [SpaceChange] {
        var result: [SpaceChange] = []
        func keep(_ change: SpaceChange?) { if let change { result.append(change) } }
        guard row.kind == .sample, row.free != nil, row.valid() else {
            keep(finish()); previous = nil; return result
        }
        defer { previous = row }
        guard let old = previous, old.runID == row.runID, old.boot == row.boot,
              row.date > old.date, row.date.timeIntervalSince(old.date) <= min(300, Double(max(row.interval ?? 60, old.interval ?? 60)) * 2.5) else {
            keep(finish()); return result
        }
        if let burst, row.date.timeIntervalSince(burst.before.date) > 300 || row.date.timeIntervalSince(burst.after.date) > 90 { keep(finish()) }
        let step = row.free! - old.free!
        guard abs(step) >= 250_000_000 else { return result }
        if let burst, (burst.bytes > 0) != (step > 0) { keep(finish()) }
        burst = SpaceChange(before: burst?.before ?? old, after: row)
        return result
    }
}
struct SpaceAction: Codable, Sendable {
    enum Kind: String, Codable, Sendable { case snapshot, purge }
    let date: Date
    let kind: Kind
    let subject: String
    let process: String
    let subsystem: String
    let message: String
    var bytes: Int64? = nil
}
enum SpaceActionParser {
    static func decode(_ text: String, from start: Date, through end: Date) -> [SpaceAction] {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"
        var actions: [SpaceAction] = [], snapshots: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["eventMessage"] as? String, message.utf8.count <= 16384,
                  let stamp = object["timestamp"] as? String, let date = format.date(from: stamp), date >= start, date <= end else { continue }
            let subsystem = object["subsystem"] as? String ?? ""
            let process = ((object["processImagePath"] as? String ?? "") as NSString).lastPathComponent
            // Destination-drive pruning is not evidence of space reclaimed on the startup disk.
            if subsystem == "com.apple.TimeMachine", object["category"] as? String == "LocalThinning",
               BackupLogParser.groups(#"on disk '/System/Volumes/Data(?:'|$)"#, message) != nil,
               let name = BackupLogParser.groups(#"^(?:Age-based |Space-based )?[Tt]hinning deleted Time Machine snapshot '([^']+)'"#, message)?.first,
               snapshots.insert(name).inserted {
                actions.append(SpaceAction(date: date, kind: .snapshot, subject: name, process: "backupd", subsystem: subsystem, message: message))
            } else if ["deleted", "deleted_helper", "bird", "fileproviderd", "softwareupdated", "installd"].contains(process),
                      let fields = BackupLogParser.groups(#"(?i)^(purged|evicted|reclaimed) ([0-9]+) bytes\b"#, message), let bytes = Int64(fields[1]), bytes > 0,
                      message.contains("/System/Volumes/Data") {
                actions.append(SpaceAction(date: date, kind: .purge, subject: process, process: process, subsystem: subsystem, message: message, bytes: bytes))
            }
            if actions.count == 100 { break }
        }
        return actions.sorted { $0.date < $1.date }
    }
}
struct SpaceFolderChange: Codable, Sendable {
    let name: String
    let before: ConsumerMeasurement
    let after: ConsumerMeasurement
    var delta: Int64 { after.bytes - before.bytes }
    static func matching(_ rows: [ConsumerMeasurement], change: SpaceChange) -> [SpaceFolderChange] {
        Dictionary(grouping: rows.filter { $0.valid() && $0.active }, by: \.folderID).values.compactMap { values in
            let sorted = values.sorted { $0.measuredAt < $1.measuredAt }
            guard let first = sorted.last(where: { $0.measuredAt <= change.before.date && change.before.date.timeIntervalSince($0.measuredAt) <= 1800 }),
                  let last = sorted.first(where: { $0.measuredAt >= change.after.date && $0.measuredAt.timeIntervalSince(change.after.date) <= 1800 }),
                  first.measuredAt < last.measuredAt, first.root == last.root, first.coverage == last.coverage,
                  first.exclusions == last.exclusions, first.skipped == last.skipped,
                  let identity = first.identity, identity == last.identity, abs(last.bytes - first.bytes) >= 500_000_000 else { return nil }
            return SpaceFolderChange(name: last.name, before: first, after: last)
        }.sorted { abs($0.delta) > abs($1.delta) }.prefix(8).map { $0 }
    }
}
struct SpaceChangeReport: Codable, Sendable {
    let change: SpaceChange
    let checkedAt: Date
    let actions: [SpaceAction]
    let folders: [SpaceFolderChange]
    let logStatus: String
    var fileFindings: FileFindings? = nil
    var headline: String {
        let count = actions.filter { $0.kind == .snapshot }.count
        if count > 0 { return "Time Machine removed \(count) local restore point\(count == 1 ? "" : "s")" }
        if !actions.isEmpty { return "macOS recorded storage reclamation" }
        let swap = (change.after.allocated ?? 0) - (change.before.allocated ?? 0)
        if change.before.allocated != nil && change.after.allocated != nil && abs(Double(swap) + Double(change.bytes)) <= Double(max(1_000_000_000, abs(change.bytes) / 10)) { return "Swap change matches the space change" }
        if let delta = dockerDelta, abs(Double(delta) + Double(change.bytes)) <= Double(max(1_000_000_000, abs(change.bytes) / 10)) { return "Docker image change matches the space change" }
        if let folder = folders.first(where: { ($0.delta > 0) != (change.bytes > 0) }) { return "Nearby change in " + folder.name }
        if let file = fileFindings?.files.first, file.kind == "Created" || file.delta != nil {
            return "Possible contributor: " + URL(fileURLWithPath: file.path).lastPathComponent
        }
        return "Cause not established"
    }
    var logsUnavailable: Bool { ["Local logs unavailable", "Log check reached its limit"].contains(logStatus) }
    var dockerDelta: Int64? {
        guard let source = change.before.dockerSource, source == change.after.dockerSource,
              let first = change.before.docker, let last = change.after.docker else { return nil }
        return last - first
    }
    var measurements: [(String, String)] {
        func pair(_ a: Int64, _ b: Int64) -> String { CapacityFormat.string(a) + " → " + CapacityFormat.string(b) }
        var rows: [(String, String)] = []
        if let first = change.before.free, let last = change.after.free { rows.append(("Free space", pair(first, last))) }
        if let first = change.before.allocated, let last = change.after.allocated { rows.append(("Swap allocated", pair(first, last))) }
        if let delta = dockerDelta, let first = change.before.docker, let last = change.after.docker { rows.append(("Docker allocated", delta == 0 ? CapacityFormat.string(last) + " · unchanged" : pair(first, last))) }
        return rows
    }
}

private actor SpaceLogGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

actor SpaceChangeStore {
    typealias Query = @Sendable (Date, Date) throws -> String
    nonisolated let directory: URL
    private let query: Query
    private let fileQuery: @Sendable (SpaceChange) async -> FileFindings
    private let gate = SpaceLogGate()
    private var pending: [String: Task<SpaceChangeReport, Error>] = [:]
    init(directory: URL, query: @escaping Query = { start, end in
        let snapshotPredicate = #"process == "backupd" AND subsystem == "com.apple.TimeMachine" AND category == "LocalThinning" AND eventMessage CONTAINS "deleted Time Machine snapshot""#
        let snapshots = try BackupLogReader.output(from: start, through: end, predicate: snapshotPredicate, cap: 524288)
        if !SpaceActionParser.decode(snapshots, from: start, through: end).isEmpty { return snapshots }
        var failure: Error?
        // Keep each lookup process-specific so macOS can use its process index.
        for process in ["deleted", "deleted_helper"] {
            let predicate = "process == \"" + process + "\" AND (eventMessage BEGINSWITH[c] \"Purged \" OR eventMessage BEGINSWITH[c] \"Evicted \" OR eventMessage BEGINSWITH[c] \"Reclaimed \")"
            do {
                let text = try BackupLogReader.output(from: start, through: end, predicate: predicate, cap: 524288)
                if !SpaceActionParser.decode(text, from: start, through: end).isEmpty { return text }
            } catch { failure = error }
        }
        if let failure { throw failure }
        return ""
    }, fileQuery: @escaping @Sendable (SpaceChange) async -> FileFindings = { await FileEvidenceCollector.shared.collect($0) }) {
        self.directory = directory; self.query = query; self.fileQuery = fileQuery
    }
    nonisolated func source(for change: SpaceChange) -> URL {
        let f = ISO8601DateFormatter()
        return directory.appendingPathComponent(String(f.string(from: change.before.date).prefix(7))).appendingPathComponent(change.id + ".json")
    }
    nonisolated func cached(_ change: SpaceChange) -> SpaceChangeReport? {
        guard change.valid, let data = try? Data(contentsOf: source(for: change)),
              let report = try? JSONDecoder().decode(SpaceChangeReport.self, from: data), report.change.valid,
              report.change.before.id == change.before.id, report.change.after.id == change.after.id else { return nil }
        return report
    }
    func investigate(_ change: SpaceChange, consumers: ConsumerHistoryStore, retry: Bool = false, retryFiles: Bool = false) async throws -> SpaceChangeReport {
        guard change.valid else { throw CocoaError(.fileReadCorruptFile) }
        let existing = cached(change)
        let reuse = existing != nil && (!retry || Date().timeIntervalSince(existing!.checkedAt) < 60)
        let savedFiles = existing?.fileFindings
        let reuseFiles = savedFiles != nil && (!(retry || retryFiles) || Date().timeIntervalSince(savedFiles!.checkedAt) < 60)
        let key = change.id + change.after.id
        if let task = pending[key] { return try await task.value }
        guard pending.count < 24 else { throw BackupLogQueryError.workLimit }
        let query = self.query, fileQuery = self.fileQuery, gate = self.gate
        let task = Task.detached(priority: .utility) { () throws -> SpaceChangeReport in
            let start = change.before.date.addingTimeInterval(-30), finish = change.after.date.addingTimeInterval(1)
            let findings: FileFindings
            if reuseFiles, let savedFiles { findings = savedFiles }
            else { findings = await fileQuery(change).preserving(existing?.fileFindings) }
            var status = "Checked local logs", actions: [SpaceAction] = []
            // Native counters can explain a pure swap/image change without a log query.
            let empty = SpaceChangeReport(change: change, checkedAt: Date(), actions: [], folders: [], logStatus: "Native measurements")
            if reuse, let existing {
                status = existing.logStatus; actions = existing.actions
            } else if empty.headline == "Cause not established" {
                do {
                    await gate.acquire()
                    let result = Result { try query(start, finish) }
                    await gate.release()
                    actions = SpaceActionParser.decode(try result.get(), from: start, through: finish)
                } catch BackupLogQueryError.workLimit { status = "Log check reached its limit" }
                catch { status = "Local logs unavailable" }
            } else { status = "Native measurements" }
            let rows = (try? await consumers.nearbyMeasurements(from: change.before.date.addingTimeInterval(-1800), through: change.after.date.addingTimeInterval(1800))) ?? []
            return SpaceChangeReport(change: change, checkedAt: reuse ? existing!.checkedAt : Date(), actions: actions,
                folders: SpaceFolderChange.matching(rows, change: change), logStatus: status, fileFindings: findings)
        }
        pending[key] = task
        defer { pending[key] = nil }
        let report = try await task.value
        let url = source(for: change)
        if let data = try? Data(contentsOf: url), let newer = try? JSONDecoder().decode(SpaceChangeReport.self, from: data), newer.change.after.date > change.after.date { return report }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        return report
    }
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        guard FileManager.default.fileExists(atPath: directory.path) else { return 0 }
        var removed = 0
        for month in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where month.lastPathComponent.range(of: #"^\d{4}-\d{2}$"#, options: .regularExpression) != nil {
            for file in try FileManager.default.contentsOfDirectory(at: month, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let report = try JSONDecoder().decode(SpaceChangeReport.self, from: Data(contentsOf: file))
                guard report.change.valid else { throw CocoaError(.fileReadCorruptFile) }
                if report.change.after.date < cutoff { try FileManager.default.removeItem(at: file); removed += 1 }
            }
        }
        return removed
    }
}

@MainActor final class SpaceChangeMonitor {
    var onChanged: (() -> Void)?
    private var detector = SpaceChangeDetector()
    private var queue: [SpaceChange] = []
    private var worker: Task<Void, Never>?
    private var startup: Task<Void, Never>?
    private let store: HistoryStore
    private let enabled: Bool
    init(store: HistoryStore, enabled: Bool) {
        self.store = store; self.enabled = enabled
        guard enabled else { return }
        Task { await FileEvidenceCollector.shared.start() }
        startup = Task { [weak self] in
            let system = store.system, now = Date()
            let events = try? await Task.detached(priority: .utility) { try system.load(from: now.addingTimeInterval(-7 * 86400), through: now, bucketSeconds: 3600).events }.value
            guard let self, !Task.isCancelled else { return }
            // Latest twelve events automatically; other historical reports are collected on click.
            for change in (events ?? []).compactMap(\.spaceChange).suffix(12) { self.enqueue(change) }
        }
    }
    func observe(_ row: SystemRecord) { guard enabled else { return }; for change in detector.consume(row) { enqueue(change) } }
    private func enqueue(_ change: SpaceChange) {
        guard store.space.cached(change) == nil, !queue.contains(where: { $0.id == change.id }), queue.count < 24 else { return }
        queue.append(change)
        guard worker == nil else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !self.queue.isEmpty && !Task.isCancelled {
                let change = self.queue.removeFirst()
                if (try? await self.store.space.investigate(change, consumers: self.store.consumers)) != nil { self.onChanged?() }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            self.worker = nil
        }
    }
    deinit { worker?.cancel(); startup?.cancel() }
}
