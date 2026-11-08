import Foundation

private func journalCacheFixtures(_ root: URL) throws {
    let file = root.appendingPathComponent("numbers.csv")
    let cache = ParsedHistoryJournalCache(budget: 16384)
    func read() throws -> [Int] {
        var values: [Int] = []
        try cache.forEach(in: file, entryCost: 32, parse: { text -> ParsedHistoryLine<Int>? in
            Int(text).map { .value($0) } ?? .invalid
        }) { if case let .value(value) = $0 { values.append(value) } else { values.append(-1) } }
        return values
    }
    func append(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: file); defer { try? handle.close() }
        try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8))
    }
    try Data("1\n2\n".utf8).write(to: file)
    let first = try read(); precondition(first == [1,2])
    let before = cache.statistics
    let second = try read(); precondition(second == first)
    precondition(cache.statistics.bytesRead == before.bytesRead && cache.statistics.decoded == before.decoded)
    try append("3\n")
    let appended = try read(); precondition(appended == [1,2,3])
    precondition(cache.statistics.decoded - before.decoded == 1, "Only the appended line is decoded")
    try Data("8\n9\n10\n11\n".utf8).write(to: file)
    let rewritten = try read(); precondition(rewritten == [8,9,10,11], "Larger rewrite cannot be mistaken for append")
    try Data("7\n6\n".utf8).write(to: file, options: .atomic)
    let replaced = try read(); precondition(replaced == [7,6])
    try Data("1\n2".utf8).write(to: file, options: .atomic)
    let partial = try read(); precondition(partial == [1,-1])
    try append("\n3\n")
    let recovered = try read(); precondition(recovered == [1,2,3], "Partial final lines must be reparsed when completed")
    let tiny = ParsedHistoryJournalCache(budget: 1)
    var count = 0
    try tiny.forEach(in: file, entryCost: 32, parse: { text -> ParsedHistoryLine<Int>? in Int(text).map { .value($0) } }) { _ in count += 1 }
    precondition(count == 3 && tiny.statistics.retainedBytes == 0, "An oversized journal streams without unbounded retention")
    precondition(cache.statistics.retainedBytes <= 16384)
    print("PASS: unchanged journals use no disk reads/decoding; append-only tails, rewrite/replacement detection, partial-write recovery and bounded streaming")
}
private func reuseFixture() throws -> (URL, Date, String) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-reuse-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try journalCacheFixtures(root)
    let history = root.appendingPathComponent("history")
    try FileManager.default.createDirectory(at: history.appendingPathComponent("Docker"), withIntermediateDirectories: true)
    let end = Date(timeIntervalSince1970: 1793376000), run = UUID().uuidString
    let format = ISO8601DateFormatter(); format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let month = String(format.string(from: end).prefix(7))
    var disk = HistoryStore.header, docker = DockerHistoryStore.header
    let system = SystemHistoryStore(directory: history.appendingPathComponent("System"))
    for index in 1...360 {
        let date = end.addingTimeInterval(Double(index - 360) * 60)
        disk += format.string(from: date) + ",80000000000,500000000000\n"
        docker += format.string(from: date) + ",38000000000," + String(repeating: "a", count: 64) + ",available\n"
        try system.append(SystemRecord(date: date, kind: .sample, runID: run, boot: end.addingTimeInterval(-86400), interval: 60,
            allocated: 2_000_000_000, used: 1_000_000_000, pressure: index < 330 ? .normal : .warning, free: 80_000_000_000,
            docker: 38_000_000_000, dockerSource: String(repeating: "a", count: 64), dockerPath: "/fixture/Docker.raw"))
    }
    let systemFile = system.source(for: end)
    let data = try Data(contentsOf: systemFile)
    var prefixed = Data("invalid legacy row\n".utf8); prefixed.append(data)
    try prefixed.write(to: systemFile, options: .atomic)
    try Data(disk.utf8).write(to: history.appendingPathComponent(month + ".csv"))
    try Data(docker.utf8).write(to: history.appendingPathComponent("Docker/" + month + ".csv"))
    return (root, end, run)
}
@MainActor func checkHistoryReuse() async throws {
    let (root, end, run) = try reuseFixture()
    defer { try? FileManager.default.removeItem(at: root) }
    ParsedHistoryJournalCache.shared.clear()
    let store = HistoryStore(directory: root.appendingPathComponent("history"))
    let cache = HistoryPageCache(store: store)
    let six = HistoryPageKey(start: end.addingTimeInterval(-21600), end: end, bucket: 60)
    let hour = HistoryPageKey(start: end.addingTimeInterval(-3600), end: end, bucket: 60)
    let started = Date()
    let full = try await cache.page(six)
    let coldTime = Date().timeIntervalSince(started)
    precondition(full.disk?.sampleCount == 360 && full.system?.skipped == 1 && full.systemError != nil && full.backupError == nil)
    let loaded = ParsedHistoryJournalCache.shared.statistics
    let quick = Date()
    let narrow = try await cache.page(hour)
    let narrowTime = Date().timeIntervalSince(quick)
    _ = try await cache.page(six)
    precondition(narrow.disk?.sampleCount == 61 && narrow.system?.points.count == 61)
    precondition(narrow.system?.events.contains { $0.category == .memory } == true)
    precondition(ParsedHistoryJournalCache.shared.statistics.bytesRead == loaded.bytesRead)
    precondition(ParsedHistoryJournalCache.shared.statistics.decoded == loaded.decoded)
    let coarse = HistoryPageKey(start: six.start, end: end, bucket: 600)
    let coarsePage = try await cache.page(coarse)
    precondition(coarsePage.disk?.points.count == 37)
    precondition(ParsedHistoryJournalCache.shared.statistics.bytesRead == loaded.bytesRead, "Different aggregation must reuse parsed data")
    precondition(ParsedHistoryJournalCache.shared.statistics.decoded == loaded.decoded)
    let direct = try await HistoryPage.load(store: store, key: hour)
    precondition(direct.disk?.points.map(\.lastGB) == narrow.disk?.points.map(\.lastGB))
    precondition(direct.system?.events.map(\.id) == narrow.system?.events.map(\.id))
    precondition(direct.storage?.frames.map(\.free) == narrow.storage?.frames.map(\.free))

    let date = end.addingTimeInterval(60)
    try await store.append(DiskSnapshot(name: "fixture", path: "/", freeBytes: 79_000_000_000, totalBytes: 500_000_000_000, reclaimableEstimateBytes: nil, refreshedAt: date))
    try store.system.append(SystemRecord(date: date, kind: .sample, runID: run, boot: end.addingTimeInterval(-86400), interval: 60,
        allocated: 2_000_000_000, used: 1_000_000_000, pressure: .normal, free: 79_000_000_000))
    let beforeTail = ParsedHistoryJournalCache.shared.statistics
    let newSix = HistoryPageKey(start: date.addingTimeInterval(-21600), end: date, bucket: 60)
    let updated = try await cache.page(newSix)
    let afterTail = ParsedHistoryJournalCache.shared.statistics
    precondition(updated.disk?.points.last?.freeBytes == 79_000_000_000)
    precondition(afterTail.decoded - beforeTail.decoded <= 4, "Live refresh must decode only new lines")
    precondition(afterTail.bytesRead - beforeTail.bytesRead < 4096, "Live refresh must not reread complete monthly journals")
    let newHour = HistoryPageKey(start: date.addingTimeInterval(-3600), end: date, bucket: 60)
    let updatedHour = try await cache.page(newHour)
    precondition(updatedHour.disk?.points.last?.freeBytes == 79_000_000_000)
    precondition(ParsedHistoryJournalCache.shared.statistics.bytesRead == afterTail.bytesRead)
    print("PASS: six-hour → one-hour → six-hour reuse, pressure/events and composition fidelity, reaggregation without I/O, live append-only reads")
    print(String(format: "Fixture timing: cold six-hour %.1f ms; contained one-hour %.2f ms; live tail %lld bytes / %d new lines", coldTime * 1000, narrowTime * 1000, afterTail.bytesRead - beforeTail.bytesRead, afterTail.decoded - beforeTail.decoded))
}

@MainActor func diagnoseHistoryReuse() async throws {
    ParsedHistoryJournalCache.shared.clear()
    let store = HistoryStore(), cache = HistoryPageCache(store: store)
    let end = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970))
    let six = HistoryPageKey(start: end.addingTimeInterval(-21600), end: end, bucket: 60)
    let hour = HistoryPageKey(start: end.addingTimeInterval(-3600), end: end, bucket: 60)
    let start = Date(), full = try await cache.page(six)
    let cold = Date().timeIntervalSince(start), loaded = ParsedHistoryJournalCache.shared.statistics
    let quick = Date(), small = try await cache.page(hour)
    let hot = Date().timeIntervalSince(quick)
    _ = try await cache.page(six)
    let reused = ParsedHistoryJournalCache.shared.statistics
    print("Six-hour samples:", full.disk?.sampleCount ?? -1, "one-hour:", small.disk?.sampleCount ?? -1, "estimated page:", full.estimatedBytes)
    print("System event archive:", full.system?.events.count ?? -1, "of", full.system?.totalEvents ?? -1)
    print("Reader notices:", [full.diskError, full.dockerError, full.backupError, full.systemError, full.storageError].compactMap { $0 })
    print(String(format: "Actual saved history: cold %.1f ms; contained %.2f ms; repeat I/O %lld bytes, %d decoded lines", cold * 1000, hot * 1000, reused.bytesRead - loaded.bytesRead, reused.decoded - loaded.decoded))
}
