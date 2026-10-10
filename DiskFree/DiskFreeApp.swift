import SwiftUI
import AppKit
import ServiceManagement

@main
struct DiskFreeApp: App {
    @StateObject private var preferences: Preferences
    @StateObject private var monitor: DiskMonitor
    private let settings = SettingsController()
    private let historyController = HistoryController()
    private let historyStore: HistoryStore

    init() {
        InstanceGuard.acquire()
        let preferences = Preferences()
        let historyStore = HistoryStore()
        self.historyStore = historyStore
        _preferences = StateObject(wrappedValue: preferences)
        _monitor = StateObject(wrappedValue: DiskMonitor(preferences: preferences, historyStore: historyStore))
    }
    var body: some Scene {
        MenuBarExtra {
            DiskMenu(monitor: monitor, preferences: preferences, showSettings: {
                settings.show(preferences: preferences, store: historyStore, monitor: monitor)
            }, showHistory: {
                historyController.show(store: historyStore, monitor: monitor)
            })
        } label: {
            Image(nsImage: MenuIndicator.image(snapshot: monitor.snapshot,
                failed: monitor.errorMessage != nil, preferences: preferences))
                .renderingMode(.original)
                .accessibilityLabel("DiskFree: " + (monitor.errorMessage != nil ? "unavailable" :
                    monitor.snapshot.map { CapacityFormat.string($0.freeBytes) + " free" } ?? "loading"))
        }
        .menuBarExtraStyle(.window)
    }
}

// Render the label as an original-color image: menu bar text otherwise follows system tint.
enum MenuIndicator {
    static func color(_ level: SpaceLevel) -> NSColor {
        switch level {
        case .good: return .systemGreen
        case .warning: return .systemYellow
        case .low: return .systemOrange
        case .danger: return .systemRed
        }
    }
    static func image(snapshot: DiskSnapshot?, failed: Bool, preferences: Preferences) -> NSImage {
        let text = failed ? "Unavailable" : snapshot.map { CapacityFormat.string($0.freeBytes) } ?? "…"
        let label = (preferences.showPrefix ? "SSD: " : "") + text
        let color = failed ? NSColor.systemRed : snapshot.map {
            Self.color(SpaceLevel.classify(freeBytes: $0.freeBytes, thresholdGB: preferences.warningThresholdGB))
        } ?? .secondaryLabelColor
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium), .foregroundColor: color]
        let size = (label as NSString).size(withAttributes: attributes)
        let image = NSImage(size: NSSize(width: ceil(size.width) + 22, height: 22), flipped: false) { _ in
            if let icon = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: nil) {
                let tinted = NSImage(size: NSSize(width: 16, height: 16))
                tinted.lockFocus()
                icon.draw(in: NSRect(x: 0, y: 0, width: 16, height: 16))
                color.setFill()
                NSRect(x: 0, y: 0, width: 16, height: 16).fill(using: .sourceAtop)
                tinted.unlockFocus()
                tinted.draw(in: NSRect(x: 0, y: 3, width: 16, height: 16))
            }
            (label as NSString).draw(at: NSPoint(x: 22, y: (22 - size.height) / 2), withAttributes: attributes)
            return true
        }
        image.isTemplate = false
        return image
    }
}

struct DiskMenu: View {
    @ObservedObject var monitor: DiskMonitor
    @ObservedObject var preferences: Preferences
    let showSettings: () -> Void
    let showHistory: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("DiskFree", systemImage: "internaldrive").font(.headline)
            if let disk = monitor.snapshot {
                Text(disk.name).font(.subheadline).textSelection(.enabled)
                row("Available now", CapacityFormat.string(disk.freeBytes))
                row("Used / unavailable", CapacityFormat.string(disk.usedBytes))
                row("Total capacity", CapacityFormat.string(disk.totalBytes))
                row("Status", SpaceLevel.classify(freeBytes: disk.freeBytes,
                    thresholdGB: preferences.warningThresholdGB).rawValue)
                if let reclaimable = disk.reclaimableEstimateBytes {
                    row("Reclaimable estimate", CapacityFormat.string(reclaimable))
                }
                Text("Free space excludes purgeable data. Reclaimable space is an estimate from macOS. APFS capacity is shared; used space includes other volumes and system reservations.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text("Last refresh: \(disk.refreshedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption).foregroundStyle(.secondary)
            } else if monitor.errorMessage == nil {
                Text("Reading startup disk…").foregroundStyle(.secondary)
            }
            if let error = monitor.errorMessage {
                Text("Refresh failed: \(error)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                if monitor.snapshot != nil { Text("Values above are from the last successful refresh.").font(.caption) }
            }
            if let error = monitor.historyError {
                Text("History could not be saved: \(error)").font(.caption).foregroundStyle(.orange)
            }
            Divider()
            Button(monitor.isRefreshing ? "Refreshing…" : "Refresh Now") { monitor.refresh() }
                .disabled(monitor.isRefreshing)
            Button("History…", action: showHistory)
            Button("Settings…", action: showSettings).keyboardShortcut(",")
            Button("Quit DiskFree") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
        }
        .padding(16).frame(width: 320)
    }
    private func row(_ label: String, _ value: String) -> some View {
        HStack { Text(label).foregroundStyle(.secondary); Spacer(); Text(value).monospacedDigit() }
            .font(.system(size: 12))
    }
}

@MainActor
final class SettingsController {
    private var window: NSWindow?
    func show(preferences: Preferences, store: HistoryStore, monitor: DiskMonitor) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 510),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "DiskFree Settings"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: SettingsView(preferences: preferences, store: store, monitor: monitor))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject var preferences: Preferences
    let store: HistoryStore
    @ObservedObject var monitor: DiskMonitor
    @State private var confirmCleanup = false
    @State private var cleaning = false
    @State private var cleanupMessage: String?
    @State private var loginEnabled = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
    @State private var loginMessage: String?
    var body: some View {
        Form {
            Picker("Refresh interval", selection: $preferences.refreshInterval) {
                ForEach(Preferences.intervals, id: \.self) { value in
                    Text(value == 300 ? "5 minutes" : "\(value) seconds").tag(value)
                }
            }
            Toggle("Show SSD: prefix", isOn: $preferences.showPrefix)
            HStack {
                Text("Warning threshold")
                TextField("GB", value: $preferences.warningThresholdGB, format: .number)
                    .frame(width: 70)
                Text("GB (1–1,000)").foregroundStyle(.secondary)
            }
            Text("Green: above threshold · Yellow: at or below threshold\nOrange: at or below half · Red: at or below one quarter")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Launch automatically at login", isOn: Binding(get: { loginEnabled }, set: setLogin))
            if let loginMessage { Text(loginMessage).font(.caption).foregroundStyle(.secondary) }
            if SMAppService.mainApp.status == .requiresApproval {
                Button("Open Login Items Settings") { SMAppService.openSystemSettingsLoginItems() }
            }
            Section("History") {
                Text("Monthly CSV logs are saved in Application Support and survive app updates. No automatic deletion.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 8) {
                    Button("Show Logs in Finder") { NSWorkspace.shared.open(store.directory) }
                    Button(cleaning ? "Cleaning…" : "Remove History Older Than One Year…") { confirmCleanup = true }
                        .disabled(cleaning)
                }
                if let cleanupMessage { Text(cleanupMessage).font(.caption).foregroundStyle(.secondary) }
            }
            Text("Preferences save automatically. Login registration is managed by macOS. Install DiskFree in Applications before enabling it.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped).padding(8).frame(width: 480, height: 510)
        .alert("Remove history older than one year?", isPresented: $confirmCleanup) {
            Button("Cancel", role: .cancel) {}
            Button("Remove Old History", role: .destructive) { cleanHistory() }
        } message: {
            Text("This permanently removes samples older than one calendar year. Newer samples are kept. Copy the monthly CSV files first if you want an archive.")
        }
        .onAppear { syncLoginStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            syncLoginStatus()
        }
    }
    private func cleanHistory() {
        cleaning = true
        Task {
            do {
                let cutoff = Calendar.current.date(byAdding: .year, value: -1, to: Date())!
                let count = try await store.removeSamples(olderThan: cutoff)
                cleanupMessage = "Removed \(count.formatted()) old samples."
            } catch { cleanupMessage = "Cleanup failed: \(error.localizedDescription)" }
            monitor.historyWasCleaned()
            cleaning = false
        }
    }
    private func syncLoginStatus() {
        loginEnabled = [.enabled, .requiresApproval].contains(SMAppService.mainApp.status)
        if SMAppService.mainApp.status == .requiresApproval {
            loginMessage = "Allow DiskFree in System Settings → General → Login Items."
        }
    }
    private func setLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            loginMessage = nil
        } catch { loginMessage = "Could not change login registration: \(error.localizedDescription)" }
        syncLoginStatus()
    }
}
