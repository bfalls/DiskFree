import Foundation

struct HistorySample: Sendable {
    let date: Date
    let freeBytes: Int64
    let totalBytes: Int64
}

struct HistoryPoint: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    var lastDate: Date
    var lastGB: Double
    var minGB: Double
    var maxGB: Double
    var samples: Int
}

struct HistoryResult: Sendable {
    let points: [HistoryPoint]
    let sampleCount: Int
    let skippedLines: Int
    let bucketSeconds: TimeInterval
}

/// Serializes append, streaming reads and cleanup; never executes file I/O on the UI actor.
actor HistoryStore {
    nonisolated let directory: URL
    static let header = "timestamp_utc,free_bytes,total_bytes\n"
    private let formatter: ISO8601DateFormatter
    init(directory: URL = HistoryStore.defaultDirectory) {
        self.directory = directory
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }
    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DiskFree/History", isDirectory: true)
    }
    func append(_ snapshot: DiskSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = formatter.string(from: snapshot.refreshedAt)
        let url = directory.appendingPathComponent(String(timestamp.prefix(7)) + ".csv")
        // Atomic creation prevents an incomplete header. Later samples are append-only.
        if !FileManager.default.fileExists(atPath: url.path) {
            try Data(Self.header.utf8).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        // A interrupted write must not join a new sample to a partial old row.
        var prefix = ""
        if length > 0 {
            try handle.seek(toOffset: length - 1)
            if try handle.read(upToCount: 1)?.first != 10 { prefix = "\n" }
        }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(prefix)\(timestamp),\(snapshot.freeBytes),\(snapshot.totalBytes)\n".utf8))
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.csv$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func sample(_ line: String) -> HistorySample? {
        let fields = line.split(separator: ",", omittingEmptySubsequences: false)
        guard fields.count == 3, let date = formatter.date(from: String(fields[0])),
              let free = Int64(fields[1]), let total = Int64(fields[2]), free >= 0, total >= free else { return nil }
        return HistorySample(date: date, freeBytes: free, totalBytes: total)
    }
    /// Reads one bounded chunk at a time, rather than loading years of logs into memory.
    private func forEachLine(in url: URL, _ body: (String) throws -> Void) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var pending = Data()
        while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
            try Task.checkCancellation()
            pending.append(chunk)
            while let newline = pending.firstIndex(of: 10) {
                try body(String(decoding: pending[..<newline], as: UTF8.self))
                pending.removeSubrange(...newline)
            }
            if pending.count > 65_536 {
                throw NSError(domain: "DiskFree.History", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "An oversized history row was found in \(url.lastPathComponent)."])
            }
        }
        // Only newline-terminated records are committed; a partial tail is ignored.
        if !pending.isEmpty { try body("[incomplete row]") }
    }
    func load(from start: Date, through end: Date, bucketSeconds: TimeInterval) throws -> HistoryResult {
        let width = max(60, bucketSeconds)
        var buckets: [Int: HistoryPoint] = [:]
        var count = 0
        var skipped = 0
        let firstMonth = String(formatter.string(from: start).prefix(7))
        let lastMonth = String(formatter.string(from: end).prefix(7))
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month >= firstMonth && month <= lastMonth else { continue }
            try forEachLine(in: url) { line in
                if line == Self.header.trimmingCharacters(in: .newlines) || line.isEmpty { return }
                guard let record = sample(line) else { skipped += 1; return }
                guard record.date >= start && record.date <= end else { return }
                count += 1
                let index = Int(record.date.timeIntervalSince(start) / width)
                let gb = Double(record.freeBytes) / 1_000_000_000
                if var point = buckets[index] {
                    point.minGB = min(point.minGB, gb)
                    point.maxGB = max(point.maxGB, gb)
                    point.samples += 1
                    if record.date >= point.lastDate { point.lastDate = record.date; point.lastGB = gb }
                    buckets[index] = point
                } else {
                    buckets[index] = HistoryPoint(date: start.addingTimeInterval(Double(index) * width),
                        lastDate: record.date, lastGB: gb, minGB: gb, maxGB: gb, samples: 1)
                }
            }
        }
        return HistoryResult(points: buckets.keys.sorted().compactMap { buckets[$0] },
                             sampleCount: count, skippedLines: skipped, bucketSeconds: width)
    }
    /// Deletes full old months and rewrites the cutoff month atomically, preserving newer rows.
    /// Other files and unreadable/malformed data are never silently deleted.
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        let cutoffMonth = String(formatter.string(from: cutoff).prefix(7))
        var removed = 0
        for url in try files() {
            let month = url.deletingPathExtension().lastPathComponent
            guard month <= cutoffMonth else { continue }
            var retained = Data(Self.header.utf8)
            var oldCount = 0
            var unknown = false
            try forEachLine(in: url) { line in
                if line == Self.header.trimmingCharacters(in: .newlines) || line.isEmpty { return }
                guard let record = sample(line) else { unknown = true; return }
                if record.date < cutoff { oldCount += 1 }
                else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !unknown else {
                throw NSError(domain: "DiskFree.History", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Cleanup stopped to preserve malformed data in \(url.lastPathComponent). Earlier months may already have been cleaned."])
            }
            if oldCount > 0 {
                if retained.count == Self.header.utf8.count { try FileManager.default.removeItem(at: url) }
                else { try retained.write(to: url, options: .atomic) }
                removed += oldCount
            }
        }
        return removed
    }
}
