import Foundation
import Darwin

struct GrowthFolder: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    var path: String
    static var swapFolder: GrowthFolder {
        let modern = "/System/Volumes/VM"
        return GrowthFolder(id: "swap-vm", name: "Swap and sleep files", path:
            FileManager.default.fileExists(atPath: modern) ? modern : "/private/var/vm")
    }
    static var defaults: [GrowthFolder] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            ("downloads", "Downloads", "/Downloads"), ("trash", "Trash", "/.Trash"),
            ("caches", "App caches", "/Library/Caches"),
            ("appdata", "Application data", "/Library/Application Support"),
            ("builds", "Xcode builds", "/Library/Developer/Xcode/DerivedData"),
            ("archives", "Xcode archives", "/Library/Developer/Xcode/Archives"),
            ("simulators", "Simulators", "/Library/Developer/CoreSimulator"),
            ("backups", "Device backups", "/Library/Application Support/MobileSync/Backup")
        ].map { GrowthFolder(id: $0.0, name: $0.1, path: home + $0.2) }
            + [swapFolder]
    }
}

struct DirectorySize: Codable, Sendable {
    var bytes: Int64
    var children: Set<String>
}
struct FolderCache: Codable, Sendable {
    let root: String
    var nodes: [String: DirectorySize]
    var measuredAt: Date
    let bytes: Int64
    let exclusions: [String]
    let incrementalReady: Bool?
    let skippedPaths: [String]?
    let skippedCount: Int?
    let coverageID: String?
    init(root: String, nodes: [String: DirectorySize], measuredAt: Date, exclusions: [String] = [], incrementalReady: Bool = true, skippedPaths: [String] = [], skippedCount: Int = 0, coverageID: String = "0") {
        self.root = root; self.nodes = nodes; self.measuredAt = measuredAt
        self.exclusions = exclusions.sorted()
        self.incrementalReady = incrementalReady; self.skippedPaths = skippedPaths; self.skippedCount = skippedCount; self.coverageID = coverageID
        bytes = nodes.values.reduce(0) { $0 + $1.bytes }
    }
}
struct GrowthReading: Codable, Identifiable, Sendable {
    let date: Date
    let folderID: String
    let bytes: Int64
    var id: String { "\(folderID)-\(date.timeIntervalSince1970)" }
}
struct GrowthChange: Sendable {
    let path: String
    let recursive: Bool
}
struct GrowthBudget: Sendable {
    var seconds: TimeInterval = 20
    var entries = 100_000
    var directories = 10_000
}
enum GrowthScanError: LocalizedError, Equatable, Sendable {
    case budget, unavailable(String), access(String, Int32)
    static func fileAccess(_ path: String, code: Int32) -> GrowthScanError { .access(path, code) }
    var permissionDenied: Bool {
        if case .access(_, let code) = self { return code == EACCES || code == EPERM }
        return false
    }
    var errorDescription: String? {
        switch self {
        case .budget: return "Scan limit reached, not a permissions error. Choose smaller folders to track separately. Retrying the same scope may hit the limit again. Previous complete reading preserved."
        case .access(let path, let code):
            if permissionDenied {
                return "macOS denied access to \(path) (\(String(cString: strerror(code)))). Privacy protection or file permissions may be responsible. Previous complete reading preserved."
            }
            return "Cannot read \(path): \(String(cString: strerror(code))). Previous complete reading preserved."
        case .unavailable(let path): return "Cannot measure \(path) as a folder. Previous complete reading preserved."
        }
    }
}

/// Measures metadata only. Cached direct-directory totals allow changed directories to be refreshed
/// without traversing their unchanged descendants. No symlinks, packages on other volumes or file data are read.
enum GrowthScanner {
    static func contains(_ root: String, _ path: String) -> Bool { path == root || path.hasPrefix(root + "/") }
    static func scan(folder: GrowthFolder, previous: FolderCache?, changes: [GrowthChange],
                     excluded: [String], budget: GrowthBudget = GrowthBudget(), now: Date = Date()) throws -> FolderCache {
        let session = GrowthScanSession(folder: folder, previous: previous, changes: changes,
                                        excluded: excluded, directoryLimit: budget.directories, strictAccess: true)
        guard let cache = try session.advance(budget: budget, now: now) else { throw GrowthScanError.budget }
        return cache
    }
}

/// A serially owned scan cursor. Only one worker touches a session at a time.
/// Directory handles stay open between small slices, so a large directory is not restarted
/// at every budget boundary. Completed results alone become historical measurements.
final class GrowthScanSession: @unchecked Sendable {
    private final class Frame {
        let path: String
        let recursive: Bool
        let directory: UnsafeMutablePointer<DIR>
        var bytes: Int64
        var children = Set<String>()
        let oldChildren: Set<String>
        init(path: String, recursive: Bool, directory: UnsafeMutablePointer<DIR>, bytes: Int64, oldChildren: Set<String>) {
            self.path = path; self.recursive = recursive; self.directory = directory
            self.bytes = bytes; self.oldChildren = oldChildren
        }
        deinit { closedir(directory) }
    }
    let root: String
    let exclusions: [String]
    private var nodes: [String: DirectorySize]
    private var pending: [GrowthChange]
    private var frames: [Frame] = []
    private var device: dev_t = 0
    private let strictAccess: Bool
    private let directoryLimit: Int
    private var cacheComplete = true
    private var overflowBytes: Int64 = 0
    private var skipped = Set<String>()
    private var skippedCount = 0
    private var coverageHash: UInt64 = 0
    private var visited = Set<String>()
    private(set) var processedEntries = 0
    private var initialized = false
    private var fullTraversal: Bool

    init(folder: GrowthFolder, previous: FolderCache?, changes: [GrowthChange], excluded: [String],
         directoryLimit: Int = 10_000, strictAccess: Bool = false) {
        let normalizedRoot = URL(fileURLWithPath: folder.path).standardizedFileURL.path
        root = normalizedRoot
        exclusions = excluded.sorted()
        self.strictAccess = strictAccess
        self.directoryLimit = max(0, directoryLimit)
        let valid = previous?.root == root && previous?.exclusions == exclusions
            && (previous?.nodes.count ?? 0) <= max(0, directoryLimit) && previous?.incrementalReady != false
            && (previous?.skippedCount ?? 0) == (previous?.skippedPaths?.count ?? 0) ? previous : nil
        fullTraversal = valid == nil || changes.isEmpty || changes.contains { $0.path == normalizedRoot && $0.recursive }
        nodes = fullTraversal ? [:] : valid?.nodes ?? [:]
        let requests = fullTraversal ? [GrowthChange(path: root, recursive: true)] : changes
        // A recursive ancestor already covers descendant requests; keep the work list bounded.
        pending = requests.filter { change in
            !requests.contains { $0.recursive && $0.path != change.path && GrowthScanner.contains($0.path, change.path) }
        }
        if !fullTraversal, let valid {
            skipped = Set(valid.skippedPaths ?? []); skippedCount = valid.skippedCount ?? 0
            coverageHash = UInt64(valid.coverageID ?? "0") ?? 0
        }
    }
    private func removeTree(_ path: String) { nodes = nodes.filter { !GrowthScanner.contains(path, $0.key) } }
    private func skip(_ path: String, code: Int32) throws {
        if strictAccess || path == root { throw GrowthScanError.fileAccess(path, code: code) }
        if !skipped.contains(path) {
            skippedCount += 1
            coverageHash = coverageHash &+ fingerprint(path)
        }
        skipped.insert(path)
        if skipped.count > 32 { skipped.remove(skipped.max()!) }
        removeTree(path)
    }
    private func fingerprint(_ path: String) -> UInt64 {
        // Commutative sum of stable hashes covers every skipped path with bounded storage.
        var hash: UInt64 = 14695981039346656037
        for byte in path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return hash
    }
    private func open(_ path: String, recursive: Bool) throws {
        guard GrowthScanner.contains(root, path), !exclusions.contains(where: { GrowthScanner.contains($0, path) }) else { return }
        var info = stat()
        if lstat(path, &info) != 0 {
            let code = errno
            if code == ENOENT { removeTree(path); return }
            try skip(path, code: code); return
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_dev == device else { removeTree(path); return }
        // Bound open handles and path depth. Unusually deep data remains explicitly outside coverage.
        guard frames.count < 32 else { try skip(path, code: ELOOP); return }
        guard let directory = opendir(path) else { try skip(path, code: errno); return }
        for restored in skipped.filter({ recursive ? GrowthScanner.contains(path, $0) : $0 == path }) {
            skipped.remove(restored); skippedCount -= 1
            coverageHash = coverageHash &- fingerprint(restored)
        }
        let oldChildren = nodes[path]?.children ?? []
        if recursive && nodes[path] != nil { removeTree(path) }
        frames.append(Frame(path: path, recursive: recursive, directory: directory,
                            bytes: Int64(info.st_blocks) * 512, oldChildren: oldChildren))
    }
    /// nil means more work remains, not a failure. Limits apply to this slice only.
    func advance(budget: GrowthBudget = GrowthBudget(seconds: 1, entries: 2_000), now: Date = Date()) throws -> FolderCache? {
        try Task.checkCancellation()
        guard budget.seconds > 0, budget.entries > 0 else { return nil }
        if !initialized {
            var info = stat()
            if lstat(root, &info) != 0 {
                let code = errno
                if code == ENOENT { pending = []; return FolderCache(root: root, nodes: [:], measuredAt: now, exclusions: exclusions) }
                throw GrowthScanError.fileAccess(root, code: code)
            }
            guard info.st_mode & S_IFMT == S_IFDIR else { throw GrowthScanError.unavailable(root) }
            device = info.st_dev
            initialized = true
        }
        let start = ProcessInfo.processInfo.systemUptime
        var count = 0
        while count < budget.entries && ProcessInfo.processInfo.systemUptime - start < budget.seconds {
            try Task.checkCancellation()
            if frames.isEmpty {
                guard let change = pending.popLast() else {
                    let total = nodes.values.reduce(overflowBytes) { $0 + $1.bytes }
                    let finalNodes = cacheComplete ? nodes : [root: DirectorySize(bytes: total, children: [])]
                    return FolderCache(root: root, nodes: finalNodes, measuredAt: now, exclusions: exclusions,
                                       incrementalReady: cacheComplete, skippedPaths: skipped.sorted(), skippedCount: skippedCount, coverageID: String(coverageHash))
                }
                let key = change.path + (change.recursive ? "/*" : "")
                if visited.count < 256 && !visited.insert(key).inserted { continue }
                try open(change.path, recursive: change.recursive)
                continue
            }
            let frame = frames.last!
            errno = 0
            guard let pointer = readdir(frame.directory) else {
                let code = errno
                if code != 0 {
                    try skip(frame.path, code: code)
                    frames.removeLast()
                    continue
                }
                for removed in frame.oldChildren.subtracting(frame.children) { removeTree(removed) }
                if nodes[frame.path] != nil || nodes.count < directoryLimit {
                    nodes[frame.path] = DirectorySize(bytes: frame.bytes, children: frame.children)
                } else {
                    cacheComplete = false
                    overflowBytes += frame.bytes
                }
                frames.removeLast()
                continue
            }
            let name = withUnsafePointer(to: &pointer.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(pointer.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            count += 1; processedEntries += 1
            if count % 128 == 0 { Thread.sleep(forTimeInterval: 0.002) }
            let child = URL(fileURLWithPath: frame.path).appendingPathComponent(name).path
            if exclusions.contains(where: { GrowthScanner.contains($0, child) }) { continue }
            var item = stat()
            if lstat(child, &item) != 0 {
                let code = errno
                if code != ENOENT { try skip(child, code: code) }
                continue
            }
            if item.st_dev != device || item.st_mode & S_IFMT == S_IFLNK { continue }
            if item.st_mode & S_IFMT == S_IFDIR {
                if frame.children.count < directoryLimit { frame.children.insert(child) }
                else { cacheComplete = false }
                if frame.recursive || nodes[child] == nil { try open(child, recursive: true) }
            } else if item.st_mode & S_IFMT == S_IFREG { frame.bytes += Int64(item.st_blocks) * 512 }
            if !cacheComplete && !fullTraversal {
                // A targeted update that outgrows its cache restarts once as a streamed full total.
                // Later changes to an aggregate-only category also use sliced full traversal.
                fullTraversal = true; cacheComplete = true
                frames = []; nodes = [:]; overflowBytes = 0
                skipped = []; skippedCount = 0; coverageHash = 0; visited = []
                pending = [GrowthChange(path: root, recursive: true)]
            }
        }
        return nil
    }
}

struct GrowthArchive: Codable, Sendable {
    var caches: [String: FolderCache] = [:]
    var readings: [GrowthReading] = []
}

/// Small bounded history (90 days / 10,000 readings) and an atomic directory-total cache.
/// All calls are made by detached background-priority tasks, never by the UI/disk-refresh timer.
struct GrowthStore: Sendable {
    let directory: URL
    init(directory: URL = HistoryStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Growth")) {
        self.directory = directory
    }
    func load() throws -> GrowthArchive {
        let url = directory.appendingPathComponent("growth.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return GrowthArchive() }
        return try JSONDecoder().decode(GrowthArchive.self, from: Data(contentsOf: url))
    }
    func save(_ archive: GrowthArchive) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: directory.appendingPathComponent("growth.json"), options: .atomic)
    }
    static func adding(cache: FolderCache, folderID: String, to archive: GrowthArchive) -> GrowthArchive {
        var updated = archive
        if let previous = updated.caches[folderID], previous.root != cache.root || previous.exclusions != cache.exclusions
            || (previous.skippedPaths ?? []) != (cache.skippedPaths ?? [])
            || (previous.skippedCount ?? 0) != (cache.skippedCount ?? 0)
            || (previous.coverageID ?? "0") != (cache.coverageID ?? "0") {
            // A changed scope is a new baseline, not apparent file growth or shrinkage.
            updated.readings.removeAll { $0.folderID == folderID }
        }
        updated.caches[folderID] = cache
        updated.readings.append(GrowthReading(date: cache.measuredAt, folderID: folderID, bytes: cache.bytes))
        let cutoff = cache.measuredAt.addingTimeInterval(-90 * 86_400)
        updated.readings = Array(updated.readings.filter { $0.date >= cutoff }.suffix(10_000))
        return updated
    }
    static func baseline(_ readings: [GrowthReading], folderID: String, before date: Date) -> GrowthReading? {
        var best: GrowthReading?
        for reading in readings where reading.folderID == folderID && reading.date <= date {
            if best == nil || reading.date > best!.date { best = reading }
        }
        return best
    }
}

/// One background slice per 30 seconds, fair rotation across categories, and
/// a 30-minute cooldown for starting a new measurement (not for continuing one).
struct GrowthSchedule {
    static let globalCooldown: TimeInterval = 30
    static let folderCooldown: TimeInterval = 1800
    var lastAttempt: Date = .distantPast
    var attempts: [String: Date] = [:]
    var slices: [String: Date] = [:]
    func next(folders: [GrowthFolder], dirty: Set<String>, continuing: Set<String> = [], now: Date) -> GrowthFolder? {
        guard now.timeIntervalSince(lastAttempt) >= Self.globalCooldown else { return nil }
        return folders.filter { dirty.contains($0.id) && (continuing.contains($0.id)
            || now.timeIntervalSince(attempts[$0.id] ?? .distantPast) >= Self.folderCooldown) }
            .min { (slices[$0.id] ?? .distantPast) < (slices[$1.id] ?? .distantPast) }
    }
    mutating func started(_ id: String, at date: Date, continuing: Bool = false) {
        lastAttempt = date; slices[id] = date
        if !continuing { attempts[id] = date }
    }
}
