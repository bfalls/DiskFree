import Foundation
import Combine

final class Preferences: ObservableObject {
    static let intervals = [15, 30, 60, 300]
    private let defaults: UserDefaults
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
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["refreshInterval": 60, "showPrefix": false,
                                     "warningThresholdGB": 20.0])
        let interval = defaults.integer(forKey: "refreshInterval")
        refreshInterval = Self.intervals.contains(interval) ? interval : 60
        showPrefix = defaults.bool(forKey: "showPrefix")
        let threshold = defaults.double(forKey: "warningThresholdGB")
        warningThresholdGB = threshold.isFinite && (1...1000).contains(threshold) ? threshold : 20
    }
}
