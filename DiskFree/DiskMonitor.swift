import Foundation
import Combine

@MainActor
final class DiskMonitor: ObservableObject {
    @Published private(set) var snapshot: DiskSnapshot?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isRefreshing = false
    @Published private(set) var historyError: String?
    @Published private(set) var historyRevision = 0
    @Published private(set) var historyCleanupRevision = 0
    private let historyStore: HistoryStore?
    private var timer: Timer?
    private var subscriptions = Set<AnyCancellable>()
    private let collect: @Sendable () throws -> DiskSnapshot
    private var task: Task<Void, Never>?

    init(preferences: Preferences, historyStore: HistoryStore? = nil,
         collect: @escaping @Sendable () throws -> DiskSnapshot = { try DiskStatisticsProvider().collect() }) {
        self.collect = collect
        self.historyStore = historyStore
        preferences.$refreshInterval.removeDuplicates().sink { [weak self] interval in
            self?.schedule(interval: interval)
        }.store(in: &subscriptions)
        refresh()
    }
    private func schedule(interval: Int) {
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
        task = Task { [weak self] in
            let result = await Task.detached(priority: .utility) {
                Result { try collect() }
            }.value
            guard let self, !Task.isCancelled else { return }
            switch result {
            case .success(let snapshot):
                if let historyStore = self.historyStore {
                    do {
                        try await historyStore.append(snapshot)
                        self.historyError = nil
                        self.historyRevision += 1
                    } catch { self.historyError = error.localizedDescription }
                }
                self.snapshot = snapshot
                self.errorMessage = nil
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
            self.isRefreshing = false
        }
    }
    func historyWasCleaned() { historyCleanupRevision += 1 }
    deinit { timer?.invalidate(); task?.cancel() }
}
