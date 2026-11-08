import SwiftUI
import Charts
import AppKit

private struct HistoryLoadingRing: View {
    let fraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var rotating = false
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 1.5)
            if let fraction {
                Circle().trim(from: 0, to: min(1, max(0, fraction)))
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            } else {
                Circle().trim(from: 0, to: 0.25)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                    .rotationEffect(.degrees(rotating ? 360 : 0))
                    .animation(reduceMotion ? nil : .linear(duration: 0.9).repeatForever(autoreverses: false), value: rotating)
                    .onAppear { rotating = true }
                    .onDisappear { rotating = false }
            }
        }.frame(width: 14, height: 14)
    }
}

enum HistoryRange: String, CaseIterable, Identifiable {
    case hour = "1 hour", sixHours = "6 hours", day = "24 hours", week = "7 days", month = "30 days", year = "1 year"
    var id: String { rawValue }
    var seconds: TimeInterval {
        switch self {
        case .hour: return 3_600
        case .sixHours: return 21_600
        case .day: return 86_400
        case .week: return 604_800
        case .month: return 2_592_000
        case .year: return 31_536_000
        }
    }
    var bucketSeconds: TimeInterval {
        switch self {
        case .hour, .sixHours, .day: return 60
        case .week: return 600
        case .month: return 1_800
        case .year: return 21_600
        }
    }
}

@MainActor final class HistorySession {
    let cache: HistoryPageCache
    var end = Date()
    var live = true
    var closing: Task<Void, Never>?
    init(store: HistoryStore) { cache = HistoryPageCache(store: store) }
}

@MainActor
final class HistoryController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var session: HistorySession?
    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow { AppWindowPresence.shared.closed(window) }
        window?.contentView = nil
        window = nil
    }
    func show(store: HistoryStore, monitor: DiskMonitor, growth: GrowthMonitor, preferences: Preferences, backups: BackupActivityMonitor, reviewBackups: @escaping () -> Void = {}, investigate: @escaping () -> Void) {
        if session == nil { session = HistorySession(store: store) }
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 760),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "DiskFree History"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: HistoryView(store: store, session: session!, monitor: monitor, growth: growth, preferences: preferences, backups: backups, reviewBackups: reviewBackups, investigate: investigate))
            window.minSize = NSSize(width: 800, height: 680)
            window.center()
            self.window = window
        }
        if let window { AppWindowPresence.shared.present(window) }
    }
}

struct PlotPoint: Identifiable {
    var id: Date { point.date }
    let point: HistoryPoint
    let segment: Int
}

private struct BackupHover {
    let id: String
    let part: BackupHoverPart
    let location: CGPoint
}

struct HistoryView: View {
    let store: HistoryStore
    let session: HistorySession
    @ObservedObject var monitor: DiskMonitor
    @ObservedObject var growth: GrowthMonitor
    @ObservedObject var preferences: Preferences
    @ObservedObject var backups: BackupActivityMonitor
    @AppStorage("showBackupMarkers") private var showBackups = true
    @AppStorage("showSystemMarkers") private var showSystem = true
    @AppStorage("showDockerLine") private var showDockerLine = false
    @AppStorage("showSwapLine") private var showSwapLine = false
    @State private var hoveredEvent: ActivityEvent?
    @State private var eventLocation = CGPoint.zero
    @State private var openedEvent: ActivityEvent?
    @State private var backupHover: BackupHover?
    let reviewBackups: () -> Void
    let investigate: () -> Void
    @AppStorage("historyGraphMode") private var graphMode = "Free-space trend"
    @AppStorage("compositionScale") private var storageScale: StorageScale = .used
    @State private var storageHover: StorageSelection?
    @State private var storageHoverLocation = CGPoint.zero
    @State private var storageInspection: StorageSelection?
    private var composition: Bool { graphMode == "Storage composition" }
    private var visibleEvents: [ActivityEvent] {
        ActivityEvent.forChart((systemResult?.events ?? []) + (storageTimeline?.events ?? []))
    }
    @AppStorage("historyTimeRange") private var selectedRange: HistoryRange = .hour
    @State private var requestedEnd = Date()
    @State private var frame: HistoryChartFrame?
    private var cache: HistoryPageCache { session.cache }
    @State private var loadStatus: HistoryLoadStatus?
    @State private var prefetchTask: Task<Void, Never>?
    @State private var pageID = UUID()
    @State private var slideDirection = -1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var range: HistoryRange { frame?.range ?? selectedRange }
    private var end: Date { frame?.page.key.end ?? requestedEnd }
    private var result: HistoryResult? { frame?.page.disk }
    private var plot: [PlotPoint] { frame?.plot ?? [] }
    private var systemResult: SystemHistoryResult? { frame?.page.system }
    private var backupResult: BackupHistoryResult? { frame?.page.backups }
    private var storageTimeline: StorageTimeline? { frame?.page.storage }
    private var error: String? { frame?.page.diskError }
    private var systemError: String? { frame?.page.systemError }
    private var backupError: String? { frame?.page.backupError }
    private var storageError: String? { frame?.page.storageError }
    private var dockerError: String? { frame?.page.dockerError }
    @State private var live = true
    @State private var selected: HistoryPoint?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var lastReload = Date.distantPast
    private var start: Date { end.addingTimeInterval(-range.seconds) }

    var body: some View {
        ScrollView { VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Disk space history").font(.title2.bold())
                Spacer()
                Button("Investigate…", action: investigate)
                historyProgress
                Button("Refresh") { reload(force: true, reloadJournals: true) }.disabled(loading)
                Button("Show Logs") { NSWorkspace.shared.open(store.directory) }
            }
            HStack {
                Picker("Time range", selection: $selectedRange) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Button { live = false; requestedEnd = requestedEnd.addingTimeInterval(-selectedRange.seconds); reload() } label: {
                    Image(systemName: "chevron.left")
                }.help("Previous time range")
                Button { requestedEnd = min(Date(), requestedEnd.addingTimeInterval(selectedRange.seconds)); reload() } label: {
                    Image(systemName: "chevron.right")
                }.disabled(live).help("Next time range")
                Button("Live") { live = true; reload(advanceLive: true) }.disabled(live)
            }
            HStack {
                Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))\(live ? " · Live" : "")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Show backups", isOn: $showBackups).toggleStyle(.checkbox).controlSize(.small)
                    .help("Show Time Machine backups")
            }
            HStack {
                Picker("Graph", selection: $graphMode) {
                    Text("Free-space trend").tag("Free-space trend")
                    Text("Storage composition").tag("Storage composition")
                }.pickerStyle(.segmented).frame(width: 360)
                if composition {
                    Picker("Scale", selection: $storageScale) { ForEach(StorageScale.allCases) { Text($0.rawValue).tag($0) } }
                        .frame(width: 250)
                }
                Spacer()
            }
            HStack(spacing: 16) {
                if !composition {
                Label("Free space", systemImage: "line.diagonal").foregroundStyle(.blue)
                Toggle("Docker", isOn: $showDockerLine).foregroundStyle(.orange)
                Toggle("Swap allocated", isOn: $showSwapLine).foregroundStyle(.purple)
                }
                Toggle("Events", isOn: $showSystem)
                Spacer()
                Menu("Events…") {
                    ForEach(visibleEvents.suffix(120).reversed()) { event in
                        Button(event.date.formatted(date: .omitted, time: .shortened) + " · " + event.title) { openedEvent = event }
                    }
                    if visibleEvents.isEmpty { Text("No recorded events in this range") }
                }
            }.font(.caption).toggleStyle(.checkbox)
            if composition {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 4) {
                    ForEach(ConsumerKind.allCases.filter { kind in storageScale.includes(kind) && (storageTimeline?.frames.contains { ($0.portions + $0.estimatedPortions).contains { $0.kind == kind } } ?? false) }, id: \.self) { kind in
                        HStack(spacing: 5) {
                            Circle().fill(kind.color.opacity(kind == .other ? 0.35 : 1)).frame(width: 7, height: 7)
                            Text(kind.title).foregroundStyle(.secondary)
                        }
                    }
                }.font(.caption)
                Text(storageScale == .whole ? "Estimated composition · colored consumers and Other used / system make up used space." : storageScale == .used ? "Used-space scale excludes the free region so a mostly empty large disk stays readable. The capacity bar shows free space independently of this scale." : "Tracked-consumer scale compares allocated-size estimates separately from the disk total. Shared blocks may overlap.")
                    .font(.caption).foregroundStyle(.secondary)
                if !preferences.trackGrowth {
                    Button("Enable Background Consumer Measurements") { preferences.trackGrowth = true }
                } else { Text(growth.status).font(.caption).foregroundStyle(.secondary) }
                if let storageError { Text(storageError).font(.caption).foregroundStyle(.secondary) }
            }
            if composition, let frame = storageHover?.frame ?? storageTimeline?.frames.last {
                capacityBar(frame)
            }
            HStack(spacing: 15) {
                    if showSystem {
                        eventKey("Swap", color: .purple)
                        eventKey("Docker", color: .orange)
                    }
                    HStack(spacing: 4) {
                        ForEach([MemoryPressure.normal, .warning, .critical], id: \.self) { pressure in
                            Circle().fill(pressure.color).frame(width: 6, height: 6)
                        }
                        Text("Memory pressure")
                    }
                    if showSystem {
                        eventKey("Power / app", color: .teal, symbol: "diamond.fill")
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").foregroundStyle(.mint)
                            Image(systemName: "star.fill").foregroundStyle(.pink)
                            Text("Space changes").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    if showBackups { eventKey("Backups", color: .green, symbol: "rectangle.fill") }
            }.font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if frame == nil {
                VStack(spacing: 10) {
                    if !loading { Text("No samples in this time range").foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity).frame(height: 320)
            } else {
                ZStack {
                    if let frame {
                        HistoryChartView(frame: frame, composition: composition, storageScale: storageScale,
                            showSystem: showSystem, showBackups: showBackups, showDockerLine: showDockerLine, showSwapLine: showSwapLine,
                            selected: $selected, hoveredEvent: $hoveredEvent, eventLocation: $eventLocation, openedEvent: $openedEvent,
                            backupHover: $backupHover, storageHover: $storageHover, storageHoverLocation: $storageHoverLocation,
                            storageInspection: $storageInspection)
                            .compositingGroup().id(pageID).transition(pageTransition)
                    }
                }.frame(height: 320).clipped().allowsHitTesting(!loading).zIndex(1)
                if let latestCapturedDate {
                    Text("Last captured: " + latestCapturedDate.formatted(date: .abbreviated, time: .standard))
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if composition {
                    Text("Hover a region for its measurements and nearby events. Click it for sources and current cleanup options.").font(.caption).foregroundStyle(.secondary)
                } else if let point = selected {
                    Text("\(point.lastDate.formatted(date: .abbreviated, time: .standard)): \(point.lastGB, specifier: "%.2f") GB free · range \(point.minGB, specifier: "%.2f")–\(point.maxGB, specifier: "%.2f") GB · \(point.samples) samples")
                        .font(.caption).monospacedDigit()
                    Text(growthClues(at: point.lastDate)).font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Click or drag across the graph to inspect a sample.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            HStack(spacing: 16) {
                Text("Now").foregroundStyle(.secondary)
                if let snapshot = monitor.dockerReading.snapshot {
                    Text("Docker: " + CapacityFormat.string(snapshot.allocatedBytes)).foregroundStyle(.orange)
                }
                if let vitals = monitor.systemVitals {
                    if let allocated = vitals.allocated { Text("Swap allocated: " + CapacityFormat.string(allocated)).foregroundStyle(.purple) }
                    if let used = vitals.used { Text("Swap used: " + CapacityFormat.string(used)) }
                    Text("Memory pressure: " + (vitals.pressure?.rawValue ?? "unavailable"))
                }
            }.font(.caption).monospacedDigit()
            if let selected { Text(systemSampleDetail(at: selected.lastDate)).font(.caption).foregroundStyle(.secondary) }
            Text("Hover an event or shaded span for context; click for evidence.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = systemError ?? monitor.systemHistoryError { Text("System history: " + error).font(.caption).foregroundStyle(.secondary) }
            if let dockerError { Text(dockerError).font(.caption).foregroundStyle(.secondary) }
            if let systemResult, systemResult.totalEvents > min(500, systemResult.events.count) {
                Text("Showing up to \(min(500, systemResult.events.count)) of \(systemResult.totalEvents) events. Choose a shorter range for earlier events.").font(.caption).foregroundStyle(.secondary)
            }
            if let result {
                Text("Free-space history: \(result.sampleCount.formatted()) samples · \(Int(result.bucketSeconds / 60)) minute summaries.")
                    .font(.caption).foregroundStyle(.secondary)
                if result.skippedLines > 0 {
                    Text("\(result.skippedLines) malformed or incomplete rows skipped; original logs preserved.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            if showBackups {
                if let backupResult, backupResult.totalCount > backupResult.spans.count {
                    Text("Showing the latest \(backupResult.spans.count) of \(backupResult.totalCount) backup spans in this range.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let message = backupError ?? backups.recordingError { Text("Backup markers: " + message).font(.caption).foregroundStyle(.secondary) }
                if !backups.statusAvailable { Text("Backup status is temporarily unavailable; affected spans remain unknown.").font(.caption).foregroundStyle(.secondary) }
            }
        }
        .padding(22).frame(minWidth: 740) }
        .frame(minWidth: 800, minHeight: 680)
        .sheet(item: $openedEvent) { event in ActivityEvidenceView(event: event, store: store) }
        .sheet(item: $storageInspection) { selection in StorageInspectionView(selection: selection, store: store, reviewBackups: reviewBackups) }

        .onAppear {
            requestedEnd = session.end; live = session.live
            reload()
        }
        .onDisappear {
            session.end = requestedEnd; session.live = live
            loadTask?.cancel(); prefetchTask?.cancel()
            let cache = cache; session.closing = Task { await cache.cancelPending() }
        }
        .onChange(of: selectedRange) { _ in reload() }
        .onChange(of: graphMode) { _ in
            hoveredEvent = nil; backupHover = nil; storageHover = nil
            if composition { preferences.beginInvestigation() }
        }
        .onChange(of: storageScale) { _ in storageHover = nil; hoveredEvent = nil }
        .onReceive(growth.$consumerRevision.dropFirst()) { _ in if live && !loading { reload(advanceLive: true) } }
        .onChange(of: showSystem) { _ in hoveredEvent = nil }
        .onChange(of: showBackups) { _ in backupHover = nil }
        .onReceive(backups.$evidenceRevision.dropFirst()) { _ in reload(force: true) }
        .onReceive(backups.$transitionRevision.dropFirst()) { _ in if live { reload() } }
        .onReceive(backups.$revision.dropFirst()) { _ in
            if live && !loading && Date().timeIntervalSince(lastReload) >= 60 { reload(advanceLive: true) }
        }
        .onReceive(monitor.$spaceRevision.dropFirst()) { _ in reload(force: true) }
        .onReceive(monitor.$historyCleanupRevision.dropFirst()) { _ in reload(force: true, reloadJournals: true) }
        .onReceive(monitor.$historyRevision.dropFirst()) { _ in
            if live && !loading && Date().timeIntervalSince(lastReload) >= 60 { reload(advanceLive: true) }
        }
    }
    private var latestCapturedDate: Date? { result?.points.last?.lastDate }
    private func eventKey(_ title: String, color: Color, symbol: String = "circle.fill") -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 7)).foregroundStyle(color)
            Text(title)
        }
    }
    private func capacityBar(_ frame: StorageFrame) -> some View {
        let fraction = frame.total > 0 ? Double(frame.free) / Double(frame.total) : 0
        let level = SpaceLevel.classify(freeBytes: frame.free, thresholdGB: preferences.warningThresholdGB)
        let color: Color = level == .danger ? .red : level == .low ? .orange : level == .warning ? .yellow : .green
        return VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(CapacityFormat.string(frame.free) + " free · " + String(format: "%.1f%%", fraction * 100))
                    .foregroundStyle(color).fontWeight(.semibold)
                Spacer()
                Text(CapacityFormat.string(frame.total) + " capacity · " + level.rawValue).foregroundStyle(.secondary)
            }.font(.caption).monospacedDigit()
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    Rectangle().fill(Color.primary.opacity(0.12)).frame(width: geometry.size.width * (1 - fraction))
                    Rectangle().fill(color).frame(width: geometry.size.width * fraction)
                }.clipShape(Capsule())
            }.frame(height: 9)
                .accessibilityLabel("Disk capacity: " + CapacityFormat.string(frame.free) + " free, " + String(format: "%.1f percent", fraction * 100))
            HStack {
                Text("Used / unavailable")
                Spacer()
                Text((storageHover == nil ? "Latest in range · " : "At cursor · ") + frame.date.formatted(date: .abbreviated, time: .standard))
                Spacer()
                Text("Free")
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func systemSampleDetail(at date: Date) -> String {
        guard let point = systemResult?.points.min(by: { abs($0.record.date.timeIntervalSince(date)) < abs($1.record.date.timeIntervalSince(date)) }),
              abs(point.record.date.timeIntervalSince(date)) <= range.bucketSeconds else { return "No swap or memory-pressure measurement recorded near this sample." }
        let row = point.record
        return "At " + row.date.formatted(date: .abbreviated, time: .standard) + ": swap allocated " + (row.allocated.map(CapacityFormat.string) ?? "unavailable")
            + ", used " + (row.used.map(CapacityFormat.string) ?? "unavailable") + "; memory pressure " + (row.pressure?.rawValue ?? "unavailable") + (row.docker.map { "; Docker " + CapacityFormat.string($0) } ?? "") + "."
    }
    private func growthClues(at date: Date) -> String {
        let clues = preferences.growthFolders.compactMap { folder -> (String, Int64)? in
            guard let ending = GrowthStore.baseline(growth.archive.readings, folderID: folder.id, before: date),
                  ending.date >= date.addingTimeInterval(-3600),
                  let beginning = GrowthStore.baseline(growth.archive.readings, folderID: folder.id, before: date.addingTimeInterval(-3600)) else { return nil }
            let delta = ending.bytes - beginning.bytes
            guard delta > 0 else { return nil }
            return (folder.name, delta)
        }.sorted { $0.1 > $1.1 }.prefix(3)
        guard !clues.isEmpty else { return "No measured folder growth available around this point. Open Investigate for coverage and measurement times." }
        return "Approximate folder growth over the preceding hour: " + clues.map { "\($0.0) +\(CapacityFormat.string($0.1))" }.joined(separator: " · ")
    }
    private var pageTransition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(insertion: .move(edge: slideDirection < 0 ? .leading : .trailing).combined(with: .opacity),
                           removal: .move(edge: slideDirection < 0 ? .trailing : .leading).combined(with: .opacity))
    }
    private var historyProgress: some View {
        ZStack {
            Color.clear
            if loading {
                HistoryLoadingRing(fraction: loadStatus?.overallFraction)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(loadStatus?.stage ?? "Loading history")
        .accessibilityValue(loadStatus?.overallFraction.map { String(Int($0 * 100)) + "%" } ?? "Loading")
        .accessibilityHidden(!loading)
    }
    private func reload(force: Bool = false, advanceLive: Bool = false, reloadJournals: Bool = false) {
        loadTask?.cancel(); prefetchTask?.cancel()
        lastReload = Date()
        if live && (frame == nil || force || advanceLive) {
            // Whole seconds keep nested ranges on the same one-minute bucket grid.
            requestedEnd = Date(timeIntervalSince1970: ceil(Date().timeIntervalSince1970))
        }
        let cache = cache
        let id = UUID(); requestID = id
        let selectedRange = selectedRange
        let key = HistoryPageKey(start: requestedEnd.addingTimeInterval(-selectedRange.seconds), end: requestedEnd, bucket: selectedRange.bucketSeconds)
        loading = true
        loadStatus = nil
        loadTask = Task { @MainActor in
            await session.closing?.value
            guard !Task.isCancelled, requestID == id else { return }
            if force { await cache.clear(reloadJournals: reloadJournals) }
            do {
                let page = try await cache.page(key) { update in
                    Task { @MainActor in
                        guard requestID == id, loading else { return }
                        loadStatus = update
                    }
                }
                try Task.checkCancellation()
                guard requestID == id else { return }
                if loadStatus != nil {
                    loadStatus = HistoryLoadStatus(stage: "Preparing chart…", source: 5, completedBytes: 0, totalBytes: 0)
                    await Task.yield()
                }
                guard requestID == id, !Task.isCancelled else { return }
                let replacement = HistoryChartFrame(page: page, range: selectedRange)
                let navigated = frame != nil && (frame?.range != selectedRange || abs(end.timeIntervalSince(key.end)) > selectedRange.seconds / 2)
                selected = nil; backupHover = nil; hoveredEvent = nil; storageHover = nil
                slideDirection = key.end < end ? -1 : 1
                if navigated {
                    withAnimation(.easeInOut(duration: reduceMotion ? 0.15 : 0.3)) {
                        frame = replacement; pageID = UUID()
                    }
                } else { frame = replacement }
                loading = false
                // Warm only the immediate neighbors. Historical windows remain valid
                // when new samples are appended after their end timestamp.
                prefetchTask = Task {
                    for shift in [-1.0, 1.0] {
                        guard !Task.isCancelled else { return }
                        let target = key.end.addingTimeInterval(shift * selectedRange.seconds)
                        guard target <= Date() else { continue }
                        let neighbor = HistoryPageKey(start: target.addingTimeInterval(-selectedRange.seconds), end: target, bucket: key.bucket)
                        _ = try? await cache.page(neighbor)
                    }
                }
            } catch {
                guard requestID == id else { return }
                loading = false
            }
        }
    }
}


private struct HistoryChartFrame {
    let page: HistoryPage
    let range: HistoryRange
    let plot: [PlotPoint]
    let dockerPlot: [PlotPoint]
    init(page: HistoryPage, range: HistoryRange) {
        self.page = page; self.range = range
        func points(_ result: HistoryResult?, docker: Bool) -> [PlotPoint] {
            var segment = 0
            var previous: HistoryPoint?
            return (result?.points ?? []).map { point in
                if let previous, point.date.timeIntervalSince(previous.date) > page.key.bucket * 1.5
                    || (docker && point.seriesID != previous.seriesID) { segment += 1 }
                previous = point
                return PlotPoint(point: point, segment: segment)
            }
        }
        plot = points(page.disk, docker: false); dockerPlot = points(page.docker, docker: true)
    }
}

private struct HistoryChartView: View {
    let frame: HistoryChartFrame
    let composition: Bool
    let storageScale: StorageScale
    let showSystem: Bool
    let showBackups: Bool
    let showDockerLine: Bool
    let showSwapLine: Bool
    @Binding var selected: HistoryPoint?
    @Binding var hoveredEvent: ActivityEvent?
    @Binding var eventLocation: CGPoint
    @Binding var openedEvent: ActivityEvent?
    @Binding var backupHover: BackupHover?
    @Binding var storageHover: StorageSelection?
    @Binding var storageHoverLocation: CGPoint
    @Binding var storageInspection: StorageSelection?
    private var range: HistoryRange { frame.range }
    private var start: Date { frame.page.key.start }
    private var end: Date { frame.page.key.end }
    private var result: HistoryResult? { frame.page.disk }
    private var plot: [PlotPoint] { frame.plot }
    private var dockerPlot: [PlotPoint] { frame.dockerPlot }
    private var systemResult: SystemHistoryResult? { frame.page.system }
    private var backupResult: BackupHistoryResult? { frame.page.backups }
    private var storageTimeline: StorageTimeline? { frame.page.storage }
    private var visibleEvents: [ActivityEvent] {
        ActivityEvent.forChart((systemResult?.events ?? []) + (storageTimeline?.events ?? []))
    }
    var body: some View {
        Group {
            if plot.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No samples in this time range")
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { chart }
        }.transaction { $0.animation = nil }
    }
    private var latestCapturedDate: Date? {
        result?.points.map(\.lastDate).filter { $0 >= start && $0 <= end }.max()
    }
    // Explicit labels avoid Charts' automatic trailing ellipsis. Reserve room for
    // the last observation, anchoring it inward at its actual time coordinate.
    private var historyAxisDates: [Date] {
        guard let latest = latestCapturedDate else { return [] }
        let interior = (0...3).map { start.addingTimeInterval(range.seconds * Double($0) / 4) }
            .filter { $0 < latest.addingTimeInterval(-range.seconds * 0.2) }
        return interior + [latest]
    }
    private func axisLabel(_ date: Date) -> String {
        range.seconds <= 86_400 ? date.formatted(.dateTime.hour().minute()) : date.formatted(.dateTime.month(.abbreviated).day())
    }
    private var yTicks: [Double] {
        let bounds = yDomain
        if composition && storageScale == .whole { return (0...5).map { bounds.upperBound * Double($0) / 5 } }
        let rough = (bounds.upperBound - bounds.lowerBound) / 4
        let magnitude = pow(10, floor(log10(max(rough, 0.001))))
        let step = ([1.0, 2, 5, 10].first { $0 * magnitude >= rough } ?? 10) * magnitude
        let first = ceil(bounds.lowerBound / step), last = floor(bounds.upperBound / step)
        guard first <= last else { return [bounds.lowerBound, bounds.upperBound] }
        return (0...Int(last - first)).map { (first + Double($0)) * step }
    }
    private var scaleLabelWidth: CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        return ceil(yTicks.map { tick in
            (tick.formatted(.number.precision(.fractionLength(0...2))) as NSString)
                .size(withAttributes: [.font: font]).width
        }.max() ?? 20)
    }
    @ViewBuilder private func scaleLabels(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        let frame = geometry[proxy.plotAreaFrame]
        ForEach(yTicks, id: \.self) { tick in
            if let y = proxy.position(forY: tick) {
                Text(tick.formatted(.number.precision(.fractionLength(0...2))))
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    .frame(width: scaleLabelWidth, alignment: .trailing)
                    .position(x: frame.maxX + 6 + scaleLabelWidth / 2,
                              y: min(frame.maxY - 7, max(frame.minY + 7, frame.minY + y)))
                    .allowsHitTesting(false)
            }
        }
    }
    private let pressureRowHeight: CGFloat = 8
    private func pressureRow(proxy: ChartProxy, geometry: GeometryProxy) -> some View {
        let frame = geometry[proxy.plotAreaFrame]
        let floor = frame.minY + (proxy.position(forY: yDomain.lowerBound) ?? frame.height - pressureRowHeight)
        return Canvas { context, _ in
            context.fill(Path(CGRect(x: frame.minX, y: floor, width: frame.width, height: pressureRowHeight)),
                         with: .color(.secondary.opacity(0.12)))
            for point in systemResult?.points ?? [] {
                guard let pressure = point.maximumPressure,
                      let first = proxy.position(forX: max(start, point.date)),
                      let last = proxy.position(forX: min(end, point.date.addingTimeInterval(range.bucketSeconds))) else { continue }
                let left = max(frame.minX, frame.minX + first)
                let right = min(frame.maxX, frame.minX + last)
                if right > left {
                    context.fill(Path(CGRect(x: left, y: floor, width: right - left, height: pressureRowHeight)),
                                 with: .color(pressure.color))
                }
            }
        }.allowsHitTesting(false)
            .accessibilityLabel("Memory pressure history: light green normal, yellow elevated, red critical; neutral gaps have no reading")
    }
    private var chart: some View {
        Chart {
            if showBackups { backupMarks }
            if showSystem { activityMarks }
            if !composition && showDockerLine {
                ForEach(dockerPlot) { item in
                    LineMark(x: .value("Time", item.point.lastDate), y: .value("Docker allocated GB", item.point.lastGB), series: .value("Series", "docker-\(item.segment)"))
                        .foregroundStyle(.orange).interpolationMethod(.linear)
                }
            }
            if !composition && showSwapLine {
                ForEach(systemResult?.points ?? []) { point in
                    if let bytes = point.record.allocated {
                        LineMark(x: .value("Time", point.record.date), y: .value("Swap allocated GB", Double(bytes) / 1e9), series: .value("Series", "swap-\(point.segment)"))
                            .foregroundStyle(.purple).interpolationMethod(.linear)
                    }
                }
            }
            if composition { compositionMarks } else {
            ForEach(plot) { item in
                let point = item.point
                RectangleMark(xStart: .value("Time", point.date),
                              xEnd: .value("Time", min(end, point.date.addingTimeInterval(range.bucketSeconds))),
                              yStart: .value("Minimum GB", point.minGB), yEnd: .value("Maximum GB", point.maxGB))
                    .foregroundStyle(.blue.opacity(0.18))
                LineMark(x: .value("Time", point.lastDate), y: .value("Free GB", point.lastGB),
                         series: .value("Series", "free-\(item.segment)"))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                PointMark(x: .value("Time", point.lastDate), y: .value("Free GB", point.lastGB))
                    .foregroundStyle(.blue).symbolSize(plot.count < 100 ? 14 : 4)
            }
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.lastDate)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: start...end)
        .chartXAxis {
            AxisMarks(values: historyAxisDates) { value in
                AxisGridLine()
                AxisTick()
                if let date = value.as(Date.self) {
                    AxisValueLabel(anchor: date == latestCapturedDate ? .topTrailing : date == start ? .topLeading : .top,
                                   collisionResolution: .disabled) {
                        Text(axisLabel(date)).fixedSize()
                    }
                }
            }
        }
        .chartYScale(domain: yDomain, range: .plotDimension(startPadding: pressureRowHeight, endPadding: 0))
        .chartYAxis {
            AxisMarks(position: .trailing, values: yTicks) { _ in
                AxisGridLine()
                AxisTick()
                // Reserve the column; draw numbers below with one shared x position.
                // Charts adjusts endpoint label positions even with a fixed text width.
                AxisValueLabel { Color.clear.frame(width: scaleLabelWidth + 6, height: 12) }
            }
        }
        .chartYAxisLabel(composition ? "Allocated space (GB)" : showDockerLine || showSwapLine ? "Space (GB)" : "Free space (GB)")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let origin = geometry[proxy.plotAreaFrame].origin
                        guard let date: Date = proxy.value(atX: value.location.x - origin.x) else { return }
                        selected = plot.min { abs($0.point.lastDate.timeIntervalSince(date)) < abs($1.point.lastDate.timeIntervalSince(date)) }?.point
                    }.onEnded { value in
                        hoverBackup(at: value.location, proxy: proxy, geometry: geometry)
                        if let event = hitActivity(at: value.location, proxy: proxy, geometry: geometry) { openedEvent = event }
                        else if composition, let selection = storageSelection(at: value.location, proxy: proxy, geometry: geometry) { storageInspection = selection }
                        else if let hover = backupHover, let span = backupResult?.spans.first(where: { $0.id == hover.id }) {
                            openedEvent = ActivityEvent(id: span.id, date: span.start, end: span.end, category: .backup,
                                title: "Time Machine", detail: span.detail(part: hover.part), records: [], backupSession: span.verified)
                        }
                    })
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let location):
                            let event = hitActivity(at: location, proxy: proxy, geometry: geometry)
                            if event?.id != hoveredEvent?.id { hoveredEvent = event; eventLocation = location }
                            hoverBackup(at: location, proxy: proxy, geometry: geometry)
                            if composition {
                                let selection = storageSelection(at: location, proxy: proxy, geometry: geometry)
                                if selection?.id != storageHover?.id || selection?.kind != storageHover?.kind {
                                    storageHover = selection; storageHoverLocation = location
                                }
                            }
                        case .ended: backupHover = nil; hoveredEvent = nil; storageHover = nil
                        }
                    }
                pressureRow(proxy: proxy, geometry: geometry)
                scaleLabels(proxy: proxy, geometry: geometry)
                if !composition, hoveredEvent == nil, showBackups, let hover = backupHover,
                   let span = backupResult?.spans.first(where: { $0.id == hover.id }) {
                    ChartHoverTooltip(title: "Time Machine", text: backupTooltip(span), color: .green,
                        anchor: hover.location, obstacles: tooltipObstacles(proxy: proxy, geometry: geometry),
                        size: geometry.size)
                }
                if composition, hoveredEvent == nil, let selection = storageHover {
                    ChartHoverTooltip(title: storageTooltipTitle(selection), text: storageTooltip(selection), color: selection.kind?.color ?? .secondary,
                        anchor: storageHoverLocation, obstacles: tooltipObstacles(proxy: proxy, geometry: geometry), size: geometry.size)
                }
                if let event = hoveredEvent {
                    ChartHoverTooltip(title: event.title, text: event.tooltipBody, color: event.color,
                        anchor: eventLocation, obstacles: tooltipObstacles(proxy: proxy, geometry: geometry),
                        size: geometry.size)
                }
            }
        }
        .accessibilityLabel("Free disk space in gigabytes over time, with optional Time Machine backup markers")
    }
    @ChartContentBuilder private var backupMarks: some ChartContent {
        let bounds = yDomain
        ForEach(backupResult?.spans ?? []) { span in
            RectangleMark(xStart: .value("Backup start", max(start, span.start)),
                          xEnd: .value("Backup end", span.bandEnd(through: end)),
                          yStart: .value("Band lower", bounds.lowerBound), yEnd: .value("Band upper", bounds.upperBound))
                .foregroundStyle(.green.opacity(0.08))
            if span.start >= start {
                RuleMark(x: .value("Start observed", span.start))
                    .foregroundStyle(.green.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: span.previousIdle == nil && span.verified?.start == nil ? [3, 3] : []))
                    .annotation(position: .top, spacing: 2) {
                        Image(systemName: "clock.arrow.circlepath").font(.system(size: 11)).foregroundStyle(.green)
                            .help("Time Machine backup")
                    }
            }
            if let stop = span.end, stop >= start && stop <= end {
                RuleMark(x: .value("End observed", stop))
                    .foregroundStyle(.green.opacity(0.65))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: span.ending == .gap ? [3, 3] : []))
            }
        }
    }
    private func tooltipObstacles(proxy: ChartProxy, geometry: GeometryProxy) -> [CGRect] {
        let frame = geometry[proxy.plotAreaFrame]
        var obstacles: [CGRect] = []
        if showSystem {
            for event in visibleEvents where event.markerDate >= start && event.markerDate <= end {
                if let x = proxy.position(forX: event.markerDate), let y = proxy.position(forY: eventY(event)) {
                    obstacles.append(CGRect(x: frame.minX + x - 14, y: frame.minY + y - 14, width: 28, height: 28))
                }
            }
        }
        if showBackups {
            for span in backupResult?.spans ?? [] {
                for date in [span.start, span.end].compactMap({ $0 }) where date >= start && date <= end {
                    if let x = proxy.position(forX: date) {
                        obstacles.append(CGRect(x: frame.minX + x - 12, y: frame.minY - 20, width: 24, height: 36))
                    }
                }
            }
        }
        return obstacles
    }
    private func hoverBackup(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) {
        guard showBackups else { backupHover = nil; return }
        let frame = geometry[proxy.plotAreaFrame]
        guard location.x >= frame.minX && location.x <= frame.maxX,
              location.y >= frame.minY - 18 && location.y <= frame.maxY,
              let date: Date = proxy.value(atX: location.x - frame.minX) else { backupHover = nil; return }
        let tolerance = range.seconds * 7 / max(1, frame.width)
        let spans = backupResult?.spans ?? []
        var hit: (BackupSpan, BackupHoverPart)?
        var nearest = Double.infinity
        for span in spans {
            let startDistance = abs(span.start.timeIntervalSince(date))
            if span.start >= start && startDistance <= tolerance && startDistance < nearest {
                nearest = startDistance; hit = (span, .start)
            }
            if let stop = span.end {
                let distance = abs(stop.timeIntervalSince(date))
                if distance <= tolerance && distance < nearest { nearest = distance; hit = (span, .stop) }
            }
        }
        if hit == nil, let span = spans.first(where: { date >= $0.start && date <= $0.bandEnd(through: end) }) { hit = (span, .span) }
        guard let (span, part) = hit else { if backupHover != nil { backupHover = nil }; return }
        // Keep the tooltip still within a span, avoiding a chart rebuild on every mouse movement.
        if backupHover?.id != span.id || backupHover?.part != part { backupHover = BackupHover(id: span.id, part: part, location: location) }
    }
    @ChartContentBuilder private var activityMarks: some ChartContent {
        let bounds = yDomain
        ForEach(visibleEvents) { event in
            if let finish = event.end {
                RectangleMark(xStart: .value("Event start", max(start, event.date)), xEnd: .value("Event end", min(end, finish)),
                              yStart: .value("Event lower", bounds.lowerBound), yEnd: .value("Event upper", bounds.upperBound))
                    .foregroundStyle(event.color.opacity(0.07))
            }
            if event.markerDate >= start && event.markerDate <= end {
                if event.category == .space {
                    PointMark(x: .value("Event time", event.markerDate), y: .value("Event GB", eventY(event)))
                        .symbol {
                            Image(systemName: "star.fill")
                                .font(.system(size: 11)).foregroundStyle(event.color)
                        }
                } else {
                    PointMark(x: .value("Event time", event.markerDate), y: .value("Event GB", eventY(event)))
                        .foregroundStyle(event.color)
                        .symbolSize(event.category == .power ? 55 : 48)
                        .symbol(event.category == .power ? BasicChartSymbolShape.diamond : BasicChartSymbolShape.circle)
                }
            }
        }
    }
    private func eventY(_ event: ActivityEvent) -> Double {
        let bounds = yDomain
        if event.category == .space {
            // Keep milestones on a nearby, separate row; this height does not represent GB.
            return bounds.upperBound - (bounds.upperBound - bounds.lowerBound) * 0.08
        }
        if composition {
            // Context markers share a top row; their height never represents GB.
            return bounds.upperBound - (bounds.upperBound - bounds.lowerBound) * 0.025
        }
        if event.category == .memory { return bounds.upperBound - (bounds.upperBound - bounds.lowerBound) * 0.095 }
        return event.freeGB.map { min(bounds.upperBound, max(bounds.lowerBound, $0)) }
            ?? bounds.upperBound - (bounds.upperBound - bounds.lowerBound) * 0.035
    }
    private func hitActivity(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> ActivityEvent? {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX) else { return nil }
        let floor = frame.minY + (proxy.position(forY: yDomain.lowerBound) ?? frame.height - pressureRowHeight)
        if location.y >= floor && location.y <= floor + pressureRowHeight {
            guard let point = systemResult?.points.first(where: { date >= $0.date && date < $0.date.addingTimeInterval(range.bucketSeconds) }),
                  let pressure = point.maximumPressure else { return nil }
            let record = point.pressureRecord
            return ActivityEvent(id: record.id + "pressureBucket", date: record.date, category: .memory,
                title: "Memory pressure: \(pressure.rawValue)",
                detail: record.date.formatted(date: .abbreviated, time: .standard) + "\nHighest sampled pressure in this \(Int(range.bucketSeconds / 60))-minute summary: \(pressure.rawValue).\nSource: kern.memorystatus_vm_pressure_level.",
                records: [record])
        }
        guard showSystem else { return nil }
        var nearest: ActivityEvent?, distance = 14.0
        for event in visibleEvents where event.markerDate >= start && event.markerDate <= end {
            guard let x = proxy.position(forX: event.markerDate), let y = proxy.position(forY: eventY(event)) else { continue }
            let delta = hypot(location.x - frame.minX - x, location.y - frame.minY - y)
            if delta < distance { nearest = event; distance = delta }
        }
        if let nearest { return nearest }
        return visibleEvents.first { event in event.end.map { date >= event.date && date <= $0 } ?? false }
    }
    private var compositionPlotFrames: [StorageFrame] {
        let frames = storageTimeline?.frames ?? []
        let stride = max(1, Int(ceil(Double(frames.count) / 400)))
        guard stride > 1 else { return frames }
        return frames.enumerated().compactMap { index, frame in
            let boundary = index == 0 || index == frames.count - 1
                || (index > 0 && frames[index - 1].segment != frame.segment)
                || (index + 1 < frames.count && frames[index + 1].segment != frame.segment)
            return boundary || index % stride == 0 ? frame : nil
        }
    }
    @ChartContentBuilder private var compositionMarks: some ChartContent {
        let frames = compositionPlotFrames
        ForEach(Array(frames.enumerated()), id: \.element.id) { index, frame in
            let next = index + 1 < frames.count ? frames[index + 1] : nil
            let width = max(range.bucketSeconds, Double(frame.native?.interval ?? 60))
            let finish = min(end, next?.segment == frame.segment ? next!.date : frame.date.addingTimeInterval(width))
            ForEach((storageScale == .tracked ? frame.estimatedPortions : frame.portions).filter { storageScale.includes($0.kind) }) { portion in
                RectangleMark(xStart: .value("Observed", frame.date), xEnd: .value("Through", finish),
                    yStart: .value("Lower GB", Double(portion.lower) / 1e9), yEnd: .value("Upper GB", Double(portion.upper) / 1e9))
                    .foregroundStyle(portion.kind.color.opacity(portion.kind == .other ? 0.12 : portion.kind == .free ? 0.22 : 0.65))
                if portion.kind == .free {
                    RuleMark(xStart: .value("Observed", frame.date), xEnd: .value("Through", finish),
                             y: .value("Free boundary GB", Double(portion.lower) / 1e9))
                        .foregroundStyle(Color(red: 0.15, green: 0.7, blue: 1))
                        .lineStyle(StrokeStyle(lineWidth: 1.25))
                    if let next, next.segment == frame.segment,
                       let nextFree = next.portions.first(where: { $0.kind == .free }) {
                        RuleMark(x: .value("Boundary change", finish),
                                 yStart: .value("Previous boundary GB", Double(portion.lower) / 1e9),
                                 yEnd: .value("Next boundary GB", Double(nextFree.lower) / 1e9))
                            .foregroundStyle(Color(red: 0.15, green: 0.7, blue: 1))
                            .lineStyle(StrokeStyle(lineWidth: 1.25))
                    }
                }
            }
        }
    }
    private func storageSelection(at location: CGPoint, proxy: ChartProxy, geometry: GeometryProxy) -> StorageSelection? {
        let frame = geometry[proxy.plotAreaFrame]
        guard frame.contains(location), let date: Date = proxy.value(atX: location.x - frame.minX),
              let y: Double = proxy.value(atY: location.y - frame.minY),
              let sample = compositionPlotFrames.last(where: { $0.date <= date }) else { return nil }
        let next = compositionPlotFrames.first { $0.date > sample.date }
        let finish = min(end, next?.segment == sample.segment ? next!.date : sample.date.addingTimeInterval(max(range.bucketSeconds, Double(sample.native?.interval ?? 60))))
        guard date <= finish else { return nil }
        let bytes = y * 1e9
        let kind = (storageScale == .tracked ? sample.estimatedPortions : sample.portions).first { storageScale.includes($0.kind) && bytes >= Double($0.lower) && bytes <= Double($0.upper) }?.kind
        var events = visibleEvents.filter { event in
            if let finish = event.end { return date >= event.date && date <= finish }
            return abs(event.date.timeIntervalSince(sample.date)) <= range.bucketSeconds
        }
        if showBackups {
            events += (backupResult?.spans ?? []).filter { date >= $0.start && date <= $0.bandEnd(through: end) }.map { span in
                ActivityEvent(id: span.id, date: span.start, end: span.end, category: .backup,
                    title: "Time Machine backup", detail: span.detail(part: .span), records: [], backupSession: span.verified)
            }
        }
        return StorageSelection(frame: sample, kind: kind, events: Array(events.suffix(5)))
    }
    private func backupTooltip(_ span: BackupSpan) -> String {
        var lines = [span.observedEnd > span.start ? ActivityEvent.timeRange(from: span.start, through: span.observedEnd)
            : span.start.formatted(date: .abbreviated, time: .standard)]
        if let session = span.verified {
            lines.append(session.end == nil ? (span.ending == .running ? "Running at last check" : "Completion not recorded") : session.outcome.rawValue)
            var statistics: [String] = []
            if let bytes = session.copiedBytes { statistics.append(CapacityFormat.string(bytes) + " copied") }
            if let files = session.files { statistics.append(files.formatted() + " files") }
            if !statistics.isEmpty { lines.append(statistics.joined(separator: " · ")) }
        } else {
        switch span.ending {
        case .running: lines.append("Running at last check")
        case .stopped: lines.append("Stopped · result unknown")
        case .gap: lines.append("Finish time unknown")
        }
        }
        if let first = span.startFree, let last = span.lastFree, span.observations > 1 {
            let delta = last - first
            lines.append("Observed free: " + (delta >= 0 ? "+" : "−") + CapacityFormat.string(abs(delta)))
        }
        return lines.joined(separator: "\n")
    }
    private func storageTooltipTitle(_ selection: StorageSelection) -> String {
        let portions = storageScale == .tracked ? selection.frame.estimatedPortions : selection.frame.portions
        guard let kind = selection.kind, let portion = portions.first(where: { $0.kind == kind }) else { return "Storage composition" }
        return kind.title + ": " + CapacityFormat.string(portion.bytes)
    }
    private func storageTooltip(_ selection: StorageSelection) -> String {
        let frame = selection.frame
        var lines = [frame.date.formatted(date: .abbreviated, time: .standard),
            "Used " + CapacityFormat.string(frame.used) + " · Free " + CapacityFormat.string(frame.free) + " · Total " + CapacityFormat.string(frame.total)]
        if let event = selection.events.first { lines.append(event.title) }
        if frame.overlap { lines.append("Estimates overlap.") }
        return lines.joined(separator: "\n")
    }
    private var yDomain: ClosedRange<Double> {
        if composition {
            let maximum = storageTimeline?.frames.map { frame -> Double in
                Double(storageScale == .whole ? frame.total : storageScale == .used ? frame.used : frame.tracked) / 1e9
            }.max() ?? 1
            return 0...max(1, storageScale == .whole ? ceil(maximum) : maximum * 1.03)
        }
        var values = plot.flatMap { [$0.point.minGB, $0.point.maxGB] }
        if showDockerLine { values += dockerPlot.flatMap { [$0.point.minGB, $0.point.maxGB] } }
        if showSwapLine { values += (systemResult?.points ?? []).compactMap { $0.record.allocated.map { Double($0) / 1e9 } } }
        let minimum = values.min() ?? 0, maximum = values.max() ?? 1
        let margin = max(0.5, (maximum - minimum) * 0.1)
        return 0...(maximum + margin)
    }
}

private extension MemoryPressure {
    var color: Color {
        switch self {
        case .normal: return Color(red: 0.62, green: 0.84, blue: 0.57)
        case .warning: return .yellow
        case .critical: return .red
        }
    }
}
private extension ActivityCategory {
    var color: Color {
        switch self {
        case .swap: return .purple
        case .docker: return .orange
        case .memory: return .red
        case .power: return .teal
        case .backup: return .green
        case .storage: return .indigo
        case .space: return .mint
        }
    }
}
private struct ActivityEvidenceView: View {
    let event: ActivityEvent
    let store: HistoryStore
    @Environment(\.dismiss) private var dismiss
    private var sources: [URL] {
        if event.category == .backup {
            if let session = event.backupSession {
                return Array(Set(session.evidence.map { store.backups.logs.source(for: $0.date) })).sorted { $0.path < $1.path }
            }
            let formatter = ISO8601DateFormatter()
            let dates = [event.date, event.end ?? event.date]
            return Array(Set(dates.map { store.backups.directory.appendingPathComponent(String(formatter.string(from: $0).prefix(7)) + ".csv") })).sorted { $0.path < $1.path }
        }
        if !event.consumerRecords.isEmpty { return Array(Set(event.consumerRecords.map { store.consumers.source(for: $0.date) })).sorted { $0.path < $1.path } }
        return Array(Set(event.records.map { store.system.source(for: $0.date) })).sorted { $0.path < $1.path }
    }
    private var evidence: String {
        if let session = event.backupSession { return session.evidence.map { $0.date.formatted(date: .abbreviated, time: .standard) + "\n" + $0.message }.joined(separator: "\n\n") }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (event.records.compactMap { try? encoder.encode($0) } + event.consumerRecords.compactMap { try? encoder.encode($0) }).map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n\n")
    }
    var body: some View {
        Group {
        if let change = event.spaceChange { SpaceChangeReportView(change: change, store: store) } else {
        VStack(alignment: .leading, spacing: 14) {
            Label(event.title, systemImage: "info.circle").font(.title2.bold()).foregroundStyle(event.color)
            if let session = event.backupSession {
                ForEach(Array(session.facts.enumerated()), id: \.offset) { _, fact in
                    HStack(alignment: .firstTextBaseline) {
                        Text(fact.0).foregroundStyle(.secondary)
                        Spacer()
                        Text(fact.1).textSelection(.enabled).multilineTextAlignment(.trailing)
                    }
                }
            } else { Text(event.detail).textSelection(.enabled) }
            if event.backupSession != nil || !event.records.isEmpty || !event.consumerRecords.isEmpty {
                DisclosureGroup("Recorded evidence") {
                    ScrollView { Text(evidence).font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 190)
                }
            }

            ForEach(sources, id: \.self) { url in
                Button("Reveal " + url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            }
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 570)
    }
        }
        }
}

private extension ActivityEvent {
    var tooltipBody: String {
        let first = records.first, last = records.last
        let beginning = category == .swap || category == .docker || category == .memory ? first?.date ?? date : date
        let finish = end ?? (category == .swap || category == .docker || category == .memory ? last?.date : nil)
        let stamp: String
        if let finish, finish > beginning { stamp = ActivityEvent.timeRange(from: beginning, through: finish) }
        else { stamp = beginning.formatted(date: .abbreviated, time: .standard) }
        var lines = [stamp]
        if category == .space, let change = spaceChange, let first = change.before.free, let last = change.after.free {
            lines.append(CapacityFormat.string(first) + " → " + CapacityFormat.string(last))
        } else if category == .swap || category == .docker {
            let before = category == .swap ? first?.allocated : first?.docker
            let after = category == .swap ? last?.allocated : last?.docker
            if let before, let after { lines.append(CapacityFormat.string(before) + " → " + CapacityFormat.string(after)) }
            if let before = first?.free, let after = last?.free {
                let delta = after - before
                lines.append("Free space: " + (delta >= 0 ? "+" : "−") + CapacityFormat.string(abs(delta)))
            }
        } else if category == .power && title.hasPrefix("Recording gap") {
            lines.append("Power state unknown")
        } else if category == .memory && records.count == 1 {
            lines.append("Sampled peak")
        } else if category == .storage, let before = consumerRecords.first, let after = consumerRecords.last {
            lines.append(CapacityFormat.string(before.bytes) + " → " + CapacityFormat.string(after.bytes))
        }
        return lines.joined(separator: "\n")
    }
    var color: Color {
        if category == .storage, let row = consumerRecords.last { return row.kind.color }
        if category == .space { return (spaceChange?.bytes ?? 0) > 0 ? .mint : .pink }
        guard category == .memory else { return category.color }
        switch records.last?.pressure {
        case .normal: return MemoryPressure.normal.color
        case .warning: return .yellow
        case .critical: return .red
        case nil: return .gray
        }
    }
}

/// Measures actual wrapped text before placing it; no mouse-following layout state or extra polling.
private struct ChartHoverTooltip: View {
    let title: String
    let text: String
    let color: Color
    let anchor: CGPoint
    let obstacles: [CGRect]
    let size: CGSize
    var body: some View {
        TooltipAvoidanceLayout(anchor: anchor, obstacles: obstacles) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.caption.bold()).foregroundStyle(color)
                Text(text).font(.caption).foregroundStyle(.primary)
            }.padding(12)
                .truncationMode(.tail)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .windowBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(color.opacity(0.6)))
                .shadow(radius: 5)
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}

private struct TooltipAvoidanceLayout: Layout {
    let anchor: CGPoint
    let obstacles: [CGRect]
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        proposal.replacingUnspecifiedDimensions()
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let view = subviews.first else { return }
        let available = CGRect(origin: .zero, size: bounds.size).insetBy(dx: 8, dy: 8)
        let width = min(360, max(1, available.width))
        let measured = view.sizeThatFits(ProposedViewSize(width: width, height: nil))
        // Long descriptions remain clickable for full evidence without blanketing the graph.
        let size = CGSize(width: width, height: min(measured.height, max(1, min(280, available.height * 0.7))))
        let origin = Self.origin(size: size, available: available, anchor: anchor, obstacles: obstacles)
        view.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                   anchor: .topLeading, proposal: ProposedViewSize(size))
    }
    static func origin(size: CGSize, available: CGRect, anchor: CGPoint, obstacles: [CGRect]) -> CGPoint {
        func clamp(_ point: CGPoint) -> CGRect {
            CGRect(x: min(max(point.x, available.minX), max(available.minX, available.maxX - size.width)),
                   y: min(max(point.y, available.minY), max(available.minY, available.maxY - size.height)),
                   width: size.width, height: size.height)
        }
        // Try both sides and above/below first, then search the remaining chart for clear space.
        let gap: CGFloat = 24
        var candidates = [
            CGPoint(x: anchor.x - gap - size.width, y: anchor.y - size.height / 2),
            CGPoint(x: anchor.x + gap, y: anchor.y - size.height / 2),
            CGPoint(x: anchor.x - size.width / 2, y: anchor.y + gap),
            CGPoint(x: anchor.x - size.width / 2, y: anchor.y - gap - size.height)
        ]
        for row in 0...4 {
            for column in 0...4 {
                candidates.append(CGPoint(x: available.minX + max(0, available.width - size.width) * CGFloat(column) / 4,
                                          y: available.minY + max(0, available.height - size.height) * CGFloat(row) / 4))
            }
        }
        let cursor = CGRect(x: anchor.x - 18, y: anchor.y - 18, width: 36, height: 36)
        func score(_ rect: CGRect) -> Double {
            var cost = rect.intersects(cursor) ? 1_000_000_000.0 : 0
            for obstacle in obstacles where rect.intersects(obstacle) {
                let overlap = rect.intersection(obstacle)
                let near = hypot(obstacle.midX - anchor.x, obstacle.midY - anchor.y) < 120
                cost += (near ? 10_000 : 1_000) + Double(overlap.width * overlap.height)
            }
            // Distance is a tie breaker; keeping nearby events visible takes precedence.
            cost += Double(hypot(rect.midX - anchor.x, rect.midY - anchor.y)) * 0.01
            return cost
        }
        return candidates.map(clamp).min { score($0) < score($1) }?.origin ?? available.origin
    }
}
