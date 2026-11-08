import SwiftUI
import AppKit

enum StorageScale: String, CaseIterable, Identifiable {
    case whole = "Whole disk", used = "Used space", tracked = "Tracked consumers"
    var id: String { rawValue }
    func includes(_ kind: ConsumerKind) -> Bool { self == .whole || (kind != .free && (self == .used || kind != .other)) }
}
extension ConsumerKind {
    var color: Color {
        switch self {
        case .docker: return .orange
        case .swap: return .purple
        case .models: return .indigo
        case .developer: return .cyan
        case .caches: return .yellow
        case .downloads: return .green
        case .backups: return .pink
        case .applicationData: return .brown
        case .custom: return .mint
        case .other: return .gray
        case .free: return .blue
        }
    }
}
struct StorageSelection: Identifiable {
    var id: Date { frame.date }
    let frame: StorageFrame
    let kind: ConsumerKind?
    let events: [ActivityEvent]
}
struct StorageInspectionView: View {
    let selection: StorageSelection
    let store: HistoryStore
    let reviewBackups: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var openedSpace: SpaceChange?
    private var frame: StorageFrame { selection.frame }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selection.kind?.title ?? "Storage at this time").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text(frame.date.formatted(date: .abbreviated, time: .standard)).foregroundStyle(.secondary)
            HStack(spacing: 30) {
                number("Used / unavailable", frame.used)
                number("Free", frame.free)
                number("Capacity", frame.total)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Consumer regions are allocated-size estimates, not Apple's Storage categories. Shared APFS blocks, protected files and older measurements limit attribution. Other used / system is the remainder, including unmeasured data and snapshots.")
                        .font(.caption).foregroundStyle(.secondary)
                    if frame.overlap { Text("Consumer estimates exceed the used-space total. They are listed below but not stacked, to avoid presenting an impossible partition.").font(.caption).foregroundStyle(.secondary) }
                    if frame.omitted > 0 { Text("\(frame.omitted) overlapping parent measurements are omitted until their scopes are updated.").font(.caption).foregroundStyle(.secondary) }
                    if let bytes = frame.native?.reclaimable {
                        Text("macOS potentially reclaimable: \(CapacityFormat.string(bytes)). Already included in used space; this is not a snapshot-only size or a guaranteed recovery amount.").font(.caption)
                    }
                    Text("Measured consumers").font(.headline)
                    if let row = frame.native, let bytes = row.docker {
                        HStack { Label("Docker disk image", systemImage: "externaldrive").foregroundStyle(.orange); Spacer(); Text(CapacityFormat.string(bytes)).monospacedDigit() }
                        Text("Allocated blocks, observed \(row.date.formatted(date: .omitted, time: .standard)). Docker manages the image contents.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            openApplicationButton("Docker")
                            if let path = row.dockerPath { Button("Reveal Disk Image") { reveal(path) } }
                        }
                        Text("Review images, build cache and stopped containers in Docker. Volumes may contain databases or other important data; DiskFree does not prune them or delete the disk image.").font(.caption).foregroundStyle(.secondary)
                    }
                    if let row = frame.native, let bytes = row.allocated {
                        HStack { Label("macOS swap", systemImage: "memorychip").foregroundStyle(.purple); Spacer(); Text(CapacityFormat.string(bytes)).monospacedDigit() }
                        Text("\(row.used.map(CapacityFormat.string) ?? "Unknown") in use; pressure \(row.pressure?.rawValue ?? "unknown"). macOS manages these files. Review memory-heavy work rather than deleting swap files.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Open Activity Monitor") { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app")) }
                    }
                    ForEach(frame.consumers, id: \.folderID) { row in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack { Text(row.name).foregroundStyle(row.kind.color).font(.headline); Spacer(); Text(CapacityFormat.string(row.bytes)).monospacedDigit() }
                            Text("Measured \(row.measuredAt.formatted(date: .abbreviated, time: .shortened))\(row.skipped > 0 ? " · accessible files only" : "")").font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Reveal Folder") { reveal(row.root) }
                                if let definition = StorageDiscovery.candidates(home: FileManager.default.homeDirectoryForCurrentUser.path).first(where: { $0.id == row.folderID }),
                                   let app = definition.application { openApplicationButton(app) }
                                Button("Source Record") { NSWorkspace.shared.activateFileViewerSelecting([store.consumers.source(for: row.date)]) }
                            }
                            if row.kind == .models {
                                Text("A model may be loaded by a server, notebook or other app even when its desktop app is closed. Unload it and stop downloads before removing it in the owning tool. Removal can interrupt jobs and require another large download.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(10).background(.quaternary.opacity(0.3)).cornerRadius(8)
                    }
                    if frame.consumers.isEmpty { Text("Folder measurements were not yet available at this time. They appear as the background collector completes them.").font(.caption).foregroundStyle(.secondary) }
                    if !selection.events.isEmpty {
                        Text("Events near this time").font(.headline)
                        ForEach(selection.events) { event in
                            DisclosureGroup(event.title) {
                                VStack(alignment: .leading) {
                                    Text(event.detail).font(.caption).textSelection(.enabled)
                                    if let change = event.spaceChange { Button("Space-change Report") { openedSpace = change } }
                                    Button("Event Source Record") {
                                        let url: URL
                                        if let change = event.spaceChange, store.space.cached(change) != nil {
                                            url = store.space.source(for: change)
                                        } else if let evidence = event.backupSession?.evidence.first {
                                            url = store.backups.logs.source(for: evidence.date)
                                        } else if event.category == .backup {
                                            let f = ISO8601DateFormatter()
                                            url = store.backups.directory.appendingPathComponent(String(f.string(from: event.date).prefix(7)) + ".csv")
                                        } else if let row = event.consumerRecords.last { url = store.consumers.source(for: row.date) }
                                        else { url = store.system.source(for: event.date) }
                                        NSWorkspace.shared.activateFileViewerSelecting([url])
                                    }
                                }
                            }
                        }
                    }
                    Divider()
                    Text("Current cleanup options").font(.headline)
                    Text("Actions open current storage and tools; they do not operate on a historical state. DiskFree won't delete models, personal data or containers here.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Time Machine Cleanup…") {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: reviewBackups)
                        }
                        Button("macOS Storage Settings") {
                            if !NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.Storage")!) {
                                NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
                            }
                        }
                        Button("Free-space Source") {
                            let f = ISO8601DateFormatter()
                            NSWorkspace.shared.activateFileViewerSelecting([store.directory.appendingPathComponent(String(f.string(from: frame.date).prefix(7)) + ".csv")])
                        }
                    }
                    Text("Time Machine cleanup shows a separate confirmation and rechecks backup activity before removing local restore points. External backups are not deleted.").font(.caption).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }.padding(24).frame(width: 650, height: 650)
            .sheet(item: $openedSpace) { change in SpaceChangeReportView(change: change, store: store) }
    }
    private func number(_ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading) { Text(CapacityFormat.string(bytes)).font(.title3.bold()).monospacedDigit(); Text(title).font(.caption).foregroundStyle(.secondary) }
    }
    @ViewBuilder private func openApplicationButton(_ app: String) -> some View {
        let locations = ["/Applications/\(app).app", FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(app).app").path]
        if let location = locations.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            Button("Open " + app) { NSWorkspace.shared.open(URL(fileURLWithPath: location)) }
        }
    }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
}
