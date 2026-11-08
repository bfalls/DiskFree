import Foundation
import CryptoKit
import Darwin

struct BackupLogRecord: Codable, Sendable, Identifiable {
    let id: String
    let date: Date
    let boot: String
    let process: Int
    let category: String
    let message: String
    var processKey: String { boot + ":" + String(process) }
    func valid() -> Bool {
        id.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil && UUID(uuidString: boot) != nil
            && process > 0 && date.timeIntervalSince1970.isFinite && message.utf8.count <= 32768
    }
}
enum BackupOutcome: String, Codable, Sendable { case succeeded = "Succeeded", failed = "Failed", cancelled = "Cancelled", unverified = "Stopped" }
struct BackupVolumeStatistics: Sendable {
    var files: Int64?
    var folders: Int64?
    var items: Int64?
    var contentsBytes: Int64?
}
struct BackupSession: Sendable, Identifiable {
    let id: String
    var start: Date?
    var end: Date?
    var outcome: BackupOutcome = .unverified
    var destination: String?
    var snapshot: String?
    var copiedBytes: Int64?
    var transferredItems: Int64?
    var destinationFree: Int64?
    var volumes: [String: BackupVolumeStatistics] = [:]
    var evidence: [BackupLogRecord] = []
    var firstDate: Date { start ?? evidence.first!.date }
    var lastDate: Date { end ?? evidence.last!.date }
    private func sum(_ value: (BackupVolumeStatistics) -> Int64?) -> Int64? {
        let values = volumes.values.compactMap(value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0) { $0 > Int64.max - $1 ? Int64.max : $0 + $1 }
    }
    var files: Int64? { sum { $0.files } }
    var contentsBytes: Int64? { sum { $0.contentsBytes } }
    var duration: String? {
        guard let start, let end, end >= start else { return nil }
        let seconds = Int(end.timeIntervalSince(start).rounded())
        return seconds >= 3600 ? "\(seconds / 3600)h \(seconds / 60 % 60)m" : "\(seconds / 60)m \(seconds % 60)s"
    }
    var facts: [(String, String)] {
        var rows = [("Result", end == nil ? "Completion not recorded" : outcome.rawValue)]
        if let start { rows.append(("Started", start.formatted(date: .abbreviated, time: .standard))) }
        if let end { rows.append(("Finished", end.formatted(date: .abbreviated, time: .standard))) }
        if let duration { rows.append(("Duration", duration)) }
        if let copiedBytes { rows.append(("Copied", CapacityFormat.string(copiedBytes))) }
        if let files { rows.append(("Files copied", files.formatted())) }
        else if let transferredItems { rows.append(("Items transferred", transferredItems.formatted())) }
        if let contentsBytes { rows.append(("Backup contents (reported)", "≈" + CapacityFormat.string(contentsBytes))) }
        if let destinationFree { rows.append(("Destination free (reported)", CapacityFormat.string(destinationFree))) }
        if let destination { rows.append(("Destination", destination)) }
        return rows
    }
}

/// Parses only session-level backupd messages. Component errors are not backup failures.
enum BackupLogParser {
    static func groups(_ pattern: String, _ text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
    }
    static func relevant(_ message: String) -> Bool {
        let prefixes = ["Starting ", "Completed backup:", "Backup failed", "Backup cancelled", "Backup canceled", "Backup result:", "Backing up ", "Finished copying from volume"]
        return prefixes.contains { message.hasPrefix($0) }
    }
    static func decode(_ text: String) -> [BackupLogRecord] {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSSSSSZ"; formatter.isLenient = false
        return text.split(separator: "\n").compactMap { line in
            guard let value = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = value["eventMessage"] as? String, relevant(message),
                  value["subsystem"] as? String == "com.apple.TimeMachine",
                  let timestamp = value["timestamp"] as? String, let date = formatter.date(from: timestamp),
                  let boot = value["bootUUID"] as? String, let process = value["processID"] as? Int,
                  let category = value["category"] as? String,
                  category == "General" || category == "CopyProgress" else { return nil }
            let identity = boot + ":\(process):" + timestamp + ":" + category + ":" + message
            let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            let record = BackupLogRecord(id: id, date: date, boot: boot, process: process, category: category, message: message)
            return record.valid() ? record : nil
        }
    }
    static func bytes(_ text: String) -> Int64? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2 else { return nil }
        let amount = parts[0] == "Zero" ? 0 : Double(parts[0].replacingOccurrences(of: ",", with: ""))
        let units: [String: Double] = ["bytes": 1, "byte": 1, "B": 1, "KB": 1e3, "MB": 1e6, "GB": 1e9, "TB": 1e12]
        guard let amount, let multiplier = units[String(parts[1])], amount >= 0,
              (amount * multiplier).isFinite, amount * multiplier < Double(Int64.max) else { return nil }
        return Int64((amount * multiplier).rounded())
    }
    static func sessions(_ records: [BackupLogRecord]) -> [BackupSession] {
        var result: [BackupSession] = [], active: [String: Int] = [:]
        for record in records.sorted(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }) {
            let message = record.message
            let starting = record.category == "General" && groups(#"^Starting (?:(?:automatic|manual|standard|scheduled|on-demand) )?backup\b"#, message) != nil
            let terminal: BackupOutcome? = record.category != "General" ? nil : message.hasPrefix("Completed backup:") ? .succeeded
                : message.hasPrefix("Backup failed") ? .failed
                : message.hasPrefix("Backup cancelled") || message.hasPrefix("Backup canceled") ? .cancelled : nil
            if starting || active[record.processKey] == nil {
                guard starting || terminal != nil || message.hasPrefix("Backup result:") || message.hasPrefix("Finished copying") else { continue }
                result.append(BackupSession(id: record.id, start: starting ? record.date : nil))
                active[record.processKey] = result.count - 1
            }
            guard let index = active[record.processKey] else { continue }
            result[index].evidence.append(record)
            if message.hasPrefix("Backing up "), let fields = groups(#"^Backing up \d+ volumes? to (.+?) \([^\n]+\): "#, message) { result[index].destination = fields[0] }
            if message.hasPrefix("Backup result:"), let brace = message.firstIndex(of: "{"),
               let plist = try? PropertyListSerialization.propertyList(from: Data(message[brace...].utf8), options: [], format: nil) as? [String: Any] {
                func integer(_ value: Any?) -> Int64? {
                    let number = (value as? String).flatMap(Int64.init) ?? (value as? NSNumber).flatMap { Int64($0.stringValue) }
                    return number.flatMap { $0 >= 0 ? $0 : nil }
                }
                result[index].copiedBytes = integer(plist["com.apple.backupd.SnapshotTotalBytesCopied"]) ?? result[index].copiedBytes
                result[index].destinationFree = integer(plist["FreeBytes"]) ?? result[index].destinationFree
                if let progress = plist["Progress"] as? [String: Any] { result[index].transferredItems = integer(progress["files"]) }
                if result[index].destination == nil, let path = plist["DestinationMountPoint"] as? String { result[index].destination = URL(fileURLWithPath: path).lastPathComponent }
            }
            if message.hasPrefix("Finished copying"), let volume = groups(#"^Finished copying from volume \"([^\"]+)\""#, message)?.first {
                var statistics = BackupVolumeStatistics()
                func count(_ label: String) -> Int64? {
                    groups("(?m)^\\s*([0-9,]+) " + label + "\\b", message)?.first.flatMap { Int64($0.replacingOccurrences(of: ",", with: "")) }
                }
                statistics.files = count("Files Copied"); statistics.folders = count("Directories Copied"); statistics.items = count("Total Items in Backup")
                if let physical = groups(#"(?m)^\s*[0-9,]+ Total Items in Backup \(l:[^\n]*?p:\s*([^\)]+)\)"#, message)?.first { statistics.contentsBytes = bytes(physical) }
                result[index].volumes[volume] = statistics // last summary for each volume; never double-count retries
            }
            if let terminal {
                result[index].outcome = terminal; result[index].end = record.date
                if terminal == .succeeded { result[index].snapshot = String(message.dropFirst("Completed backup:".count)).trimmingCharacters(in: .whitespacesAndNewlines) }
                active.removeValue(forKey: record.processKey)
            }
        }
        return result
    }
}

/// One indexed, session-message-only query, bounded in runtime and output. No mounts or sudo.
enum BackupLogQueryError: Error { case workLimit }
enum BackupLogReader {
    static func read(from start: Date, through end: Date) throws -> [BackupLogRecord] {
        let predicate = #"process == "backupd" AND subsystem == "com.apple.TimeMachine" AND ((category == "General" AND (eventMessage BEGINSWITH "Starting " OR eventMessage BEGINSWITH "Completed backup:" OR eventMessage BEGINSWITH "Backup failed" OR eventMessage BEGINSWITH "Backup cancelled" OR eventMessage BEGINSWITH "Backup canceled" OR eventMessage BEGINSWITH "Backup result:" OR eventMessage BEGINSWITH "Backing up ")) OR (category == "CopyProgress" AND eventMessage BEGINSWITH "Finished copying from volume"))"#
        return BackupLogParser.decode(try output(from: start, through: end, predicate: predicate))
    }
    static func output(from start: Date, through end: Date, predicate: String, cap: Int = 4_194_304) throws -> String {
        let format = DateFormatter(); format.locale = Locale(identifier: "en_US_POSIX"); format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/log")
        process.arguments = ["show", "--style", "ndjson", "--info", "--start", format.string(from: start), "--end", format.string(from: end), "--predicate", predicate]
        process.standardOutput = output; process.standardError = output; process.qualityOfService = .utility
        try process.run()
        let watchdog = DispatchWorkItem { if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) } }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 15, execute: watchdog)
        defer { watchdog.cancel(); if process.isRunning { process.terminate() } }
        var data = Data()
        while let chunk = try output.fileHandleForReading.read(upToCount: 65536), !chunk.isEmpty {
            guard data.count + chunk.count <= cap else {
                _ = Darwin.kill(process.processIdentifier, SIGKILL); process.waitUntilExit()
                throw BackupLogQueryError.workLimit
            }
            data.append(chunk)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            if process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL { throw BackupLogQueryError.workLimit }
            throw BackupToolError.unavailable("Time Machine log records are unavailable.")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

actor BackupLogStore {
    typealias Query = @Sendable (Date, Date) throws -> [BackupLogRecord]
    nonisolated let directory: URL
    private let query: Query
    private var ids: Set<String>?
    init(directory: URL, query: @escaping Query = { try BackupLogReader.read(from: $0, through: $1) }) { self.directory = directory; self.query = query }
    nonisolated func source(for date: Date) -> URL {
        let format = ISO8601DateFormatter()
        return directory.appendingPathComponent(String(format.string(from: date).prefix(7)) + ".jsonl")
    }
    nonisolated private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.jsonl$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    nonisolated private func records() throws -> (values: [BackupLogRecord], skipped: Int) {
        let decoder = JSONDecoder(); var values: [BackupLogRecord] = [], skipped = 0
        for url in try files() {
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: 2048, parse: { line -> ParsedHistoryLine<BackupLogRecord>? in
                if line.isEmpty { return nil }
                guard let record = try? decoder.decode(BackupLogRecord.self, from: Data(line.utf8)), record.valid() else { return .invalid }
                return .value(record)
            }) { entry in
                guard case let .value(record) = entry else { skipped += 1; return }
                values.append(record)
            }
        }
        return (values, skipped)
    }
    func importRecords(_ records: [BackupLogRecord]) throws -> Int {
        if ids == nil { ids = Set(try self.records().values.map(\.id)) }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var added = 0
        for record in records where record.valid() && !ids!.contains(record.id) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let url = source(for: record.date)
            if !FileManager.default.fileExists(atPath: url.path) { _ = FileManager.default.createFile(atPath: url.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.seekToEnd(); var data = Data([10]); data.append(try encoder.encode(record)); data.append(10)
                try handle.write(contentsOf: data); try handle.close()
            } catch { try? handle.close(); throw error }
            ids!.insert(record.id); added += 1
        }
        return added
    }
    func reconcile(from start: Date, through end: Date) async throws -> Int {
        try Task.checkCancellation()
        let query = self.query
        do {
            let records = try await Task.detached(priority: .utility) { try query(start, end) }.value
            try Task.checkCancellation()
            return try importRecords(records.filter { $0.date >= start.addingTimeInterval(-1) && $0.date <= end.addingTimeInterval(1) })
        } catch BackupLogQueryError.workLimit {
            try Task.checkCancellation()
            guard end.timeIntervalSince(start) > 3600 else { throw BackupLogQueryError.workLimit }
            let middle = start.addingTimeInterval(end.timeIntervalSince(start) / 2)
            let earlier = try await reconcile(from: start, through: middle)
            return earlier + (try await reconcile(from: middle, through: end))
        }
    }
    private struct Migration: Codable { var version = 1; var cursor: Date; let through: Date; var complete = false }
    /// Thirty daily slices, checkpointed after each successful query; retries resume safely.
    func migrateOnce(now: Date = Date()) async throws -> Int {
        let marker = directory.appendingPathComponent("import-v1.json")
        var state: Migration
        if let data = try? Data(contentsOf: marker), let existing = try? JSONDecoder().decode(Migration.self, from: data), existing.version == 1 { state = existing }
        else { state = Migration(cursor: now.addingTimeInterval(-30 * 86400), through: now) }
        guard !state.complete else { return 0 }
        var added = 0
        while state.cursor < state.through {
            try Task.checkCancellation()
            let finish = min(state.through, state.cursor.addingTimeInterval(86400))
            added += try await reconcile(from: state.cursor, through: finish)
            state.cursor = finish; state.complete = finish >= state.through
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: marker, options: .atomic)
            if !state.complete { try await Task.sleep(nanoseconds: 100_000_000) }
        }
        return added
    }
    nonisolated func sessions() throws -> (values: [BackupSession], skipped: Int) {
        let read = try records()
        return (BackupLogParser.sessions(read.values), read.skipped)
    }
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        var removed = 0
        for url in try files() where url.lastPathComponent <= source(for: cutoff).lastPathComponent {
            let decoder = JSONDecoder(); var kept = Data(), old = 0, malformed = false
            try HistoryStore.forEachLine(in: url) { line in
                guard !line.isEmpty else { return }
                guard let record = try? decoder.decode(BackupLogRecord.self, from: Data(line.utf8)), record.valid() else { malformed = true; return }
                if record.date < cutoff { old += 1 } else { kept.append(contentsOf: line.utf8); kept.append(10) }
            }
            guard !malformed else { throw CocoaError(.fileReadCorruptFile) }
            if old > 0 {
                if kept.isEmpty { try FileManager.default.removeItem(at: url) } else { try kept.write(to: url, options: .atomic) }
                removed += old
            }
        }
        ids = nil; return removed
    }
}
