import Foundation
import Darwin

func checkGrowth() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-Growth-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let tree = root.appendingPathComponent("tree")
    let a = tree.appendingPathComponent("a"), b = tree.appendingPathComponent("b")
    try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 65_536).write(to: a.appendingPathComponent("one"))
    try Data(repeating: 2, count: 65_536).write(to: b.appendingPathComponent("two"))
    let folder = GrowthFolder(id: "test", name: "Test", path: tree.path)
    let now = Date()
    let first = try GrowthScanner.scan(folder: folder, previous: nil, changes: [], excluded: [], now: now)
    precondition(first.nodes.count == 3 && first.bytes >= 131_072)
    // Unchanged descendants must not be traversed for a direct-directory event.
    try Data(repeating: 3, count: 262_144).write(to: b.appendingPathComponent("two"))
    let direct = try GrowthScanner.scan(folder: folder, previous: first,
        changes: [GrowthChange(path: a.path, recursive: false)], excluded: [])
    precondition(direct.bytes == first.bytes, "An unaffected descendant should stay cached")
    let updated = try GrowthScanner.scan(folder: folder, previous: direct,
        changes: [GrowthChange(path: b.path, recursive: false)], excluded: [], now: now.addingTimeInterval(86_400))
    precondition(updated.bytes > first.bytes)
    let child = a.appendingPathComponent("new")
    try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
    try Data(repeating: 4, count: 65_536).write(to: child.appendingPathComponent("three"))
    let added = try GrowthScanner.scan(folder: folder, previous: updated,
        changes: [GrowthChange(path: a.path, recursive: false)], excluded: [])
    precondition(added.nodes[child.path] != nil && added.bytes > updated.bytes)
    try FileManager.default.removeItem(at: b)
    let deleted = try GrowthScanner.scan(folder: folder, previous: added,
        changes: [GrowthChange(path: tree.path, recursive: false)], excluded: [])
    precondition(deleted.nodes[b.path] == nil && deleted.bytes < added.bytes)
    let excluded = try GrowthScanner.scan(folder: folder, previous: deleted, changes: [], excluded: [a.path])
    precondition(excluded.nodes[a.path] == nil && excluded.bytes < deleted.bytes)
    let link = tree.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: a)
    let noLinks = try GrowthScanner.scan(folder: folder, previous: deleted, changes: [], excluded: [])
    precondition(noLinks.nodes[link.path] == nil)
    let missing = GrowthFolder(id: "missing", name: "Missing", path: root.appendingPathComponent("missing").path)
    let missingCache = try GrowthScanner.scan(folder: missing, previous: nil, changes: [], excluded: [])
    precondition(missingCache.bytes == 0)
    do {
        _ = try GrowthScanner.scan(folder: folder, previous: nil, changes: [], excluded: [], budget: GrowthBudget(seconds: 0, entries: 1, directories: 1))
        preconditionFailure("Must stop when budget is exhausted")
    } catch GrowthScanError.budget { }
    precondition(GrowthScanError.fileAccess(tree.path, code: EACCES).permissionDenied)
    precondition(GrowthScanError.fileAccess(tree.path, code: EPERM).permissionDenied)
    precondition(!GrowthScanError.fileAccess(tree.path, code: EIO).permissionDenied)
    precondition(!GrowthScanError.budget.permissionDenied)
    let locked = root.appendingPathComponent("locked")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    precondition(chmod(locked.path, 0) == 0)
    defer { _ = chmod(locked.path, 0o700) }
    do {
        _ = try GrowthScanner.scan(folder: GrowthFolder(id: "locked", name: "Locked", path: locked.path),
                                   previous: nil, changes: [], excluded: [])
        preconditionFailure("Permission denial must not be reported as zero or a budget limit")
    } catch let error as GrowthScanError {
        precondition(error.permissionDenied)
        precondition(error.localizedDescription.contains(locked.path))
    }
    _ = chmod(locked.path, 0o700)
    do {
        _ = try GrowthScanner.scan(folder: folder, previous: first, changes: [], excluded: [],
                                   budget: GrowthBudget(entries: 1))
        preconditionFailure("Entry limit must apply before the 128-entry pacing boundary")
    } catch GrowthScanError.budget { }
    var archive = GrowthStore.adding(cache: first, folderID: "test", to: GrowthArchive())
    archive = GrowthStore.adding(cache: updated, folderID: "test", to: archive)
    let baseline = GrowthStore.baseline(archive.readings, folderID: "test", before: now.addingTimeInterval(10))
    precondition(baseline?.bytes == first.bytes)
    precondition(GrowthStore.baseline(archive.readings, folderID: "test", before: now.addingTimeInterval(-1)) == nil)
    let store = GrowthStore(directory: root.appendingPathComponent("archive"))
    try store.save(archive)
    let restored = try store.load()
    precondition(restored.readings.count == 2 && restored.caches["test"]?.bytes == updated.bytes)
    let changedScope = GrowthStore.adding(cache: excluded, folderID: "test", to: archive)
    precondition(changedScope.readings.count == 1, "Changed exclusions must start a new comparable baseline")
    var schedule = GrowthSchedule()
    precondition(schedule.next(folders: [folder], dirty: [], now: now) == nil)
    precondition(schedule.next(folders: [folder], dirty: [folder.id], now: now) != nil)
    schedule.started(folder.id, at: now)
    precondition(schedule.next(folders: [folder, missing], dirty: [missing.id], now: now.addingTimeInterval(29)) == nil)
    precondition(schedule.next(folders: [folder, missing], dirty: [missing.id], now: now.addingTimeInterval(30))?.id == missing.id)
    precondition(schedule.next(folders: [folder], dirty: [folder.id], now: now.addingTimeInterval(1799)) == nil)
    precondition(schedule.next(folders: [folder], dirty: [folder.id], now: now.addingTimeInterval(1800)) != nil)
    precondition(schedule.next(folders: [folder], dirty: [folder.id], continuing: [folder.id], now: now.addingTimeInterval(30)) != nil,
                 "A continuation must not wait for the completed-category cooldown")
    precondition(schedule.next(folders: [folder, missing], dirty: [folder.id, missing.id], continuing: [folder.id],
                               now: now.addingTimeInterval(30))?.id == missing.id, "A large category must let an untouched category get its first slice")
    let old = FolderCache(root: tree.path, nodes: first.nodes, measuredAt: now.addingTimeInterval(-100 * 86_400))
    let trimmed = GrowthStore.adding(cache: first, folderID: "test", to: GrowthStore.adding(cache: old, folderID: "test", to: GrowthArchive()))
    precondition(trimmed.readings.count == 1)
    try checkBackupTools()
    try checkProgressiveGrowth(root: root)
    print("PASS: growth caching, targeted updates, creation/deletion, scope exclusions, symlink avoidance, work limits, durable baselines, history retention and scan cooldowns")
}

func checkProgressiveGrowth(root: URL) throws {
    let tree = root.appendingPathComponent("progressive")
    let sub = tree.appendingPathComponent("nested")
    try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    for i in 0..<30 { try Data(repeating: 7, count: 4096).write(to: tree.appendingPathComponent("file-\(i)")) }
    try Data(repeating: 8, count: 4096).write(to: sub.appendingPathComponent("inner"))
    let folder = GrowthFolder(id: "progressive", name: "Progressive", path: tree.path)
    let expected = try GrowthScanner.scan(folder: folder, previous: nil, changes: [], excluded: [])
    let session = GrowthScanSession(folder: folder, previous: nil, changes: [], excluded: [])
    var finished: FolderCache?
    var slices = 0
    while finished == nil && slices < 100 {
        let before = session.processedEntries
        finished = try session.advance(budget: GrowthBudget(seconds: 5, entries: 2))
        precondition(session.processedEntries - before <= 2)
        slices += 1
    }
    precondition(slices > 10 && finished?.bytes == expected.bytes, "Slices must resume within a large directory without losing or duplicating entries")
    precondition(finished?.nodes.count == expected.nodes.count)
    let streaming = GrowthScanSession(folder: folder, previous: nil, changes: [], excluded: [], directoryLimit: 1)
    var aggregated: FolderCache?
    for _ in 0..<100 where aggregated == nil { aggregated = try streaming.advance(budget: GrowthBudget(seconds: 5, entries: 2)) }
    precondition(aggregated?.incrementalReady == false && aggregated?.nodes.count == 1)
    precondition(aggregated?.bytes == expected.bytes, "Large trees must finish as streamed totals when directory caching fills")
    let extra = tree.appendingPathComponent("new-child")
    try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
    try Data(repeating: 9, count: 4096).write(to: extra.appendingPathComponent("extra"))
    let targeted = GrowthScanSession(folder: folder, previous: expected,
        changes: [GrowthChange(path: tree.path, recursive: false)], excluded: [], directoryLimit: 2)
    var retargeted: FolderCache?
    for _ in 0..<100 where retargeted == nil { retargeted = try targeted.advance(budget: GrowthBudget(seconds: 5, entries: 2)) }
    let expectedExpanded = try GrowthScanner.scan(folder: folder, previous: nil, changes: [], excluded: [])
    precondition(retargeted?.incrementalReady == false && retargeted?.bytes == expectedExpanded.bytes,
                 "An incremental update that fills the cache must restart once and finish with a correct streamed total")
    let locked = tree.appendingPathComponent("protected")
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try Data(repeating: 1, count: 4096).write(to: locked.appendingPathComponent("hidden"))
    precondition(chmod(locked.path, 0) == 0)
    defer { _ = chmod(locked.path, 0o700) }
    let accessible = GrowthScanSession(folder: folder, previous: nil, changes: [], excluded: [])
    var partial: FolderCache?
    for _ in 0..<100 where partial == nil { partial = try accessible.advance(budget: GrowthBudget(seconds: 5, entries: 2)) }
    precondition(partial != nil && partial!.bytes >= 31 * 4096)
    precondition(partial!.skippedCount == 1 && partial!.skippedPaths == [locked.path])
    precondition(partial!.nodes[locked.path] == nil, "Unreadable contents must not be presented as a measured zero")
    try Data(repeating: 8, count: 8192).write(to: sub.appendingPathComponent("inner"))
    let partialUpdate = GrowthScanSession(folder: folder, previous: partial,
        changes: [GrowthChange(path: sub.path, recursive: false)], excluded: [])
    let continuedCoverage = try partialUpdate.advance(budget: GrowthBudget(seconds: 5, entries: 100))!
    precondition(partialUpdate.processedEntries == 1, "Partial coverage must still use targeted updates, without rescanning accessible siblings")
    precondition(continuedCoverage.skippedCount == 1 && continuedCoverage.coverageID == partial!.coverageID)
    precondition(continuedCoverage.bytes > partial!.bytes)
    let partialArchive = GrowthStore.adding(cache: continuedCoverage, folderID: folder.id,
        to: GrowthStore.adding(cache: partial!, folderID: folder.id, to: GrowthArchive()))
    precondition(partialArchive.readings.count == 2, "Stable partial coverage should retain comparable history")
    _ = chmod(locked.path, 0o700)
    let complete = try GrowthScanner.scan(folder: folder, previous: nil, changes: [], excluded: [])
    precondition(complete.bytes > partial!.bytes)
    let archive = GrowthStore.adding(cache: complete, folderID: folder.id,
        to: GrowthStore.adding(cache: partial!, folderID: folder.id, to: GrowthArchive()))
    precondition(archive.readings.count == 1, "A coverage change must start a fresh baseline instead of reporting false growth")
    // Version 1.2 caches remain readable without the new optional coverage keys.
    let data = try JSONEncoder().encode(expected)
    var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
    for key in ["incrementalReady", "skippedPaths", "skippedCount", "coverageID"] { json.removeValue(forKey: key) }
    let migrated = try JSONDecoder().decode(FolderCache.self, from: JSONSerialization.data(withJSONObject: json))
    precondition(migrated.bytes == expected.bytes && migrated.skippedCount == nil)
    print("PASS: progressive directory continuation, per-slice work limits, bounded aggregate fallback, protected-child coverage, coverage-baseline reset and old-cache migration")
}

func checkBackupTools() throws {
    let listing = "Snapshots for volume group containing disk /System/Volumes/Data:\ncom.apple.TimeMachine.2026-10-10-165737.local\n"
    let names = try BackupContextReader.snapshotNames(listing)
    precondition(names.count == 1 && BackupContextReader.snapshotDate(names[0]) != nil)
    let empty = try BackupContextReader.snapshotNames("Snapshots for disk /System/Volumes/Data:\n")
    precondition(empty.isEmpty)
    do { _ = try BackupContextReader.snapshotNames("Permission denied"); preconditionFailure("Unknown output must not imply zero snapshots") }
    catch { }
    precondition(BackupContextReader.running("Running = 1;") == true)
    precondition(BackupContextReader.running("Running = 0;") == false)
    precondition(BackupContextReader.running("Running = 10;") == nil)
    precondition(BackupContextReader.running("Unavailable") == nil)
    precondition(SnapshotCleanup.recover(10).arguments == ["thinlocalsnapshots", "/System/Volumes/Data", "10000000000", "1"])
    precondition(SnapshotCleanup.removeLocal.arguments == ["deletelocalsnapshots", "/System/Volumes/Data"])
    do { _ = try BackupContextReader.authorizationScript(.recover(-1)); preconditionFailure("Invalid recovery target must be rejected") }
    catch { }
    let script = try BackupContextReader.authorizationScript(.removeLocal)
    precondition(script.contains("with administrator privileges") && script.contains("|| exit 75"))
    precondition(!script.contains("deleteSnapshot") && !script.contains(" /Volumes/"))
    var capacityCalls = 0
    let capacity = { () -> DiskSnapshot in
        capacityCalls += 1
        return DiskSnapshot(name: "Fixture", path: "/System/Volumes/Data", freeBytes: capacityCalls == 1 ? 10_000_000_000 : 12_000_000_000,
            totalBytes: 100_000_000_000, reclaimableEstimateBytes: 5_000_000_000, refreshedAt: Date())
    }
    let command: BackupContextReader.Command = { args in args == ["status"] ? "Running = 0;" : listing }
    var mutations = 0
    let result = try BackupContextReader.clean(.recover(10), command: command, capacity: capacity, perform: { _ in mutations += 1 })
    precondition(mutations == 1 && result.freeChange == 2_000_000_000 && result.context.snapshots?.count == 1)
    for status in ["Running = 1;", "Unknown"] {
        do {
            _ = try BackupContextReader.clean(.removeLocal, command: { args in args == ["status"] ? status : listing },
                capacity: capacity, perform: { _ in mutations += 1 })
            preconditionFailure("Cleanup must refuse active or unknown backup state")
        } catch BackupToolError.unsafeState { }
    }
    do {
        _ = try BackupContextReader.clean(.removeLocal, command: { args in args == ["status"] ? "Running = 0;" : "Snapshots for disk /System/Volumes/Data:" },
            capacity: capacity, perform: { _ in mutations += 1 })
        preconditionFailure("Cleanup requires known local restore points")
    } catch BackupToolError.unsafeState { }
    precondition(mutations == 1)
    let partial = BackupContextReader.read(command: { args in
        if args == ["status"] { throw BackupToolError.unavailable("Denied") }
        return listing
    }, capacity: capacity)
    precondition(partial.backupRunning == nil && partial.snapshots?.count == 1 && !partial.canClean)
    print("PASS: Time Machine parsing, unknown-state preservation, volume-scoped cleanup, whitelisted targets, fresh safety checks, simulated recovery measurement and partial reads")
}
