import Foundation
import Combine

struct SpotlightClue: Identifiable {
    let path: String
    let bytes: Int64
    let modified: Date?
    var id: String { path }
}

/// On-demand, bounded Spotlight search; no permanent live query and no recursive scan.
@MainActor
final class SpotlightClues: ObservableObject {
    @Published private(set) var files: [SpotlightClue] = []
    @Published private(set) var searching = false
    @Published private(set) var message = "Spotlight can find large recently changed files. These are clues, not measured growth."
    private var query: NSMetadataQuery?
    private var observer: NSObjectProtocol?
    private var timeout: Timer?
    func search(folders: [GrowthFolder]) {
        stop()
        files = []
        let query = NSMetadataQuery()
        query.searchScopes = folders.map(\.path)
        query.predicate = NSPredicate(format: "kMDItemFSSize >= %lld AND kMDItemFSContentChangeDate >= %@", Int64(500_000_000), Date().addingTimeInterval(-7 * 86_400) as NSDate)
        query.sortDescriptors = [NSSortDescriptor(key: "kMDItemFSSize", ascending: false)]
        self.query = query
        searching = true
        message = "Searching the existing Spotlight index…"
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.finish() }
        }
        timeout = Timer.scheduledTimer(withTimeInterval: 15, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.stop()
                self?.message = "Spotlight search timed out. Folder-growth tracking is independent of indexing."
            }
        }
        if !query.start() { stop(); message = "Spotlight search could not start." }
    }
    private func finish() {
        guard let query else { return }
        query.disableUpdates()
        files = (0..<min(query.resultCount, 50)).compactMap { index in
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: "kMDItemPath") as? String,
                  let size = item.value(forAttribute: "kMDItemFSSize") as? NSNumber else { return nil }
            return SpotlightClue(path: path, bytes: size.int64Value, modified: item.value(forAttribute: "kMDItemFSContentChangeDate") as? Date)
        }
        message = "\(files.count) results shown (up to 50). Indexed logical sizes; excluded folders and system data may be missing. Modification time does not prove growth."
        stop()
    }
    func stop() {
        query?.stop(); query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        timeout?.invalidate(); timeout = nil
        searching = false
    }
    deinit {
        query?.stop()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        timeout?.invalidate()
    }
}
