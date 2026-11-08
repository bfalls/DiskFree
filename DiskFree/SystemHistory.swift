import Foundation
import AppKit
import Combine
import Darwin

enum MemoryPressure: String, Codable, Sendable {
    case normal, warning, critical
    var rank: Int { self == .critical ? 2 : self == .warning ? 1 : 0 }
}
struct SystemVitals: Sendable {
    let allocated: Int64?
    let used: Int64?
    let pressure: MemoryPressure?
    static func collect() -> SystemVitals {
        var swap = xsw_usage(), size = MemoryLayout<xsw_usage>.size
        let available = sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0
        var level: Int32 = 0
        size = MemoryLayout<Int32>.size
        let known = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        let pressure: MemoryPressure? = known ? (level == 1 ? .normal : level == 2 ? .warning : level == 4 ? .critical : nil) : nil
        return SystemVitals(allocated: available ? Int64(exactly: swap.xsu_total) : nil,
                            used: available ? Int64(exactly: swap.xsu_used) : nil, pressure: pressure)
    }
    static var bootTime: Date? {
        var time = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &time, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(time.tv_sec))
    }
}
enum SystemRecordKind: String, Codable, Sendable {
    case sample, appStart, appStop, sleep, wake, shutdown
    var title: String {
        switch self {
        case .sample: return "System measurement"
        case .appStart: return "DiskFree started"
        case .appStop: return "DiskFree stopped"
        case .sleep: return "Mac going to sleep"
        case .wake: return "Mac woke"
        case .shutdown: return "Mac shutdown requested"
        }
    }
}
struct SystemRecord: Codable, Sendable {
    var id = UUID().uuidString
    var date: Date
    var kind: SystemRecordKind
    var runID: String
    var boot: Date?
    var interval: Int?
    var allocated: Int64?
    var used: Int64?
    var pressure: MemoryPressure?
    var free: Int64?
    var docker: Int64?
    var dockerSource: String?
    var dockerPath: String?
    var reclaimable: Int64?
    func valid() -> Bool {
        UUID(uuidString: id) != nil && UUID(uuidString: runID) != nil && date.timeIntervalSince1970.isFinite
            && [allocated, used, free, docker].allSatisfy { $0 == nil || $0! >= 0 }
            && (used == nil || allocated == nil || used! <= allocated!)
            && (interval == nil || Preferences.intervals.contains(interval!))
    }
}
struct SystemPlotPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var record: SystemRecord
    var maximumPressure: MemoryPressure?
    var pressureRecord: SystemRecord
    var segment: Int
}
enum ActivityCategory: String, Sendable { case swap, docker, memory, power, backup, storage, space }
struct ActivityEvent: Identifiable, Sendable {
    let id: String
    let date: Date
    var end: Date? = nil
    let category: ActivityCategory
    let title: String
    let detail: String
    let records: [SystemRecord]
    var consumerRecords: [ConsumerMeasurement] = []
    var backupSession: BackupSession? = nil
    var spaceChange: SpaceChange? = nil
    var markerDate: Date { category == .space ? end ?? date : date }
    var freeGB: Double? { records.last?.free.map { Double($0) / 1e9 } }
    var critical: Bool { records.last?.pressure == .critical }
}
extension ActivityEvent {
    /// Same-day ranges print the date once; cross-day ranges retain both dates.
    static func timeRange(from start: Date, through end: Date, calendar: Calendar = .current) -> String {
        let first = start.formatted(date: .abbreviated, time: .standard)
        let last = end.formatted(date: calendar.isDate(start, inSameDayAs: end) ? .omitted : .abbreviated, time: .standard)
        return first + " → " + last
    }
    /// Reserve room for significant disk changes when ordinary indicators are dense.
    static func forChart(_ events: [ActivityEvent], limit: Int = 500, hideReversals: Bool = true) -> [ActivityEvent] {
        let cap = max(1, limit)
        var seen: Set<String> = []
        let unique = events.filter { seen.insert($0.id).inserted }
        let sorted = hideReversals ? removingSmallSwapReversals(unique) : unique.sorted { $0.date < $1.date }
        let milestones = Array(sorted.filter { $0.category == .space }.suffix(min(100, cap)))
        let others = sorted.filter { $0.category != .space }.suffix(cap - milestones.count)
        return (milestones + others).sorted { $0.date < $1.date }
    }
    /// Display-only noise reduction. Raw observations and chart samples remain unchanged.
    /// Only adjacent, exactly reversing, normal-pressure changes with a shared sample
    /// are hidden. Larger excursions remain useful clues even when they later recover.
    static func removingSmallSwapReversals(_ events: [ActivityEvent]) -> [ActivityEvent] {
        let sorted = events.sorted { $0.date < $1.date }
        var result: [ActivityEvent] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            if index + 1 < sorted.count {
                let second = sorted[index + 1]
                if first.category == .swap, second.category == .swap,
                   first.records.count == 2, second.records.count == 2 {
                    let a = first.records[0], b = first.records[1]
                    let c = second.records[0], d = second.records[1]
                    if b.id == c.id, a.runID == d.runID, a.boot == d.boot,
                       [a, b, c, d].allSatisfy({ $0.kind == .sample && $0.pressure == .normal }),
                       d.date > a.date, d.date.timeIntervalSince(a.date) <= 300,
                       b.date.timeIntervalSince(a.date) <= Double(max(a.interval ?? 60, b.interval ?? 60)) * 2.5,
                       d.date.timeIntervalSince(c.date) <= Double(max(c.interval ?? 60, d.interval ?? 60)) * 2.5,
                       let base = a.allocated, let peak = b.allocated, d.allocated == base,
                       abs(peak - base) <= 2_147_483_648 {
                        index += 2
                        continue
                    }
                }
            }
            result.append(first)
            index += 1
        }
        return result
    }
}
struct SystemHistoryResult: Sendable {
    let points: [SystemPlotPoint]
    let events: [ActivityEvent]
    let skipped: Int
    let totalEvents: Int
}

/// Append-only monthly JSONL. Small writes share a lock; streaming chart reads run off the UI thread.
/// Lifecycle notifications write synchronously so orderly termination doesn't abandon an async task.
final class SystemHistoryStore: @unchecked Sendable {
    let directory: URL
    private let writeLock = NSLock()
    init(directory: URL) { self.directory = directory }
    private func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder
    }
    private func decoder() -> JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
    func source(for date: Date) -> URL {
        let formatter = ISO8601DateFormatter()
        return directory.appendingPathComponent(String(formatter.string(from: date).prefix(7)) + ".jsonl")
    }
    func append(_ record: SystemRecord) throws {
        guard record.valid() else { throw CocoaError(.fileWriteInvalidFileName) }
        let bytes = try encoder().encode(record)
        writeLock.lock(); defer { writeLock.unlock() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = source(for: record.date).path
        // O_APPEND + a single small write prevents readers from seeing interleaved records.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var data = Data([10]); data.append(bytes); data.append(10)
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress, write(fd, base, buffer.count) == buffer.count else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.jsonl$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    static func events(previous: SystemRecord?, row: SystemRecord) -> [ActivityEvent] {
        var events: [ActivityEvent] = []
        let stamp: (Date) -> String = { $0.formatted(date: .abbreviated, time: .standard) }
        func add(_ category: ActivityCategory, _ title: String, _ detail: String, records: [SystemRecord], end: Date? = nil, date: Date? = nil) {
            events.append(ActivityEvent(id: row.id + category.rawValue + title, date: date ?? row.date, end: end,
                category: category, title: title, detail: detail, records: records))
        }
        if row.kind != .sample {
            var detail = "\(row.kind.title)\n\(stamp(row.date))\nSource: "
            switch row.kind {
            case .sleep: detail += "NSWorkspace.willSleepNotification. Sleep requested; actual entry may be slightly later."
            case .wake: detail += "NSWorkspace.didWakeNotification."
            case .shutdown: detail += "NSWorkspace.willPowerOffNotification. Shutdown/logout was requested; completion isn't observable by this app."
            case .appStop: detail += "NSApplication.willTerminateNotification. This marks the app stopping, not the Mac powering off."
            case .appStart:
                detail += "DiskFree process launch."
                if let boot = row.boot { detail += "\nmacOS boot time (kern.boottime): \(stamp(boot))." }
                if let previous, previous.runID != row.runID {
                    let seconds = max(0, Int(row.date.timeIntervalSince(previous.date)))
                    if row.date > previous.date {
                        add(.power, "Recording gap · \(seconds / 60)m \(seconds % 60)s", "No recordings: \(ActivityEvent.timeRange(from: previous.date, through: row.date)).\nThe Mac's power state during this gap is unknown. It may have been awake, asleep, or off.\nSource: the previous session's last record and the next app-start record.", records: [previous, row], end: row.date, date: previous.date)
                    }
                    detail += "\n\(seconds / 60)m \(seconds % 60)s since the last recorded observation; power state during this gap is unknown."
                    if let old = previous.boot, let boot = row.boot, boot != old {
                        detail += "\nThe Mac restarted between observations. Its exact power-off duration is unknown."
                        if boot > previous.date && boot <= row.date {
                            add(.power, "Mac startup", "macOS reports startup at \(stamp(boot)).\nSource: kern.boottime, read when DiskFree launched at \(stamp(row.date)).", records: [previous, row], date: boot)
                        }
                    }
                }
            case .sample: break
            }
            add(.power, row.kind.title, detail, records: [row])
        }
        guard let previous, row.kind == .sample, previous.kind == .sample,
              row.runID == previous.runID, row.boot == previous.boot,
              row.date > previous.date, row.date.timeIntervalSince(previous.date) <= Double(max(row.interval ?? 60, previous.interval ?? 60)) * 2.5 else { return events }
        let records = [previous, row]
        func interval() -> String { "\(stamp(previous.date)) → \(stamp(row.date))" }
        func freeChange() -> String { previous.free.flatMap { first in row.free.map { String(format: "%+.2f GB", Double($0 - first) / 1e9) } } ?? "unavailable" }
        func delta(_ first: Int64?, _ last: Int64?, category: ActivityCategory, name: String, source: String) {
            guard let first, let last, abs(last - first) >= 536_870_912 else { return }
            let change = last - first
            let title = name + (change > 0 ? " grew " : " shrank ") + CapacityFormat.string(abs(change))
            add(category, title, "\(title)\n\(interval())\nAllocated: \(CapacityFormat.string(first)) → \(CapacityFormat.string(last))\nFree-space change: \(freeChange())\nSource: \(source).", records: records)
        }
        delta(previous.allocated, row.allocated, category: .swap, name: "Swap", source: "native sysctl vm.swapusage (xsu_total)")
        if let source = row.dockerSource, source == previous.dockerSource {
            delta(previous.docker, row.docker, category: .docker, name: "Docker", source: "Docker image allocated blocks (lstat st_blocks × 512); same image identity")
        }
        if let pressure = row.pressure, pressure != previous.pressure {
            add(.memory, "Memory pressure: \(pressure.rawValue)", "Memory pressure became \(pressure.rawValue).\n\(interval())\nSource: native kern.memorystatus_vm_pressure_level.\nPressure is sampled at the disk refresh interval; shorter transitions may not be observed.", records: records)
        }
        return events
    }
    func load(from start: Date, through end: Date, bucketSeconds: TimeInterval, limit: Int = 500) throws -> SystemHistoryResult {
        let origin = HistoryStore.bucketOrigin(for: start)
        let width = max(60, bucketSeconds), cap = max(1, limit)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let context = calendar.date(byAdding: .month, value: -1, to: start) ?? start
        let first = source(for: context).lastPathComponent, last = source(for: end).lastPathComponent
        let decoder = decoder()
        var previous: SystemRecord?, previousSample: SystemRecord?, sleep: SystemRecord?
        var buckets: [Int: SystemPlotPoint] = [:], events: [ActivityEvent] = [], milestones: [ActivityEvent] = []
        var skipped = 0, total = 0, segment = 0
        var space = SpaceChangeDetector()
        func emit(_ event: ActivityEvent) {
            guard event.date <= end && (event.end ?? event.date) >= start else { return }
            total += 1; events.append(event)
            if event.category == .space { milestones.append(event); if milestones.count > 200 { milestones.removeFirst(100) } }
            if events.count > cap * 2 { events.removeFirst(cap) }
        }
        for url in try files() where url.lastPathComponent >= first && url.lastPathComponent <= last {
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: MemoryLayout<ParsedHistoryLine<SystemRecord>>.stride + 96, parse: { line -> ParsedHistoryLine<SystemRecord>? in
                if line.isEmpty { return nil }
                guard var row = try? decoder.decode(SystemRecord.self, from: Data(line.utf8)), row.valid() else { return .invalid }
                row.runID = JournalStrings.shared.intern(row.runID)
                row.dockerSource = row.dockerSource.map { JournalStrings.shared.intern($0) }
                row.dockerPath = row.dockerPath.map { JournalStrings.shared.intern($0) }
                return .value(row)
            }) { entry in
                guard case let .value(row) = entry else {
                    if let change = space.finish() { emit(change.event) }; space = SpaceChangeDetector()
                    skipped += 1; previous = nil; previousSample = nil; sleep = nil; segment += 1; return
                }
                guard row.date <= end else { return }
                if let prior = previous, row.date < prior.date { skipped += 1; previous = nil; previousSample = nil; sleep = nil; segment += 1 }
                for change in space.consume(row) { emit(change.event) }
                let comparable = row.kind == .sample ? previousSample : previous
                // Earlier rows establish state, but cannot end an event in this window.
                if row.date >= start { for event in Self.events(previous: comparable, row: row) { emit(event) } }
                if row.kind == .wake, let beginning = sleep, beginning.runID == row.runID, beginning.boot == row.boot, row.date >= beginning.date {
                    let seconds = Int(row.date.timeIntervalSince(beginning.date))
                    emit(ActivityEvent(id: beginning.id + "sleepSpan", date: beginning.date, end: row.date, category: .power, title: "Mac sleep · \(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s",
                        detail: "Observed sleep/wake span: \(ActivityEvent.timeRange(from: beginning.date, through: row.date)).\nDuration is between macOS sleep-request and wake notifications.\nSource: NSWorkspace.willSleepNotification and didWakeNotification in the same app session. DiskFree doesn't sample while the Mac sleeps.", records: [beginning, row]))
                    sleep = nil
                }
                if row.kind == .sleep { sleep = row }
                if row.kind == .appStart || row.kind == .appStop || row.kind == .shutdown { sleep = nil }
                if row.kind == .sample {
                    if let prior = previousSample, row.allocated == nil || prior.allocated == nil || row.runID != prior.runID || row.boot != prior.boot || row.date.timeIntervalSince(prior.date) > Double(max(row.interval ?? 60, prior.interval ?? 60)) * 2.5 { segment += 1 }
                    if row.date >= start {
                        let index = Int(row.date.timeIntervalSince(origin) / width)
                        if var point = buckets[index], point.segment == segment {
                            point.record = row
                            if let pressure = row.pressure, pressure.rank > (point.maximumPressure?.rank ?? -1) { point.maximumPressure = pressure; point.pressureRecord = row }
                            buckets[index] = point
                        } else { buckets[index] = SystemPlotPoint(date: origin.addingTimeInterval(Double(index) * width), record: row, maximumPressure: row.pressure, pressureRecord: row, segment: segment) }
                    }
                    previousSample = row
                } else if row.kind != .wake { previousSample = nil; segment += 1 }
                previous = row
            }
        }
        if let change = space.finish() { emit(change.event) }
        if let beginning = sleep, beginning.date <= end {
            emit(ActivityEvent(id: beginning.id + "openSleep", date: beginning.date, category: .power, title: "Sleep requested; wake not recorded", detail: "Sleep was requested at \(beginning.date.formatted(date: .abbreviated, time: .standard)). No matching wake was recorded. Duration and subsequent power state are unknown.", records: [beginning]))
        }
        return SystemHistoryResult(points: buckets.keys.sorted().compactMap { buckets[$0] }, events: ActivityEvent.forChart(Array(events.suffix(cap)) + milestones, limit: cap, hideReversals: false), skipped: skipped, totalEvents: total)
    }
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        writeLock.lock(); defer { writeLock.unlock() }
        let decoder = decoder()
        var removed = 0
        for url in try files() where url.lastPathComponent <= source(for: cutoff).lastPathComponent {
            var retained = Data(), old = 0, malformed = false
            try HistoryStore.forEachLine(in: url) { line in
                guard !line.isEmpty else { return }
                guard let row = try? decoder.decode(SystemRecord.self, from: Data(line.utf8)), row.valid() else { malformed = true; return }
                if row.date < cutoff { old += 1 } else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !malformed else { throw NSError(domain: "DiskFree.SystemHistory", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unreadable system history was preserved in \(url.lastPathComponent). Earlier months may already have been cleaned."]) }
            if old > 0 {
                if retained.isEmpty { try FileManager.default.removeItem(at: url) } else { try retained.write(to: url, options: .atomic) }
                removed += old
            }
        }
        return removed
    }
}

/// Power events are notification driven; no power polling or system-log mining.
final class SystemActivityMonitor: @unchecked Sendable {
    let store: SystemHistoryStore
    let runID = UUID().uuidString
    let boot = SystemVitals.bootTime
    private var workspaceTokens: [NSObjectProtocol] = []
    private var terminateToken: NSObjectProtocol?
    private let lock = NSLock()
    private(set) var recordingError: String?
    init(store: SystemHistoryStore, observe: Bool = true) {
        self.store = store
        guard observe else { return }
        record(.appStart)
        let center = NSWorkspace.shared.notificationCenter
        for (name, kind) in [(NSWorkspace.willSleepNotification, SystemRecordKind.sleep), (NSWorkspace.didWakeNotification, .wake), (NSWorkspace.willPowerOffNotification, .shutdown)] {
            workspaceTokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] _ in self?.record(kind) })
        }
        terminateToken = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in self?.record(.appStop) }
    }
    func record(_ kind: SystemRecordKind, date: Date = Date()) {
        let row = SystemRecord(date: date, kind: kind, runID: runID, boot: boot)
        do { try store.append(row) } catch { lock.lock(); recordingError = error.localizedDescription; lock.unlock() }
    }
    @discardableResult func sample(vitals: SystemVitals, disk: DiskSnapshot?, docker: DockerDiskSnapshot?, interval: Int, at date: Date = Date()) throws -> SystemRecord {
        let row = SystemRecord(date: date, kind: .sample, runID: runID, boot: boot, interval: interval,
            allocated: vitals.allocated, used: vitals.used, pressure: vitals.pressure,
            free: disk?.freeBytes, docker: docker?.allocatedBytes, dockerSource: docker?.sourceID, dockerPath: docker?.path, reclaimable: disk?.reclaimableEstimateBytes)
        try store.append(row)
        return row
    }
    deinit {
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        if let terminateToken { NotificationCenter.default.removeObserver(terminateToken) }
    }
}
