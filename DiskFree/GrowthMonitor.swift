import Foundation
import Combine
import CoreServices

@MainActor
final class GrowthMonitor: ObservableObject {
    private struct BatchResult: Sendable {
        let archive: GrowthArchive?
        let storageError: String?
    }
    @Published private(set) var consumerRevision = 0
    @Published private(set) var archive = GrowthArchive()
    @Published private(set) var status = "Folder tracking is off."
    // Diagnostic detail is available on demand; it never replaces useful measurements.
    @Published private(set) var errors: [String: String] = [:]
    @Published private(set) var scanErrors: [String: GrowthScanError] = [:]
    @Published private(set) var accessLimited = Set<String>()
    @Published private(set) var gathering: [String: Int] = [:]
    @Published private(set) var activeFolder: String?
    @Published private(set) var ready = false
    @Published private(set) var notificationsAvailable = false
    private let preferences: Preferences
    private let store: GrowthStore
    private let consumerStore: ConsumerHistoryStore?
    private var discoveryTask: Task<Void, Never>?
    private var lastDiscovery = -Double.infinity
    private var nativeExclusions: [String] = []
    private var watcher: GrowthWatcher?
    private var watcherSetup: Task<Void, Never>?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private var dirty: [String: [GrowthChange]] = [:]
    private var schedule = GrowthSchedule()
    private var sessions: [String: GrowthScanSession] = [:]
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var lastReconcile: Date = .distantPast
    static let sliceRest: TimeInterval = GrowthSchedule.globalCooldown

    init(preferences: Preferences, store: GrowthStore = GrowthStore(), consumerStore: ConsumerHistoryStore? = nil) {
        self.consumerStore = consumerStore
        self.preferences = preferences
        self.store = store
        task = Task { [weak self] in
            let result = await Task.detached(priority: .background) { Result { try store.load() } }.value
            guard let self else { return }
            switch result {
            case .success(let archive):
                self.archive = archive
                for (id, cache) in archive.caches { self.schedule.attempts[id] = cache.measuredAt }
            case .failure(let error):
                self.status = "Saved folder history needs attention. Disk-space history is still available."
                self.errors["storage"] = error.localizedDescription
                return // Preserve a damaged archive instead of overwriting it.
            }
            // Migration: legacy work-limit pauses must not strand categories permanently.
            self.preferences.growthPausedIDs = []
            self.ready = true
            self.preferences.$trackGrowth.removeDuplicates().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.configure() }
            }.store(in: &self.subscriptions)
            self.preferences.$autoDiscoverConsumers.dropFirst().sink { [weak self] _ in
                self?.lastDiscovery = -Double.infinity
                self?.discoverIfDue()
            }.store(in: &self.subscriptions)
            self.preferences.$growthFolders.dropFirst().sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.configure() }
            }.store(in: &self.subscriptions)
        }
    }
    private func configure() {
        generation = UUID()
        task?.cancel()
        watcherSetup?.cancel()
        watcher = nil; notificationsAvailable = false
        timer?.invalidate()
        sessions = [:]; gathering = [:]; dirty = [:]
        accessLimited = []; errors = [:]; scanErrors = [:]
        persistConsumers()
        if !preferences.trackGrowth { status = "Folder tracking is off."; return }
        discoverIfDue()
        let folders = preferences.growthFolders
        guard !folders.isEmpty else { status = "Add a folder to track."; return }
        let watcherGeneration = generation
        let receive: @Sendable ([GrowthChange]) -> Void = { [weak self] changes in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self, self.generation == watcherGeneration else { return }
                self.received(changes)
            }
        }
        watcherSetup = Task { [weak self] in
            // FSEvents may block opening a protected path. Never do this on the UI actor.
            let prepared = await Task.detached(priority: .background) {
                GrowthWatcher(folders: folders, receive: receive)
            }.value
            guard let self, !Task.isCancelled, self.generation == watcherGeneration else { return }
            self.watcher = prepared
            self.notificationsAvailable = prepared != nil
        }
        for folder in folders { dirty[folder.id] = [GrowthChange(path: folder.path, recursive: true)] }
        lastReconcile = Date()
        let timer = Timer(timeInterval: Self.sliceRest, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.tick() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        updateStatus()
        tick()
    }
    private func received(_ changes: [GrowthChange]) {
        for folder in preferences.growthFolders where !accessLimited.contains(folder.id) {
            let excluded = exclusions(for: folder)
            for change in changes {
                if excluded.contains(where: { GrowthScanner.contains($0, change.path) }) { continue }
                if GrowthScanner.contains(folder.path, change.path) {
                    var pending = dirty[folder.id] ?? []
                    if pending.count >= 128 { pending = [GrowthChange(path: folder.path, recursive: true)] }
                    else { pending.append(change) }
                    dirty[folder.id] = pending
                } else if GrowthScanner.contains(change.path, folder.path) {
                    dirty[folder.id] = [GrowthChange(path: folder.path, recursive: true)]
                }
            }
        }
    }
    private func exclusions(for folder: GrowthFolder) -> [String] {
        preferences.growthFolders.filter { $0.id != folder.id && GrowthScanner.contains(folder.path, $0.path) }.map(\.path)
            + [HistoryStore.defaultDirectory.deletingLastPathComponent().path]
            + nativeExclusions.filter { $0 != folder.path && GrowthScanner.contains(folder.path, $0) }
    }
    func checkNow() {
        guard ready, preferences.trackGrowth else { return }
        for folder in preferences.growthFolders where sessions[folder.id] == nil {
            dirty[folder.id] = [GrowthChange(path: folder.path, recursive: true)]
            // Explicit access rechecks need no half-hour wait, but retain the global slice rest.
            if accessLimited.contains(folder.id) { schedule.attempts[folder.id] = nil }
        }
        accessLimited = []
        preferences.growthPausedIDs = []
        tick()
    }
    func retry(_ folderID: String) {
        guard ready, preferences.trackGrowth,
              let folder = preferences.growthFolders.first(where: { $0.id == folderID }) else { return }
        if sessions[folderID] == nil { dirty[folderID] = [GrowthChange(path: folder.path, recursive: true)] }
        if accessLimited.remove(folderID) != nil { schedule.attempts[folderID] = nil }
        preferences.growthPausedIDs.remove(folderID)
        tick()
    }
    func cancel() { preferences.trackGrowth = false }
    private func updateStatus() {
        let measured = preferences.growthFolders.filter { archive.caches[$0.id] != nil && !accessLimited.contains($0.id) }.count
        if !sessions.isEmpty || preferences.growthFolders.contains(where: { archive.caches[$0.id] == nil && !accessLimited.contains($0.id) }) {
            status = "Gathering folder sizes quietly in the background · \(measured) ready"
        } else { status = "Folder sizes are ready. Growth comparisons build as history accumulates." }
        if errors["storage"] != nil { status += " Saving folder history needs attention." }
    }
    private func tick() {
        guard ready, preferences.trackGrowth, activeFolder == nil else { return }
        let now = Date()
        discoverIfDue()
        if now.timeIntervalSince(lastReconcile) >= 86_400 {
            accessLimited = [] // Once a day, retry coverage without requiring user recovery.
            for folder in preferences.growthFolders { dirty[folder.id] = [GrowthChange(path: folder.path, recursive: true)] }
            lastReconcile = now
        }
        let pending = Set(dirty.keys).union(sessions.keys).subtracting(accessLimited)
        guard let folder = schedule.next(folders: preferences.growthFolders, dirty: pending,
                                         continuing: Set(sessions.keys), now: now) else {
            updateStatus(); return
        }
        let continuing = sessions[folder.id] != nil
        let session: GrowthScanSession
        if let existing = sessions[folder.id] { session = existing }
        else {
            let work = dirty.removeValue(forKey: folder.id) ?? []
            // Bound total retained directory metadata across all configured categories.
            let limit = min(10_000, max(1, 30_000 / preferences.growthFolders.count))
            session = GrowthScanSession(folder: folder, previous: archive.caches[folder.id], changes: work,
                                        excluded: exclusions(for: folder), directoryLimit: limit)
            sessions[folder.id] = session
        }
        schedule.started(folder.id, at: now, continuing: continuing)
        activeFolder = folder.id
        status = "Gathering \(folder.name)… Other folder sizes remain available."
        let token = generation, store = self.store
        var saved = archive
        let selected = Set(preferences.growthFolders.map(\.id))
        saved.caches = saved.caches.filter { selected.contains($0.key) }
        let archiveForWorker = saved
        task = Task { [weak self] in
            let worker = Task.detached(priority: .background) { () throws -> BatchResult in
                guard let cache = try session.advance() else { return BatchResult(archive: nil, storageError: nil) }
                try Task.checkCancellation()
                let updated = GrowthStore.adding(cache: cache, folderID: folder.id, to: archiveForWorker)
                do { try store.save(updated); return BatchResult(archive: updated, storageError: nil) }
                catch { return BatchResult(archive: updated, storageError: error.localizedDescription) }
            }
            let result = await withTaskCancellationHandler(operation: { await worker.result }, onCancel: { worker.cancel() })
            guard let self else { return }
            self.activeFolder = nil
            guard self.generation == token else { self.tick(); return }
            switch result {
            case .success(let batch):
                self.errors[folder.id] = nil; self.scanErrors[folder.id] = nil
                if let updated = batch.archive {
                    self.errors["storage"] = batch.storageError
                    self.archive = updated
                    self.persistConsumers()
                    self.sessions[folder.id] = nil; self.gathering[folder.id] = nil
                    // The cooldown follows completion, not the first slice of a long scan.
                    self.schedule.attempts[folder.id] = Date()
                } else { self.gathering[folder.id] = session.processedEntries }
            case .failure(let error):
                self.sessions[folder.id] = nil; self.gathering[folder.id] = nil
                if !(error is CancellationError) {
                    self.scanErrors[folder.id] = error as? GrowthScanError
                    self.errors[folder.id] = error.localizedDescription
                    self.accessLimited.insert(folder.id)
                }
            }
            self.updateStatus()
        }
    }
    private func persistConsumers() {
        guard let consumerStore else { return }
        let folders = preferences.growthFolders, archive = self.archive
        Task(priority: .background) { [weak self] in
            do { try await consumerStore.sync(folders: folders, archive: archive); self?.consumerRevision += 1 }
            catch { self?.errors["storage"] = error.localizedDescription }
        }
    }
    func discoverNow() {
        guard discoveryTask == nil else { return }
        lastDiscovery = -Double.infinity
        discoverIfDue()
    }
    private func discoverIfDue() {
        guard consumerStore != nil, preferences.trackGrowth, preferences.autoDiscoverConsumers,
              discoveryTask == nil, ProcessInfo.processInfo.systemUptime - lastDiscovery >= 1800 else { return }
        lastDiscovery = ProcessInfo.processInfo.systemUptime
        discoveryTask = Task { [weak self] in
            let discovered = await Task.detached(priority: .background) { StorageDiscovery.collect() }.value
            guard let self else { return }
            self.discoveryTask = nil
            guard self.preferences.trackGrowth, self.preferences.autoDiscoverConsumers else { return }
            let exclusions = discovered.dockerPath.map { [$0] } ?? []
            let changedExclusions = exclusions != self.nativeExclusions
            self.nativeExclusions = exclusions
            var proposed = self.preferences.growthFolders
            var paths = Set(proposed.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path })
            for definition in discovered.definitions where !self.preferences.suppressedConsumerIDs.contains(definition.id) {
                let path = URL(fileURLWithPath: definition.path).standardizedFileURL.path
                if let index = proposed.firstIndex(where: { $0.id == definition.id }) {
                    if proposed[index].path != path && !paths.contains(path) {
                        paths.remove(proposed[index].path); proposed[index] = definition.folder; paths.insert(path)
                    }
                } else if paths.insert(path).inserted { proposed.append(definition.folder) }
            }
            if proposed != self.preferences.growthFolders { self.preferences.growthFolders = proposed }
            else if changedExclusions { self.configure() }
        }
    }
    deinit { timer?.invalidate(); task?.cancel() }
}

/// Only batches event paths. It never reads directory contents in its callback.
final class GrowthWatcher: @unchecked Sendable {
    private static let setupLock = NSLock()
    private var stream: FSEventStreamRef?
    private let receive: @Sendable ([GrowthChange]) -> Void
    nonisolated static func canWatch(_ folder: GrowthFolder) -> Bool {
        // The VM volume can block FSEventStreamCreate; swap uses native counters instead.
        let normalized = URL(fileURLWithPath: folder.path).standardizedFileURL.path
        return !["/System/Volumes/VM", "/private/var/vm", "/var/vm"].contains { GrowthScanner.contains($0, normalized) }
    }
    init?(folders: [GrowthFolder], receive: @escaping @Sendable ([GrowthChange]) -> Void) {
        self.receive = receive
        // Skip overlapping setup instead of accumulating blocked workers. Daily reconciliation remains available.
        guard Self.setupLock.try() else { return nil }
        defer { Self.setupLock.unlock() }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        // Watching existing ancestors also detects folders created after the baseline.
        let paths = Set(folders.filter(Self.canWatch).map { folder -> String in
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            // One accessible ancestor covers all home folders, including protected children.
            var url = URL(fileURLWithPath: GrowthScanner.contains(home, folder.path) ? home : folder.path)
            while !FileManager.default.fileExists(atPath: url.path) && url.path != "/" { url.deleteLastPathComponent() }
            return url.path
        })
        guard !paths.isEmpty else { return nil }
        stream = FSEventStreamCreate(nil, { _, info, count, paths, flags, _ in
            guard let info else { return }
            let watcher = Unmanaged<GrowthWatcher>.fromOpaque(info).takeUnretainedValue()
            let names = unsafeBitCast(paths, to: NSArray.self) as! [String]
            var changes: [GrowthChange] = []
            for index in 0..<min(count, 256) {
                let recursive = flags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagEventIdsWrapped) != 0
                changes.append(GrowthChange(path: names[index], recursive: recursive))
            }
            if count > 256 {
                // The batch was bounded: reconcile monitored roots rather than lose overflow events.
                changes = (FSEventStreamCopyPathsBeingWatched(watcher.stream!) as? [String] ?? []).map { GrowthChange(path: $0, recursive: true) }
            }
            watcher.receive(changes)
        }, &context, Array(paths) as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 60,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot))
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.main)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); self.stream = nil; return nil }
    }
    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
