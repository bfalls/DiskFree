import Foundation
import Darwin

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
    @MainActor static func pump(until condition: () -> Bool, timeout: TimeInterval = 10, line: UInt = #line) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        precondition(condition(), "Timed out waiting for refresh at line \(line)")
    }
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "DiskFree validation")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        if CommandLine.arguments.contains("--history-reuse-diagnostics") { try await diagnoseHistoryReuse(); return }
        if CommandLine.arguments.contains("--history-reuse-only") { try await checkHistoryReuse(); return }
        if CommandLine.arguments.contains("--history-loading-only") { try await checkHistoryLoading(); return }
        if CommandLine.arguments.contains("--leftovers-only") { try await checkAppLeftovers(); return }
        if CommandLine.arguments.contains("--file-suspects-only") { try await checkFileSuspects(); return }
        if CommandLine.arguments.contains("--space-only") { try await checkSpaceChanges(); return }
        if CommandLine.arguments.contains("--backup-logs-only") { try await checkBackupLogs(); return }
        checkConsumerPreferences()
        try checkSystemHistory()
        try checkDockerProvider()
        try checkGrowth()
        try await checkGrowthMonitor()
        try await checkBackupActivityMonitor()
        try await checkStorageComposition(); try await checkHistory(); try await checkDockerHistory()
        try await checkBackupHistory(); try await checkBackupLogs(); try await checkSpaceChanges(); try await checkFileSuspects(); try await checkAppLeftovers(); try await checkHistoryLoading(); try await checkHistoryReuse()
        let suite = "DiskFree.Checks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        precondition(prefs.refreshInterval == 60 && !prefs.showPrefix && prefs.warningThresholdGB == 20 && !prefs.trackGrowth)
        prefs.trackGrowth = true
        prefs.growthFolders = [GrowthFolder(id: "test", name: "Test", path: "/tmp/test")]
        let growthPreferences = Preferences(defaults: defaults)
        precondition(growthPreferences.trackGrowth && growthPreferences.growthFolders.count == 1)
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
        let dockerProbe = DockerProbe()
        let monitor = DiskMonitor(preferences: prefs, historyStore: monitorStore, observePower: false, collectVitals: { SystemVitals(allocated: 1_073_741_824, used: 536_870_912, pressure: .warning) }, collect: { try probe.collect() }, collectDocker: { dockerProbe.collect() })
        await pump(until: { monitor.snapshot != nil && !monitor.isRefreshing })
        precondition(probe.count == 1)
        monitor.refresh(); monitor.refresh()
        await pump(until: { !monitor.isRefreshing })
        precondition(probe.count == 2, "Overlapping refresh must be skipped")
        dockerProbe.fail(true)
        monitor.refresh()
        await pump(until: { !monitor.isRefreshing })
        precondition(monitor.errorMessage == nil && monitor.dockerReading.snapshot == nil,
                     "Docker metadata failure must not fail the disk refresh")
        dockerProbe.fail(false)
        probe.fail(true)
        monitor.refresh()
        await pump(until: { !monitor.isRefreshing })
        precondition(monitor.errorMessage != nil && monitor.snapshot != nil)
        probe.fail(false)
        monitor.refresh()
        await pump(until: { !monitor.isRefreshing })
        precondition(monitor.errorMessage == nil)
        prefs.refreshInterval = 300
        prefs.refreshInterval = 15
        let before = probe.count
        await pump(until: { probe.count > before && !monitor.isRefreshing }, timeout: 18)
        precondition(probe.count == before + 1, "Only one refresh timer may be active")
        var loggingDone = false
        Task {
            let logged = try! await monitorStore.load(from: Date().addingTimeInterval(-120), through: Date(), bucketSeconds: 60)
            precondition(logged.sampleCount == 5, "Only successful refreshes should be logged")
            precondition(monitor.historyError == nil && monitor.dockerHistoryError == nil)
            let docker = try! await monitorStore.docker.load(from: Date().addingTimeInterval(-120), through: Date(), bucketSeconds: 60)
            precondition(docker.sampleCount == 5, "Docker must keep recording even when the free-space read fails")
            let systemStore = monitorStore.system
            let system = try! await Task.detached { try systemStore.load(from: Date().addingTimeInterval(-120), through: Date(), bucketSeconds: 60) }.value
            precondition(!system.points.isEmpty && system.points.last?.record.pressure == .warning)
            precondition(system.points.last?.record.allocated == 1_073_741_824 && monitor.systemHistoryError == nil)
            loggingDone = true
        }
        await pump(until: { loggingDone })
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

    @MainActor static func checkGrowthMonitor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-GrowthMonitor-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("test"))
        let suite = "DiskFree.GrowthMonitor.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.growthPausedIDs = ["fixture"] // legacy budget failures must migrate automatically
        preferences.growthFolders = [GrowthFolder(id: "fixture", name: "Fixture", path: folder.path)]
        let monitor = GrowthMonitor(preferences: preferences, store: GrowthStore(directory: root.appendingPathComponent("cache")))
        await pump(until: { monitor.ready })
        precondition(monitor.archive.caches.isEmpty && !preferences.trackGrowth, "Opt-out must not scan")
        precondition(preferences.growthPausedIDs.isEmpty, "Legacy pauses must not prevent first-run collection")
        preferences.beginInvestigation()
        precondition(preferences.trackGrowth, "First opening Investigate starts collection without a recovery step")
        preferences.trackGrowth = true
        await pump(until: { monitor.archive.caches["fixture"] != nil && monitor.activeFolder == nil }, timeout: 10)
        precondition(monitor.archive.caches["fixture"]!.bytes >= 4096)
        monitor.checkNow()
        precondition(monitor.activeFolder == nil, "Manual check must respect cooldown")
        preferences.growthPausedIDs = ["fixture", "other-paused"]
        monitor.retry("fixture")
        precondition(preferences.growthPausedIDs == ["other-paused"], "Per-folder retry must leave other categories paused")
        precondition(monitor.activeFolder == nil, "Per-folder retry must respect cooldown")
        preferences.trackGrowth = false
        await pump(until: { monitor.status == "Folder tracking is off." })
        precondition(monitor.activeFolder == nil)
        preferences.beginInvestigation()
        precondition(!preferences.trackGrowth, "Reopening Investigate must respect an explicit pause")
        let saved = try GrowthStore(directory: root.appendingPathComponent("cache")).load()
        precondition(saved.readings.count == 1)
        try await checkGrowthStorageFailure()
        print("PASS: growth monitor opt-in/out, background baseline, cooldown and persistence integration")
    }
    @MainActor static func checkGrowthStorageFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-GrowthWrite-\(UUID().uuidString)")
        let folder = root.appendingPathComponent("files")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 1, count: 4096).write(to: folder.appendingPathComponent("test"))
        let blockedStore = root.appendingPathComponent("not-a-directory")
        try Data("occupied".utf8).write(to: blockedStore)
        let suite = "DiskFree.GrowthWrite.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.growthFolders = [GrowthFolder(id: "fixture", name: "Fixture", path: folder.path)]
        let monitor = GrowthMonitor(preferences: preferences, store: GrowthStore(directory: blockedStore))
        await pump(until: { monitor.ready })
        preferences.trackGrowth = true
        await pump(until: { monitor.archive.caches["fixture"] != nil && monitor.activeFolder == nil }, timeout: 10)
        precondition(monitor.errors["storage"] != nil && monitor.status.contains("Saving folder history needs attention"))
        precondition(!monitor.accessLimited.contains("fixture"), "A log write failure must not hide a valid folder measurement")
        preferences.trackGrowth = false
        await pump(until: { monitor.status == "Folder tracking is off." })
        print("PASS: folder-history write failure keeps useful sizes visible and reports the persistence issue once")
    }

    @MainActor static func checkBackupActivityMonitor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-BackupMonitor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let probe = BackupActivityProbe()
        let monitor = BackupActivityMonitor(store: BackupEventStore(directory: root), startTimer: false,
            status: { probe.status() }, measurements: { probe.values() })
        monitor.poll(uptime: 0)
        await pump(until: { monitor.lastCheckedAt != nil })
        precondition(probe.counts.0 == 1 && probe.counts.1 == 0)
        monitor.poll(uptime: 59)
        precondition(probe.counts.0 == 1, "Status checks must be throttled independently of the disk refresh interval")
        var last = monitor.lastCheckedAt
        probe.set(true); monitor.poll(uptime: 60); monitor.poll(uptime: 60)
        await pump(until: { monitor.lastCheckedAt != last })
        precondition(probe.counts.0 == 2 && probe.counts.1 == 1, "No overlapping status checks; metadata only while running")
        last = monitor.lastCheckedAt
        probe.set(false); monitor.poll(uptime: 120)
        await pump(until: { monitor.lastCheckedAt != last })
        precondition(probe.counts.1 == 2, "Capture a final endpoint when a stop is observed")
        let revision = monitor.revision
        last = monitor.lastCheckedAt
        monitor.poll(uptime: 180)
        await pump(until: { monitor.lastCheckedAt != last })
        precondition(monitor.revision == revision && probe.counts.1 == 2, "Repeated idle checks must not read extra disk metrics or write records")
        last = monitor.lastCheckedAt
        probe.set(nil); monitor.poll(uptime: 240)
        await pump(until: { monitor.lastCheckedAt != last })
        precondition(!monitor.statusAvailable && monitor.recordingError == nil)
        print("PASS: backup monitor one-minute throttling, overlap protection, active/stop-only metadata, idle write suppression and unavailable-status handling")
    }

}
