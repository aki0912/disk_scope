import Foundation
import Darwin

// Compiled with a temporary accounting property by benchmark_storage.py.
@main struct StorageBenchmark {
    static func rss() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        precondition(status == KERN_SUCCESS)
        return info.resident_size
    }
    static func read(_ url: URL) throws -> ScanSnapshot {
        // Mapping avoids retaining an additional input-file allocation after decode.
        return try ScanSnapshot(data: Data(contentsOf: url, options: .alwaysMapped))
    }
    static func main() throws {
        let rssBefore = rss()
        let start = ProcessInfo.processInfo.systemUptime
        let snapshot = try read(URL(fileURLWithPath: CommandLine.arguments[1]))
        let decodeMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
        let rssAfter = rss()
        var output: [String: Any] = [
            "decode_ms": decodeMS, "rss_before": rssBefore, "rss_after_decode": rssAfter,
            "node_stride": MemoryLayout<ScanNode>.stride, "nodes": snapshot.nodes.count,
            "backing_storage_bytes": snapshot.benchmarkStorageBytes,
        ]
        var operations: [String: Double] = [:]
        var checksums: [String: UInt64] = [:]
        func measure(_ name: String, action: () -> UInt64) {
            var times: [Double] = []
            var result: UInt64 = 0
            for iteration in 0..<5 {
                let started = ProcessInfo.processInfo.systemUptime
                let checksum = action()
                if iteration > 0 { times.append((ProcessInfo.processInfo.systemUptime - started) * 1000) }
                result &+= checksum
            }
            let sorted = times.sorted()
            operations[name] = (sorted[1] + sorted[2]) / 2
            checksums[name] = result
        }
        func digest(_ selection: ChildSelection) -> UInt64 {
            selection.ids.reduce(selection.bytes &+ UInt64(selection.count) &+ UInt64(selection.nonzeroCount)) { ($0 &* 31) &+ UInt64($1) }
        }
        for query in ["", "file", "9999", "no-match"] {
            measure("root_selection_" + query) {
                digest(snapshot.largestChildren(of: 0, metric: .allocated, limit: 300, matching: query))
            }
        }
        let folders = Array(snapshot.nodes.indices.filter { snapshot.nodes[$0].isDirectory }.prefix(1000))
        measure("folder_navigation_1000") {
            folders.reduce(UInt64(0)) { result, id in
                result &+ digest(snapshot.largestChildren(of: id, metric: .logical, limit: 300))
            }
        }
        var hierarchyDigest: UInt64 = 0
        for id in snapshot.nodes.indices {
            hierarchyDigest = hierarchyDigest &* 31 &+ UInt64(snapshot.descendantFiles[id])
            for child in snapshot.children[id] { hierarchyDigest = hierarchyDigest &* 31 &+ UInt64(child) }
        }
        output["hierarchy_digest"] = hierarchyDigest
        output["operations_ms"] = operations
        output["checksums"] = checksums
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        output["peak_rss_bytes"] = usage.ru_maxrss
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]), as: UTF8.self))
    }
}
