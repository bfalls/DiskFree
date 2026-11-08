import Foundation
import AppKit
import Darwin

final class LeftoverCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws { lock.lock(); let value = cancelled; lock.unlock(); if value { throw CancellationError() } }
}
struct LeftoverApp: Codable, Sendable {
    let bundleID: String
    let path: String
    let names: [String]
}
struct LeftoverInventory: Sendable {
    var apps: [LeftoverApp]
    var limited: Bool
}
struct LeftoverCandidate: Codable, Identifiable, Sendable {
    var id: String { path }
    let path: String
    let identity: String
    let bundleIDs: [String]
    let reason: String
    let bytes: Int64
    let measuredAt: Date
    let partial: Bool
    var movedAt: Date? = nil
    var canTrash: Bool { !bundleIDs.isEmpty && movedAt == nil }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct LeftoverResults: Codable, Sendable {
    let schema: Int
    let checkedAt: Date
    let root: String
    let rootIdentity: String
    let knownApps: [LeftoverApp]
    var candidates: [LeftoverCandidate]
    var kept: Set<String>
    let inventoryLimited: Bool
    let measurementLimited: Bool
}
struct LeftoverProgress: Sendable {
    let message: String
    var completed: Int = 0
    var total: Int = 0
}
enum LeftoverFailure: LocalizedError {
    case inaccessible, changed, appPresent, uncertain, incomplete, saved, workLimit
    var errorDescription: String? {
        switch self {
        case .inaccessible: return "This folder isn’t accessible. Review it in Finder."
        case .changed: return "The folder changed. Run Find App Leftovers again."
        case .appPresent: return "An associated app is installed or running. Nothing was moved."
        case .uncertain: return "App ownership is uncertain. Review this folder in Finder."
        case .incomplete: return "The app check was incomplete. Nothing was moved."
        case .saved: return "Results couldn’t be saved."
        case .workLimit: return "The check reached its work limit."
        }
    }
}

enum LeftoverScanner {
    static var supportRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").resolvingSymlinksInPath()
    }
    static func normalized(_ name: String) -> String {
        name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }
    static func identity(_ url: URL) -> String? {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }
    static func excluded(_ name: String) -> Bool {
        let lower = name.lowercased()
        let shared: Set<String> = ["apple", "adobe", "google", "microsoft", "mozilla", "jetbrains", "docker", "steam", "valve",
            "mobilesync", "addressbook", "contacts", "calendar", "calendars", "icloud", "clouddocs", "cloudkit", "ubiquity", "fileprovider",
            "syncservices", "crashreporter", "knowledge", "spotlight", "diskfree", "app store", "shared", "group containers"]
        return name.hasPrefix(".") || lower.hasPrefix("com.apple") || lower.hasPrefix("group.") || shared.contains(lower)
            || lower.hasSuffix(".app") || lower.hasSuffix(".framework") || lower.hasSuffix(".shared")
    }
    static func ignoredAppPath(_ path: String) -> Bool {
        let parts = URL(fileURLWithPath: path).pathComponents
        return parts.contains { [".Trash", ".Trashes", ".timemachine", "Backups.backupdb", ".MobileBackups", "com.apple.TimeMachine.localsnapshots"].contains($0) }
    }
    static func app(at url: URL) -> LeftoverApp? {
        let url = url.resolvingSymlinksInPath()
        guard url.pathExtension.lowercased() == "app", !ignoredAppPath(url.path), identity(url) != nil else { return nil }
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let size = try? info.resourceValues(forKeys: [.fileSizeKey]).fileSize, size < 1_048_576,
              let data = try? Data(contentsOf: info), let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let id = plist["CFBundleIdentifier"] as? String, !id.isEmpty else { return nil }
        let names = [url.deletingPathExtension().lastPathComponent, plist["CFBundleName"] as? String, plist["CFBundleDisplayName"] as? String].compactMap { $0 }
        return LeftoverApp(bundleID: id, path: url.path, names: Array(Set(names)))
    }
    static func inventory(indexedPaths: [String], roots: [URL], token: LeftoverCancellation, seconds: Double = 15) throws -> LeftoverInventory {
        let deadline = Date().addingTimeInterval(seconds)
        var apps: [String: LeftoverApp] = [:], limited = false, entries = 0
        for path in indexedPaths.prefix(5000) {
            try token.check()
            if Date() >= deadline { limited = true; break }
            if let item = app(at: URL(fileURLWithPath: path)) { apps[item.path] = item }
        }
        if indexedPaths.count > 5000 { limited = true }
        for root in roots {
            try token.check()
            if !FileManager.default.fileExists(atPath: root.path) { continue }
            guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in limited = true; return true }) else { limited = true; continue }
            for case let url as URL in enumerator {
                try token.check(); entries += 1
                if entries > 15_000 || Date() >= deadline { limited = true; break }
                var info = stat()
                guard lstat(url.path, &info) == 0 else { limited = true; continue }
                if info.st_mode & S_IFMT == S_IFLNK { enumerator.skipDescendants(); continue }
                if url.pathExtension.lowercased() == "app" {
                    enumerator.skipDescendants()
                    if let item = app(at: url) { apps[item.path] = item }
                } else if url.pathComponents.count - root.pathComponents.count > 6 { enumerator.skipDescendants(); limited = true }
            }
        }
        return LeftoverInventory(apps: Array(apps.values), limited: limited)
    }
    static func association(name: String, installed: [LeftoverApp], known: [LeftoverApp]) -> (ids: [String], reason: String)? {
        guard !excluded(name) else { return nil }
        let key = normalized(name), lower = name.lowercased()
        guard !installed.contains(where: { $0.names.contains { normalized($0) == key } || $0.bundleID.lowercased() == lower || normalized($0.bundleID.components(separatedBy: ".").last ?? "") == key }) else { return nil }
        if installed.contains(where: { app in
            let parts = app.bundleID.lowercased().split(separator: ".")
            return parts.count >= 3 && parts[1].count >= 4 && key.contains(normalized(String(parts[1])))
        }) { return nil }
        let historical = known.filter { $0.names.contains { normalized($0) == key } || $0.bundleID.lowercased() == lower }
        let shaped = name.range(of: #"^[A-Za-z][A-Za-z0-9-]*(?:\.[A-Za-z0-9_-]+){2,}$"#, options: .regularExpression) != nil
        let ids = Array(Set(historical.map(\.bundleID) + (shaped ? [name] : []))).sorted()
        // A sibling app from the same publisher may share this data.
        for id in ids {
            let vendor = id.split(separator: ".").dropLast().joined(separator: ".").lowercased() + "."
            if installed.contains(where: { $0.bundleID.lowercased().hasPrefix(vendor) }) { return nil }
        }
        return (ids, ids.isEmpty ? "App name not found; ownership uncertain" : "Associated app not found")
    }
    static func measure(_ root: URL, token: LeftoverCancellation, maxEntries: Int = 25_000, seconds: Double = 3) throws -> (bytes: Int64, partial: Bool) {
        let deadline = Date().addingTimeInterval(seconds)
        var rootInfo = stat()
        guard lstat(root.path, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else { throw LeftoverFailure.inaccessible }
        var bytes = max(0, Int64(rootInfo.st_blocks) * 512), count = 0, partial = false
        var seen = Set<String>()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil, options: [], errorHandler: { _, _ in partial = true; return true }) else { throw LeftoverFailure.inaccessible }
        for case let url as URL in enumerator {
            try token.check(); count += 1
            if count > maxEntries || Date() >= deadline { partial = true; break }
            var info = stat()
            guard lstat(url.path, &info) == 0 else { partial = true; continue }
            let type = info.st_mode & S_IFMT
            if type == S_IFLNK || info.st_dev != rootInfo.st_dev { enumerator.skipDescendants(); if info.st_dev != rootInfo.st_dev { partial = true }; continue }
            guard type == S_IFDIR || type == S_IFREG else { continue }
            if seen.insert("\(info.st_dev):\(info.st_ino)").inserted { bytes += max(0, Int64(info.st_blocks) * 512) }
        }
        return (bytes, partial)
    }
    static func scan(root: URL, inventory: LeftoverInventory, previous: LeftoverResults?, caches: [FolderCache], token: LeftoverCancellation,
                     minimum: Int64 = 50_000_000, seconds: Double = 120,
                     progress: @Sendable (LeftoverProgress) -> Void) throws -> LeftoverResults {
        guard let rootID = identity(root) else { throw LeftoverFailure.inaccessible }
        let deadline = Date().addingTimeInterval(seconds)
        let kept = previous?.kept ?? []
        let known = Array(Dictionary((previous?.knownApps ?? []).map { ($0.bundleID + $0.path, $0) } + inventory.apps.map { ($0.bundleID + $0.path, $0) }, uniquingKeysWith: { _, new in new }).values.prefix(5000))
        var children: [URL] = [], limited = false, rootEntries = 0
        guard let directory = opendir(root.path) else { throw LeftoverFailure.inaccessible }
        defer { closedir(directory) }
        while let entry = readdir(directory) {
            try token.check(); rootEntries += 1
            if rootEntries > 4096 || Date() >= deadline { limited = true; break }
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) } }
            guard name != ".", name != "..", !excluded(name) else { continue }
            if children.count >= 512 { limited = true; break }
            let child = root.appendingPathComponent(name)
            if identity(child) != nil { children.append(child) }
        }
        var candidates: [LeftoverCandidate] = []
        for (offset, child) in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).enumerated() {
            try token.check()
            if Date() >= deadline { limited = true; break }
            progress(LeftoverProgress(message: "Checking " + child.lastPathComponent, completed: offset, total: children.count))
            guard !kept.contains(child.path), let association = association(name: child.lastPathComponent, installed: inventory.apps, known: known), let id = identity(child) else { continue }
            let cached = caches.first { $0.root == child.path && $0.exclusions.isEmpty && ($0.skippedCount ?? 0) == 0 && Date().timeIntervalSince($0.measuredAt) < 86400 }
            let measurement: (bytes: Int64, partial: Bool)
            do { measurement = try cached.map { ($0.bytes, false) } ?? measure(child, token: token, seconds: min(3, max(0, deadline.timeIntervalSinceNow))) }
            catch is CancellationError { throw CancellationError() }
            catch { limited = true; continue }
            guard identity(child) == id else { limited = true; continue }
            if measurement.partial { limited = true }
            guard measurement.bytes >= minimum else { continue }
            candidates.append(LeftoverCandidate(path: child.path, identity: id, bundleIDs: association.ids, reason: association.reason,
                bytes: measurement.bytes, measuredAt: cached?.measuredAt ?? Date(), partial: measurement.partial))
            // Yield disk activity between candidate folders. This runs only during the requested check.
            Thread.sleep(forTimeInterval: 0.015)
        }
        candidates += (previous?.candidates ?? []).filter { kept.contains($0.path) }
        progress(LeftoverProgress(message: "Check complete", completed: children.count, total: children.count))
        return LeftoverResults(schema: 1, checkedAt: Date(), root: root.path, rootIdentity: rootID, knownApps: known,
            candidates: candidates.sorted { $0.bytes > $1.bytes }, kept: kept, inventoryLimited: inventory.limited, measurementLimited: limited)
    }
    static func validateForTrash(_ candidate: LeftoverCandidate, results: LeftoverResults, inventory: LeftoverInventory, root: URL = supportRoot) throws {
        guard candidate.canTrash, !results.kept.contains(candidate.path), !excluded(candidate.name) else { throw LeftoverFailure.uncertain }
        guard !inventory.limited else { throw LeftoverFailure.incomplete }
        guard root.path == results.root, identity(root) == results.rootIdentity,
              URL(fileURLWithPath: candidate.path).deletingLastPathComponent().path == root.path,
              identity(URL(fileURLWithPath: candidate.path)) == candidate.identity else { throw LeftoverFailure.changed }
        if association(name: candidate.name, installed: inventory.apps, known: results.knownApps) == nil { throw LeftoverFailure.appPresent }
        if inventory.apps.contains(where: { candidate.bundleIDs.contains($0.bundleID) }) { throw LeftoverFailure.appPresent }
    }
}

struct LeftoverResultStore: Sendable {
    let url: URL
    static var standard: LeftoverResultStore { LeftoverResultStore(url: HistoryStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("AppLeftovers/results.json")) }
    func load() throws -> LeftoverResults? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 8 * 1024 * 1024 else { throw LeftoverFailure.saved }
        let result = try JSONDecoder().decode(LeftoverResults.self, from: Data(contentsOf: url))
        guard result.schema == 1, result.candidates.count <= 1024, result.knownApps.count <= 5000 else { throw LeftoverFailure.saved }
        return result
    }
    func save(_ results: LeftoverResults) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(results).write(to: url, options: .atomic)
    }
}

struct LeftoverIndexResult: Sendable { let paths: [String]; let limited: Bool }
@MainActor final class LeftoverAppQuery {
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timer: Task<Void, Never>?
    private var continuation: CheckedContinuation<LeftoverIndexResult, Never>?
    func search() async -> LeftoverIndexResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let query = NSMetadataQuery()
            query.searchScopes = [NSMetadataQueryLocalComputerScope]
            query.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
            self.query = query
            observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in self?.finish(limited: false) }
            }
            timer = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 8_000_000_000)
                if !Task.isCancelled { self?.finish(limited: true) }
            }
            if !query.start() { finish(limited: true) }
        }
    }
    func cancel() { finish(limited: true) }
    private func finish(limited: Bool) {
        guard let continuation, let query else { return }
        query.disableUpdates()
        let paths = (0..<min(query.resultCount, 5000)).compactMap { (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: "kMDItemPath") as? String }
        let capped = query.resultCount > 5000
        query.stop(); self.query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timer?.cancel(); timer = nil; self.continuation = nil
        continuation.resume(returning: LeftoverIndexResult(paths: paths, limited: limited || capped))
    }
}
