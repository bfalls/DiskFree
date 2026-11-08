import Foundation

func checkSystemHistory() throws {
    precondition(!GrowthWatcher.canWatch(GrowthFolder(id: "test", name: "VM", path: "/System/Volumes/VM")))
    precondition(GrowthWatcher.canWatch(GrowthFolder(id: "test", name: "Download", path: "/tmp/downloads")))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-SystemChecks-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = SystemHistoryStore(directory: root)
    let start = Date(timeIntervalSince1970: 1_790_800_000)
    let run = UUID().uuidString, boot = start.addingTimeInterval(-1000)
    func sample(_ seconds: Double, _ allocated: Int64, pressure: MemoryPressure = .normal, session: String? = nil) -> SystemRecord {
        SystemRecord(date: start.addingTimeInterval(seconds), kind: .sample, runID: session ?? run, boot: boot, interval: 60,
                     allocated: allocated, used: allocated / 2, pressure: pressure, free: 50_000_000_000 - allocated)
    }
    let sameDayStart = ISO8601DateFormatter().date(from: "2026-10-24T19:02:42Z")!
    let sameDayEnd = sameDayStart.addingTimeInterval(121)
    let localCalendar = Calendar.current
    let coalesced = ActivityEvent.timeRange(from: sameDayStart, through: sameDayEnd)
    precondition(coalesced == sameDayStart.formatted(date: .abbreviated, time: .standard) + " → " + sameDayEnd.formatted(date: .omitted, time: .standard))
    let nextDay = localCalendar.date(byAdding: .day, value: 1, to: sameDayStart)!
    precondition(ActivityEvent.timeRange(from: sameDayStart, through: nextDay) == sameDayStart.formatted(date: .abbreviated, time: .standard) + " → " + nextDay.formatted(date: .abbreviated, time: .standard))
    let first = sample(0, 1_073_741_824)
    let second = sample(60, 4_294_967_296, pressure: .warning)
    let unknown = SystemRecord(date: start, kind: .sample, runID: run, boot: boot, interval: 60)
    precondition(unknown.valid())
    precondition(SystemHistoryStore.events(previous: unknown, row: second).allSatisfy { $0.category != .swap }, "Unavailable swap is not zero")
    let changes = SystemHistoryStore.events(previous: first, row: second)
    precondition(changes.count == 2 && changes.contains { $0.category == .swap && $0.title.contains("grew") })
    precondition(changes.contains { $0.category == .memory && $0.detail.contains("kern.memorystatus") })
    precondition(SystemHistoryStore.events(previous: second, row: sample(120, 1_073_741_824)).contains { $0.title.contains("shrank") })
    precondition(SystemHistoryStore.events(previous: first, row: sample(600, 8_589_934_592)).isEmpty, "Don't compare across gaps")
    precondition(SystemHistoryStore.events(previous: first, row: sample(60, 8_589_934_592, session: UUID().uuidString)).isEmpty, "Don't compare across app runs")
    // Hide only small exact round trips; preserve significant or ambiguous evidence.
    let smallPeak = sample(60, 2_147_483_648)
    let recovered = sample(120, first.allocated!)
    let up = SystemHistoryStore.events(previous: first, row: smallPeak)
    let down = SystemHistoryStore.events(previous: smallPeak, row: recovered)
    precondition(ActivityEvent.removingSmallSwapReversals(up + down).isEmpty)
    precondition(up.count == 1 && down.count == 1, "Filtering must not mutate raw events")
    let netGrowth = sample(120, 3_221_225_472)
    precondition(ActivityEvent.removingSmallSwapReversals(up + SystemHistoryStore.events(previous: smallPeak, row: netGrowth)).count == 2)
    let largePeak = sample(60, 5_368_709_120)
    let largeCycle = SystemHistoryStore.events(previous: first, row: largePeak) + SystemHistoryStore.events(previous: largePeak, row: recovered)
    precondition(ActivityEvent.removingSmallSwapReversals(largeCycle).count == 2, "Large recovered excursions remain diagnostic")
    let pressureCycle = changes + SystemHistoryStore.events(previous: second, row: recovered)
    precondition(ActivityEvent.removingSmallSwapReversals(pressureCycle).count == pressureCycle.count)
    let warningPeak = sample(60, 2_147_483_648, pressure: .warning)
    let warningCycle = SystemHistoryStore.events(previous: first, row: warningPeak) + SystemHistoryStore.events(previous: warningPeak, row: recovered)
    precondition(ActivityEvent.removingSmallSwapReversals(warningCycle).count == warningCycle.count)
    var differentSample = smallPeak; differentSample.id = UUID().uuidString
    let discontinuous = up + SystemHistoryStore.events(previous: differentSample, row: recovered)
    precondition(ActivityEvent.removingSmallSwapReversals(discontinuous).count == 2, "Never bridge missing sample evidence")
    let slowPeak = sample(240, 2_147_483_648)
    let slowRecovery = sample(480, first.allocated!)
    let slowCycle = [ActivityEvent(id: "slowUp", date: slowPeak.date, category: .swap, title: "up", detail: "", records: [first, slowPeak]),
                     ActivityEvent(id: "slowDown", date: slowRecovery.date, category: .swap, title: "down", detail: "", records: [slowPeak, slowRecovery])]
    precondition(ActivityEvent.removingSmallSwapReversals(slowCycle).count == 2)
    let lifecycle = ActivityEvent(id: "sleep", date: start.addingTimeInterval(90), category: .power, title: "sleep", detail: "", records: [])
    precondition(ActivityEvent.removingSmallSwapReversals(up + [lifecycle] + down).count == 3)
    var otherRun = recovered; otherRun.runID = UUID().uuidString
    let crossing = up + [ActivityEvent(id: "crossing", date: otherRun.date, category: .swap, title: "down", detail: "", records: [smallPeak, otherRun])]
    precondition(ActivityEvent.removingSmallSwapReversals(crossing).count == 2)
    try store.append(first); try store.append(second)
    try store.append(SystemRecord(date: start.addingTimeInterval(70), kind: .sleep, runID: run, boot: boot))
    try store.append(SystemRecord(date: start.addingTimeInterval(3670), kind: .wake, runID: run, boot: boot))
    var loaded = try store.load(from: start, through: start.addingTimeInterval(4000), bucketSeconds: 60)
    precondition(loaded.points.count == 2 && loaded.events.contains { $0.end != nil && $0.title.contains("1h") })
    let spanning = try store.load(from: start.addingTimeInterval(100), through: start.addingTimeInterval(4000), bucketSeconds: 60)
    precondition(spanning.events.contains { $0.end != nil }, "Sleep spanning range start must remain visible")
    let pressureStore = SystemHistoryStore(directory: root.appendingPathComponent("pressure"))
    try pressureStore.append(second)
    try pressureStore.append(sample(90, 4_294_967_296))
    let pressureSummary = try pressureStore.load(from: start, through: start.addingTimeInterval(120), bucketSeconds: 120)
    precondition(pressureSummary.points.first?.record.pressure == .normal)
    precondition(pressureSummary.points.first?.maximumPressure == .warning && pressureSummary.points.first?.pressureRecord.pressure == .warning)
    // Restart without a matching wake must not invent a sleep span.
    let other = SystemHistoryStore(directory: root.appendingPathComponent("other"))
    try other.append(SystemRecord(date: start, kind: .sleep, runID: run, boot: boot))
    try other.append(SystemRecord(date: start.addingTimeInterval(600), kind: .appStart, runID: UUID().uuidString, boot: boot))
    let otherLoaded = try other.load(from: start, through: start.addingTimeInterval(1000), bucketSeconds: 60)
    precondition(otherLoaded.events.allSatisfy { !$0.title.hasPrefix("Mac sleep ·") })
    // Monthly boundaries, precise cutoff cleanup, and malformed data preservation.
    let month = ISO8601DateFormatter().date(from: "2026-09-30T23:59:40Z")!
    let monthly = SystemHistoryStore(directory: root.appendingPathComponent("monthly"))
    var before = first; before.date = month
    var after = second; after.date = month.addingTimeInterval(60)
    try monthly.append(before); try monthly.append(after)
    loaded = try monthly.load(from: month, through: month.addingTimeInterval(120), bucketSeconds: 60)
    precondition(loaded.points.count == 2)
    let removed = try monthly.removeSamples(olderThan: month.addingTimeInterval(1))
    precondition(removed == 1)
    let remaining = try monthly.load(from: month, through: month.addingTimeInterval(120), bucketSeconds: 60)
    precondition(remaining.points.count == 1)
    let file = monthly.source(for: after.date)
    let handle = try FileHandle(forWritingTo: file); try handle.seekToEnd(); try handle.write(contentsOf: Data("bad row\n".utf8)); try handle.close()
    do { _ = try monthly.removeSamples(olderThan: month.addingTimeInterval(200)); preconditionFailure("Malformed data must be preserved") }
    catch { precondition(FileManager.default.fileExists(atPath: file.path)) }
    let suite = "DiskFree.SwapMigration." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(try JSONEncoder().encode([GrowthFolder(id: "swap", name: "Swap and sleep files", path: "/private/var/vm")]), forKey: "growthFolders")
    let preferences = Preferences(defaults: defaults)
    precondition(preferences.growthFolders.first?.id == "swap-vm")
    precondition(preferences.growthFolders.first?.path == GrowthFolder.swapFolder.path)
    precondition(Preferences(defaults: defaults).growthFolders == preferences.growthFolders)
    print("System history: swap/pressure deltas, gaps, sessions, sleep spans, month rollover, cleanup and migration passed.")
}
