import Foundation

private final class SpaceQueryProbe: @unchecked Sendable {
    private let lock = NSLock(); private var reads = 0, active = 0, peak = 0
    let text: String
    init(_ text: String) { self.text = text }
    func query() -> String { lock.lock(); reads += 1; active += 1; peak = max(peak, active); lock.unlock(); Thread.sleep(forTimeInterval: 0.03); lock.lock(); active -= 1; lock.unlock(); return text }
    var maximumActive: Int { lock.lock(); defer { lock.unlock() }; return peak }
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
}
private func spaceFixtures(root: URL) throws -> (change: SpaceChange, native: String, pureSwap: SpaceChange, variants: [SpaceChange]) {
    let base = ISO8601DateFormatter().date(from: "2026-10-25T00:16:52Z")!, run = UUID().uuidString
    func row(_ seconds: Double, _ free: Int64, swap: Int64 = 20_401_094_656) -> SystemRecord {
        SystemRecord(date: base.addingTimeInterval(seconds), kind: .sample, runID: run, boot: base.addingTimeInterval(-1000), interval: 15,
            allocated: swap, used: swap / 2, pressure: .normal, free: free, docker: 38_105_145_344, dockerSource: String(repeating: "a", count: 64))
    }
    let samples = [row(0, 86_543_233_024), row(15, 90_283_847_680), row(30, 98_959_777_792, swap: 19_327_352_832),
                   row(46, 105_491_992_576, swap: 19_327_352_832), row(60, 108_452_397_056, swap: 19_327_352_832)]
    var detector = SpaceChangeDetector()
    for sample in samples { precondition(detector.consume(sample).isEmpty) }
    let change = detector.finish()!
    precondition(change.bytes == 21_909_164_032 && change.title == "Freed 21.9 GB" && change.event.markerDate == samples.last!.date)
    var quiet = SpaceChangeDetector(); for sample in samples { _ = quiet.consume(sample) }
    var quietEvents = 0
    for t in stride(from: 75, through: 165, by: 15) { quietEvents += quiet.consume(row(Double(t), samples.last!.free!)).count }
    precondition(quietEvents == 1 && quiet.finish() == nil)
    var gap = SpaceChangeDetector(); _ = gap.consume(row(0, 10_000_000_000))
    precondition(gap.consume(row(1000, 30_000_000_000)).isEmpty && gap.finish() == nil)
    var restarted = row(15, 30_000_000_000); restarted.runID = UUID().uuidString
    var restart = SpaceChangeDetector(); _ = restart.consume(row(0, 10_000_000_000)); _ = restart.consume(restarted)
    precondition(restart.finish() == nil)
    var tiny = SpaceChangeDetector()
    for i in 0..<40 { _ = tiny.consume(row(Double(i * 15), Int64(i % 2) * 1_000_000_000 + 30_000_000_000)) }
    precondition(tiny.finish() == nil, "Swap jitter must not become a large milestone")
    var loss = SpaceChangeDetector(); _ = loss.consume(row(0, 40_000_000_000)); _ = loss.consume(row(15, 34_000_000_000))
    precondition(loss.finish()?.title == "Used 6.0 GB")
    var broken = SpaceChangeDetector(); _ = broken.consume(row(0, 10_000_000_000))
    var missing = row(15, 10_000_000_000); missing.free = nil; _ = broken.consume(missing); _ = broken.consume(row(30, 30_000_000_000))
    precondition(broken.finish() == nil)
    func message(_ name: String, _ volume: String = "/System/Volumes/Data") -> String {
        let object: [String: Any] = ["timestamp": "2026-10-24 18:17:01.098525-0600", "subsystem": "com.apple.TimeMachine", "category": "LocalThinning",
            "eventMessage": "Age-based thinning deleted Time Machine snapshot '\(name)' on disk '\(volume)"]
        return String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }
    let native = [message("snapshot-1"), message("snapshot-2"), message("snapshot-1"), message("destination", "/Volumes/Backup"), message("wrong-volume", "/System/Volumes/DataOther")].joined(separator: "\n")
    let actions = SpaceActionParser.decode(native, from: base, through: base.addingTimeInterval(60))
    precondition(actions.count == 2 && actions.allSatisfy { $0.bytes == nil })
    precondition(SpaceActionParser.decode(native, from: base.addingTimeInterval(60), through: base.addingTimeInterval(120)).isEmpty)
    func folder(_ date: Date, bytes: Int64, coverage: String = "same") -> ConsumerMeasurement {
        ConsumerMeasurement(date: date, folderID: "consumer.ai.ollama", name: "Ollama models", root: "/fixture/models", bytes: bytes,
            measuredAt: date, exclusions: [], skipped: 0, coverage: coverage, identity: "device:inode")
    }
    let beforeFolder = folder(base.addingTimeInterval(-300), bytes: 30_000_000_000)
    let afterFolder = folder(base.addingTimeInterval(300), bytes: 10_000_000_000)
    precondition(SpaceFolderChange.matching([beforeFolder, afterFolder], change: change).first?.delta == -20_000_000_000)
    precondition(SpaceFolderChange.matching([beforeFolder, folder(base.addingTimeInterval(300), bytes: 10, coverage: "different")], change: change).isEmpty)
    let pureSwap = SpaceChange(before: row(0, 30_000_000_000, swap: 10_000_000_000), after: row(30, 36_000_000_000, swap: 4_000_000_000))
    let system = SystemHistoryStore(directory: root.appendingPathComponent("system"))
    for sample in samples { try system.append(sample) }
    let history = try system.load(from: base, through: base.addingTimeInterval(120), bucketSeconds: 3600)
    precondition(history.events.filter { $0.spaceChange != nil }.count == 1, "Detect before downsampling")
    let noisy = (0..<800).map { i in ActivityEvent(id: "noise-\(i)", date: base.addingTimeInterval(Double(120 + i)), category: .power, title: "Fixture", detail: "", records: []) }
    let prioritized = ActivityEvent.forChart([change.event] + noisy, limit: 50)
    precondition(prioritized.count == 50 && prioritized.contains { $0.spaceChange != nil }, "A milestone must survive dense indicator history")
    print("PASS: grouped 21.9 GB native scenario, noise/loss/coverage safeguards, exact-volume cleanup evidence and popular-app folder comparisons")
    var b1 = change.before; b1.id = UUID().uuidString
    var b2 = change.before; b2.id = UUID().uuidString
    return (change, native, pureSwap, [SpaceChange(before: b1, after: change.after), SpaceChange(before: b2, after: change.after)])
}
func checkSpaceChanges() async throws {
    print("Checking space-change reports")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-SpaceChanges-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let fixture = try spaceFixtures(root: root), change = fixture.change, native = fixture.native, pureSwap = fixture.pureSwap
    let consumers = ConsumerHistoryStore(directory: root.appendingPathComponent("consumers"))
    let noFiles: @Sendable (SpaceChange) async -> FileFindings = { _ in FileFindings(checkedAt: Date(), files: [], spotlight: "Fixture", tracking: "Fixture", trackingSince: nil) }
    let probe = SpaceQueryProbe(native), store = SpaceChangeStore(directory: root.appendingPathComponent("reports"), query: { _, _ in probe.query() }, fileQuery: noFiles)
    let reports = try await withThrowingTaskGroup(of: SpaceChangeReport.self) { group in
        for _ in 0..<3 { group.addTask { try await store.investigate(change, consumers: consumers) } }
        var result: [SpaceChangeReport] = []; for try await report in group { result.append(report) }; return result
    }
    precondition(probe.count == 1 && reports.count == 3 && reports[0].actions.count == 2)
    precondition(reports[0].headline.contains("2 local restore points") && reports[0].dockerDelta == 0)
    try await withThrowingTaskGroup(of: Void.self) { group in
        for variant in fixture.variants { group.addTask { _ = try await store.investigate(variant, consumers: consumers) } }
        try await group.waitForAll()
    }
    precondition(probe.count == 3 && probe.maximumActive == 1, "Different reports must serialize native queries")
    let reopened = SpaceChangeStore(directory: root.appendingPathComponent("reports"), query: { _, _ in preconditionFailure("Cached reports must not requery logs") }, fileQuery: noFiles)
    let cached = try await reopened.investigate(change, consumers: consumers)
    precondition(cached.actions.count == 2)
    let swapProbe = SpaceQueryProbe("")
    let swapStore = SpaceChangeStore(directory: root.appendingPathComponent("swap"), query: { _, _ in swapProbe.query() }, fileQuery: noFiles)
    let swap = try await swapStore.investigate(pureSwap, consumers: consumers)
    precondition(swapProbe.count == 0 && swap.headline == "Swap change matches the space change")
    let unavailable = SpaceChangeStore(directory: root.appendingPathComponent("unavailable"), query: { _, _ in throw CocoaError(.fileReadNoPermission) }, fileQuery: noFiles)
    let fallback = try await unavailable.investigate(change, consumers: consumers)
    precondition(fallback.logStatus == "Local logs unavailable" && fallback.actions.isEmpty && fallback.measurements.count == 3)
    let removed = try await reopened.removeSamples(olderThan: change.after.date.addingTimeInterval(1))
    precondition(removed == 3 && reopened.cached(change) == nil)
    let url = store.source(for: change); try Data("broken".utf8).write(to: url)
    do { _ = try await store.removeSamples(olderThan: Date.distantFuture); preconditionFailure("Corrupt reports must be preserved") }
    catch { let text = try String(contentsOf: url); precondition(text == "broken") }
    print("PASS: durable action reports, concurrent query coalescing, cached reopen, query-free native explanations, unavailable-log fallback and safe retention")
}
