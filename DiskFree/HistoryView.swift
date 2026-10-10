import SwiftUI
import Charts
import AppKit

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

@MainActor
final class HistoryController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
    }
    func show(store: HistoryStore, monitor: DiskMonitor) {
        if window == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 540),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "DiskFree History"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: HistoryView(store: store, monitor: monitor))
            window.minSize = NSSize(width: 700, height: 500)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct PlotPoint: Identifiable {
    var id: Date { point.date }
    let point: HistoryPoint
    let segment: Int
}

struct HistoryView: View {
    let store: HistoryStore
    @ObservedObject var monitor: DiskMonitor
    @State private var range: HistoryRange = .hour
    @State private var end = Date()
    @State private var live = true
    @State private var result: HistoryResult?
    @State private var plot: [PlotPoint] = []
    @State private var selected: HistoryPoint?
    @State private var error: String?
    @State private var loading = false
    @State private var requestID = UUID()
    @State private var loadTask: Task<Void, Never>?
    @State private var lastReload = Date.distantPast
    private var start: Date { end.addingTimeInterval(-range.seconds) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Free disk space").font(.title2.bold())
                Spacer()
                Button("Refresh") { reload() }.disabled(loading)
                Button("Show Logs") { NSWorkspace.shared.open(store.directory) }
            }
            HStack {
                Picker("Time range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                Button { live = false; end = end.addingTimeInterval(-range.seconds); reload() } label: {
                    Image(systemName: "chevron.left")
                }.help("Previous time range")
                Button { end = min(Date(), end.addingTimeInterval(range.seconds)); reload() } label: {
                    Image(systemName: "chevron.right")
                }.disabled(live).help("Next time range")
                Button("Live") { live = true; reload() }.disabled(live)
            }
            Text("\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .abbreviated, time: .shortened))\(live ? " · Live" : "")")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            if plot.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "chart.xyaxis.line").font(.largeTitle).foregroundStyle(.secondary)
                    Text(loading ? "Reading history…" : "No samples in this time range")
                    Text("History starts with the first refresh in this version of DiskFree.")
                        .font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                chart
                if let point = selected {
                    Text("\(point.lastDate.formatted(date: .abbreviated, time: .standard)): \(point.lastGB, specifier: "%.2f") GB free · range \(point.minGB, specifier: "%.2f")–\(point.maxGB, specifier: "%.2f") GB · \(point.samples) samples")
                        .font(.caption).monospacedDigit()
                } else {
                    Text("Click or drag across the graph to inspect a sample.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                Text("\(result.sampleCount.formatted()) samples · \(Int(result.bucketSeconds / 60)) minute summaries. Line: last reading; shading: minimum to maximum. Gaps indicate missing samples.")
                    .font(.caption).foregroundStyle(.secondary)
                if result.skippedLines > 0 {
                    Text("\(result.skippedLines) malformed or incomplete rows skipped; original logs preserved.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Text("Recorded at your refresh interval while DiskFree is running. Choose 60 seconds or faster for minute-level history.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(minWidth: 660, minHeight: 450)
        .onAppear { reload() }
        .onDisappear { loadTask?.cancel() }
        .onChange(of: range) { _ in reload() }
        .onReceive(monitor.$historyCleanupRevision.dropFirst()) { _ in reload() }
        .onReceive(monitor.$historyRevision.dropFirst()) { _ in
            if live && !loading && Date().timeIntervalSince(lastReload) >= 60 { reload() }
        }
    }
    private var chart: some View {
        Chart {
            ForEach(plot) { item in
                let point = item.point
                RectangleMark(xStart: .value("Time", point.date),
                              xEnd: .value("Time", min(end, point.date.addingTimeInterval(range.bucketSeconds))),
                              yStart: .value("Minimum GB", point.minGB), yEnd: .value("Maximum GB", point.maxGB))
                    .foregroundStyle(.blue.opacity(0.18))
                LineMark(x: .value("Time", point.lastDate), y: .value("Free GB", point.lastGB),
                         series: .value("Run", item.segment))
                    .foregroundStyle(.blue).interpolationMethod(.linear)
                PointMark(x: .value("Time", point.lastDate), y: .value("Free GB", point.lastGB))
                    .foregroundStyle(.blue).symbolSize(plot.count < 100 ? 14 : 4)
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.lastDate)).foregroundStyle(.secondary)
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: yDomain)
        .chartYAxisLabel("Free space (GB)")
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        let origin = geometry[proxy.plotAreaFrame].origin
                        guard let date: Date = proxy.value(atX: value.location.x - origin.x) else { return }
                        selected = plot.min { abs($0.point.lastDate.timeIntervalSince(date)) < abs($1.point.lastDate.timeIntervalSince(date)) }?.point
                    })
            }
        }
        .accessibilityLabel("Free disk space in gigabytes over time")
    }
    private var yDomain: ClosedRange<Double> {
        let minimum = plot.map { $0.point.minGB }.min() ?? 0
        let maximum = plot.map { $0.point.maxGB }.max() ?? 1
        let margin = max(0.5, (maximum - minimum) * 0.1)
        return max(0, minimum - margin)...(maximum + margin)
    }
    private func reload() {
        loadTask?.cancel()
        lastReload = Date()
        if live { end = Date() }
        let id = UUID()
        requestID = id
        let from = start, to = end, bucket = range.bucketSeconds
        loading = true
        selected = nil
        loadTask = Task {
            do {
                let loaded = try await store.load(from: from, through: to, bucketSeconds: bucket)
                guard requestID == id else { return }
                result = loaded
                var segment = 0
                var previous: Date?
                plot = loaded.points.map { point in
                    if let previous, point.date.timeIntervalSince(previous) > bucket * 1.5 { segment += 1 }
                    previous = point.date
                    return PlotPoint(point: point, segment: segment)
                }
                error = nil
            } catch {
                guard requestID == id else { return }
                self.error = "Could not read history: \(error.localizedDescription)"
                plot = []
                result = nil
            }
            loading = false
        }
    }
}
