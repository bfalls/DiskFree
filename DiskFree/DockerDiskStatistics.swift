import Foundation
import Darwin
import CryptoKit

struct DockerDiskSnapshot: Sendable {
    let allocatedBytes: Int64
    let sourceID: String
    let path: String
}

enum DockerDiskReading: Sendable {
    case available(DockerDiskSnapshot)
    case notFound
    case unavailable(String)
    var snapshot: DockerDiskSnapshot? {
        if case .available(let snapshot) = self { return snapshot }
        return nil
    }
    var state: String {
        switch self { case .available: return "available"; case .notFound: return "missing"; case .unavailable: return "unavailable" }
    }
}

/// A few metadata lookups only: no enumeration, file-content reads, daemon calls or Docker startup.
/// Discovery reads a bounded local Docker settings file at most once per five minutes.
final class DockerDiskStatisticsProvider: StatisticsProvider, @unchecked Sendable {
    static let shared = DockerDiskStatisticsProvider()
    private let lock = NSLock()
    private let candidates: [URL]?
    private let settings: [URL]
    private let home: URL
    private let volume: URL
    private var discovered: [URL] = []
    private var lastDiscovery: Date = .distantPast
    init(candidates: [URL]? = nil, settings: [URL]? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser,
         volume: URL = URL(fileURLWithPath: "/System/Volumes/Data")) {
        self.candidates = candidates; self.home = home; self.volume = volume
        self.settings = settings ?? ["settings-store.json", "settings.json"].map {
            home.appendingPathComponent("Library/Group Containers/group.com.docker/" + $0)
        }
    }
    private func localPath(_ path: String) -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return false }
        var longest = -1, local = false
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let name = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if (name == "/" || path == name || path.hasPrefix(name + "/")), name.count > longest {
                longest = name.count; local = mount.f_flags & UInt32(MNT_LOCAL) != 0
            }
        }
        return local
    }
    private func discover(now: Date) -> [URL] {
        if let candidates { return candidates }
        if now.timeIntervalSince(lastDiscovery) < 300 { return discovered }
        lastDiscovery = now
        var urls: [URL] = []
        for url in settings where localPath(url.path) {
            guard let handle = try? FileHandle(forReadingFrom: url) else { continue }
            let data = try? handle.read(upToCount: 65_537)
            try? handle.close()
            guard let data, data.count <= 65_536,
                  let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let folder = (json["DataFolder"] ?? json["dataFolder"]) as? String, folder.hasPrefix("/") else { continue }
            let base = URL(fileURLWithPath: folder).standardizedFileURL
            urls += [base.appendingPathComponent("Docker.raw"), base.appendingPathComponent("Docker.qcow2")]
            // The configured location takes precedence; do not silently measure a stale default image.
            discovered = urls; return urls
        }
        let base = home.appendingPathComponent("Library/Containers/com.docker.docker/Data/vms/0")
        discovered = [base.appendingPathComponent("data/Docker.raw"), base.appendingPathComponent("data/Docker.qcow2"),
                      base.appendingPathComponent("Docker.qcow2")]
        return discovered
    }
    func collect() -> DockerDiskReading { collect(now: Date()) }
    func collect(now: Date) -> DockerDiskReading {
        lock.lock(); defer { lock.unlock() }
        var root = stat()
        guard stat(volume.path, &root) == 0 else { return .unavailable("Startup volume metadata is unavailable.") }
        var problem: String?
        for url in discover(now: now) {
            let path = url.standardizedFileURL.path
            guard localPath(path) else { problem = "Docker image is on a network volume; it is not monitored."; continue }
            var info = stat()
            if lstat(path, &info) != 0 {
                if errno != ENOENT { problem = "Docker image metadata is not readable. Check optional disk access." }
                continue
            }
            guard info.st_mode & S_IFMT == S_IFREG else { problem = "Docker image must be a regular local file."; continue }
            guard info.st_dev == root.st_dev else { problem = "Docker image is on another volume; it is excluded from startup-disk history."; continue }
            let identity = "\(path)|\(info.st_dev)|\(info.st_ino)"
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return .available(DockerDiskSnapshot(allocatedBytes: max(0, Int64(info.st_blocks) * 512), sourceID: id, path: path))
        }
        return problem.map(DockerDiskReading.unavailable) ?? .notFound
    }
}

/// Independent monthly logs keep the existing free-space CSV format unchanged.
actor DockerHistoryStore {
    nonisolated let directory: URL
    static let header = "timestamp_utc,allocated_bytes,source_id,state\n"
    private let formatter: ISO8601DateFormatter
    private var hasHistory: Bool?
    init(directory: URL) {
        self.directory = directory
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    @discardableResult func append(_ reading: DockerDiskReading, at date: Date) throws -> Bool {
        if hasHistory == nil { hasHistory = FileManager.default.fileExists(atPath: directory.path) }
        // Do not create or repeatedly write empty Docker logs on a Mac without a measured image.
        guard reading.snapshot != nil || hasHistory == true else { return false }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = formatter.string(from: date)
        let url = directory.appendingPathComponent(String(timestamp.prefix(7)) + ".csv")
        if !FileManager.default.fileExists(atPath: url.path) { try Data(Self.header.utf8).write(to: url, options: .atomic) }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        var prefix = ""
        if length > 0 {
            try handle.seek(toOffset: length - 1)
            if try handle.read(upToCount: 1)?.first != 10 { prefix = "\n" }
        }
        try handle.seekToEnd()
        let bytes = reading.snapshot.map { String($0.allocatedBytes) } ?? ""
        try handle.write(contentsOf: Data("\(prefix)\(timestamp),\(bytes),\(reading.snapshot?.sourceID ?? ""),\(reading.state)\n".utf8))
        hasHistory = true
        return true
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.csv$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func record(_ line: String) -> (date: Date, bytes: Int64?, source: String)? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 4, let date = formatter.date(from: String(fields[0])) else { return nil }
        if fields[3] == "available" {
            let id = String(fields[2])
            guard let bytes = Int64(fields[1]), bytes >= 0, id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else { return nil }
            return (date, bytes, id)
        }
        guard ["missing", "unavailable"].contains(String(fields[3])), fields[1].isEmpty, fields[2].isEmpty else { return nil }
        return (date, nil, "")
    }
    func load(from start: Date, through end: Date, bucketSeconds: TimeInterval) throws -> HistoryResult {
        let origin = HistoryStore.bucketOrigin(for: start)
        let width = max(60, bucketSeconds)
        var buckets: [Int: HistoryPoint] = [:], count = 0, skipped = 0, gap = 0
        let firstMonth = String(formatter.string(from: start).prefix(7)), lastMonth = String(formatter.string(from: end).prefix(7))
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month >= firstMonth && month <= lastMonth else { continue }
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: 96, parse: { line -> ParsedHistoryLine<(date: Date, bytes: Int64?, source: String)>? in
                if line.isEmpty || line == Self.header.trimmingCharacters(in: .newlines) { return nil }
                guard var row = record(line) else { return .invalid }
                row.source = JournalStrings.shared.intern(row.source)
                return .value(row)
            }) { entry in
                guard case let .value(row) = entry else { skipped += 1; gap += 1; return }
                guard row.date >= start && row.date <= end else { return }
                guard let bytes = row.bytes else { gap += 1; return }
                count += 1
                let index = Int(row.date.timeIntervalSince(origin) / width), gb = Double(bytes) / 1_000_000_000
                let series = "\(row.source)-\(gap)"
                if var point = buckets[index], point.seriesID == series {
                    point.minGB = min(point.minGB, gb); point.maxGB = max(point.maxGB, gb); point.samples += 1
                    if row.date >= point.lastDate { point.lastDate = row.date; point.lastGB = gb }
                    buckets[index] = point
                } else {
                    buckets[index] = HistoryPoint(date: origin.addingTimeInterval(Double(index) * width), lastDate: row.date,
                        lastGB: gb, minGB: gb, maxGB: gb, samples: 1, sourceID: row.source, seriesID: series)
                }
            }
        }
        return HistoryResult(points: buckets.keys.sorted().compactMap { buckets[$0] }, sampleCount: count,
                             skippedLines: skipped, bucketSeconds: width)
    }
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        var removed = 0
        let cutoffMonth = String(formatter.string(from: cutoff).prefix(7))
        for url in try files() where url.deletingPathExtension().lastPathComponent <= cutoffMonth {
            var retained = Data(Self.header.utf8), old = 0, malformed = false
            try HistoryStore.forEachLine(in: url) { line in
                if line.isEmpty || line == Self.header.trimmingCharacters(in: .newlines) { return }
                guard let row = record(line) else { malformed = true; return }
                if row.date < cutoff { old += 1 } else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !malformed else { throw NSError(domain: "DiskFree.DockerHistory", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Malformed Docker history preserved in \(url.lastPathComponent). Earlier files may already have been cleaned."]) }
            if old > 0 {
                if retained.count == Self.header.utf8.count { try FileManager.default.removeItem(at: url) }
                else { try retained.write(to: url, options: .atomic) }
                removed += old
            }
        }
        return removed
    }
}
