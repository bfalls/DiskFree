import SwiftUI
import AppKit

struct SpaceChangeReportView: View {
    let change: SpaceChange
    let store: HistoryStore
    @Environment(\.dismiss) private var dismiss
    @State private var report: SpaceChangeReport?
    @State private var loading = false
    @State private var saveError = false
    @State private var saved = false
    @State private var retryReady = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(change.title, systemImage: "star.fill").font(.title2.bold())
                .foregroundStyle(change.bytes > 0 ? Color.mint : .pink)
            Text(ActivityEvent.timeRange(from: change.before.date, through: change.after.date)).font(.caption).foregroundStyle(.secondary)
            if let report {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !loading || report.headline != "Cause not established" { Text(report.headline).font(.headline) }
                        if report.actions.contains(where: { $0.kind == .snapshot }) {
                            Text(change.bytes > 0 ? "Snapshot removal matches the timing; reclaimed size wasn’t logged." : "Cleanup occurred alongside other disk growth.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(Array(report.measurements.enumerated()), id: \.offset) { _, row in
                            HStack { Text(row.0).foregroundStyle(.secondary); Spacer(); Text(row.1).textSelection(.enabled) }
                        }
                        if !report.folders.isEmpty {
                            Divider()
                            Text("Nearby folder changes").font(.headline)
                            ForEach(Array(report.folders.enumerated()), id: \.offset) { _, folder in
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(folder.name + (folder.delta > 0 ? " grew " : " shrank ") + CapacityFormat.string(abs(folder.delta)))
                                        Spacer()
                                        Button("Reveal Folder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.after.root)]) }.controlSize(.small)
                                    }
                                    Text(ActivityEvent.timeRange(from: folder.before.measuredAt, through: folder.after.measuredAt)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if let findings = report.fileFindings {
                            Divider()
                            HStack {
                                Text("Suspect files").font(.headline)
                                Spacer()
                                Button("Check Again") { Task { await collect(retryFiles: true) } }.controlSize(.small)
                                    .disabled(loading || !retryReady)
                                    .task(id: findings.checkedAt) {
                                        retryReady = false
                                        let delay = max(0, 60 - Date().timeIntervalSince(findings.checkedAt))
                                        do {
                                            try await Task.sleep(nanoseconds: UInt64(min(60, delay) * 1e9))
                                            retryReady = true
                                        } catch {}
                                    }
                            }
                            if findings.files.isEmpty {
                                Text("No matching files found").font(.caption).foregroundStyle(.secondary)
                            } else {
                                VStack(alignment: .leading, spacing: 10) {
                                        ForEach(findings.files) { file in
                                            VStack(alignment: .leading, spacing: 3) {
                                                HStack {
                                                    Text(URL(fileURLWithPath: file.path).lastPathComponent).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                                                    Spacer()
                                                    Button(file.kind == "Removed" ? "Show Folder" : "Show in Finder") { showInFinder(file) }
                                                        .controlSize(.small)
                                                }
                                                Text(file.summary + " · " + file.source).font(.caption)
                                                Text(file.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                                            }
                                        }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                                Text("Possible contributors, not confirmed causes.").font(.caption).foregroundStyle(.secondary)
                            }
                            DisclosureGroup("File sources") {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(findings.spotlight)
                                    Text(findings.tracking)
                                    Text("Checked " + findings.checkedAt.formatted(date: .abbreviated, time: .standard))
                                    if let since = findings.trackingSince { Text("Tracking since " + since.formatted(date: .abbreviated, time: .standard)) }
                                }.font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !report.actions.isEmpty {
                            DisclosureGroup("Recorded actions · \(report.actions.count)") {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 10) {
                                        ForEach(Array(report.actions.enumerated()), id: \.offset) { _, action in
                                            Text(action.date.formatted(date: .omitted, time: .standard) + " · " + action.process + "\n" + action.message)
                                                .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                        }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }.frame(maxHeight: 170)
                            }
                        }
                        DisclosureGroup("History files") {
                            HStack {
                                if saved { Button("Reveal Report") { NSWorkspace.shared.activateFileViewerSelecting([store.space.source(for: change)]) } }
                                Button("Measurements") { NSWorkspace.shared.activateFileViewerSelecting(Array(Set([store.system.source(for: change.before.date), store.system.source(for: change.after.date)]))) }
                            }.controlSize(.small)
                        }
                        Text(report.logStatus).font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: .infinity)
            }
            if loading { ProgressView("Checking recorded activity…").controlSize(.small) }
            if saveError { Text("Report not saved").font(.caption).foregroundStyle(.secondary) }
            HStack {
                if let file = report?.fileFindings?.files.first {
                    Button(file.kind == "Removed" ? "Show Folder in Finder" : "Show in Finder") { showInFinder(file) }
                }
                if report?.logsUnavailable == true || saveError { Button("Retry Logs") { Task { await collect(retry: true) } }.disabled(loading) }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 600, height: 560)
            .task {
                let cached = store.space.cached(change)
                saved = cached != nil
                report = cached ?? SpaceChangeReport(change: change, checkedAt: Date(), actions: [], folders: [], logStatus: "")
                await collect()
            }
    }
    @MainActor private func showInFinder(_ file: SuspectFile) {
        let url = URL(fileURLWithPath: file.path)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            var folder = url.deletingLastPathComponent()
            while folder.path != "/" && !FileManager.default.fileExists(atPath: folder.path) {
                folder.deleteLastPathComponent()
            }
            NSWorkspace.shared.open(folder)
        }
    }
    @MainActor private func collect(retry: Bool = false, retryFiles: Bool = false) async {
        loading = true; saveError = false
        defer { loading = false }
        do { report = try await store.space.investigate(change, consumers: store.consumers, retry: retry, retryFiles: retryFiles); saved = true }
        catch { if !Task.isCancelled { saveError = true } }
    }
}
