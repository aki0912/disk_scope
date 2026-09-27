import AppKit
import SwiftUI
import CScanner
import DiskScopeCore

struct ScanProgress: Decodable {
    let status: String
    let files: UInt64
    let directories: UInt64
    let allocated: UInt64
    let error: String?
}

enum ScannerBridge {
    static func read<T: Decodable>(_ pointer: UnsafeMutablePointer<CChar>?, as type: T.Type) throws -> T {
        guard let pointer else { throw CocoaError(.fileReadUnknown) }
        defer { ds_string_free(pointer) }
        return try JSONDecoder().decode(type, from: Data(bytes: pointer, count: strlen(pointer)))
    }

    static func waitForCompletion(_ id: UInt64) async throws -> ScanProgress {
        // A blocking C wait belongs on a dispatch worker, not Swift's cooperative executor.
        // Model cancellation destroys the job and wakes this worker immediately.
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    var status: Int32 = 0
                    repeat { status = ds_scan_wait(id, 250) } while status == 0
                    if status == 2 { throw CancellationError() }
                    guard status != -1 else { throw CocoaError(.fileReadUnknown) }
                    continuation.resume(returning: try read(ds_scan_poll(id), as: ScanProgress.self))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func result(_ id: UInt64) throws -> ScanSnapshot {
        defer { ds_scan_destroy(id) }
        guard let pointer = ds_scan_take_result(id) else { throw CocoaError(.fileReadUnknown) }
        // Data owns the Rust allocation, including when decoding throws.
        let data = Data(bytesNoCopy: pointer, count: strlen(pointer), deallocator: .custom { buffer, _ in
            ds_string_free(buffer.assumingMemoryBound(to: CChar.self))
        })
        return try ScanSnapshot(data: data)
    }
}

@MainActor
final class ScannerModel: ObservableObject {
    @Published var snapshot: ScanSnapshot?
    @Published var scanning = false
    @Published var preparing = false
    @Published var progress: ScanProgress?
    @Published var rootURL: URL?
    @Published var error: String?
    @Published var notice: String?
    @Published var currentID = 0
    @Published var selectedID: Int?
    @Published var metric: SizeMetric = .allocated { didSet { refreshChildren() } }
    @Published var search = "" { didSet { refreshFilter() } }
    @Published var currentSelection = ChildSelection.empty
    @Published var filteredSelection = ChildSelection.empty
    @Published private(set) var searching = false
    @Published var volumeTotal: UInt64 = 0
    @Published var volumeAvailable: UInt64 = 0
    @Published var recentRoots: [String] = UserDefaults.standard.stringArray(forKey: "recentRoots") ?? []
    private var scanID: UInt64 = 0
    private var generation = UUID()
    private var scanTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?
    private var searchGeneration = UUID()

    deinit { searchTask?.cancel() }

    var current: ScanNode? { snapshot.map { $0.nodes[currentID] } }
    var selected: ScanNode? { guard let id = selectedID else { return nil }; return snapshot?.nodes[id] }
    var filteredChildren: [Int] { filteredSelection.ids }

    func chooseFolder() {
        chooseFolder(at: rootURL)
    }

    func chooseFolder(at suggestedURL: URL?) {
        let panel = NSOpenPanel()
        panel.title = "解析するフォルダまたはSSDを選択"
        panel.prompt = "解析する"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.directoryURL = suggestedURL ?? FileManager.default.homeDirectoryForCurrentUser
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in self?.start(url) }
        }
    }

    func start(_ url: URL) {
        cancel(showNotice: false)
        rootURL = url
        snapshot = nil; selectedID = nil; currentSelection = .empty; filteredSelection = .empty; currentID = 0
        error = nil; notice = nil; progress = nil; search = ""
        volumeTotal = 0; volumeAvailable = 0
        if let volume = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]) {
            volumeTotal = UInt64(max(0, volume.volumeTotalCapacity ?? 0))
            volumeAvailable = UInt64(max(0, volume.volumeAvailableCapacity ?? 0))
        }
        let id = url.path.withCString { ds_scan_start($0) }
        guard id != 0 else { error = "このフォルダの解析を開始できませんでした。"; return }
        scanID = id; scanning = true
        let token = UUID(); generation = token
        scanTask = Task { [weak self] in
            let progressTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(120)) }
                    catch { return }
                    guard let self, self.generation == token, self.scanID == id else { return }
                    if let state = try? ScannerBridge.read(ds_scan_poll(id), as: ScanProgress.self) {
                        self.progress = state
                    }
                }
            }
            defer { progressTask.cancel() }
            do {
                let state = try await ScannerBridge.waitForCompletion(id)
                guard let self, self.generation == token, !Task.isCancelled else { return }
                progressTask.cancel()
                self.progress = state
                switch state.status {
                case "complete":
                    self.preparing = true
                    self.scanID = 0
                    var selectionMetric = self.metric
                    let initialMetric = selectionMetric
                    let prepared = try await Task.detached(priority: .userInitiated) {
                        let snapshot = try ScannerBridge.result(id)
                        let selection = snapshot.largestChildren(of: 0, metric: initialMetric, limit: 300)
                        return (snapshot: snapshot, selection: selection)
                    }.value
                    guard self.generation == token, !Task.isCancelled else { return }
                    var selection = prepared.selection
                    // Keep the selection consistent even if the metric changes during preparation.
                    while self.metric != selectionMetric {
                        selectionMetric = self.metric
                        let updatedMetric = selectionMetric
                        selection = await Task.detached(priority: .userInitiated) {
                            prepared.snapshot.largestChildren(of: 0, metric: updatedMetric, limit: 300)
                        }.value
                        guard self.generation == token, !Task.isCancelled else { return }
                    }
                    self.snapshot = prepared.snapshot
                    self.currentSelection = selection
                    self.refreshFilter()
                    self.scanning = false; self.preparing = false
                    self.recentRoots.removeAll { $0 == url.path }
                    self.recentRoots.insert(url.path, at: 0)
                    self.recentRoots = Array(self.recentRoots.prefix(5))
                    UserDefaults.standard.set(self.recentRoots, forKey: "recentRoots")
                case "failed":
                    self.error = state.error ?? "解析できませんでした。"
                    self.finish(id)
                default: self.finish(id)
                }
            } catch is CancellationError {
                guard let self, self.generation == token else { return }
                self.finish(id)
            } catch {
                guard let self, self.generation == token else { return }
                self.error = "解析結果を読み込めませんでした: \(error.localizedDescription)"
                self.finish(id)
            }
        }
    }

    private func finish(_ id: UInt64) {
        ds_scan_destroy(id); scanID = 0; scanning = false; preparing = false
    }

    func cancel(showNotice: Bool = true) {
        generation = UUID()
        invalidateSearch()
        scanTask?.cancel(); scanTask = nil
        if scanID != 0 { ds_scan_cancel(scanID); ds_scan_destroy(scanID); scanID = 0 }
        if scanning && showNotice { notice = "解析をキャンセルしました。" }
        scanning = false; preparing = false
    }

    func refreshChildren() {
        currentSelection = snapshot?.largestChildren(of: currentID, metric: metric, limit: 300) ?? .empty
        refreshFilter()
    }

    private func invalidateSearch() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration = UUID()
        searching = false
    }

    private func refreshFilter() {
        invalidateSearch()
        guard !search.isEmpty else { filteredSelection = currentSelection; return }
        filteredSelection = .empty
        guard let snapshot else { return }
        searching = true
        let token = searchGeneration
        let query = search, id = currentID, selectedMetric = metric
        searchTask = Task.detached(priority: .userInitiated) { [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                let selection = try snapshot.largestChildren(of: id, metric: selectedMetric, limit: 300,
                                                             matching: query, checkCancellation: { try Task.checkCancellation() })
                try Task.checkCancellation()
                await self?.publishSearch(selection, token: token)
            } catch is CancellationError {
                // A newer query, navigation, or scan owns the visible selection now.
            } catch {
                assertionFailure("Unexpected search error: \(error)")
            }
        }
    }

    private func publishSearch(_ selection: ChildSelection, token: UUID) {
        guard searchGeneration == token else { return }
        filteredSelection = selection
        searching = false
        searchTask = nil
    }

    func navigate(_ id: Int) {
        guard let snapshot, snapshot.nodes[id].isDirectory else { return }
        currentID = id; selectedID = nil; search = ""; refreshChildren()
    }

    func up() { if let parent = current?.parent { navigate(parent) } }

    func reveal(_ id: Int) {
        guard let snapshot else { return }
        NSWorkspace.shared.activateFileViewerSelecting([snapshot.url(for: id)])
    }

    func relativePath(_ id: Int) -> String {
        guard let snapshot else { return "" }
        return snapshot.ancestors(of: id).map { snapshot.nodes[$0].name }.joined(separator: " / ")
    }
}
