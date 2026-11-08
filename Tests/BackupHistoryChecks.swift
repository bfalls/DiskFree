import Foundation

final class BackupActivityProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var running: Bool? = false
    private var polls = 0, measurements = 0
    func set(_ value: Bool?) { lock.lock(); running = value; lock.unlock() }
    func status() -> Bool? { lock.lock(); defer { lock.unlock() }; polls += 1; return running }
    func values() -> (Int64?, DockerDiskSnapshot?) {
        lock.lock(); defer { lock.unlock() }; measurements += 1
        return (90_000_000_000, DockerDiskSnapshot(allocatedBytes: 38_000_000_000,
            sourceID: String(repeating: "a", count: 64), path: "/fixture/Docker.raw"))
    }
    var counts: (Int, Int) { lock.lock(); defer { lock.unlock() }; return (polls, measurements) }
}

func checkBackupHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-Backups-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BackupEventStore(directory: root)
    let base = ISO8601DateFormatter().date(from: "2026-10-31T23:58:00Z")!
    let run = UUID().uuidString.lowercased(), anotherRun = UUID().uuidString.lowercased()
    func observation(_ seconds: Double, _ state: BackupObservationState, _ free: Int64? = nil,
                     _ docker: Int64? = nil, runID: String? = nil, source: String = "a") -> BackupObservation {
        BackupObservation(date: base.addingTimeInterval(seconds), runID: runID ?? run, state: state,
            freeBytes: free, dockerBytes: docker, dockerSource: docker == nil ? nil : String(repeating: source, count: 64))
    }
    try await store.append(observation(0, .idle))
    let idleWritten = try await store.append(observation(60, .idle))
    precondition(!idleWritten, "Steady idle polling must not keep writing history")
    try await store.append(observation(120, .running, 90_000_000_000, 38_000_000_000))
    try await store.append(observation(180, .running, 89_000_000_000, 39_000_000_000))
    try await store.append(observation(240, .idle, 88_000_000_000, 40_000_000_000))
    let reopened = BackupEventStore(directory: root)
    let result = try await reopened.load(from: base, through: base.addingTimeInterval(250))
    precondition(result.spans.count == 1 && result.skippedLines == 0)
    let span = result.spans[0]
    precondition(span.start == base.addingTimeInterval(120) && span.end == base.addingTimeInterval(240))
    precondition(span.previousIdle == base.addingTimeInterval(60) && span.ending == .stopped && span.observations == 3)
    let detail = span.detail(part: .span)
    precondition(detail.contains("−2.0 GB") && detail.contains("+2.0 GB") && detail.contains("result not verified"))
    let cropped = try await reopened.load(from: base.addingTimeInterval(150), through: base.addingTimeInterval(190))
    precondition(cropped.spans.count == 1 && cropped.spans[0].start == span.start && cropped.spans[0].ending == .running)
    // A run change is unknown coverage even with only a minute between observations.
    try await store.append(observation(300, .running, 88_000_000_000, 40_000_000_000))
    try await store.append(observation(360, .running, 87_000_000_000, 41_000_000_000, runID: anotherRun))
    try await store.append(observation(420, .idle, 86_000_000_000, 42_000_000_000, runID: anotherRun))
    let restarted = try await reopened.load(from: base, through: base.addingTimeInterval(430))
    precondition(restarted.spans.count == 3 && restarted.spans[1].ending == .gap)
    precondition(restarted.spans[1].end == base.addingTimeInterval(300))
    precondition(restarted.spans[2].previousIdle == nil, "A backup first observed after launch must not invent its actual start")
    // Sleep/long scheduling gaps split a span instead of connecting across the unknown interval.
    try await store.append(observation(480, .running, runID: anotherRun))
    try await store.append(observation(900, .running, runID: anotherRun))
    try await store.append(observation(960, .unknown, runID: anotherRun))
    let gaps = try await reopened.load(from: base, through: base.addingTimeInterval(1000))
    precondition(gaps.spans.suffix(2).allSatisfy { $0.ending == .gap })
    precondition(gaps.spans.last?.end == base.addingTimeInterval(900))
    // A stale open span is not displayed as still running indefinitely.
    try await store.append(observation(1020, .running, 80_000_000_000, 42_000_000_000, runID: anotherRun))
    let stale = try await reopened.load(from: base, through: base.addingTimeInterval(1300))
    precondition(stale.spans.last?.ending == .gap)
    let bounded = try await reopened.load(from: base, through: base.addingTimeInterval(1300), limit: 2)
    precondition(bounded.spans.count == 2 && bounded.totalCount > 2)
    var changedImage = span
    changedImage.lastDockerSource = String(repeating: "b", count: 64)
    precondition(changedImage.detail(part: .stop).contains("changed image"))
    let months = try FileManager.default.contentsOfDirectory(atPath: root.path)
    precondition(months.contains("2026-10.csv") && months.contains("2026-11.csv"))
    let removed = try await reopened.removeSamples(olderThan: base.addingTimeInterval(120))
    precondition(removed == 1, "Only one idle row was persisted before the cutoff")
    let retained = try await reopened.load(from: base.addingTimeInterval(120), through: base.addingTimeInterval(250))
    precondition(retained.spans.count == 1)
    let file = root.appendingPathComponent("2026-11.csv")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("broken,partial".utf8)); try handle.close()
    try await reopened.append(observation(1400, .idle, runID: anotherRun))
    let malformed = try await reopened.load(from: base, through: base.addingTimeInterval(1500))
    precondition(malformed.skippedLines == 1)
    let before = try Data(contentsOf: file)
    do { _ = try await reopened.removeSamples(olderThan: base.addingTimeInterval(1500)); preconditionFailure("Malformed observations must be preserved") }
    catch { let after = try Data(contentsOf: file); precondition(after == before) }
    print("PASS: durable backup spans, idle write suppression, start bounds, stop uncertainty, restart/sleep/unknown gaps, stale active handling, endpoint changes, monthly retention and malformed preservation")
}
