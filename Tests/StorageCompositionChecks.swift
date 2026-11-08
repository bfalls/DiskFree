import Foundation

func checkStorageComposition() async throws {
    let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/checks/Composition-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gb: Int64 = 1_000_000_000, date = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
    func measurement(_ id: String, _ path: String, _ bytes: Int64, excluded: [String] = [], at: Date? = nil) -> ConsumerMeasurement {
        ConsumerMeasurement(date: date, folderID: id, name: id, root: path, bytes: bytes, measuredAt: at ?? date, exclusions: excluded, skipped: 0, coverage: "0")
    }
    let model = measurement("consumer.ai.ollama", "/Users/test/.ollama/models", 4 * gb)
    let native = SystemRecord(date: date, kind: .sample, runID: UUID().uuidString, interval: 60, allocated: 2 * gb, used: gb, pressure: .normal, free: 970 * gb, docker: 10 * gb, dockerSource: String(repeating: "a", count: 64), dockerPath: "/Users/test/docker/Docker.raw", reclaimable: 5 * gb)
    let frame = StorageFrame.make(date: date, total: 1000 * gb, free: 970 * gb, measurements: [model], native: native)
    precondition(frame.used == 30 * gb && frame.tracked == 16 * gb)
    precondition(frame.portions.reduce(0, { $0 + $1.bytes }) == 1000 * gb)
    precondition(frame.portions.first(where: { $0.kind == .other })?.bytes == 14 * gb)
    let parent = measurement("parent", "/Users/test", 20 * gb)
    let nested = StorageFrame.make(date: date, total: 100 * gb, free: 50 * gb, measurements: [parent, model], native: nil)
    precondition(nested.omitted == 1 && nested.tracked == 4 * gb)
    let exclusive = measurement("parent", "/Users/test", 20 * gb, excluded: [model.root])
    precondition(StorageFrame.make(date: date, total: 100 * gb, free: 50 * gb, measurements: [exclusive, model], native: nil).tracked == 24 * gb)
    let duplicated = measurement("duplicate", model.root, 4 * gb)
    precondition(StorageFrame.make(date: date, total: 100 * gb, free: 50 * gb, measurements: [model, duplicated], native: nil).tracked == 4 * gb)
    let excess = StorageFrame.make(date: date, total: 100 * gb, free: 99 * gb, measurements: [model], native: native)
    precondition(excess.overlap && excess.tracked > excess.used && excess.portions.reduce(0, { $0 + $1.bytes }) == 100 * gb)
    let stale = measurement("stale", "/stale", gb, at: date.addingTimeInterval(-172801))
    precondition(StorageFrame.make(date: date, total: 100 * gb, free: 50 * gb, measurements: [stale], native: nil).tracked == 0)
    let candidates = StorageDiscovery.candidates(home: "/Users/test", environment: ["OLLAMA_MODELS": "/custom/ollama", "HF_HOME": "/custom/hf"])
    precondition(candidates.first(where: { $0.id == "consumer.ai.ollama" })?.path == "/custom/ollama")
    precondition(candidates.first(where: { $0.id == "consumer.ai.huggingface" })?.path == "/custom/hf/hub")
    precondition(StorageDiscovery.startupDirectory(root.path))
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    precondition(!StorageDiscovery.startupDirectory(link.path))
    let folder = GrowthFolder(id: "consumer.ai.test", name: "Test models", path: root.path)
    func archive(_ time: Date, _ bytes: Int64, coverage: String = "0") -> GrowthArchive {
        GrowthArchive(caches: [folder.id: FolderCache(root: root.path, nodes: [root.path: DirectorySize(bytes: bytes, children: [])], measuredAt: time, coverageID: coverage)])
    }
    let store = ConsumerHistoryStore(directory: root.appendingPathComponent("history"))
    try await store.sync(folders: [folder], archive: archive(date, gb), at: date)
    try await store.sync(folders: [folder], archive: archive(date.addingTimeInterval(60), 3 * gb), at: date.addingTimeInterval(60))
    let points = [0.0, 30, 60, 90, 120].map { seconds -> HistoryPoint in
        let t = date.addingTimeInterval(seconds)
        return HistoryPoint(date: t, lastDate: t, lastGB: 50, minGB: 50, maxGB: 50, samples: 1, totalBytes: 100 * gb, freeBytes: 50 * gb)
    }
    var timeline = try await store.timeline(points: points, system: [], bucket: 30)
    precondition(timeline.frames[0].tracked == gb && timeline.frames[1].tracked == gb && timeline.frames[2].tracked == 3 * gb)
    precondition(timeline.events.count == 1 && timeline.events[0].title.contains("grew"))
    try await store.sync(folders: [folder], archive: archive(date.addingTimeInterval(90), 5 * gb, coverage: "changed"), at: date.addingTimeInterval(90))
    timeline = try await store.timeline(points: points, system: [], bucket: 30)
    precondition(timeline.events.last?.title.contains("coverage updated") == true)
    try await store.sync(folders: [], archive: GrowthArchive(), at: date.addingTimeInterval(120))
    timeline = try await store.timeline(points: points, system: [], bucket: 30)
    precondition(timeline.frames.last?.tracked == 0)
    let removed = try await store.removeSamples(olderThan: date.addingTimeInterval(1))
    precondition(removed == 1)
    let file = store.source(for: date), handle = try FileHandle(forWritingTo: store.source(for: date))
    try handle.seekToEnd(); try handle.write(contentsOf: Data("invalid\n".utf8)); try handle.close()
    do { _ = try await store.removeSamples(olderThan: date.addingTimeInterval(200)); preconditionFailure("Preserve invalid rows") } catch { precondition(FileManager.default.fileExists(atPath: file.path)) }
    // Reproduce 15-second stress-test history: JSON rounds timestamps down to
    // seconds while disk/Docker CSV retains milliseconds. Fractional chart ranges
    // must never make native consumers disappear from alternate minute buckets.
    let alignmentStore = HistoryStore(directory: root.appendingPathComponent("alignment"))
    let alignmentConsumers = ConsumerHistoryStore(directory: root.appendingPathComponent("alignment-consumers"))
    let session = UUID().uuidString
    let base = Date(timeIntervalSince1970: 1_790_800_000)
    for index in 0...16 {
        let stamp = base.addingTimeInterval(Double(index * 15) + 0.7)
        let free = (70 - Int64(index)) * gb
        try await alignmentStore.append(DiskSnapshot(name: "Test", path: "/", freeBytes: free, totalBytes: 100 * gb, reclaimableEstimateBytes: nil, refreshedAt: stamp))
        try alignmentStore.system.append(SystemRecord(date: stamp, kind: .sample, runID: session, interval: 15,
            allocated: Int64(index + 1) * gb, used: Int64(index) * gb, pressure: index >= 14 ? .critical : index >= 10 ? .warning : .normal,
            free: free, docker: 10 * gb, dockerPath: "/test/Docker.raw"))
    }
    for fraction in [0.1, 0.5, 0.9] {
        let from = base.addingTimeInterval(fraction), through = base.addingTimeInterval(241)
        let disks = try await alignmentStore.load(from: from, through: through, bucketSeconds: 60)
        let systems = try alignmentStore.system.load(from: from, through: through, bucketSeconds: 60)
        let aligned = try await alignmentConsumers.timeline(points: disks.points, system: systems.points, bucket: 60)
        precondition(aligned.frames.count == 5)
        for frame in aligned.frames {
            precondition(frame.native != nil, "Fractional query boundaries must not drop fresh native readings")
            precondition(frame.native?.free == frame.free, "Native readings must match the disk sample in the same minute")
            precondition(frame.portions.contains { $0.kind == .docker } && frame.portions.contains { $0.kind == .swap })
        }
    }
    let complete = try await Task.detached(priority: .utility) {
        try await HistoryPage.load(store: alignmentStore,
            key: HistoryPageKey(start: base.addingTimeInterval(0.5), end: base.addingTimeInterval(241), bucket: 60))
    }.value
    let diskCount = complete.disk?.points.count ?? 0
    let systemCount = complete.system?.points.count ?? 0
    let storageCount = complete.storage?.frames.count ?? 0
    guard diskCount == 5, systemCount == 5, storageCount == 5 else { throw CocoaError(.fileReadCorruptFile) }
    for frame in complete.storage?.frames ?? [] {
        guard frame.native != nil else { throw CocoaError(.fileReadCorruptFile) }
    }
    try await checkHistoryPageCache()
    print("PASS: composition totals, 1 TB scaling, overlap/stale safeguards, discovery overrides/symlinks, sparse history, coverage events, retirements and retention")
}

@MainActor func checkConsumerPreferences() {
    let suite = "DiskFree.Discovery." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let prefs = Preferences(defaults: defaults)
    precondition(prefs.autoDiscoverConsumers && !prefs.trackGrowth)
    prefs.growthFolders = [GrowthFolder(id: "consumer.ai.ollama", name: "Models", path: "/test/models")]
    prefs.growthFolders = []
    prefs.autoDiscoverConsumers = false
    let restored = Preferences(defaults: defaults)
    precondition(!restored.autoDiscoverConsumers && restored.suppressedConsumerIDs.contains("consumer.ai.ollama"))
    print("PASS: discovery opt-out and explicitly removed discoveries survive restart")
}

private actor PageReadProbe {
    private(set) var count = 0
    private(set) var active = 0
    private(set) var peak = 0
    func read(_ key: HistoryPageKey) async throws -> HistoryPage {
        count += 1; active += 1; peak = max(peak, active)
        defer { active -= 1 }
        try await Task.sleep(nanoseconds: 30_000_000)
        return HistoryPage(key: key)
    }
}
private func checkHistoryPageCache() async throws {
    let probe = PageReadProbe()
    let cache = HistoryPageCache(capacity: 2, loader: { try await probe.read($0) })
    @Sendable func key(_ index: Int) -> HistoryPageKey {
        HistoryPageKey(start: Date(timeIntervalSince1970: Double(index * 3600)),
                       end: Date(timeIntervalSince1970: Double((index + 1) * 3600)), bucket: 60)
    }
    _ = try await cache.page(key(0)); _ = try await cache.page(key(0))
    let initialReads = await probe.count
    precondition(initialReads == 1, "Cached redraws must not reread logs")
    async let first = cache.page(key(1))
    async let duplicate = cache.page(key(1))
    _ = try await (first, duplicate)
    let sharedReads = await probe.count
    precondition(sharedReads == 2, "Concurrent requests for a page must share one read")
    _ = try await cache.page(key(0)) // touch 0 so 1 becomes the LRU
    _ = try await cache.page(key(2)); _ = try await cache.page(key(1))
    let evictedReads = await probe.count
    precondition(evictedReads == 4, "Cache must evict the least recently used page")
    await cache.clear()
    _ = try await cache.page(key(1))
    let freshReads = await probe.count
    precondition(freshReads == 5, "Explicit refresh/cleanup must invalidate cached data")
    let obsolete = Task { try await cache.page(key(8)) }
    try await Task.sleep(nanoseconds: 5_000_000)
    await cache.clear()
    do { _ = try await obsolete.value; preconditionFailure("Invalidated in-flight pages must not publish") }
    catch is CancellationError {} // expected
    try await withThrowingTaskGroup(of: Void.self) { group in
        for index in 10...19 { group.addTask { _ = try await cache.page(key(index)) } }
        try await group.waitForAll()
    }
    let peak = await probe.peak
    precondition(peak <= 3, "Rapid navigation must not launch unbounded log readers")
    print("PASS: complete history pages, cache hits, shared reads, LRU bound, invalidation/cancellation and bounded rapid navigation")
}
