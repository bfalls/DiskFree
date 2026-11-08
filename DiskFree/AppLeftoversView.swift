import SwiftUI
import AppKit

@MainActor final class AppLeftoversModel: ObservableObject {
    @Published private(set) var results: LeftoverResults?
    @Published private(set) var busy = false
    @Published private(set) var progress = LeftoverProgress(message: "")
    @Published private(set) var message: String?
    private let store: LeftoverResultStore
    private var token: LeftoverCancellation?
    var cancellable: Bool { token != nil }
    private var query: LeftoverAppQuery?
    private var job: Task<Void, Never>?
    init(store: LeftoverResultStore = .standard) { self.store = store }
    func load() async {
        do { let store = self.store; results = try await Task.detached(priority: .utility) { try store.load() }.value }
        catch { message = "Saved results aren’t available. Run a new check." }
    }
    private func loadInventory(_ token: LeftoverCancellation, ids: [String] = []) async throws -> LeftoverInventory {
        progress = LeftoverProgress(message: "Finding installed apps…")
        let query = LeftoverAppQuery(); self.query = query
        let indexed = await query.search(); self.query = nil
        try token.check()
        let roots = [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
                     URL(fileURLWithPath: "/System/Applications"), URL(fileURLWithPath: "/System/Library/CoreServices")]
        var inventory = try await Task.detached(priority: .utility) { try LeftoverScanner.inventory(indexedPaths: indexed.paths, roots: roots, token: token) }.value
        inventory.limited = inventory.limited || indexed.limited
        inventory.apps += try await registeredApps(ids, token: token)
        return inventory
    }
    private func registeredApps(_ ids: [String], token: LeftoverCancellation) async throws -> [LeftoverApp] {
        var apps = NSWorkspace.shared.runningApplications.compactMap { running -> LeftoverApp? in
            guard let id = running.bundleIdentifier else { return nil }
            return LeftoverApp(bundleID: id, path: running.bundleURL?.path ?? "Running: " + id, names: [running.localizedName ?? id])
        }
        for (offset, id) in Array(Set(ids)).prefix(1024).enumerated() {
            try token.check()
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id),
               !LeftoverScanner.ignoredAppPath(url.resolvingSymlinksInPath().path), FileManager.default.fileExists(atPath: url.path) {
                apps.append(LeftoverApp(bundleID: id, path: url.path, names: [url.deletingPathExtension().lastPathComponent]))
            }
            if offset % 8 == 0 { await Task.yield() }
        }
        return apps
    }
    func find(caches: [FolderCache]) {
        guard !busy else { return }
        busy = true; message = nil
        let token = LeftoverCancellation(); self.token = token
        let previous = results, store = self.store
        job = Task { [self] in
            defer { busy = false; self.token = nil; job = nil }
            do {
                var inventory = try await loadInventory(token)
                progress = LeftoverProgress(message: "Checking support folders…")
                let snapshot = inventory
                var found = try await Task.detached(priority: .utility) {
                    try LeftoverScanner.scan(root: LeftoverScanner.supportRoot, inventory: snapshot, previous: previous, caches: caches, token: token) { update in
                        Task { @MainActor [weak self] in
                            guard let self, self.token === token else { return }
                            self.progress = update
                        }
                    }
                }.value
                try token.check()
                inventory.apps += try await registeredApps(found.candidates.flatMap(\.bundleIDs), token: token)
                let kept = found.kept, known = found.knownApps
                found.candidates.removeAll { candidate in
                    !kept.contains(candidate.path) && LeftoverScanner.association(name: candidate.name, installed: inventory.apps, known: known) == nil
                }
                let final = LeftoverResults(schema: 1, checkedAt: found.checkedAt, root: found.root, rootIdentity: found.rootIdentity,
                    knownApps: found.knownApps, candidates: found.candidates, kept: found.kept, inventoryLimited: found.inventoryLimited, measurementLimited: found.measurementLimited)
                try token.check()
                try await Task.detached(priority: .utility) { try token.check(); try store.save(final) }.value
                results = final; message = "Check complete"
            } catch is CancellationError { message = "Cancelled · previous results kept" }
            catch { message = (error as? LeftoverFailure)?.errorDescription ?? "Check couldn’t finish. Previous results kept." }
        }
    }
    func cancel() { token?.cancel(); query?.cancel(); progress = LeftoverProgress(message: "Cancelling…") }
    func keep(_ candidate: LeftoverCandidate, keep: Bool = true) {
        guard !busy, var updated = results else { return }
        if keep { updated.kept.insert(candidate.path) } else { updated.kept.remove(candidate.path) }
        busy = true; progress = LeftoverProgress(message: "Saving…")
        let store = self.store, final = updated
        job = Task { [self] in
            defer { busy = false; job = nil }
            do { try await Task.detached(priority: .utility) { try store.save(final) }.value; results = final; message = nil }
            catch { message = "Choice couldn’t be saved." }
        }
    }
    func moveToTrash(_ candidate: LeftoverCandidate) {
        guard !busy, let results else { return }
        busy = true; message = nil
        let token = LeftoverCancellation(); self.token = token
        let store = self.store
        job = Task { [self] in
            defer { busy = false; self.token = nil; job = nil }
            do {
                let fresh = try await loadInventory(token, ids: candidate.bundleIDs)
                progress = LeftoverProgress(message: "Checking folder…")
                try await Task.detached(priority: .utility) {
                    try token.check()
                    try LeftoverScanner.validateForTrash(candidate, results: results, inventory: fresh)
                }.value
                // Recheck running/registered apps after all awaited inventory work.
                let registered = try await registeredApps(candidate.bundleIDs, token: token)
                guard LeftoverScanner.association(name: candidate.name, installed: registered, known: results.knownApps) != nil else { throw LeftoverFailure.appPresent }
                progress = LeftoverProgress(message: "Moving to Trash…")
                var updated = results
                try await Task.detached(priority: .utility) {
                    try token.check()
                    try LeftoverScanner.validateForTrash(candidate, results: results, inventory: fresh)
                    try FileManager.default.trashItem(at: URL(fileURLWithPath: candidate.path), resultingItemURL: nil)
                }.value
                if let index = updated.candidates.firstIndex(where: { $0.path == candidate.path }) { updated.candidates[index].movedAt = Date() }
                self.results = updated
                let final = updated
                do { try await Task.detached(priority: .utility) { try store.save(final) }.value; message = "Moved to Trash" }
                catch { message = "Moved to Trash; results couldn’t be saved." }
            } catch is CancellationError { message = "Cancelled · nothing moved" }
            catch { message = (error as? LeftoverFailure)?.errorDescription ?? "Couldn’t move this folder. Review it in Finder." }
        }
    }
}

struct AppLeftoversView: View {
    let startImmediately: Bool
    let caches: [FolderCache]
    @StateObject private var model = AppLeftoversModel()
    @Environment(\.dismiss) private var dismiss
    @State private var showKept = false
    @State private var pendingTrash: LeftoverCandidate?
    @State private var confirmTrash = false
    private var visible: [LeftoverCandidate] {
        (model.results?.candidates ?? []).filter { $0.movedAt == nil && (showKept || model.results?.kept.contains($0.path) != true) }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("App leftovers").font(.title2.bold())
                Spacer()
                Button(model.results == nil ? "Find App Leftovers" : "Find Again") { model.find(caches: caches) }.disabled(model.busy)
            }
            if model.busy {
                HStack {
                    if model.progress.total > 0 {
                        ProgressView(value: Double(model.progress.completed), total: Double(model.progress.total)).frame(width: 150)
                    } else { ProgressView().controlSize(.small) }
                    Text(model.progress.message).font(.caption).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Cancel") { model.cancel() }.disabled(!model.cancellable)
                }
            }
            if let results = model.results {
                HStack {
                    Text("\(visible.count) possible leftovers · \(CapacityFormat.string(visible.reduce(0) { $0 + $1.bytes })) measured").font(.headline)
                    Spacer()
                    if !results.kept.isEmpty { Toggle("Show kept", isOn: $showKept).toggleStyle(.checkbox).font(.caption) }
                }
                Text("Checked " + results.checkedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(visible) { candidate in
                        VStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(candidate.name).font(.headline).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text((candidate.partial ? "At least " : "") + CapacityFormat.string(candidate.bytes)).monospacedDigit()
                                    .help("Measured " + candidate.measuredAt.formatted(date: .abbreviated, time: .shortened))
                            }
                            Text(candidate.reason).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: candidate.path)]) }
                                let kept = model.results?.kept.contains(candidate.path) == true
                                Button(kept ? "Review Again" : "Keep") { model.keep(candidate, keep: !kept) }.disabled(model.busy)
                                Spacer()
                                if candidate.canTrash && model.results?.inventoryLimited == false && !kept {
                                    Button("Move to Trash…") { pendingTrash = candidate; confirmTrash = true }.disabled(model.busy)
                                }
                            }.controlSize(.small)
                        }.padding(12).background(.quaternary.opacity(0.35)).cornerRadius(8)
                    }
                    if visible.isEmpty && !model.busy {
                        Text(model.results == nil ? "Run a check to find possible leftovers." : "No matching leftovers to review.")
                            .foregroundStyle(.secondary).padding(.top, 30)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.results?.inventoryLimited == true || model.results?.measurementLimited == true {
                Text("Some locations weren’t fully checked. Finder review is available.").font(.caption).foregroundStyle(.secondary)
            }
            if let message = model.message { Text(message).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Application Support · checked only on request").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.cancel(); dismiss() }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 740, height: 570)
        .task { await model.load(); if startImmediately && !Task.isCancelled { model.find(caches: caches) } }
        .onDisappear { model.cancel() }
        .alert("Move \(pendingTrash?.name ?? "folder") to Trash?", isPresented: $confirmTrash) {
            Button("Cancel", role: .cancel) { pendingTrash = nil }
            Button("Move to Trash", role: .destructive) { if let candidate = pendingTrash { model.moveToTrash(candidate) }; pendingTrash = nil }
        } message: {
            Text("This can include documents, models, saved games and settings. DiskFree will check again that the app is absent. You can restore the folder from Trash.\n\n" + (pendingTrash?.path ?? ""))
        }
    }
}
