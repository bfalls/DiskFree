import Foundation
import Combine

final class Preferences: ObservableObject {
    static let intervals = [15, 30, 60, 300]
    private let defaults: UserDefaults
    @Published var autoDiscoverConsumers: Bool {
        didSet { defaults.set(autoDiscoverConsumers, forKey: "autoDiscoverConsumers") }
    }
    var suppressedConsumerIDs: Set<String> {
        didSet { defaults.set(Array(suppressedConsumerIDs), forKey: "suppressedConsumerIDs") }
    }
    @Published var growthPausedIDs: Set<String> {
        didSet { defaults.set(Array(growthPausedIDs), forKey: "growthPausedIDs") }
    }
    @Published var trackGrowth: Bool {
        didSet { defaults.set(trackGrowth, forKey: "trackGrowth") }
    }
    @Published var growthFolders: [GrowthFolder] {
        didSet {
            let current = Set(growthFolders.map(\.id))
            suppressedConsumerIDs.formUnion(oldValue.filter { $0.id.hasPrefix("consumer.") && !current.contains($0.id) }.map(\.id))
            if let data = try? JSONEncoder().encode(growthFolders) { defaults.set(data, forKey: "growthFolders") }
        }
    }
    @Published var refreshInterval: Int {
        didSet {
            if !Self.intervals.contains(refreshInterval) { refreshInterval = 60 }
            defaults.set(refreshInterval, forKey: "refreshInterval")
        }
    }
    @Published var showPrefix: Bool {
        didSet { defaults.set(showPrefix, forKey: "showPrefix") }
    }
    @Published var warningThresholdGB: Double {
        didSet {
            if !warningThresholdGB.isFinite || warningThresholdGB < 1 || warningThresholdGB > 1000 {
                warningThresholdGB = 20
            }
            defaults.set(warningThresholdGB, forKey: "warningThresholdGB")
        }
    }
    /// Starting Investigate opts into collection once, while preserving an explicit off preference.
    func beginInvestigation() {
        if defaults.object(forKey: "trackGrowth") == nil { trackGrowth = true }
    }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoDiscoverConsumers = defaults.object(forKey: "autoDiscoverConsumers") == nil || defaults.bool(forKey: "autoDiscoverConsumers")
        suppressedConsumerIDs = Set(defaults.stringArray(forKey: "suppressedConsumerIDs") ?? [])
        growthPausedIDs = Set(defaults.stringArray(forKey: "growthPausedIDs") ?? [])
        trackGrowth = defaults.bool(forKey: "trackGrowth")
        growthFolders = defaults.data(forKey: "growthFolders").flatMap { try? JSONDecoder().decode([GrowthFolder].self, from: $0) } ?? GrowthFolder.defaults
        defaults.register(defaults: ["refreshInterval": 60, "showPrefix": false,
                                     "warningThresholdGB": 20.0])
        let interval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = Self.intervals.contains(interval) ? interval : 60
        showPrefix = defaults.bool(forKey: "showPrefix")
        let threshold = defaults.double(forKey: "warningThresholdGB")
        warningThresholdGB = threshold.isFinite && (1...1000).contains(threshold) ? threshold : 20
        // A new identity keeps old sleepimage-only readings out of swap growth comparisons.
        var migrated = false
        growthFolders = growthFolders.map { folder in
            if folder.id == "swap" && ["/private/var/vm", "/var/vm"].contains(folder.path) {
                migrated = true
                return GrowthFolder.swapFolder
            }
            return folder
        }
        if migrated, let data = try? JSONEncoder().encode(growthFolders) { defaults.set(data, forKey: "growthFolders") }

    }
}
