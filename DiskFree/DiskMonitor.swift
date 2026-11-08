import Foundation
import Combine

@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var snapshot: DiskSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var historyError: String?
    @Published private(set) var dockerReading: DockerDiskReading = .notFound
    @Published private(set) var dockerHistoryError: String?
    @Published private(set) var historyRevision = 0
    @Published private(set) var spaceRevision = 0
    @Published private(set) var historyCleanupRevision = 0
    @Published private(set) var systemVitals: SystemVitals?
    @Published private(set) var systemHistoryError: String?
    private var refreshInterval = 60
    private let activity: SystemActivityMonitor?
    private let spaceChanges: SpaceChangeMonitor?
    private let historyStore: HistoryStore?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let collectDocker: @Sendable () -> DockerDiskReading
    private let collectVitals: @Sendable () -> SystemVitals
    private let collect: @Sendable () throws -> DiskSnapshot
    private var task: Task<Void, Never>?

    init(preferences: Preferences, historyStore: HistoryStore? = nil,
         observePower: Bool = true,
         collectVitals: @escaping @Sendable () -> SystemVitals = { SystemVitals.collect() },
         collect: @escaping @Sendable () throws -> DiskSnapshot = { try DiskStatisticsProvider().collect() },
         collectDocker: @escaping @Sendable () -> DockerDiskReading = { DockerDiskStatisticsProvider.shared.collect() }) {
        self.activity = historyStore.map { SystemActivityMonitor(store: $0.system, observe: observePower) }
        self.spaceChanges = historyStore.map { SpaceChangeMonitor(store: $0, enabled: observePower) }
        self.collectVitals = collectVitals
        self.collect = collect
        self.collectDocker = collectDocker
        self.historyStore = historyStore
        self.spaceChanges?.onChanged = { [weak self] in self?.spaceRevision += 1 }
        preferences.$refreshInterval.removeDuplicates().sink { [weak self] interval in
            self?.schedule(interval: interval)
        }.store(in: &subscriptions)
        refresh()
    }
    private func schedule(interval: Int) {
        refreshInterval = interval
        timer?.invalidate()
        let timer = Timer(timeInterval: TimeInterval(interval), repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        timer.tolerance = min(5, Double(interval) * 0.1)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
    func refresh() {
        guard !isRefreshing else { return }
        isRefreshing = true
        let collect = self.collect
        let collectVitals = self.collectVitals
        let collectDocker = self.collectDocker
        let interval = refreshInterval
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                (Result { try collect() }, collectDocker(), collectVitals())
            }.value
            guard let self, !Task.isCancelled else { return }
            var historyChanged = false
            self.dockerReading = result.1
            self.systemVitals = result.2
            switch result.0 {
            case .success(let snapshot):
                if let historyStore = self.historyStore {
                    do {
                        try await historyStore.append(snapshot)
                        self.historyError = nil
                        historyChanged = true
                    } catch { self.historyError = error.localizedDescription }
                }
                self.snapshot = snapshot
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
            if let historyStore = self.historyStore {
                do {
                    if try await historyStore.docker.append(result.1, at: (try? result.0.get().refreshedAt) ?? Date()) { historyChanged = true }
                    self.dockerHistoryError = nil
                } catch { self.dockerHistoryError = error.localizedDescription }
            }
            if let activity = self.activity {
                do {
                    let row = try await Task.detached(priority: .utility) {
                        try activity.sample(vitals: result.2, disk: try? result.0.get(), docker: result.1.snapshot,
                                            interval: interval, at: (try? result.0.get().refreshedAt) ?? Date())
                    }.value
                    if self.spaceChanges != nil { self.spaceChanges?.observe(row) }
                    self.systemHistoryError = nil
                    historyChanged = true
                } catch { self.systemHistoryError = error.localizedDescription }
            }
            if historyChanged { self.historyRevision += 1 }
            self.isRefreshing = false
        }
    }
    func historyWasCleaned() { historyCleanupRevision += 1 }
    deinit { timer?.invalidate(); task?.cancel() }
}
