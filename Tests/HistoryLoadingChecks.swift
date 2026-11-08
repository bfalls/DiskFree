import Foundation

private final class HistoryProgressProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var updates: [HistoryLoadStatus] = []
    func add(_ status: HistoryLoadStatus) { lock.lock(); updates.append(status); lock.unlock() }
    var values: [HistoryLoadStatus] { lock.lock(); defer { lock.unlock() }; return updates }
}
private actor LoadingReadProbe {
    private(set) var count = 0
    let file: URL
    init(file: URL) { self.file = file }
    func read(_ key: HistoryPageKey) async throws -> HistoryPage {
        count += 1
        let context = HistoryReadContext.current
        context?.stage("Reading fixture", source: 1, files: [file])
        try await Task.sleep(nanoseconds: 60_000_000)
        context?.processed(131072)
        return HistoryPage(key: key)
    }
}
private func historyProgressFixture() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-loading-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let file = root.appendingPathComponent("2026-10.csv")
    let data = String(repeating: "test\n", count: 30000)
    try Data(data.utf8).write(to: file)
    let recorder = HistoryReadContext(), probe = HistoryProgressProbe()
    let id = recorder.subscribe { probe.add($0) }
    recorder.stage("Reading fixture", source: 1, files: [file])
    var rows = 0
    try HistoryReadContext.$current.withValue(recorder) { try HistoryStore.forEachLine(in: file) { _ in rows += 1 } }
    let values = probe.values.filter { $0.source == 1 }
    precondition(rows == 30000 && values.last?.totalBytes == Int64(data.utf8.count) && values.last?.completedBytes == Int64(data.utf8.count))
    precondition(values.last?.fraction == 1)
    precondition(zip(values, values.dropFirst()).allSatisfy { $0.completedBytes <= $1.completedBytes })
    recorder.unsubscribe(id)
    let count = probe.values.count; recorder.processed(1)
    precondition(probe.values.count == count)
    print("PASS: known file-size progress counts processed bytes, reaches completion monotonically and detaches observers")
    return root
}
@MainActor func checkHistoryLoading() async throws {
    let root = try historyProgressFixture()
    let expected = StorageFrame.make(date: Date(), total: 100, free: 10, measurements: [], native: nil)
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = LoadingReadProbe(file: root.appendingPathComponent("2026-10.csv"))
    let cache = HistoryPageCache(capacity: 12, estimatedBudget: 4096, loader: { try await probe.read($0) })
    let key0 = HistoryPageKey(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), bucket: 60)
    let key1 = HistoryPageKey(start: Date(timeIntervalSince1970: 3600), end: Date(timeIntervalSince1970: 7200), bucket: 60)
    _ = try await cache.page(key0)
    await cache.cancelPending()
    _ = try await cache.page(key0)
    let preserved = await probe.count; precondition(preserved == 1, "Closing the view must keep completed cached pages")
    _ = try await cache.page(key1); _ = try await cache.page(key0)
    let budgetReads = await probe.count; precondition(budgetReads == 3, "Memory budget must evict pages even below the count limit")
    await cache.clear()
    let warm = Task { try await cache.page(key0) }
    try await Task.sleep(nanoseconds: 5_000_000)
    let updates = HistoryProgressProbe()
    _ = try await cache.page(key0) { updates.add($0) }
    _ = try await warm.value
    let shared = await probe.count; precondition(shared == 4)
    precondition(updates.values.contains { $0.source == 1 }, "A foreground request must see progress from an in-flight prefetch")
    print("PASS: cached pages survive view close, estimated memory budget, shared prefetch progress and request coalescing")

    let store = HistoryStore(directory: root.appendingPathComponent("history"))
    let date = Date()
    try await store.append(DiskSnapshot(name: "fixture", path: "/", freeBytes: 10, totalBytes: 100, reclaimableEstimateBytes: nil, refreshedAt: date))
    let actual = HistoryPageCache(store: store)
    let stages = HistoryProgressProbe()
    let key = HistoryPageKey(start: date.addingTimeInterval(-60), end: date.addingTimeInterval(60), bucket: 60)
    let page = try await actual.page(key) { stages.add($0) }
    precondition(page.disk?.sampleCount == 1 && page.diskError == nil)
    precondition(page.storage?.frames.first?.free == expected.free)
    precondition(Set(stages.values.map(\.source)).isSuperset(of: [1,2,3,4,5]))
    precondition(stages.values.contains { $0.source == 1 && $0.fraction == 1 })
    print("PASS: actual complete-page loader publishes all source stages and real journal-byte progress")
}
