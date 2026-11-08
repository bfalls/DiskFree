import Foundation
import Darwin

final class DockerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var fails = false
    func fail(_ value: Bool) { lock.lock(); fails = value; lock.unlock() }
    func collect() -> DockerDiskReading {
        lock.lock(); defer { lock.unlock() }
        return fails ? .unavailable("Fixture metadata unavailable") : .available(DockerDiskSnapshot(
            allocatedBytes: 4_096, sourceID: String(repeating: "a", count: 64), path: "/fixture/Docker.raw"))
    }
}

func checkDockerProvider() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-Docker-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("Docker.raw")
    FileManager.default.createFile(atPath: file.path, contents: nil)
    let handle = try FileHandle(forWritingTo: file)
    try handle.truncate(atOffset: 1_000_000_000)
    try handle.write(contentsOf: Data(repeating: 1, count: 4_096)); try handle.close()
    let provider = DockerDiskStatisticsProvider(candidates: [file], volume: root)
    let first = provider.collect().snapshot!
    var info = stat(); precondition(lstat(file.path, &info) == 0)
    precondition(first.allocatedBytes == Int64(info.st_blocks) * 512 && first.allocatedBytes < 1_000_000_000)
    precondition(first.sourceID.count == 64 && first.sourceID == provider.collect().snapshot?.sourceID)
    // Measuring metadata requires no read of image contents.
    precondition(chmod(file.path, 0) == 0)
    precondition(provider.collect().snapshot?.allocatedBytes == first.allocatedBytes)
    _ = chmod(file.path, 0o600)
    let replacement = root.appendingPathComponent("replacement")
    try Data(repeating: 2, count: 8192).write(to: replacement)
    precondition(rename(replacement.path, file.path) == 0)
    precondition(provider.collect().snapshot?.sourceID != first.sourceID, "A replaced image needs a new baseline")
    let link = root.appendingPathComponent("symlink")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    precondition(DockerDiskStatisticsProvider(candidates: [link], volume: root).collect().snapshot == nil)
    precondition(DockerDiskStatisticsProvider(candidates: [root.appendingPathComponent("absent")], volume: root).collect().state == "missing")
    let configured = root.appendingPathComponent("custom")
    try FileManager.default.createDirectory(at: configured, withIntermediateDirectories: true)
    let custom = configured.appendingPathComponent("Docker.raw")
    try Data(repeating: 3, count: 4096).write(to: custom)
    let settings = root.appendingPathComponent("settings.json")
    try JSONSerialization.data(withJSONObject: ["DataFolder": configured.path]).write(to: settings)
    let discovered = DockerDiskStatisticsProvider(settings: [settings], home: root, volume: root)
    let now = Date()
    precondition(discovered.collect(now: now).snapshot?.path == custom.path)
    try JSONSerialization.data(withJSONObject: ["DataFolder": root.path]).write(to: settings)
    precondition(discovered.collect(now: now.addingTimeInterval(299)).snapshot?.path == custom.path)
    precondition(discovered.collect(now: now.addingTimeInterval(301)).snapshot?.path == file.path)
    print("PASS: Docker allocated versus sparse logical size, content-independent metadata, identity changes, symlink/missing handling, configured location and bounded discovery caching")
}

func checkDockerHistory() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("DiskFree-DockerHistory-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let parent = HistoryStore(directory: root), store = parent.docker
    let iso = ISO8601DateFormatter()
    let start = iso.date(from: "2026-10-01T00:00:00Z")!
    func reading(_ bytes: Int64, _ source: String = "a") -> DockerDiskReading {
        .available(DockerDiskSnapshot(allocatedBytes: bytes, sourceID: String(repeating: source, count: 64), path: "/fixture/Docker.raw"))
    }
    let missing = try await store.append(.notFound, at: start)
    precondition(!missing && !FileManager.default.fileExists(atPath: root.path))
    try await store.append(reading(9_000_000_000), at: start.addingTimeInterval(-1))
    try await store.append(reading(10_000_000_000), at: start)
    try await store.append(reading(7_000_000_000), at: start.addingTimeInterval(15))
    try await store.append(.unavailable("Denied"), at: start.addingTimeInterval(60))
    try await store.append(reading(12_000_000_000), at: start.addingTimeInterval(120))
    try await store.append(reading(5_000_000_000, "b"), at: start.addingTimeInterval(180))
    let reopened = DockerHistoryStore(directory: root.appendingPathComponent("Docker"))
    let result = try await reopened.load(from: start, through: start.addingTimeInterval(240), bucketSeconds: 60)
    precondition(result.sampleCount == 4 && result.points.count == 3)
    precondition(result.points[0].minGB == 7 && result.points[0].maxGB == 10)
    precondition(result.points[0].seriesID != result.points[1].seriesID, "Unavailable intervals must break the line, not create zero samples")
    precondition(result.points[1].sourceID != result.points[2].sourceID)
    let coarse = try await reopened.load(from: start, through: start.addingTimeInterval(240), bucketSeconds: 600)
    precondition(coarse.points.count == 1 && coarse.points[0].minGB == 5 && coarse.points[0].maxGB == 5,
                 "A bucket must not merge different image identities")
    try await parent.append(DiskSnapshot(name: "Test", path: "/", freeBytes: 1, totalBytes: 2,
        reclaimableEstimateBytes: nil, refreshedAt: start.addingTimeInterval(-1)))
    let removed = try await parent.removeSamples(olderThan: start)
    precondition(removed == 2, "Settings cleanup must include both histories")
    precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent("Docker/2026-09.csv").path))
    let file = root.appendingPathComponent("Docker/2026-10.csv")
    let handle = try FileHandle(forWritingTo: file)
    try handle.seekToEnd(); try handle.write(contentsOf: Data("broken,partial".utf8)); try handle.close()
    try await reopened.append(reading(6_000_000_000, "b"), at: start.addingTimeInterval(240))
    let recovered = try await reopened.load(from: start, through: start.addingTimeInterval(300), bucketSeconds: 60)
    precondition(recovered.skippedLines == 1 && recovered.sampleCount == 5)
    let before = try Data(contentsOf: file)
    do { _ = try await reopened.removeSamples(olderThan: start.addingTimeInterval(300)); preconditionFailure("Must preserve malformed Docker history") }
    catch { let after = try Data(contentsOf: file); precondition(after == before) }
    print("PASS: Docker monthly rollover, durable reopen, aggregation, gaps/image replacement, shared cleanup and malformed-tail preservation")
}
