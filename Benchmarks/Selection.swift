import Foundation

/// Compile together with ScanData.swift using swiftc -O.
@main struct SelectionBenchmark {
    static func main() throws {
        let data: Data
        if CommandLine.arguments.count > 1 {
            data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        } else {
            let count = 50_000
            var nodes = ["{\"id\":0,\"name\":\"fixture\",\"parent\":null,\"kind\":\"directory\",\"logical\":\(count * 1000),\"allocated\":\(count * 4096),\"modified\":0,\"duplicate\":false,\"excluded\":false,\"unreadable\":false}"]
            for id in 1...count {
                nodes.append("{\"id\":\(id),\"name\":\"file-\((id * 7919) % count).txt\",\"parent\":0,\"kind\":\"file\",\"logical\":1000,\"allocated\":4096,\"modified\":0,\"duplicate\":false,\"excluded\":false,\"unreadable\":false}")
            }
            data = Data("{\"rootPath\":\"/fixture\",\"elapsed\":0,\"fileCount\":\(count),\"directoryCount\":1,\"issueCount\":0,\"excludedCount\":0,\"duplicateCount\":0,\"issues\":[],\"nodes\":[\(nodes.joined(separator: ","))]}".utf8)
        }
        let snapshot = try ScanSnapshot(data: data)
        var full = [Double](), visible = [Double]()
        var checksum = 0
        for iteration in 0..<9 {
            var reference: [Int] = [], selected: [Int] = []
            for mode in iteration.isMultiple(of: 2) ? [0, 1] : [1, 0] {
                let start = ProcessInfo.processInfo.systemUptime
                if mode == 0 {
                    // Original full-sort implementation; only its first 300 rows were displayed.
                    reference = Array(snapshot.children[0].sorted {
                        let a = snapshot.nodes[$0], b = snapshot.nodes[$1]
                        if a.allocated != b.allocated { return a.allocated > b.allocated }
                        return a.name.localizedStandardCompare(b.name) == .orderedAscending
                    }.prefix(300))
                } else {
                    selected = snapshot.largestChildren(of: 0, metric: .allocated, limit: 300).ids
                }
                let milliseconds = (ProcessInfo.processInfo.systemUptime - start) * 1000
                if iteration > 0 {
                    if mode == 0 { full.append(milliseconds) } else { visible.append(milliseconds) }
                }
            }
            precondition(reference == selected, "Visible rows changed")
            checksum += selected.reduce(0, +)
        }
        func median(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        }
        print("files=\(snapshot.children[0].count) full_sort_ms=\(median(full)) visible_selection_ms=\(median(visible)) checksum=\(checksum)")
    }
}
