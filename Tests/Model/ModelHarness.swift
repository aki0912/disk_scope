import AppKit
import CScanner

// Test runner inserts these probes into temporary source copies only.
enum OwnershipProbe {
    static var acquired = 0, released = 0
    static var corrupt = false
    static func take(_ pointer: UnsafeMutablePointer<CChar>) {
        acquired += 1
        if corrupt { pointer.pointee = 33 }
    }
    static func free(_ pointer: UnsafeMutablePointer<CChar>) {
        released += 1
        ds_string_free(pointer)
    }
}

final class SearchProbe: @unchecked Sendable {
    static let shared = SearchProbe()
    private let condition = NSCondition()
    private var gate = false, entered = false
    private var cancelledCount = 0
    var cancellations: Int { condition.lock(); defer { condition.unlock() }; return cancelledCount }
    func arm() { condition.lock(); gate = true; entered = false; condition.unlock() }
    func hasEntered() -> Bool { condition.lock(); defer { condition.unlock() }; return entered }
    func release() { condition.lock(); gate = false; condition.broadcast(); condition.unlock() }
    func check() throws {
        precondition(!Thread.isMainThread, "Search ran on the UI thread")
        condition.lock()
        if gate { entered = true; condition.broadcast() }
        while gate { condition.wait() }
        condition.unlock()
        do { try Task.checkCancellation() }
        catch {
            condition.lock(); cancelledCount += 1; condition.unlock()
            throw error
        }
    }
}

@main struct ModelHarness {
    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw CocoaError(.userCancelled) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    @MainActor static func equal(_ a: ChildSelection, _ b: ChildSelection) {
        precondition(a.ids == b.ids && a.count == b.count && a.nonzeroCount == b.nonzeroCount && a.bytes == b.bytes)
    }
    static func fixture() throws -> ScanSnapshot {
        var nodes = [ScanNode(id: 0, name: "root", parent: nil, kind: "directory", logical: 0, allocated: 0, modified: 0, duplicate: false, excluded: false, unreadable: false)]
        nodes.append(ScanNode(id: 1, name: "nested", parent: 0, kind: "directory", logical: 0, allocated: 0, modified: 0, duplicate: false, excluded: false, unreadable: false))
        for id in 2...50_001 {
            nodes.append(ScanNode(id: id, name: "日本語-file-\(id).txt", parent: id == 2 ? 1 : 0, kind: "file", logical: UInt64(id % 17), allocated: UInt64(id % 13) * 4096, modified: 0, duplicate: false, excluded: false, unreadable: false))
        }
        let payload = ScanPayload(rootPath: "/fixture", elapsed: 0, fileCount: 50_000, directoryCount: 2, issueCount: 0, excludedCount: 0, duplicateCount: 0, nodes: nodes, issues: [])
        return try ScanSnapshot(data: JSONEncoder().encode(payload))
    }
    @MainActor static func main() async throws {
        let snapshot = try fixture()
        let model = ScannerModel()
        model.snapshot = snapshot
        model.refreshChildren()
        for query in ["FILE-1", "日本語", "no-match"] {
            model.search = query
            precondition(model.searching && model.filteredChildren.isEmpty)
            try await wait { !model.searching }
            equal(model.filteredSelection, snapshot.largestChildren(of: 0, metric: .allocated, limit: 300, matching: query))
        }
        print("PASS: asynchronous search matches synchronous reference, including Unicode and no matches")
        SearchProbe.shared.arm()
        model.search = "file"
        try await wait { SearchProbe.shared.hasEntered() }
        // The old worker is paused in flight, so replacement and stale-result guards are deterministic.
        model.search = "no-match"
        SearchProbe.shared.release()
        try await wait { !model.searching && SearchProbe.shared.cancellations > 0 }
        precondition(model.filteredChildren.isEmpty)
        print("PASS: in-flight search cancels and cannot overwrite newer results")
        for query in ["f", "fi", "file", "file-7"] { model.search = query }
        model.metric = .logical
        try await wait { !model.searching }
        equal(model.filteredSelection, snapshot.largestChildren(of: 0, metric: .logical, limit: 300, matching: "file-7"))
        model.search = "file"
        model.search = ""
        precondition(!model.searching)
        equal(model.filteredSelection, model.currentSelection)
        model.search = "file"
        model.navigate(1)
        try await Task.sleep(for: .milliseconds(250))
        precondition(!model.searching && model.search.isEmpty && model.filteredChildren == [2])
        print("PASS: rapid edits, metric change, clear and navigation preserve current selection")
        model.up()
        model.search = "file"
        let path = CommandLine.arguments[1]
        model.start(URL(fileURLWithPath: path))
        try await wait { !model.scanning }
        try await Task.sleep(for: .milliseconds(250))
        precondition(model.snapshot?.payload.fileCount == 1 && !model.searching && model.search.isEmpty)
        equal(model.filteredSelection, model.currentSelection)
        model.search = "file"
        model.cancel(showNotice: false)
        try await Task.sleep(for: .milliseconds(250))
        precondition(!model.searching)
        print("PASS: replacement scan and cancellation invalidate pending searches")
        weak var releasedModel: ScannerModel?
        do {
            let temporary = ScannerModel()
            releasedModel = temporary
            temporary.snapshot = snapshot
            temporary.search = "file"
        }
        precondition(releasedModel == nil, "Pending search retains model")
        print("PASS: pending search does not retain its model")
        // Real Rust-owned C strings, with both successful and failed Swift decoding.
        for corrupt in [false, true] {
            let id = path.withCString { ds_scan_start($0) }
            _ = try await ScannerBridge.waitForCompletion(id)
            let acquired = OwnershipProbe.acquired, released = OwnershipProbe.released
            OwnershipProbe.corrupt = corrupt
            do {
                let result = try ScannerBridge.result(id)
                precondition(!corrupt && result.nodes.contains { $0.name == "日本語.txt" })
            } catch { precondition(corrupt) }
            OwnershipProbe.corrupt = false
            precondition(OwnershipProbe.acquired == acquired + 1 && OwnershipProbe.released == released + 1)
            precondition(ds_scan_take_result(id) == nil && ds_scan_wait(id, 0) == -1)
        }
        print("PASS: Rust JSON buffers freed once and jobs destroyed on success and decode failure")
    }
}
