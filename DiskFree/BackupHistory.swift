import Foundation
import Combine
import Darwin

enum BackupObservationState: String, Sendable { case running, idle, unknown }
struct BackupObservation: Sendable {
    let date: Date
    let runID: String
    let state: BackupObservationState
    var previousIdle: Date? = nil
    var freeBytes: Int64? = nil
    var dockerBytes: Int64? = nil
    var dockerSource: String? = nil
}
enum BackupSpanEnding: Sendable, Equatable { case running, stopped, gap }
enum BackupHoverPart: Sendable, Equatable { case start, stop, span }
struct BackupSpan: Identifiable, Sendable {
    var id: String { verified?.id ?? runID + "-" + String(start.timeIntervalSince1970) }
    let runID: String
    let start: Date
    let previousIdle: Date?
    var lastRunning: Date
    var end: Date?
    var ending: BackupSpanEnding = .running
    let startFree: Int64?
    var lastFree: Int64?
    let startDocker: Int64?
    var lastDocker: Int64?
    let startDockerSource: String?
    var lastDockerSource: String?
    var observations = 1
    var verified: BackupSession? = nil
    var observedEnd: Date { end ?? lastRunning }
    func bandEnd(through date: Date) -> Date { min(date, end ?? min(date, lastRunning.addingTimeInterval(BackupEventStore.maximumGap))) }
    func detail(part: BackupHoverPart) -> String {
        if let verified { return verified.facts.map { $0.0 + ": " + $0.1 }.joined(separator: "\n") }
        let stamp: (Date) -> String = { $0.formatted(date: .abbreviated, time: .standard) }
        var lines = ["Observed: " + stamp(start) + " → " + observedEnd.formatted(date: .omitted, time: .standard)]
        switch ending {
        case .running: lines.append("Running at last check")
        case .stopped: lines.append("Stopped · result not verified")
        case .gap: lines.append("Recording interrupted")
        }
        func change(_ bytes: Int64) -> String { (bytes >= 0 ? "+" : "−") + CapacityFormat.string(abs(bytes)) }
        if observations > 1 && observedEnd > start {
            if let first = startFree, let last = lastFree { lines.append("Free-space change: " + change(last - first)) }

            if let first = startDocker, let last = lastDocker, let source = startDockerSource, source == lastDockerSource {
                lines.append("Docker allocated change: " + change(last - first))
            } else { lines.append("Docker comparison unavailable (missing or changed image).") }
        }

        return lines.joined(separator: "\n")
    }
}
struct BackupHistoryResult: Sendable {
    let spans: [BackupSpan]
    let totalCount: Int
    let skippedLines: Int
}

/// Sparse monthly journal: one idle/unknown row per transition/run, one heartbeat per running minute.
/// Explicit run identities and bounded observation gaps prevent invented spans through sleep/restarts.
actor BackupEventStore {
    static let maximumGap: TimeInterval = 150
    static let header = "timestamp_utc,run_id,state,previous_idle_utc,free_bytes,docker_allocated_bytes,docker_source_id\n"
    nonisolated let directory: URL
    nonisolated let logs: BackupLogStore
    private let formatter: ISO8601DateFormatter
    private var previous: BackupObservation?
    init(directory: URL) {
        self.directory = directory
        logs = BackupLogStore(directory: directory.appendingPathComponent("TimeMachine"))
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    @discardableResult func append(_ observation: BackupObservation) throws -> Bool {
        var row = observation
        if let previous, previous.runID == row.runID {
            let gap = row.date.timeIntervalSince(previous.date)
            if row.state == .running && previous.state == .idle && gap > 0 && gap <= Self.maximumGap { row.previousIdle = previous.date }
            // Idle heartbeats are remembered in memory for start bounds, without disk writes.
            if row.state != .running && row.state == previous.state {
                self.previous = row; return false
            }
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stamp = formatter.string(from: row.date)
        let url = directory.appendingPathComponent(String(stamp.prefix(7)) + ".csv")
        if !FileManager.default.fileExists(atPath: url.path) { try Data(Self.header.utf8).write(to: url, options: .atomic) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var prefix = ""
        if length > 0 {
            try handle.seek(toOffset: length - 1)
            if try handle.read(upToCount: 1)?.first != 10 { prefix = "\n" }
        }
        try handle.seekToEnd()
        let idle = row.previousIdle.map(formatter.string) ?? ""
        let free = row.freeBytes.map(String.init) ?? "", docker = row.dockerBytes.map(String.init) ?? ""
        try handle.write(contentsOf: Data("\(prefix)\(stamp),\(row.runID),\(row.state.rawValue),\(idle),\(free),\(docker),\(row.dockerSource ?? "")\n".utf8))
        previous = row
        return true
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.csv$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func parse(_ line: String) -> BackupObservation? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard fields.count == 7, let date = formatter.date(from: fields[0]), UUID(uuidString: fields[1]) != nil,
              let state = BackupObservationState(rawValue: fields[2]) else { return nil }
        let idle = fields[3].isEmpty ? nil : formatter.date(from: fields[3])
        if !fields[3].isEmpty && (idle == nil || state != .running || date.timeIntervalSince(idle!) < 0 || date.timeIntervalSince(idle!) > Self.maximumGap) { return nil }
        let free = Int64(fields[4]), docker = Int64(fields[5])
        guard (fields[4].isEmpty || (free != nil && free! >= 0)), (fields[5].isEmpty || (docker != nil && docker! >= 0)) else { return nil }
        guard (docker == nil && fields[6].isEmpty) || (docker != nil && fields[6].range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil) else { return nil }
        return BackupObservation(date: date, runID: fields[1], state: state, previousIdle: idle,
                                 freeBytes: free, dockerBytes: docker, dockerSource: fields[6].isEmpty ? nil : fields[6])
    }
    private func observations(from start: Date, through end: Date, limit: Int) throws -> BackupHistoryResult {
        var active: BackupSpan?, spans: [BackupSpan] = [], count = 0, skipped = 0
        let cap = max(1, limit)
        // One previous month supplies context without reading unbounded years of idle history.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let context = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        let firstMonth = String(formatter.string(from: context).prefix(7)), lastMonth = String(formatter.string(from: end).prefix(7))
        func emit(_ span: BackupSpan) {
            guard span.start <= end && span.bandEnd(through: end) >= start else { return }
            count += 1; spans.append(span)
            if spans.count > cap * 2 { spans.removeFirst(cap) }
        }
        func interrupt() {
            if var span = active { span.ending = .gap; span.end = span.lastRunning; emit(span) }
            active = nil
        }
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month >= firstMonth && month <= lastMonth else { continue }
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: 384, parse: { line -> ParsedHistoryLine<BackupObservation>? in
                if line.isEmpty || line == Self.header.trimmingCharacters(in: .newlines) { return nil }
                return parse(line).map { .value($0) } ?? .invalid
            }) { entry in
                guard case let .value(row) = entry else { skipped += 1; interrupt(); return }
                guard row.date <= end else { return }
                if let span = active, row.runID != span.runID || row.date < span.lastRunning || row.date.timeIntervalSince(span.lastRunning) > Self.maximumGap { interrupt() }
                switch row.state {
                case .unknown: interrupt()
                case .idle:
                    if var span = active {
                        span.end = row.date; span.ending = .stopped
                        span.lastFree = row.freeBytes; span.lastDocker = row.dockerBytes; span.lastDockerSource = row.dockerSource
                        span.observations += 1; emit(span); active = nil
                    }
                case .running:
                    if var span = active {
                        span.lastRunning = row.date; span.lastFree = row.freeBytes
                        span.lastDocker = row.dockerBytes; span.lastDockerSource = row.dockerSource
                        span.observations += 1; active = span
                    } else {
                        active = BackupSpan(runID: row.runID, start: row.date, previousIdle: row.previousIdle,
                            lastRunning: row.date, startFree: row.freeBytes, lastFree: row.freeBytes,
                            startDocker: row.dockerBytes, lastDocker: row.dockerBytes,
                            startDockerSource: row.dockerSource, lastDockerSource: row.dockerSource)
                    }
                }
            }
        }
        if let span = active {
            if end.timeIntervalSince(span.lastRunning) > Self.maximumGap { interrupt() }
            else { emit(span) }
        }
        return BackupHistoryResult(spans: spans, totalCount: count, skippedLines: skipped)
    }
    func load(from start: Date, through end: Date, limit: Int = 500) throws -> BackupHistoryResult {
        let observed = try observations(from: start, through: end, limit: limit)
        let evidence: (values: [BackupSession], skipped: Int) = (try? logs.sessions()) ?? ([], 1)
        let merged = Self.enrich(observed.spans, sessions: evidence.values, through: end).filter {
            $0.start <= end && $0.bandEnd(through: end) >= start
        }
        return BackupHistoryResult(spans: Array(merged.suffix(max(1, limit))),
            totalCount: merged.count + max(0, observed.totalCount - observed.spans.count), skippedLines: observed.skippedLines + evidence.skipped)
    }
    /// Match by overlap, then use native session boundaries. Poll measurements keep their own provenance.
    static func enrich(_ observations: [BackupSpan], sessions: [BackupSession], through end: Date) -> [BackupSpan] {
        func overlaps(_ span: BackupSpan, _ session: BackupSession) -> Bool {
            let beginning = session.start ?? session.firstDate.addingTimeInterval(-maximumGap)
            let finish = session.end ?? session.lastDate.addingTimeInterval(maximumGap)
            return span.start <= finish && span.observedEnd >= beginning
        }
        var used: Set<String> = [], result: [BackupSpan] = []
        for session in sessions {
            let matching = observations.filter { overlaps($0, session) }
            matching.forEach { used.insert($0.id) }
            let safe = matching.filter { span in sessions.filter { overlaps(span, $0) }.count == 1 }
                .sorted { $0.start < $1.start }
            let first = safe.first, last = safe.last
            let beginning = session.start ?? matching.map(\.start).min() ?? session.firstDate
            let lastRunning = max(session.lastDate, matching.map(\.lastRunning).max() ?? session.lastDate)
            var span = BackupSpan(runID: session.id, start: beginning, previousIdle: nil,
                lastRunning: lastRunning, end: session.end,
                ending: session.end != nil ? .stopped : end.timeIntervalSince(lastRunning) > maximumGap ? .gap : .running,
                startFree: first?.startFree, lastFree: last?.lastFree,
                startDocker: first?.startDocker, lastDocker: last?.lastDocker,
                startDockerSource: first?.startDockerSource, lastDockerSource: last?.lastDockerSource,
                observations: safe.reduce(0) { $0 + $1.observations }, verified: session)
            if span.ending == .gap { span.end = lastRunning }
            result.append(span)
        }
        result += observations.filter { !used.contains($0.id) }
        return result.sorted { $0.start < $1.start }
    }
    private func removeObservations(olderThan cutoff: Date) throws -> Int {
        let month = String(formatter.string(from: cutoff).prefix(7))
        var removed = 0
        for url in try files() where url.deletingPathExtension().lastPathComponent <= month {
            var retained = Data(Self.header.utf8), old = 0, malformed = false
            try HistoryStore.forEachLine(in: url) { line in
                if line.isEmpty || line == Self.header.trimmingCharacters(in: .newlines) { return }
                guard let row = parse(line) else { malformed = true; return }
                if row.date < cutoff { old += 1 } else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !malformed else { throw NSError(domain: "DiskFree.BackupHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Malformed backup history preserved in \(url.lastPathComponent). Earlier files may already have been cleaned."]) }
            if old > 0 {
                if retained.count == Self.header.utf8.count { try FileManager.default.removeItem(at: url) }
                else { try retained.write(to: url, options: .atomic) }
                removed += old
            }
        }
        return removed
    }
    func removeSamples(olderThan cutoff: Date) async throws -> Int {
        let removed = try removeObservations(olderThan: cutoff)
        return removed + (try await logs.removeSamples(olderThan: cutoff))
    }
}

/// Independent of free-space/folder refreshes: at most one background status check per minute.
@MainActor
final class BackupActivityMonitor: ObservableObject {
    @Published private(set) var revision = 0
    @Published private(set) var transitionRevision = 0
    @Published private(set) var evidenceRevision = 0
    @Published private(set) var recordingError: String?
    @Published private(set) var statusAvailable = true
    @Published private(set) var lastCheckedAt: Date?
    private let store: BackupEventStore
    private let runID = UUID().uuidString.lowercased()
    private let status: @Sendable () -> Bool?
    private let measurements: @Sendable () -> (Int64?, DockerDiskSnapshot?)
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var logTask: Task<Void, Never>?
    private var pendingLogs = false
    private let collectLogs: Bool
    private var migrationAttempted = false
    private var busy = false
    private var lastPoll = -Double.infinity
    private var lastState: BackupObservationState?
    init(store: BackupEventStore, startTimer: Bool = true,
         status: @escaping @Sendable () -> Bool? = {
             (try? BackupContextReader.command(["status"])).flatMap(BackupContextReader.running)
         }, measurements: @escaping @Sendable () -> (Int64?, DockerDiskSnapshot?) = {
             var info = statfs()
             let free = statfs(BackupContextReader.volume, &info) == 0 ? Int64(info.f_bavail) * Int64(info.f_bsize) : nil
             return (free, DockerDiskStatisticsProvider.shared.collect().snapshot)
         }) {
        self.store = store; self.status = status; self.measurements = measurements; self.collectLogs = startTimer
        if startTimer {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in Task { @MainActor [weak self] in self?.poll() } }
            timer.tolerance = 5; RunLoop.main.add(timer, forMode: .common); self.timer = timer
            poll()
        }
    }
    func poll(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard !busy, uptime - lastPoll >= 60 else { return }
        lastPoll = uptime; busy = true
        let status = self.status, measurements = self.measurements, wasRunning = lastState == .running
        task = Task { [weak self] in
            let reading = await Task.detached(priority: .background) { () -> (BackupObservationState, Int64?, DockerDiskSnapshot?, Date) in
                let running = status()
                let state: BackupObservationState = running == true ? .running : running == false ? .idle : .unknown
                let values = state == .running || (wasRunning && state == .idle) ? measurements() : (nil, nil)
                return (state, values.0, values.1, Date())
            }.value
            guard let self, !Task.isCancelled else { return }
            self.statusAvailable = reading.0 != .unknown
            do {
                let observation = BackupObservation(date: reading.3, runID: self.runID, state: reading.0,
                    freeBytes: reading.1, dockerBytes: reading.2?.allocatedBytes, dockerSource: reading.2?.sourceID)
                if try await self.store.append(observation) { self.revision += 1 }
                self.recordingError = nil
                if self.lastState != reading.0 { self.transitionRevision += 1 }
            } catch { self.recordingError = error.localizedDescription }
            if self.lastState != reading.0 { self.refreshEvidence() }
            self.lastState = reading.0; self.lastCheckedAt = reading.3; self.busy = false
        }
    }
    private func refreshEvidence() {
        guard collectLogs else { return }
        guard logTask == nil else { pendingLogs = true; return }
        let logs = store.logs, migrate = !migrationAttempted
        migrationAttempted = true
        logTask = Task { [weak self] in
            let now = Date()
            if let added = try? await logs.reconcile(from: now.addingTimeInterval(-6 * 3600), through: now), added > 0 {
                self?.evidenceRevision += 1
            }
            if migrate, let added = try? await logs.migrateOnce(now: now), added > 0 { self?.evidenceRevision += 1 }
            guard let self, !Task.isCancelled else { return }
            self.logTask = nil
            if self.pendingLogs { self.pendingLogs = false; self.refreshEvidence() }
        }
    }
    deinit { timer?.invalidate(); task?.cancel(); logTask?.cancel() }
}
