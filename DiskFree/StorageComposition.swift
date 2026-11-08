import Foundation
import Darwin

enum ConsumerKind: String, Codable, CaseIterable, Sendable {
    case docker, swap, models, developer, caches, downloads, backups, applicationData, custom, other, free
    var title: String {
        switch self {
        case .docker: return "Docker"
        case .swap: return "Swap"
        case .models: return "AI models / caches"
        case .developer: return "Development / games"
        case .caches: return "App caches"
        case .downloads: return "Downloads"
        case .backups: return "Device backups"
        case .applicationData: return "Application data"
        case .custom: return "Other tracked folders"
        case .other: return "Other used / system"
        case .free: return "Free"
        }
    }
    static func forFolder(_ id: String) -> ConsumerKind {
        if id.hasPrefix("consumer.ai.") { return .models }
        if id.hasPrefix("consumer.dev.") || ["builds", "archives", "simulators"].contains(id) { return .developer }
        switch id {
        case "downloads": return .downloads
        case "caches": return .caches
        case "backups": return .backups
        case "appdata": return .applicationData
        default: return .custom
        }
    }
}
struct ConsumerDefinition: Sendable {
    let id: String
    let name: String
    let path: String
    let application: String?
    let documentation: String
    var folder: GrowthFolder { GrowthFolder(id: id, name: name, path: path) }
}
struct StorageDiscovery: Sendable {
    let definitions: [ConsumerDefinition]
    let dockerPath: String?
    static func candidates(home: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> [ConsumerDefinition] {
        func local(_ value: String?, fallback: String) -> String {
            guard let value, value.hasPrefix("/"), !value.contains("\0") else { return home + fallback }
            return URL(fileURLWithPath: value).standardizedFileURL.path
        }
        let hfHome = local(environment["HF_HOME"], fallback: "/.cache/huggingface")
        let hub = environment["HF_HUB_CACHE"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? hfHome + "/hub"
        let xet = environment["HF_XET_CACHE"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? hfHome + "/xet"
        return [
            ConsumerDefinition(id: "consumer.ai.ollama", name: "Ollama models", path: local(environment["OLLAMA_MODELS"], fallback: "/.ollama/models"), application: "Ollama", documentation: "https://docs.ollama.com/faq#where-are-models-stored"),
            ConsumerDefinition(id: "consumer.ai.lmstudio", name: "LM Studio models", path: home + "/.lmstudio/models", application: "LM Studio", documentation: "https://lmstudio.ai/docs/app/advanced/import-model"),
            ConsumerDefinition(id: "consumer.ai.lmstudio-legacy", name: "LM Studio legacy models", path: home + "/.cache/lm-studio/models", application: "LM Studio", documentation: "https://lmstudio.ai/docs/app/advanced/import-model"),
            ConsumerDefinition(id: "consumer.ai.huggingface", name: "Hugging Face models / datasets", path: hub, application: nil, documentation: "https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables"),
            ConsumerDefinition(id: "consumer.ai.huggingface-xet", name: "Hugging Face download cache", path: xet, application: nil, documentation: "https://huggingface.co/docs/huggingface_hub/en/package_reference/environment_variables"),
            ConsumerDefinition(id: "consumer.ai.gpt4all", name: "GPT4All models / data", path: home + "/Library/Application Support/nomic.ai/GPT4All", application: "GPT4All", documentation: "https://docs.gpt4all.io/gpt4all_desktop/settings.html"),
            ConsumerDefinition(id: "consumer.dev.gradle", name: "Gradle cache", path: home + "/.gradle/caches", application: nil, documentation: "https://docs.gradle.org/current/userguide/directory_layout.html"),
            ConsumerDefinition(id: "consumer.dev.npm", name: "npm download cache", path: home + "/.npm/_cacache", application: nil, documentation: "https://docs.npmjs.com/cli/commands/npm-cache"),
            ConsumerDefinition(id: "consumer.dev.pnpm", name: "pnpm package store", path: home + "/Library/pnpm/store", application: nil, documentation: "https://pnpm.io/settings#storedir"),
            ConsumerDefinition(id: "consumer.dev.android", name: "Android system images", path: home + "/Library/Android/sdk/system-images", application: "Android Studio", documentation: "https://developer.android.com/studio/run/managing-avds"),
            ConsumerDefinition(id: "consumer.dev.android-avd", name: "Android emulators", path: home + "/.android/avd", application: "Android Studio", documentation: "https://developer.android.com/studio/run/emulator-commandline"),
            ConsumerDefinition(id: "consumer.dev.steam", name: "Steam games", path: home + "/Library/Application Support/Steam/steamapps", application: "Steam", documentation: "https://help.steampowered.com/")
        ]
    }
    /// Cached mount metadata is checked before lstat, so discovery never touches network mounts.
    static func startupDirectory(_ path: String, volume: String = "/System/Volumes/Data") -> Bool {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { return false }
        var longest = -1, local = false
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let name = withUnsafePointer(to: &mount.f_mntonname) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if (name == "/" || GrowthScanner.contains(name, path)), name.count > longest {
                longest = name.count; local = mount.f_flags & UInt32(MNT_LOCAL) != 0
            }
        }
        guard local else { return false }
        var root = stat(), item = stat()
        guard lstat(volume, &root) == 0 else { return false }
        // Check ancestors before descendants: never traverse a parent symlink into another volume.
        var current = ""
        for component in (path as NSString).pathComponents where component != "/" {
            guard component != "." && component != ".." else { return false }
            current += "/" + component
            guard lstat(current, &item) == 0, item.st_mode & S_IFMT == S_IFDIR else { return false }
        }
        return !current.isEmpty && item.st_dev == root.st_dev
    }

    static func collect() -> StorageDiscovery {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let definitions = candidates(home: home).filter { startupDirectory($0.path) }
        return StorageDiscovery(definitions: definitions, dockerPath: DockerDiskStatisticsProvider.shared.collect().snapshot?.path)
    }
}

struct ConsumerMeasurement: Codable, Sendable {
    let date: Date // When the observation entered history; never backdates a cached reading.
    let folderID: String
    let name: String
    let root: String
    let bytes: Int64
    let measuredAt: Date
    let exclusions: [String]
    let skipped: Int
    let coverage: String
    var active = true
    var endedReason: String? = nil
    var identity: String? = nil
    var kind: ConsumerKind { ConsumerKind.forFolder(folderID) }
    func valid() -> Bool { !folderID.isEmpty && name.count < 512 && root.hasPrefix("/") && bytes >= 0 && measuredAt <= date && exclusions.count < 1000 && skipped >= 0 }
}
struct StoragePortion: Identifiable, Sendable {
    var id: String { kind.rawValue }
    let kind: ConsumerKind
    let bytes: Int64
    let lower: Int64
    var upper: Int64 { lower + bytes }
}
struct StorageFrame: Identifiable, Sendable {
    var id: Date { date }
    let date: Date
    let total: Int64
    let free: Int64
    let consumers: [ConsumerMeasurement]
    let native: SystemRecord?
    let portions: [StoragePortion]
    let estimatedPortions: [StoragePortion]
    let overlap: Bool
    let omitted: Int
    let segment: Int
    var used: Int64 { total - free }
    var tracked: Int64 { estimatedPortions.last?.upper ?? 0 }
    static func make(date: Date, total: Int64, free: Int64, measurements: [ConsumerMeasurement], native: SystemRecord?, segment: Int = 0) -> StorageFrame {
        let total = max(0, total), free = max(0, min(total, free)), used = total - free
        let fresh = measurements.filter { $0.active && $0.date <= date && $0.measuredAt <= date && date.timeIntervalSince($0.measuredAt) <= 172_800 }
        let roots = Array(Set(fresh.map(\.root)))
        var accepted: [ConsumerMeasurement] = [], omitted = 0, seen = Set<String>(), identities = Set<String>()
        for row in fresh.sorted(by: { $0.folderID < $1.folderID }) {
            guard row.folderID != "swap" && row.folderID != "swap-vm",
                  !["/System/Volumes/VM", "/private/var/vm", "/var/vm"].contains(row.root), !seen.contains(row.root), row.identity == nil || !identities.contains(row.identity!) else { continue }
            let descendants = roots.filter { $0 != row.root && GrowthScanner.contains(row.root, $0) }
            let nativeRoots = [native?.dockerPath, "/System/Volumes/VM", "/private/var/vm"].compactMap { $0 }
            let overlaps = (descendants + nativeRoots.filter { GrowthScanner.contains(row.root, $0) }).contains { child in
                !row.exclusions.contains { GrowthScanner.contains($0, child) }
            }
            guard !overlaps else { omitted += 1; continue }
            accepted.append(row); seen.insert(row.root); if let identity = row.identity { identities.insert(identity) }
        }
        var amounts: [ConsumerKind: Int64] = [:]
        for row in accepted { let old = amounts[row.kind, default: 0]; amounts[row.kind] = old > Int64.max - row.bytes ? Int64.max : old + row.bytes }
        if let allocated = native?.allocated { amounts[.swap] = allocated }
        if let docker = native?.docker, native?.dockerPath != nil { amounts[.docker] = docker }
        let sum = amounts.values.reduce(Int64(0)) { $0 > Int64.max - $1 ? Int64.max : $0 + $1 }
        var estimateLower: Int64 = 0
        let estimates = ConsumerKind.allCases.compactMap { kind -> StoragePortion? in
            guard kind != .other && kind != .free, let value = amounts[kind], value > 0 else { return nil }
            let bytes = min(value, Int64.max - estimateLower)
            defer { estimateLower += bytes }
            return StoragePortion(kind: kind, bytes: bytes, lower: estimateLower)
        }
        let overlap = sum > used
        // Never scale consumer numbers to pretend shared/stale APFS estimates are an exact partition.
        if overlap { amounts = [:] }
        amounts[.other] = used - (overlap ? 0 : sum)
        amounts[.free] = free
        var lower: Int64 = 0
        let portions = ConsumerKind.allCases.compactMap { kind -> StoragePortion? in
            guard let bytes = amounts[kind], bytes > 0 else { return nil }
            defer { lower += bytes }
            return StoragePortion(kind: kind, bytes: bytes, lower: lower)
        }
        return StorageFrame(date: date, total: total, free: free, consumers: accepted, native: native,
                            portions: portions, estimatedPortions: estimates, overlap: overlap, omitted: omitted, segment: segment)
    }
}
struct StorageTimeline: Sendable {
    let frames: [StorageFrame]
    let skipped: Int
    let events: [ActivityEvent]
}

/// Sparse monthly category journal: writes only completed/changed observations and retirements.
actor ConsumerHistoryStore {
    nonisolated let directory: URL
    private var latest: [String: ConsumerMeasurement] = [:]
    private var initialized = false
    init(directory: URL) { self.directory = directory }
    private func codec() -> (JSONEncoder, JSONDecoder) {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return (e, d)
    }
    nonisolated func source(for date: Date) -> URL {
        let f = ISO8601DateFormatter()
        return directory.appendingPathComponent(String(f.string(from: date).prefix(7)) + ".jsonl")
    }
    private func files() throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.range(of: #"^\d{4}-(0[1-9]|1[0-2])\.jsonl$"#, options: .regularExpression) != nil }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func append(_ row: ConsumerMeasurement) throws {
        guard row.valid() else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = source(for: row.date)
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url, options: .atomic) }
        let h = try FileHandle(forWritingTo: url); defer { try? h.close() }
        try h.seekToEnd()
        var bytes = Data([10]); bytes.append(try codec().0.encode(row)); bytes.append(10)
        try h.write(contentsOf: bytes)
        latest[row.folderID] = row
    }
    func sync(folders: [GrowthFolder], archive: GrowthArchive, at date: Date = Date()) throws {
        if !initialized {
            let decoder = codec().1
            let recent = source(for: date.addingTimeInterval(-62 * 86400)).lastPathComponent
            for url in try files() where url.lastPathComponent >= recent {
                try HistoryStore.forEachLine(in: url) { line in
                    guard let row = try? decoder.decode(ConsumerMeasurement.self, from: Data(line.utf8)), row.valid() else { return }
                    latest[row.folderID] = row
                }
            }
            initialized = true
        }
        let selected = Set(folders.map(\.id))
        for old in Array(latest.values) where old.active && !selected.contains(old.folderID) {
            try append(ConsumerMeasurement(date: date, folderID: old.folderID, name: old.name, root: old.root, bytes: old.bytes,
                measuredAt: old.measuredAt, exclusions: old.exclusions, skipped: old.skipped, coverage: old.coverage, active: false, endedReason: "Tracking stopped"))
        }
        for folder in folders where folder.id != "swap" && folder.id != "swap-vm" {
            guard let cache = archive.caches[folder.id], cache.root == URL(fileURLWithPath: folder.path).standardizedFileURL.path,
                  date.timeIntervalSince(cache.measuredAt) <= 172800 else { continue }
            if let old = latest[folder.id], old.active && abs(old.measuredAt.timeIntervalSince(cache.measuredAt)) < 1 && old.root == cache.root && old.name == folder.name && old.bytes == cache.bytes && old.exclusions == cache.exclusions { continue }
            if cache.bytes == 0 && cache.nodes.isEmpty {
                var info = stat()
                if lstat(cache.root, &info) != 0 && errno == ENOENT,
                   StorageDiscovery.startupDirectory((cache.root as NSString).deletingLastPathComponent) {
                    if latest[folder.id]?.active != false {
                        try append(ConsumerMeasurement(date: date, folderID: folder.id, name: folder.name, root: cache.root,
                            bytes: 0, measuredAt: cache.measuredAt, exclusions: cache.exclusions, skipped: 0, coverage: cache.coverageID ?? "0",
                            active: false, endedReason: "Folder no longer present"))
                    }
                    continue
                }
            }
            guard StorageDiscovery.startupDirectory(cache.root) else { continue }
            var info = stat()
            let identity = lstat(cache.root, &info) == 0 ? "\(info.st_dev):\(info.st_ino)" : nil
            try append(ConsumerMeasurement(date: date, folderID: folder.id, name: folder.name, root: cache.root, bytes: cache.bytes,
                measuredAt: cache.measuredAt, exclusions: cache.exclusions, skipped: cache.skippedCount ?? 0, coverage: cache.coverageID ?? "0", identity: identity))
        }
    }
    func nearbyMeasurements(from start: Date, through end: Date) throws -> [ConsumerMeasurement] {
        let first = source(for: start).lastPathComponent, last = source(for: end).lastPathComponent
        let decoder = codec().1
        var result: [ConsumerMeasurement] = []
        for url in try files() where url.lastPathComponent >= first && url.lastPathComponent <= last {
            try HistoryStore.forEachLine(in: url) { line in
                guard let row = try? decoder.decode(ConsumerMeasurement.self, from: Data(line.utf8)), row.valid(),
                      row.measuredAt >= start, row.measuredAt <= end else { return }
                result.append(row)
                if result.count > 2000 { result.removeFirst(1000) }
            }
        }
        return result
    }
    func timeline(points: [HistoryPoint], system: [SystemPlotPoint], bucket: TimeInterval) throws -> StorageTimeline {
        guard let first = points.first, let last = points.last else { return StorageTimeline(frames: [], skipped: 0, events: []) }
        let decoder = codec().1
        let context = first.lastDate.addingTimeInterval(-172800)
        let firstFile = source(for: context).lastPathComponent, lastFile = source(for: last.lastDate).lastPathComponent
        var rows: [String: ConsumerMeasurement] = [:], frames: [StorageFrame] = [], index = 0, nativeIndex = 0, segment = 0, skipped = 0
        var events: [ActivityEvent] = []
        var previous: Date?, currentNative: SystemRecord?
        func emit(before cutoff: Date) {
            while index < points.count && points[index].lastDate < cutoff {
                let point = points[index]
                while nativeIndex < system.count && system[nativeIndex].record.date <= point.lastDate {
                    currentNative = system[nativeIndex].record; nativeIndex += 1
                }
                var native = currentNative
                if let record = native, point.lastDate.timeIntervalSince(record.date) > Double(record.interval ?? 60) * 2.5 { native = nil }
                if let previous, point.lastDate.timeIntervalSince(previous) > max(bucket * 1.5, Double(native?.interval ?? 60) * 2.5) { segment += 1 }
                previous = point.lastDate
                if let total = point.totalBytes, let free = point.freeBytes { frames.append(StorageFrame.make(date: point.lastDate, total: total, free: free, measurements: Array(rows.values), native: native, segment: segment)) }
                index += 1
            }
        }
        for url in try files() where url.lastPathComponent >= firstFile && url.lastPathComponent <= lastFile {
            try ParsedHistoryJournalCache.shared.forEach(in: url, entryCost: 768, parse: { line -> ParsedHistoryLine<ConsumerMeasurement>? in
                if line.isEmpty { return nil }
                guard let row = try? decoder.decode(ConsumerMeasurement.self, from: Data(line.utf8)), row.valid() else { return .invalid }
                return .value(row)
            }) { entry in
                guard case let .value(row) = entry else { skipped += 1; rows = [:]; return }
                guard row.date >= context && row.date <= last.lastDate else { return }
                emit(before: row.date)
                if !row.active, row.date >= first.lastDate, let old = rows[row.folderID], old.active {
                    events.append(ActivityEvent(id: row.folderID + String(row.date.timeIntervalSince1970), date: row.date, category: .storage,
                        title: row.name + ": " + (row.endedReason ?? "Measurement ended"),
                        detail: (row.endedReason ?? "Measurement ended") + " at " + row.date.formatted(date: .abbreviated, time: .standard) + ".\nSource: the category observation journal. Stopping tracking does not delete files.",
                        records: [], consumerRecords: [old, row]))
                }
                if let old = rows[row.folderID], old.active, row.active, row.date >= first.lastDate,
                   row.measuredAt > old.measuredAt {
                    let changedScope = row.root != old.root || row.exclusions != old.exclusions || row.coverage != old.coverage || row.skipped != old.skipped
                    let delta = row.bytes - old.bytes
                    if changedScope || abs(delta) >= 536_870_912 {
                        let title = changedScope ? row.name + " coverage updated" : row.name + (delta >= 0 ? " grew " : " shrank ") + CapacityFormat.string(abs(delta))
                        let detail = title + "\nMeasurements: " + old.measuredAt.formatted(date: .abbreviated, time: .shortened) + " → " + row.measuredAt.formatted(date: .abbreviated, time: .shortened)
                            + "\n" + CapacityFormat.string(old.bytes) + " → " + CapacityFormat.string(row.bytes)
                            + (changedScope ? "\nCoverage changed; this is not evidence of file growth or deletion." : "\nDetected after a paced background measurement, not at the exact time files changed.")
                            + "\nSource: allocated file blocks in " + row.root
                        events.append(ActivityEvent(id: row.folderID + String(row.date.timeIntervalSince1970), date: row.date, category: .storage, title: title, detail: detail, records: [], consumerRecords: [old, row]))
                        if events.count > 1000 { events.removeFirst(500) }
                    }
                }
                rows[row.folderID] = row
            }
        }
        emit(before: .distantFuture)
        return StorageTimeline(frames: frames, skipped: skipped, events: Array(events.suffix(500)))
    }
    func removeSamples(olderThan cutoff: Date) throws -> Int {
        let decoder = codec().1
        var removed = 0
        for url in try files() where url.lastPathComponent <= source(for: cutoff).lastPathComponent {
            var retained = Data(), old = 0, malformed = false
            try HistoryStore.forEachLine(in: url) { line in
                if line.isEmpty { return }
                guard let row = try? decoder.decode(ConsumerMeasurement.self, from: Data(line.utf8)), row.valid() else { malformed = true; return }
                if row.date < cutoff { old += 1 } else { retained.append(Data((line + "\n").utf8)) }
            }
            guard !malformed else { throw NSError(domain: "DiskFree.Consumers", code: 1, userInfo: [NSLocalizedDescriptionKey: "Unreadable consumer history preserved in \(url.lastPathComponent). Earlier months may already have been cleaned."]) }
            if old > 0 {
                if retained.isEmpty { try FileManager.default.removeItem(at: url) } else { try retained.write(to: url, options: .atomic) }
                removed += old
            }
        }
        return removed
    }
}
