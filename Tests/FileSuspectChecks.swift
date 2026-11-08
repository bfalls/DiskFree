import Foundation
import CoreServices
import Darwin

private func fileSuspectFixtures() throws -> (SpaceChange, FileFindings) {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let run = UUID().uuidString
    let before = SystemRecord(date: base, kind: .sample, runID: run, boot: base.addingTimeInterval(-1000), interval: 60, free: 80_000_000_000)
    let after = SystemRecord(date: base.addingTimeInterval(60), kind: .sample, runID: run, boot: before.boot, interval: 60, free: 60_000_000_000)
    let loss = SpaceChange(before: before, after: after)
    var recovered = after; recovered.free = 100_000_000_000
    let gain = SpaceChange(before: before, after: recovered)
    func sample(_ path: String, _ bytes: Int64, _ date: Double, identity: String = "1:1", created: Double = -600) -> SuspectFileSample {
        SuspectFileSample(path: path, date: base.addingTimeInterval(date), identity: identity, logical: bytes, allocated: bytes,
                          created: base.addingTimeInterval(created), modified: base.addingTimeInterval(date))
    }
    let model = sample("/home/models/large.gguf", 20_000_000_000, 40, created: 20)
    let stale = sample("/home/old", 50_000_000_000, -600)
    let sparse = SuspectFileSample(path: "/home/sparse", date: base, identity: "1:2", logical: 50_000_000_000, allocated: 0, created: base, modified: base)
    let indexed = FileSuspectMatcher.match(change: loss, events: [], indexed: [model, stale, sparse])
    precondition(indexed.count == 1 && indexed[0].kind == "Created" && indexed[0].source == "Spotlight" && indexed[0].delta == nil)
    let old = sample(model.path, 5_000_000_000, -10)
    let growth = SuspectFileObservation(path: model.path, date: base.addingTimeInterval(45), flags: UInt32(kFSEventStreamEventFlagItemModified), eventID: 42, before: old, after: model)
    let matched = FileSuspectMatcher.match(change: loss, events: [growth], indexed: [model])
    precondition(matched.count == 1 && matched[0].delta == 15_000_000_000 && matched[0].source == "FSEvents")
    let removed = SuspectFileObservation(path: model.path, date: base.addingTimeInterval(40), flags: UInt32(kFSEventStreamEventFlagItemRemoved), eventID: 43, before: model, after: nil)
    let deletion = FileSuspectMatcher.match(change: gain, events: [removed], indexed: [])
    precondition(deletion.count == 1 && deletion[0].kind == "Removed" && deletion[0].allocated == 20_000_000_000)
    let renamed = SuspectFileObservation(path: model.path, date: removed.date, flags: UInt32(kFSEventStreamEventFlagItemRemoved | kFSEventStreamEventFlagItemRenamed), eventID: 44, before: model, after: nil)
    precondition(FileSuspectMatcher.match(change: gain, events: [renamed], indexed: []).isEmpty, "Rename is not reclaimed space")
    precondition(FileSuspectMatcher.match(change: gain, events: [growth], indexed: [model]).isEmpty)
    let outside = SuspectFileObservation(path: model.path, date: base.addingTimeInterval(900), flags: growth.flags, eventID: 45, before: old, after: model)
    precondition(FileSuspectMatcher.match(change: loss, events: [outside], indexed: []).isEmpty)
    let replaced = SuspectFileObservation(path: model.path, date: growth.date, flags: growth.flags, eventID: 46, before: sample(model.path, 1, -10, identity: "different"), after: model)
    precondition(FileSuspectMatcher.match(change: loss, events: [replaced], indexed: []).first?.delta == nil, "Different inode cannot establish growth")
    let findings = FileFindings(checkedAt: .distantPast, files: matched, spotlight: "Checked", tracking: "Checked", trackingSince: base)
    let report = SpaceChangeReport(change: loss, checkedAt: base, actions: [], folders: [], logStatus: "Checked", fileFindings: findings)
    let roundTrip = try JSONDecoder().decode(SpaceChangeReport.self, from: JSONEncoder().encode(report))
    precondition(roundTrip.fileFindings?.files.first?.eventID == 42 && roundTrip.fileFindings?.files.first?.before?.allocated == 5_000_000_000)
    let emptyFindings = FileFindings(checkedAt: base, files: [], spotlight: "Checked again", tracking: "Expired", trackingSince: nil)
    precondition(emptyFindings.preserving(findings).files.first?.eventID == 42, "Rechecking must preserve saved deletion evidence")
    let oldReport = SpaceChangeReport(change: loss, checkedAt: base, actions: [], folders: [], logStatus: "Checked")
    let legacy = try JSONDecoder().decode(SpaceChangeReport.self, from: JSONEncoder().encode(oldReport))
    precondition(legacy.fileFindings == nil)
    print("PASS: indexed and observed candidates, allocation filtering, time windows, direction, rename and inode safety, provenance round-trip, legacy reports")
    return (loss, findings)
}

@MainActor func checkFileSuspects() async throws {
    let (change, findings) = try fileSuspectFixtures()
    var root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("build/checks/DiskFree-file-clues-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    root = root.resolvingSymlinksInPath()
    defer { try? FileManager.default.removeItem(at: root) }
    let consumer = ConsumerHistoryStore(directory: root.appendingPathComponent("consumers"))
    let store = SpaceChangeStore(directory: root.appendingPathComponent("reports"), query: { _, _ in "" }, fileQuery: { _ in findings })
    let saved = try await store.investigate(change, consumers: consumer)
    precondition(saved.fileFindings?.files.count == 1)
    let reopened = SpaceChangeStore(directory: root.appendingPathComponent("reports"), query: { _, _ in preconditionFailure("No log requery") }, fileQuery: { _ in preconditionFailure("No file requery") })
    let cached = try await reopened.investigate(change, consumers: consumer)
    precondition(cached.fileFindings?.files.first?.eventID == 42)
    print("PASS: file findings persist with reports and reopen without searching")
    let legacyStore = SpaceChangeStore(directory: root.appendingPathComponent("legacy"), query: { _, _ in preconditionFailure("Legacy enrichment must preserve logs") }, fileQuery: { _ in findings })
    let legacyReport = SpaceChangeReport(change: change, checkedAt: Date(), actions: [], folders: [], logStatus: "Original logs")
    let legacyURL = legacyStore.source(for: change)
    try FileManager.default.createDirectory(at: legacyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(legacyReport).write(to: legacyURL)
    let enriched = try await legacyStore.investigate(change, consumers: consumer)
    precondition(enriched.logStatus == "Original logs" && enriched.fileFindings?.files.first?.eventID == 42)
    let fileRetry = SpaceChangeStore(directory: root.appendingPathComponent("reports"), query: { _, _ in preconditionFailure("File retry must not requery logs") }, fileQuery: { _ in FileFindings(checkedAt: Date(), files: [], spotlight: "Rechecked", tracking: "Expired", trackingSince: nil) })
    let preserved = try await fileRetry.investigate(change, consumers: consumer, retryFiles: true)
    precondition(preserved.fileFindings?.files.first?.eventID == 42 && preserved.fileFindings?.spotlight == "Rechecked")
    let nativeIndex = await FileEvidenceCollector().collect(change)
    precondition(nativeIndex.spotlight == "Spotlight checked", "Native indexed query must finish gathering")
    print("PASS: legacy report enrichment without log requery and native Spotlight query completion")

    // Real native stream, a 1 MiB fixture and no recursive scan or large allocations.
    let tracker = FileChangeTracker(root: root.path, minimum: 1)
    tracker.start()
    let initial = await tracker.snapshot()
    precondition(initial.since != nil && !initial.unavailable)
    let sparseURL = root.appendingPathComponent("sparse.bin")
    FileManager.default.createFile(atPath: sparseURL.path, contents: nil)
    let handle = try FileHandle(forWritingTo: sparseURL)
    try handle.truncate(atOffset: 1_000_000_000); try handle.close()
    let sparseSample = SuspectFileSample.read(sparseURL.path, device: SuspectFileSample.startupDevice!)!
    precondition(sparseSample.allocated < sparseSample.logical)
    let linkURL = root.appendingPathComponent("link.bin")
    try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: sparseURL.path)
    precondition(SuspectFileSample.read(linkURL.path, device: SuspectFileSample.startupDevice!) == nil)
    let file = root.appendingPathComponent("observed.bin")
    try Data(repeating: 7, count: 1_048_576).write(to: file)
    var detected = false
    for _ in 0..<150 {
        if (await tracker.snapshot()).events.contains(where: { $0.path == file.path && ($0.after?.allocated ?? 0) > 0 }) { detected = true; break }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    if !detected { let snapshot = await tracker.snapshot(); print("Native stream debug: root=\(root.path), observations=\(snapshot.events.map(\.path)), limited=\(String(describing: snapshot.limited))") }
    precondition(detected, "Native FSEvents must capture a created file")
    try FileManager.default.removeItem(at: file)
    var removed = false
    for _ in 0..<150 {
        if (await tracker.snapshot()).events.contains(where: { $0.path == file.path && $0.after == nil && $0.before != nil }) { removed = true; break }
        try await Task.sleep(nanoseconds: 200_000_000)
    }
    await tracker.stop()
    precondition(removed, "Native deletion must retain the last allocated size")
    print("PASS: native coalesced FSEvents creation and deletion, with last-observed allocation")
}
