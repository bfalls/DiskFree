import Foundation

final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0
    private var failure = false
    var count: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func fail(_ value: Bool) { lock.lock(); failure = value; lock.unlock() }
    func collect() throws -> DiskSnapshot {
        lock.lock(); reads += 1; let shouldFail = failure; lock.unlock()
        if shouldFail { throw NSError(domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Simulated failure"]) }
        return DiskSnapshot(name: "Test Disk", path: "/", freeBytes: 50_000_000_000,
                            totalBytes: 100_000_000_000, reclaimableEstimateBytes: nil, refreshedAt: Date())
    }
}

@main
struct Checks {
    @MainActor static func pump(until condition: () -> Bool, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        precondition(condition(), "Timed out waiting for refresh")
    }
    @MainActor static func main() throws {
        var historyDone = false
        Task {
            do { try await checkHistory(); historyDone = true }
            catch { fatalError("History checks failed: \(error)") }
        }
        pump(until: { historyDone }, timeout: 15)
        let suite = "DiskFree.Checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        precondition(prefs.refreshInterval == 60 && !prefs.showPrefix && prefs.warningThresholdGB == 20)
        for interval in Preferences.intervals {
            prefs.refreshInterval = interval
            precondition(Preferences(defaults: defaults).refreshInterval == interval)
        }
        prefs.showPrefix = true
        prefs.warningThresholdGB = 40
        let restored = Preferences(defaults: defaults)
        precondition(restored.showPrefix && restored.warningThresholdGB == 40)
        prefs.refreshInterval = 0
        precondition(prefs.refreshInterval == 60)
        prefs.warningThresholdGB = .nan
        precondition(prefs.warningThresholdGB == 20)
        precondition(SpaceLevel.classify(freeBytes: 21_000_000_000, thresholdGB: 20) == .good)
        precondition(SpaceLevel.classify(freeBytes: 20_000_000_000, thresholdGB: 20) == .warning)
        precondition(SpaceLevel.classify(freeBytes: 10_000_000_000, thresholdGB: 20) == .low)
        precondition(SpaceLevel.classify(freeBytes: 5_000_000_000, thresholdGB: 20) == .danger)
        precondition(CapacityFormat.string(387_500_000_000) == "387.5 GB")
        precondition(CapacityFormat.string(1_500_000_000_000) == "1.50 TB")
        let disk = try DiskStatisticsProvider().collect()
        precondition(disk.totalBytes > 0 && disk.freeBytes >= 0 && disk.freeBytes <= disk.totalBytes)
        precondition(disk.usedBytes + disk.freeBytes == disk.totalBytes)
        print("Live disk: \(disk.path) total=\(disk.totalBytes) free=\(disk.freeBytes) used=\(disk.usedBytes)")
        do {
            _ = try DiskStatisticsProvider(volumeURL: URL(fileURLWithPath: "/nonexistent-DiskFree-test")).collect()
            preconditionFailure("Invalid volume must fail")
        } catch { print("Invalid volume error handled") }
        let probe = Probe()
        prefs.refreshInterval = 15
        let loggingRoot = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-Monitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: loggingRoot) }
        let monitorStore = HistoryStore(directory: loggingRoot)
        let monitor = DiskMonitor(preferences: prefs, historyStore: monitorStore, collect: { try probe.collect() })
        pump(until: { monitor.snapshot != nil && !monitor.isRefreshing })
        precondition(probe.count == 1)
        monitor.refresh(); monitor.refresh()
        pump(until: { !monitor.isRefreshing })
        precondition(probe.count == 2, "Overlapping refresh must be skipped")
        probe.fail(true)
        monitor.refresh()
        pump(until: { !monitor.isRefreshing })
        precondition(monitor.errorMessage != nil && monitor.snapshot != nil)
        probe.fail(false)
        monitor.refresh()
        pump(until: { !monitor.isRefreshing })
        precondition(monitor.errorMessage == nil)
        prefs.refreshInterval = 300
        prefs.refreshInterval = 15
        let before = probe.count
        pump(until: { probe.count > before && !monitor.isRefreshing }, timeout: 18)
        precondition(probe.count == before + 1, "Only one refresh timer may be active")
        var loggingDone = false
        Task {
            let logged = try! await monitorStore.load(from: Date().addingTimeInterval(-120), through: Date(), bucketSeconds: 60)
            precondition(logged.sampleCount == 4, "Only successful refreshes should be logged")
            precondition(monitor.historyError == nil)
            loggingDone = true
        }
        pump(until: { loggingDone })
        print("PASS: monitor history integration")
        print("PASS: capacity, formatting, thresholds, persistence, interval changes, automatic/manual refresh, overlap protection, failure and recovery")
    }

    static func checkHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-History-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HistoryStore(directory: root)
        let iso = ISO8601DateFormatter()
        func date(_ text: String) -> Date { iso.date(from: text)! }
        func disk(_ date: Date, _ free: Int64) -> DiskSnapshot {
            DiskSnapshot(name: "Test", path: "/", freeBytes: free, totalBytes: 100_000_000_000,
                         reclaimableEstimateBytes: nil, refreshedAt: date)
        }
        let start = date("2025-10-10T12:00:00Z")
        try await store.append(disk(date("2025-09-30T23:59:59Z"), 10_000_000_000))
        try await store.append(disk(start.addingTimeInterval(-1), 11_000_000_000))
        try await store.append(disk(start, 20_000_000_000))
        try await store.append(disk(start.addingTimeInterval(15), 5_000_000_000))
        try await store.append(disk(start.addingTimeInterval(30), 30_000_000_000))
        try await store.append(disk(start.addingTimeInterval(180), 40_000_000_000))
        try await store.append(disk(date("2026-01-01T00:00:00Z"), 50_000_000_000))
        let reopened = HistoryStore(directory: root)
        let range = try await reopened.load(from: start, through: start.addingTimeInterval(240), bucketSeconds: 60)
        precondition(range.sampleCount == 4 && range.points.count == 2)
        precondition(range.points[0].minGB == 5 && range.points[0].maxGB == 30 && range.points[0].lastGB == 30)
        precondition(range.points[1].date.timeIntervalSince(range.points[0].date) == 180, "Must preserve sampling gaps")
        let coarse = try await reopened.load(from: start, through: start.addingTimeInterval(240), bucketSeconds: 600)
        precondition(coarse.points.count == 1 && coarse.points[0].minGB == 5 && coarse.points[0].maxGB == 40)
        let monthly = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(Set(monthly) == Set(["2025-09.csv", "2025-10.csv", "2026-01.csv"]))
        let removed = try await reopened.removeSamples(olderThan: start)
        precondition(removed == 2)
        precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("2025-09.csv").path))
        let remaining = try await reopened.load(from: start, through: date("2026-12-31T00:00:00Z"), bucketSeconds: 60)
        precondition(remaining.sampleCount == 5, "Cutoff sample and all newer samples must survive")
        let removedAgain = try await reopened.removeSamples(olderThan: start)
        precondition(removedAgain == 0)
        let currentFile = root.appendingPathComponent("2025-10.csv")
        let handle = try FileHandle(forWritingTo: currentFile)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("broken,partial".utf8)); try handle.close()
        try await reopened.append(disk(start.addingTimeInterval(240), 45_000_000_000))
        let recovered = try await reopened.load(from: start, through: start.addingTimeInterval(300), bucketSeconds: 60)
        precondition(recovered.sampleCount == 5 && recovered.skippedLines == 1)
        let before = try Data(contentsOf: currentFile)
        do {
            _ = try await reopened.removeSamples(olderThan: date("2026-01-01T00:00:00Z"))
            preconditionFailure("Cleanup must preserve malformed files")
        } catch { let after = try Data(contentsOf: currentFile); precondition(after == before) }
        let unrelated = root.appendingPathComponent("keep-me.txt")
        try Data("keep".utf8).write(to: unrelated)
        precondition(FileManager.default.fileExists(atPath: unrelated.path))
        let blocked = root.appendingPathComponent("not-a-directory")
        try Data().write(to: blocked)
        do {
            try await HistoryStore(directory: blocked).append(disk(start, 1))
            preconditionFailure("Expected a write failure")
        } catch { print("History write failure handled") }
        print("PASS: monthly rollover, durable reopen, exact cutoff cleanup, aggregation/extrema, gaps, malformed tail recovery and preservation, write errors")
    }
}
