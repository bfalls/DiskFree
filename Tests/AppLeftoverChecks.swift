import Foundation
import Darwin

private func leftoverFixtures() throws {
    let fm = FileManager.default
    var root = fm.temporaryDirectory.appendingPathComponent("DiskFree-leftovers-" + UUID().uuidString)
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    root = root.resolvingSymlinksInPath()
    defer { try? fm.removeItem(at: root) }
    let support = root.appendingPathComponent("Application Support")
    let apps = root.appendingPathComponent("Applications")
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try fm.createDirectory(at: apps, withIntermediateDirectories: true)
    func directory(_ name: String) throws -> URL {
        let url = support.appendingPathComponent(name)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        try Data(repeating: 5, count: 1_048_576).write(to: url.appendingPathComponent("data.bin"))
        return url
    }
    func app(_ url: URL, id: String, name: String) throws {
        try fm.createDirectory(at: url.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": id, "CFBundleName": name], format: .xml, options: 0)
        try data.write(to: url.appendingPathComponent("Contents/Info.plist"))
    }
    let alive = apps.appendingPathComponent("Alive.app")
    try app(alive, id: "com.installed.editor", name: "Alive")
    let trashed = root.appendingPathComponent(".Trash/Deleted.app")
    try app(trashed, id: "com.deleted.app", name: "Deleted")
    let absent = try directory("com.oldvendor.removed")
    _ = try directory("Alive"); _ = try directory("Google"); _ = try directory("com.apple.privateData")
    _ = try directory("UnknownData")
    _ = try directory("Old Name")
    let token = LeftoverCancellation()
    let inventory = try LeftoverScanner.inventory(indexedPaths: [alive.path, trashed.path, root.appendingPathComponent("Missing.app").path], roots: [apps], token: token)
    precondition(inventory.apps.count == 1 && inventory.apps[0].bundleID == "com.installed.editor", "Inventory: \(inventory.apps.map(\.path))")
    let historical = LeftoverApp(bundleID: "com.previous.oldname", path: "/gone/Old Name.app", names: ["Old Name"])
    let prior = LeftoverResults(schema: 1, checkedAt: Date(), root: support.path, rootIdentity: LeftoverScanner.identity(support)!, knownApps: [historical], candidates: [], kept: [], inventoryLimited: false, measurementLimited: false)
    let report = try LeftoverScanner.scan(root: support, inventory: inventory, previous: prior, caches: [], token: token, minimum: 1) { _ in }
    precondition(report.candidates.count == 3)
    precondition(report.candidates.contains { $0.name == "UnknownData" && !$0.canTrash })
    precondition(report.candidates.contains { $0.name == "Old Name" && $0.bundleIDs == [historical.bundleID] })
    let limitedInventory = try LeftoverScanner.inventory(indexedPaths: [alive.path], roots: [apps], token: token, seconds: 0)
    precondition(limitedInventory.limited, "A work limit must not look like an empty complete app inventory")
    let candidate = report.candidates.first { $0.path == absent.path }!
    try LeftoverScanner.validateForTrash(candidate, results: report, inventory: inventory, root: support)
    let reinstalled = LeftoverInventory(apps: [LeftoverApp(bundleID: "com.oldvendor.removed", path: "/Applications/Removed.app", names: ["Removed"])], limited: false)
    do { try LeftoverScanner.validateForTrash(candidate, results: report, inventory: reinstalled, root: support); preconditionFailure("Reinstalled app must prevent cleanup") } catch LeftoverFailure.appPresent {}
    let sibling = LeftoverInventory(apps: [LeftoverApp(bundleID: "com.oldvendor.another", path: "/Applications/Another.app", names: ["Another"])], limited: false)
    do { try LeftoverScanner.validateForTrash(candidate, results: report, inventory: sibling, root: support); preconditionFailure("Publisher data may be shared") } catch LeftoverFailure.appPresent {}
    do { try LeftoverScanner.validateForTrash(candidate, results: report, inventory: LeftoverInventory(apps: [], limited: true), root: support); preconditionFailure("Incomplete inventory must prevent cleanup") } catch LeftoverFailure.incomplete {}
    let uncertain = report.candidates.first { $0.name == "UnknownData" }!
    do { try LeftoverScanner.validateForTrash(uncertain, results: report, inventory: inventory, root: support); preconditionFailure("Uncertain owner must prevent cleanup") } catch LeftoverFailure.uncertain {}

    let cache = FolderCache(root: absent.path, nodes: ["": DirectorySize(bytes: 7_000_000_000, children: [])], measuredAt: Date())
    let reused = try LeftoverScanner.scan(root: support, inventory: inventory, previous: prior, caches: [cache], token: token, minimum: 1) { _ in }
    precondition(reused.candidates.first { $0.path == absent.path }?.bytes == cache.bytes)
    let sparse = absent.appendingPathComponent("sparse.bin")
    fm.createFile(atPath: sparse.path, contents: nil)
    let handle = try FileHandle(forWritingTo: sparse); try handle.truncate(atOffset: 1_000_000_000); try handle.close()
    precondition(link(absent.appendingPathComponent("data.bin").path, absent.appendingPathComponent("hardlink.bin").path) == 0)
    let foreign = root.appendingPathComponent("foreign"); try fm.createDirectory(at: foreign, withIntermediateDirectories: true)
    try Data(repeating: 9, count: 2_097_152).write(to: foreign.appendingPathComponent("outside.bin"))
    try fm.createSymbolicLink(atPath: absent.appendingPathComponent("link").path, withDestinationPath: foreign.path)
    let size = try LeftoverScanner.measure(absent, token: token)
    precondition(size.bytes < 2_000_000 && size.bytes >= 1_048_576, "Logical sparse bytes, duplicate hardlinks and symlink targets must not be counted")
    let bounded = try LeftoverScanner.measure(absent, token: token, maxEntries: 0)
    precondition(bounded.partial)

    let store = LeftoverResultStore(url: root.appendingPathComponent("saved/results.json"))
    var kept = report; kept.kept.insert(candidate.path); try store.save(kept)
    do { try LeftoverScanner.validateForTrash(candidate, results: kept, inventory: inventory, root: support); preconditionFailure("Kept data cannot be cleaned up") } catch LeftoverFailure.uncertain {}
    let persisted = try store.load()!
    precondition(persisted.kept.contains(candidate.path) && persisted.candidates.count == report.candidates.count)
    let savedBytes = try Data(contentsOf: store.url)
    let cancelled = LeftoverCancellation(); cancelled.cancel()
    do { _ = try LeftoverScanner.scan(root: support, inventory: inventory, previous: prior, caches: [], token: cancelled, minimum: 1) { _ in }; preconditionFailure("Cancelled request must stop") } catch is CancellationError {}
    let afterCancellation = try Data(contentsOf: store.url)
    precondition(afterCancellation == savedBytes)
    let hiddenKept = try LeftoverScanner.scan(root: support, inventory: inventory, previous: kept, caches: [], token: token, minimum: 1) { _ in }
    precondition(hiddenKept.kept.contains(candidate.path) && hiddenKept.candidates.contains { $0.path == candidate.path })
    let replacement = support.appendingPathComponent("original-folder")
    try fm.moveItem(at: absent, to: replacement)
    try fm.createDirectory(at: absent, withIntermediateDirectories: true)
    do { try LeftoverScanner.validateForTrash(candidate, results: report, inventory: inventory, root: support); preconditionFailure("Replacement folder must prevent cleanup") } catch LeftoverFailure.changed {}
    try fm.removeItem(at: absent)
    try fm.createSymbolicLink(atPath: absent.path, withDestinationPath: foreign.path)
    do { try LeftoverScanner.validateForTrash(candidate, results: report, inventory: inventory, root: support); preconditionFailure("Symlink substitution must prevent cleanup") } catch LeftoverFailure.changed {}
    precondition(LeftoverScanner.ignoredAppPath("/Volumes/Backup/Backups.backupdb/Mac/Applications/Old.app"))
    precondition(LeftoverScanner.association(name: "InstalledSoftware", installed: inventory.apps, known: []) == nil)
    precondition(LeftoverScanner.excluded("Microsoft") && LeftoverScanner.excluded("group.com.vendor.shared") && LeftoverScanner.excluded("DiskFree"))
    print("PASS: on-demand app inventory, ownership and shared-data safeguards, cached sizes, allocation/hardlink/symlink handling, work limits, Keep persistence, cancellation, reinstall and folder-identity cleanup guards")
}

@MainActor func checkAppLeftovers() async throws {
    try leftoverFixtures()
    let query = LeftoverAppQuery()
    let task = Task { await query.search() }
    try await Task.sleep(nanoseconds: 50_000_000)
    query.cancel()
    _ = await task.value
    print("PASS: native app metadata query cancellation completes without a live query")
}
