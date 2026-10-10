import Foundation
import Darwin

/// Providers do collection off the main actor and return an immutable snapshot.
protocol StatisticsProvider {
    associatedtype Snapshot: Sendable
    func collect() throws -> Snapshot
}

struct DiskSnapshot: Sendable {
    let name: String
    let path: String
    let freeBytes: Int64
    let totalBytes: Int64
    let reclaimableEstimateBytes: Int64?
    let refreshedAt: Date
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}

struct DiskStatisticsProvider: StatisticsProvider, Sendable {
    // On modern macOS, the writable Data volume is in the startup APFS group.
    let volumeURL: URL
    init(volumeURL: URL? = nil) {
        self.volumeURL = volumeURL ?? URL(fileURLWithPath:
            FileManager.default.fileExists(atPath: "/System/Volumes/Data")
                ? "/System/Volumes/Data" : "/")
    }
    func collect() throws -> DiskSnapshot {
        var info = statfs()
        guard volumeURL.path.withCString({ statfs($0, &info) }) == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                          userInfo: [NSLocalizedDescriptionKey: String(cString: strerror(code))])
        }
        let blockSize = Int64(info.f_bsize)
        let total = Int64(info.f_blocks) * blockSize
        // f_bavail is immediately available to an unprivileged user. It excludes purgeable data.
        let free = min(total, Int64(info.f_bavail) * blockSize)
        let values = try? volumeURL.resourceValues(forKeys: [.volumeNameKey,
                                      .volumeAvailableCapacityForImportantUsageKey])
        let important = values?.volumeAvailableCapacityForImportantUsage
        let reclaimable = important.map { max(0, $0 - free) }
        return DiskSnapshot(name: values?.volumeName ?? "Startup Disk",
                            path: volumeURL.path, freeBytes: free, totalBytes: total,
                            reclaimableEstimateBytes: reclaimable, refreshedAt: Date())
    }
}

enum SpaceLevel: String {
    case good = "Good", warning = "Warning", low = "Low", danger = "Danger"
    static func classify(freeBytes: Int64, thresholdGB: Double) -> SpaceLevel {
        let gb = Double(freeBytes) / 1_000_000_000
        if gb <= thresholdGB / 4 { return .danger }
        if gb <= thresholdGB / 2 { return .low }
        if gb <= thresholdGB { return .warning }
        return .good
    }
}

enum CapacityFormat {
    static func string(_ bytes: Int64) -> String {
        let tb = Double(bytes) / 1_000_000_000_000
        return tb >= 1 ? String(format: "%.2f TB", tb)
                      : String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
    }
}
