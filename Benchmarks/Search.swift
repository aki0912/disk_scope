import AppKit

@main struct SearchBenchmark {
    @MainActor static func main() async throws {
        let count = Int(CommandLine.arguments[1])!
        var records = ["{\"id\":0,\"name\":\"fixture\",\"parent\":null,\"kind\":\"directory\",\"logical\":0,\"allocated\":0,\"modified\":0,\"duplicate\":false,\"excluded\":false,\"unreadable\":false}"]
        for id in 1...count {
            let name = String(format: "file-%06d.txt", id)
            records.append("{\"id\":\(id),\"name\":\"\(name)\",\"parent\":0,\"kind\":\"file\",\"logical\":1,\"allocated\":4096,\"modified\":0,\"duplicate\":false,\"excluded\":false,\"unreadable\":false}")
        }
        let data = Data("{\"rootPath\":\"/fixture\",\"elapsed\":0,\"fileCount\":\(count),\"directoryCount\":1,\"issueCount\":0,\"excludedCount\":0,\"duplicateCount\":0,\"issues\":[],\"nodes\":[\(records.joined(separator: ","))]}".utf8)
        let snapshot = try ScanSnapshot(data: data)
        let model = ScannerModel()
        model.snapshot = snapshot
        model.refreshChildren()
        var results = [[String: Any]]()
        for query in ["file-0", "9999", "no-match"] {
            let expected = snapshot.largestChildren(of: 0, metric: .allocated, limit: 300, matching: query)
            let start = ProcessInfo.processInfo.systemUptime
            model.search = query
            let setter = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let deadline = ContinuousClock.now + .seconds(5)
            while model.searching {
                precondition(ContinuousClock.now < deadline)
                try await Task.sleep(for: .milliseconds(1))
            }
            let completion = (ProcessInfo.processInfo.systemUptime - start) * 1000
            let actual = model.filteredSelection
            precondition(actual.ids == expected.ids && actual.count == expected.count && actual.bytes == expected.bytes && actual.nonzeroCount == expected.nonzeroCount)
            results.append(["query": query, "input_main_thread_ms": setter, "results_ready_ms": completion, "matches": actual.count])
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: results, options: [.sortedKeys]), as: UTF8.self))
    }
}
