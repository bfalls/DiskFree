import Foundation
import Combine
import Darwin

struct BackupContext: Sendable {
    let date: Date
    let backupRunning: Bool?
    let snapshots: [String]?
    let oldestSnapshot: Date?
    let disk: DiskSnapshot?
    let message: String?
    var canClean: Bool { backupRunning == false && (snapshots?.isEmpty == false) }
}

enum SnapshotCleanup: Equatable, Sendable {
    case recover(Int), removeLocal
    var arguments: [String] {
        switch self {
        case .recover(let gb): return ["thinlocalsnapshots", BackupContextReader.volume, String(Int64(gb) * 1_000_000_000), "1"]
        case .removeLocal: return ["deletelocalsnapshots", BackupContextReader.volume]
        }
    }
    var valid: Bool {
        if case .recover(let gb) = self { return [5, 10, 20].contains(gb) }
        return true
    }
    var title: String {
        switch self {
        case .recover(let gb): return "Try to recover \(gb) GB?"
        case .removeLocal: return "Remove local restore points?"
        }
    }
    var explanation: String {
        let common = "This permanently removes local Time Machine restore points on your startup Data volume. Your current files and backups on your external backup disk are kept. Make sure important files have an external backup first. macOS may ask for an administrator password and Full Disk Access."
        switch self {
        case .recover: return common + " Time Machine chooses which local snapshots to remove. The requested amount is not guaranteed."
        case .removeLocal: return common + " All local Time Machine restore points on this volume will be removed."
        }
    }
}

struct SnapshotCleanupResult: Sendable {
    let context: BackupContext
    let freeChange: Int64?
}

enum BackupToolError: LocalizedError {
    case unavailable(String), unsafeState, invalidRequest
    var errorDescription: String? {
        switch self {
        case .unavailable(let message): return message
        case .unsafeState: return "Wait until Time Machine is idle, then refresh and try again. No cleanup was started."
        case .invalidRequest: return "The cleanup request is not supported."
        }
    }
}

/// All operations are on demand. Mutations are called only after an explicit UI confirmation.
/// No helper service, automatic thinning, backup deletion or mounted snapshot traversal.
enum BackupContextReader {
    static let volume = "/System/Volumes/Data"
    typealias Command = ([String]) throws -> String
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 5) throws -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = output; process.standardError = output
        process.qualityOfService = .background
        try process.run()
        let watchdog = DispatchWorkItem {
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); watchdog.cancel()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if text.contains("(75)") { throw BackupToolError.unsafeState }
            if text.contains("(-128)") { throw BackupToolError.unavailable("Cleanup cancelled.") }
            if process.terminationReason == .uncaughtSignal {
                throw BackupToolError.unavailable("The check timed out. If cleanup was already authorized, it may still be finishing; refresh before trying again.")
            }
            throw BackupToolError.unavailable(text.isEmpty ? "Time Machine information is unavailable. Try again or open Time Machine Settings." : String(text.prefix(2000)))
        }
        return text
    }
    static func command(_ arguments: [String]) throws -> String {
        try run(executable: "/usr/bin/tmutil", arguments: arguments)
    }
    static func running(_ text: String) -> Bool? {
        if text.range(of: #"\bRunning\s*=\s*1\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\bRunning\s*=\s*0\b"#, options: .regularExpression) != nil { return false }
        return nil
    }
    static func snapshotNames(_ text: String) throws -> [String] {
        // A successful recognized listing can be empty; arbitrary output must never mean zero.
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let names = lines.filter { $0.hasPrefix("com.apple.TimeMachine.") }
        guard lines.contains(where: { $0.hasPrefix("Snapshots for") || $0.hasPrefix("com.apple.TimeMachine.") }) else {
            throw BackupToolError.unavailable("Local restore-point information is not available yet.")
        }
        return Array(Set(names)).sorted()
    }
    static func snapshotDate(_ name: String) -> Date? {
        let prefix = "com.apple.TimeMachine."
        guard name.hasPrefix(prefix) else { return nil }
        let value = String(name.dropFirst(prefix.count).prefix(17))
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.calendar = Calendar(identifier: .gregorian)
        format.timeZone = .current; format.dateFormat = "yyyy-MM-dd-HHmmss"; format.isLenient = false
        return format.date(from: value)
    }
    static func read(command: Command = command,
                     capacity: () throws -> DiskSnapshot = { try DiskStatisticsProvider().collect() }) -> BackupContext {
        var messages: [String] = []
        var status: Bool?, names: [String]?, disk: DiskSnapshot?
        do { status = running(try command(["status"])) } catch { messages.append(error.localizedDescription) }
        do { names = try snapshotNames(command(["listlocalsnapshots", volume])) } catch { messages.append(error.localizedDescription) }
        do { disk = try capacity() } catch { messages.append("Disk capacity could not be refreshed.") }
        return BackupContext(date: Date(), backupRunning: status, snapshots: names,
            oldestSnapshot: names?.compactMap(snapshotDate).min(), disk: disk,
            message: messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }
    static func authorizationScript(_ operation: SnapshotCleanup) throws -> String {
        guard operation.valid else { throw BackupToolError.invalidRequest }
        // Only fixed verbs, a fixed volume and whitelisted numeric targets enter shell text.
        let cleanup = (["/usr/bin/tmutil"] + operation.arguments).joined(separator: " ")
        // Recheck after the password dialog as well: a backup may have started meanwhile.
        let shell = "/usr/bin/tmutil status | /usr/bin/grep -Eq 'Running[[:space:]]*=[[:space:]]*0([;[:space:]]|$)' || exit 75; " + cleanup
        return "with timeout of 600 seconds\ndo shell script \"\(shell)\" with administrator privileges\nend timeout"
    }
    static func authorize(_ operation: SnapshotCleanup) throws {
        _ = try run(executable: "/usr/bin/osascript", arguments: ["-e", authorizationScript(operation)], timeout: 610)
    }
    static func clean(_ operation: SnapshotCleanup, command: Command = command,
                      capacity: () throws -> DiskSnapshot = { try DiskStatisticsProvider().collect() },
                      perform: (SnapshotCleanup) throws -> Void = authorize) throws -> SnapshotCleanupResult {
        guard operation.valid else { throw BackupToolError.invalidRequest }
        // Fresh preflight, independent of the possibly stale window summary.
        let before = read(command: command, capacity: capacity)
        guard before.canClean else { throw BackupToolError.unsafeState }
        try perform(operation)
        let after = read(command: command, capacity: capacity)
        let change = before.disk.flatMap { original in after.disk.map { $0.freeBytes - original.freeBytes } }
        return SnapshotCleanupResult(context: after, freeChange: change)
    }
}

@MainActor
final class BackupTools: ObservableObject {
    @Published private(set) var context: BackupContext?
    @Published private(set) var busy = false
    @Published private(set) var activity = ""
    @Published private(set) var resultMessage: String?
    @Published private(set) var detail: String?
    private var task: Task<Void, Never>?
    func refreshIfNeeded() { if !busy && (context == nil || Date().timeIntervalSince(context!.date) > 60) { refresh() } }
    func refresh() {
        guard !busy else { return }
        busy = true; activity = "Checking Time Machine…"
        task = Task {
            context = await Task.detached(priority: .background) { BackupContextReader.read() }.value
            busy = false
        }
    }
    func clean(_ operation: SnapshotCleanup) {
        guard !busy else { return }
        busy = true; activity = "Waiting for authorization or recovering space…"
        resultMessage = nil; detail = nil
        task = Task {
            let result = await Task.detached(priority: .background) { Result { try BackupContextReader.clean(operation) } }.value
            switch result {
            case .success(let outcome):
                context = outcome.context
                if let change = outcome.freeChange {
                    resultMessage = change > 0 ? "Free space increased by \(CapacityFormat.string(change))." : "Cleanup finished. No increase in free space is visible yet."
                } else { resultMessage = "Cleanup finished. Refresh to check free space." }
                detail = "This measures the disk's free-space change, not an exact snapshot size. Other activity and delayed reclamation can affect it."
            case .failure(let error):
                if error.localizedDescription == "Cleanup cancelled." {
                    resultMessage = "Cleanup cancelled."; detail = nil
                } else {
                    resultMessage = "Cleanup did not complete. See details or open Time Machine Settings."
                    detail = error.localizedDescription
                }
                context = await Task.detached(priority: .background) { BackupContextReader.read() }.value
            }
            busy = false
        }
    }
}
