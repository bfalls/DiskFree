import AppKit
import Darwin

@MainActor
enum InstanceGuard {
    private static var descriptor: Int32 = -1
    static func acquire() {
        // Includes old DiskFree builds that predate the file lock.
        if NSWorkspace.shared.runningApplications.contains(where: {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != getpid()
        }) { exit(0) }
        do {
            let support = HistoryStore.defaultDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            descriptor = open(support.appendingPathComponent("instance.lock").path,
                              O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
                if errno == EWOULDBLOCK { exit(0) }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            // Keep this descriptor open for the process lifetime; the OS releases it on exit.
        } catch {
            let alert = NSAlert()
            alert.messageText = "DiskFree could not start"
            alert.informativeText = "Could not secure the history folder: \(error.localizedDescription)"
            alert.runModal()
            exit(1)
        }
    }
}
