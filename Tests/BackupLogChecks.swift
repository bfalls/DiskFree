import Foundation

private final class BackupQueryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var failAt: Int?
    var limitAt: Int?
    func query(_ start: Date, _ end: Date) throws -> [BackupLogRecord] {
        lock.lock(); defer { lock.unlock() }; calls += 1
        if calls == limitAt { throw BackupLogQueryError.workLimit }
        if calls == failAt { throw CocoaError(.fileReadUnknown) }; return []
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return calls }
}
func checkBackupLogs() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-BackupLogs-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let boot = UUID().uuidString
    func record(_ time: String, _ message: String, category: String = "General", pid: Int = 42, bootID: String? = nil) -> BackupLogRecord {
        let object: [String: Any] = ["timestamp": "2026-10-24 " + time + "-0600", "eventMessage": message,
            "subsystem": "com.apple.TimeMachine", "bootUUID": bootID ?? boot, "processID": pid, "category": category]
        let data = try! JSONSerialization.data(withJSONObject: object)
        return BackupLogParser.decode(String(decoding: data, as: UTF8.self))[0]
    }
    let start = record("18:16:51.298520", "Starting automatic backup")
    let volume = record("18:46:49.654575", """
    Finished copying from volume "Data"
           3859528 Total Items in Backup (l: 271.36 GB p: 235.79 GB)
             37578 Files Copied (l: 7.06 GB p: 7.17 GB)
              4934 Directories Copied (l: Zero KB p: Zero KB)
    """, category: "CopyProgress")
    let stats = record("18:46:58.756635", """
    Backup result: {
        "com.apple.backupd.SnapshotTotalBytesCopied" = 9206951936;
        FreeBytes = 251745280000;
        DestinationMountPoint = "/Volumes/Backup";
        Progress = { files = 42732; bytes = 9206943744; totalBytes = 358333927424; };
    }
    """)
    let finish = record("18:47:39.046756", "Completed backup: 2026-10-24-184658.backup")
    let records = [start, volume, stats, finish]
    let session = BackupLogParser.sessions(records.reversed())[0]
    precondition(session.start == start.date && session.end == finish.date && session.outcome == .succeeded)
    precondition(session.copiedBytes == 9206951936 && session.files == 37578 && session.contentsBytes == 235790000000)
    precondition(session.destinationFree == 251745280000 && session.duration == "30m 48s" && session.destination == "Backup")
    precondition(session.transferredItems == 42732 && session.snapshot == "2026-10-24-184658.backup")
    let incomplete = BackupLogParser.sessions([stats])[0]
    precondition(incomplete.start == nil && incomplete.end == nil && incomplete.outcome == .unverified)
    let failed = record("19:01:00.000000", "Backup failed: fixture")
    let cancelled = record("19:02:00.000000", "Backup canceled by user")
    precondition(BackupLogParser.sessions([failed])[0].outcome == .failed)
    precondition(BackupLogParser.sessions([cancelled])[0].outcome == .cancelled)
    let component = record("18:17:00.000000", "Backup failed: component only", category: "CopyProgress")
    precondition(BackupLogParser.sessions([start, component, finish])[0].outcome == .succeeded)
    precondition(BackupLogParser.sessions([component]).isEmpty)
    let duplicateVolume = record("18:46:50.000000", volume.message, category: "CopyProgress")
    precondition(BackupLogParser.sessions([start, volume, duplicateVolume, finish])[0].files == 37578)
    let otherVolume = record("18:46:51.000000", volume.message.replacingOccurrences(of: "\"Data\"", with: "\"Second\""), category: "CopyProgress")
    precondition(BackupLogParser.sessions([start, volume, otherVolume, finish])[0].files == 75156)
    let otherBoot = record("18:47:40.000000", finish.message, bootID: UUID().uuidString)
    precondition(BackupLogParser.sessions([start, otherBoot]).count == 2)
    let nextStart = record("19:00:00.000000", "Starting manual backup")
    precondition(BackupLogParser.sessions(records + [nextStart, failed]).count == 2)
    precondition(BackupLogParser.bytes("Zero KB") == 0 && BackupLogParser.bytes("-1 GB") == nil && BackupLogParser.bytes("1 PB") == nil)
    print("PASS: backup log parser and statistics")
    let overlapping = BackupLogParser.sessions([record("18:47:45.000000", "Starting manual backup"), record("18:48:30.000000", "Completed backup: next.backup")])[0]
    let logs = BackupLogStore(directory: root)
    let added = try await logs.importRecords(records)
    let repeated = try await logs.importRecords(records)
    precondition(added == 4 && repeated == 0)
    let reopened = BackupLogStore(directory: root)
    let again = try await reopened.importRecords(records)
    let loaded = try reopened.sessions()
    precondition(again == 0 && loaded.values.count == 1 && loaded.values[0].copiedBytes == session.copiedBytes)
    let store = BackupEventStore(directory: root.appendingPathComponent("polls"))
    _ = try await store.logs.importRecords(records)
    let logOnly = try await store.load(from: start.date, through: finish.date)
    precondition(logOnly.spans.count == 1 && logOnly.spans[0].observations == 0 && logOnly.spans[0].startFree == nil)
    let run = UUID().uuidString
    try await store.append(BackupObservation(date: start.date.addingTimeInterval(153), runID: run, state: .running, freeBytes: 90_000_000_000))
    try await store.append(BackupObservation(date: finish.date.addingTimeInterval(-17), runID: run, state: .running, freeBytes: 91_000_000_000))
    try await store.append(BackupObservation(date: finish.date.addingTimeInterval(103), runID: run, state: .idle, freeBytes: 92_000_000_000))
    print("PASS: backup evidence persistence and log-only history")
    let enriched = try await store.load(from: start.date, through: finish.date.addingTimeInterval(150))
    precondition(enriched.spans.count == 1 && enriched.spans[0].start == start.date && enriched.spans[0].end == finish.date)
    precondition(enriched.spans[0].startFree == 90_000_000_000 && enriched.spans[0].lastFree == 92_000_000_000)
    print("PASS: native times reconciled with polling")
    let raw = BackupSpan(runID: run, start: finish.date.addingTimeInterval(-17), previousIdle: nil,
        lastRunning: finish.date, end: finish.date.addingTimeInterval(103), ending: .stopped,
        startFree: 1, lastFree: 2, startDocker: nil, lastDocker: nil, startDockerSource: nil, lastDockerSource: nil)
    let ambiguous = BackupEventStore.enrich([raw], sessions: [session, overlapping], through: overlapping.lastDate)
    precondition(ambiguous.count == 2 && ambiguous.allSatisfy { $0.startFree == nil }, "Never attribute a polling interval spanning two backups to either run")
    print("PASS: backup observation reconciliation")
    // Checkpoint resumes after a query failure and never repeats a completed migration.
    let probe = BackupQueryProbe(); probe.failAt = 2
    let migration = BackupLogStore(directory: root.appendingPathComponent("migration"), query: { try probe.query($0, $1) })
    do { _ = try await migration.migrateOnce(now: finish.date); preconditionFailure("Expected query failure") } catch {}
    print("PASS: backup migration checkpoint on failure")
    probe.failAt = nil
    _ = try await migration.migrateOnce(now: finish.date.addingTimeInterval(999))
    let completedCalls = probe.count
    _ = try await migration.migrateOnce(now: finish.date.addingTimeInterval(1999))
    precondition(probe.count == completedCalls && completedCalls == 31)
    let limited = BackupQueryProbe(); limited.limitAt = 1
    let adaptive = BackupLogStore(directory: root.appendingPathComponent("adaptive"), query: { try limited.query($0, $1) })
    _ = try await adaptive.reconcile(from: finish.date.addingTimeInterval(-4 * 3600), through: finish.date)
    precondition(limited.count == 3, "A limited query must split into bounded smaller windows")
    let removed = try await reopened.removeSamples(olderThan: volume.date)
    precondition(removed == 1)
    let file = reopened.source(for: volume.date)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("broken".utf8)); try handle.close()
    let before = try Data(contentsOf: file)
    do { _ = try await reopened.removeSamples(olderThan: finish.date.addingTimeInterval(1)); preconditionFailure("Expected malformed preservation") }
    catch { let after = try Data(contentsOf: file); precondition(after == before) }
    print("PASS: verified backup times/outcomes/statistics, partial logs, component isolation, volume totals, native-only history, observation reconciliation, durable deduplication, resumable one-time import and retention")
}
