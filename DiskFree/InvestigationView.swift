import SwiftUI
import Charts
import AppKit

@MainActor
final class InvestigationController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let backupTools = BackupTools()
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { AppWindowPresence.shared.closed(window) }
        window?.contentView = nil; window = nil
    }
    func show(preferences: Preferences, growth: GrowthMonitor, showTimeMachine: Bool = false) {
        preferences.beginInvestigation()
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 680),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Investigate Space Changes"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: InvestigationView(preferences: preferences, growth: growth, backupTools: backupTools))
            window.minSize = NSSize(width: 800, height: 600)
            window.center()
            self.window = window
        }
        if let window { AppWindowPresence.shared.present(window) }
        if showTimeMachine {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                NotificationCenter.default.post(name: Notification.Name("DiskFree.showTimeMachine"), object: nil)
            }
        }
    }
}

struct InvestigationView: View {
    @ObservedObject var preferences: Preferences
    @ObservedObject var growth: GrowthMonitor
    @StateObject private var spotlight = SpotlightClues()
    @State private var showLeftovers = false
    @State private var startLeftovers = false
    @State private var days = 1
    @State private var selectedFolder: String?
    @State private var folderError: String?
    @ObservedObject var backupTools: BackupTools
    @State private var cleanup: SnapshotCleanup?
    @State private var confirmCleanup = false
    @State private var recoverGB = 10
    private var cutoff: Date { Calendar.current.date(byAdding: .day, value: -days, to: Date())! }
    private var folders: [GrowthFolder] {
        preferences.growthFolders.filter { !growth.accessLimited.contains($0.id) }.sorted {
            let lhs = delta($0.id) ?? growth.archive.caches[$0.id]?.bytes ?? -1
            let rhs = delta($1.id) ?? growth.archive.caches[$1.id]?.bytes ?? -1
            return lhs == rhs ? $0.name < $1.name : lhs > rhs
        }
    }
    private var limitedFolders: [GrowthFolder] { preferences.growthFolders.filter { growth.accessLimited.contains($0.id) } }
    var body: some View {
        ScrollViewReader { scroll in ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Investigate Space Changes").font(.title2.bold())
                    Spacer()
                    Toggle("Track folder growth", isOn: $preferences.trackGrowth).toggleStyle(.switch)
                }
                HStack {
                    Toggle("Discover common model stores and development caches", isOn: $preferences.autoDiscoverConsumers).font(.caption)
                    Spacer()
                    Button("Discover Now") { growth.discoverNow() }.disabled(!preferences.trackGrowth || !preferences.autoDiscoverConsumers)
                }
                HStack(spacing: 8) {
                    if preferences.trackGrowth && growth.ready && (growth.activeFolder != nil || !growth.gathering.isEmpty
                        || folders.contains(where: { growth.archive.caches[$0.id] == nil })) {
                        ProgressView().controlSize(.small)
                    }
                    Text(growth.status).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Compare with", selection: $days) {
                        Text("Yesterday").tag(1)
                        Text("Seven days ago").tag(7)
                    }.pickerStyle(.segmented).frame(width: 300)
                    Spacer()
                    if growth.activeFolder != nil { Button("Pause Gathering") { growth.cancel() } }
                    Button("Update Sizes") { growth.checkNow() }
                        .disabled(!preferences.trackGrowth || !growth.ready || growth.activeFolder != nil)
                    Button("Add Folder…", action: addFolder)
                }
                Text("Folder sizes appear as they are gathered. Daily growth becomes available after one day of history; weekly growth after seven days.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(folders) { folder in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Button(folder.name) { selectedFolder = folder.id }.buttonStyle(.plain).font(.headline)
                            Spacer()
                            Text(growth.archive.caches[folder.id].map { CapacityFormat.string($0.bytes) } ?? (preferences.trackGrowth ? "Gathering…" : "—"))
                                .monospacedDigit().frame(width: 110, alignment: .trailing)
                            Text(delta(folder.id).map(signed) ?? comparisonState(folder.id))
                                .monospacedDigit().frame(width: 165, alignment: .trailing)
                                .foregroundStyle((delta(folder.id) ?? 0) > 0 ? Color.orange : Color.secondary)
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)]) } label: {
                                Image(systemName: "folder")
                            }.help("Reveal in Finder")
                            Button { preferences.growthFolders.removeAll { $0.id == folder.id } } label: {
                                Image(systemName: "minus.circle")
                            }.help("Stop tracking this folder; files are not deleted")
                        }
                        if let date = growth.archive.caches[folder.id]?.measuredAt {
                            Text("Measured \(date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        if let baseline = GrowthStore.baseline(growth.archive.readings, folderID: folder.id, before: cutoff) {
                            Text("Compared with \(baseline.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        if growth.activeFolder == folder.id || growth.gathering[folder.id] != nil {
                            Text(growth.archive.caches[folder.id] == nil ? "Gathering a first measurement in small background batches…" : "Updating quietly in the background…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if (growth.archive.caches[folder.id]?.skippedCount ?? 0) > 0 {
                            Text("Accessible files measured · some locations are protected")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(10).background(.quaternary.opacity(0.35)).cornerRadius(8)
                }
                if let folder = preferences.growthFolders.first(where: { $0.id == selectedFolder }) ?? folders.first {
                    Text("\(folder.name) history").font(.headline)
                    folderChart(folder)
                }
                DisclosureGroup("Coverage and optional access\(limitedFolders.isEmpty ? "" : " · \(limitedFolders.count) folders")") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("DiskFree measures accessible files automatically. macOS can protect some locations, including Trash and device backups. Other folders continue to update normally.")
                        ForEach(limitedFolders) { folder in
                            HStack {
                                Text(folder.name)
                                Spacer()
                                Text(growth.scanErrors[folder.id]?.permissionDenied == true ? "Additional access needed" : "Available on a later check")
                                    .foregroundStyle(.secondary)
                                Button("Check Again") { growth.retry(folder.id) }
                                    .disabled(!preferences.trackGrowth || !growth.ready || growth.activeFolder != nil)
                            }
                            if let detail = growth.errors[folder.id] {
                                DisclosureGroup("Details") { Text(detail).textSelection(.enabled) }
                            }
                        }
                        Text("To include protected locations, optionally enable the installed DiskFree.app in System Settings → Privacy & Security → Full Disk Access, quit and reopen it, then click Update Sizes. Otherwise DiskFree checks access again daily.")
                        Button("Open Privacy Settings", action: openPrivacySettings)
                        if let detail = growth.errors["storage"] { Text(detail).textSelection(.enabled) }
                        if !growth.notificationsAvailable && preferences.trackGrowth {
                            Text("Folder sizes are refreshed daily while change notifications are unavailable.")
                        }
                        Text("Folder sizes are estimates. APFS shared blocks, snapshots and untracked data can explain additional disk changes. Nested tracked folders are excluded from parent totals.")
                        Text("Measurements span the time spent gathering. Folders with protected contents report accessible usage only. A change in coverage starts a new growth baseline, so newly granted access is not mistaken for disk growth.")
                    }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                }
                Divider()
                HStack {
                    Text("App leftovers").font(.headline).id("app-leftovers")
                    Spacer()
                    Button("Saved Results…") { startLeftovers = false; showLeftovers = true }
                    Button("Find App Leftovers…") { startLeftovers = true; showLeftovers = true }
                }
                Divider()
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Time Machine").font(.headline).id("time-machine")
                        Spacer()
                        if backupTools.busy {
                            ProgressView().controlSize(.small)
                            Text(backupTools.activity).font(.caption)
                        }
                        Button("Refresh") { backupTools.refresh() }.disabled(backupTools.busy)
                    }
                    if let context = backupTools.context {
                        HStack(spacing: 30) {
                            backupNumber("macOS reclaimable", context.disk?.reclaimableEstimateBytes.map(CapacityFormat.string) ?? "—")
                            backupNumber("Local restore points", context.snapshots.map { String($0.count) } ?? "—")
                        }
                        Text("Reclaimable includes caches and other system-managed data; Time Machine cleanup may recover less.").font(.caption).foregroundStyle(.secondary)
                        Text(backupRecommendation(context)).font(.caption).foregroundStyle(.secondary)
                        if let oldest = context.oldestSnapshot {
                            Text("Oldest restore point: \(oldest.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                        }
                        HStack {
                            Picker("Try to recover", selection: $recoverGB) {
                                ForEach([5, 10, 20], id: \.self) { Text("\($0) GB").tag($0) }
                            }.frame(width: 180)
                            Button("Recover Space…") { requestCleanup(.recover(recoverGB)) }
                                .disabled(backupTools.busy || !context.canClean)
                            Button("Time Machine Settings") { openTimeMachineSettings() }.disabled(backupTools.busy)
                        }
                        DisclosureGroup("Details and additional cleanup") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Potentially reclaimable is macOS’s estimate for caches, snapshots and other purgeable data combined. It is not a Time Machine size or a guaranteed cleanup result.")
                                Text("Checked \(context.date.formatted(date: .abbreviated, time: .shortened)). Cleanup affects only local Time Machine restore points on the startup Data volume.")
                                if let message = context.message { Text(message).textSelection(.enabled) }
                                ForEach(context.snapshots ?? [], id: \.self) { name in
                                    Text(BackupContextReader.snapshotDate(name)?.formatted(date: .abbreviated, time: .shortened) ?? name)
                                }
                                Button("Remove Local Restore Points…", role: .destructive) { requestCleanup(.removeLocal) }
                                    .disabled(backupTools.busy || !context.canClean)
                                Button("Review in Disk Utility") { openDiskUtility() }
                                Text("In Disk Utility, select Macintosh HD – Data, then View → Show APFS Snapshots. Private Size and Cumulative Size columns provide additional size information.")
                            }.font(.caption).foregroundStyle(.secondary).padding(.top, 6)
                        }
                    }
                    if let message = backupTools.resultMessage { Text(message).font(.callout) }
                    if let detail = backupTools.detail { DisclosureGroup("Cleanup details") { Text(detail).font(.caption).textSelection(.enabled) } }
                }
                Divider()
                HStack {
                    Text("Spotlight clues").font(.headline)
                    Spacer()
                    Button(spotlight.searching ? "Searching…" : "Find Large Recently Changed Files") {
                        spotlight.search(folders: preferences.growthFolders)
                    }.disabled(spotlight.searching || preferences.growthFolders.isEmpty)
                }
                Text(spotlight.message).font(.caption).foregroundStyle(.secondary)
                ForEach(spotlight.files) { file in
                    HStack {
                        Text(URL(fileURLWithPath: file.path).lastPathComponent).lineLimit(1).help(file.path)
                        Spacer()
                        Text(CapacityFormat.string(file.bytes)).monospacedDigit()
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file.path)]) }
                    }.font(.caption)
                }
                Text("DiskFree gathers folder sizes in small background batches, with pauses between batches. Completed sizes and history stay available while updates continue.")
                    .font(.caption).foregroundStyle(.secondary)
                if let folderError { Text(folderError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button("Restore Default Folders") { preferences.growthFolders = GrowthFolder.defaults }
                    Button("Show Tracking Data") { NSWorkspace.shared.open(HistoryStore.defaultDirectory.deletingLastPathComponent().appendingPathComponent("Growth")) }
                }
            }.padding(22)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DiskFree.showAppLeftovers"))) { _ in scroll.scrollTo("app-leftovers", anchor: .top) }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("DiskFree.showTimeMachine"))) { _ in scroll.scrollTo("time-machine", anchor: .top) }
        }
        .sheet(isPresented: $showLeftovers) { AppLeftoversView(startImmediately: startLeftovers, caches: Array(growth.archive.caches.values)) }
        .onAppear { backupTools.refreshIfNeeded() }
        .onDisappear { spotlight.stop() }
        .alert(cleanup?.title ?? "Clean up Time Machine?", isPresented: $confirmCleanup) {
            Button("Cancel", role: .cancel) { cleanup = nil }
            Button("Continue", role: .destructive) {
                if let cleanup { backupTools.clean(cleanup) }
                cleanup = nil
            }
        } message: { Text(cleanup?.explanation ?? "") }
    }
    private func comparisonState(_ id: String) -> String {
        guard let first = growth.archive.readings.filter({ $0.folderID == id }).map(\.date).min(),
              let available = Calendar.current.date(byAdding: .day, value: days, to: first) else { return "Building history" }
        return available > Date() ? "Growth from \(available.formatted(.dateTime.month(.abbreviated).day()))" : "Updating history"
    }
    private func delta(_ id: String) -> Int64? {
        guard let current = growth.archive.caches[id], current.measuredAt > cutoff,
              let baseline = GrowthStore.baseline(growth.archive.readings, folderID: id, before: cutoff) else { return nil }
        return current.bytes - baseline.bytes
    }
    private func signed(_ bytes: Int64) -> String { (bytes >= 0 ? "+" : "−") + CapacityFormat.string(abs(bytes)) }
    private func folderChart(_ folder: GrowthFolder) -> some View {
        let readings = growth.archive.readings.filter { $0.folderID == folder.id && $0.date >= cutoff }.sorted { $0.date < $1.date }
        return Chart(readings) { reading in
            LineMark(x: .value("Time", reading.date), y: .value("Allocated GB", Double(reading.bytes) / 1_000_000_000))
                .foregroundStyle(.orange).interpolationMethod(.stepEnd)
            PointMark(x: .value("Time", reading.date), y: .value("Allocated GB", Double(reading.bytes) / 1_000_000_000))
                .foregroundStyle(.orange).symbolSize(10)
        }
        .chartXScale(domain: cutoff...Date())
        .chartYAxisLabel("Folder size (GB)")
        .frame(height: 180)
        .overlay { if readings.isEmpty { Text("History will appear as measurements are gathered").foregroundStyle(.secondary) } }
    }
    private func backupNumber(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(.title3.bold()).monospacedDigit()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func backupRecommendation(_ context: BackupContext) -> String {
        if context.backupRunning == true { return "Backup in progress. Let it finish before recovering space." }
        if context.backupRunning == nil { return "Refresh to check backup activity before cleanup." }
        if context.snapshots == nil { return "Open Time Machine Settings or refresh to check local restore points." }
        if context.snapshots?.isEmpty == true { return "No local restore points to clean up." }
        if let disk = context.disk, Double(disk.freeBytes) / 1_000_000_000 > preferences.warningThresholdGB {
            return "Free space is above your warning threshold. This summary does not measure snapshot sizes or explain recent disk-space changes."
        }
        if context.disk == nil { return "Refresh to check free space. Local snapshot size is not measured here." }
        return "Space is low. You can ask Time Machine to free local restore-point space; the amount recovered may vary."
    }
    private func requestCleanup(_ operation: SnapshotCleanup) { cleanup = operation; confirmCleanup = true }
    private func openTimeMachineSettings() {
        if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Time-Machine-Settings.extension")!) {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.backup")!)
        }
    }
    private func openDiskUtility() {
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Disk Utility.app"))
    }
    private func openPrivacySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        if !NSWorkspace.shared.open(url) {
            folderError = "Open System Settings → Privacy & Security → Full Disk Access manually."
        }
    }
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != "/", resolved.path != "/System/Volumes/Data" else {
            folderError = "Choose a specific folder instead of the whole startup disk."; return
        }
        guard (try? resolved.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
            folderError = "Choose a folder on a local disk. Network locations are not monitored."; return
        }
        guard !preferences.growthFolders.contains(where: { $0.path == resolved.path }) else { return }
        preferences.growthFolders.append(GrowthFolder(id: UUID().uuidString, name: resolved.lastPathComponent, path: resolved.path))
        folderError = nil
    }
}
