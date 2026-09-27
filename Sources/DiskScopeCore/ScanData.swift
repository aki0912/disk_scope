import Foundation

public enum SizeMetric: String, CaseIterable, Sendable {
    case allocated = "ディスク上の使用量"
    case logical = "ファイルサイズ"
}

public struct ScanNode: Codable, Identifiable, Sendable {
    public let id: Int
    public let name: String
    public let parent: Int?
    public let kind: String
    public let logical: UInt64
    public let allocated: UInt64
    public let modified: Int64
    public let duplicate: Bool
    public let excluded: Bool
    public let unreadable: Bool
    public var isDirectory: Bool { kind == "directory" }
    public func bytes(_ metric: SizeMetric) -> UInt64 { metric == .allocated ? allocated : logical }
    public var category: FileCategory {
        if isDirectory { return .folder }
        if kind == "symlink" { return .link }
        switch (name as NSString).pathExtension.lowercased() {
        case "mp4", "mov", "mkv", "avi", "m4v", "webm": return .video
        case "png", "jpg", "jpeg", "heic", "gif", "raw", "tiff", "webp", "svg", "psd": return .image
        case "mp3", "wav", "aac", "flac", "m4a", "aiff": return .audio
        case "zip", "dmg", "gz", "tar", "7z", "rar", "pkg", "iso": return .archive
        case "swift", "rs", "js", "ts", "tsx", "py", "c", "h", "cpp", "json", "html", "css", "go", "java": return .code
        case "pdf", "doc", "docx", "txt", "md", "xlsx", "csv", "pptx", "pages", "numbers": return .document
        default: return .other
        }
    }
}

public enum FileCategory: String, CaseIterable, Sendable {
    case folder = "フォルダ", video = "動画", image = "画像", audio = "音声"
    case archive = "アーカイブ", code = "コード", document = "書類", link = "リンク", other = "その他"
    public var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .video: return "film"
        case .image: return "photo"
        case .audio: return "waveform"
        case .archive: return "archivebox"
        case .code: return "curlybraces"
        case .document: return "doc.text"
        case .link: return "link"
        case .other: return "doc"
        }
    }
}

public struct ScanIssue: Codable, Sendable {
    public let path: String
    public let message: String
}

public struct ScanPayload: Codable, Sendable {
    public let rootPath: String
    public let elapsed: Double
    public let fileCount: UInt64
    public let directoryCount: UInt64
    public let issueCount: Int
    public let excludedCount: Int
    public let duplicateCount: Int
    public let nodes: [ScanNode]
    public let issues: [ScanIssue]
}

public struct ScanSnapshot: Sendable {
    public let payload: ScanPayload
    public let children: [[Int]]
    public let descendantFiles: [Int]
    public var nodes: [ScanNode] { payload.nodes }

    public init(data: Data) throws {
        let payload = try JSONDecoder().decode(ScanPayload.self, from: data)
        guard !payload.nodes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        var children = [[Int]](repeating: [], count: payload.nodes.count)
        var counts = [Int](repeating: 0, count: payload.nodes.count)
        for (index, node) in payload.nodes.enumerated() {
            guard node.id == index else { throw CocoaError(.fileReadCorruptFile) }
            if let parent = node.parent {
                guard parent >= 0 && parent < index else { throw CocoaError(.fileReadCorruptFile) }
                children[parent].append(index)
            } else if index != 0 { throw CocoaError(.fileReadCorruptFile) }
            counts[index] = node.isDirectory ? 0 : 1
        }
        for index in payload.nodes.indices.reversed() {
            if let parent = payload.nodes[index].parent { counts[parent] += counts[index] }
        }
        self.payload = payload
        self.children = children
        self.descendantFiles = counts
    }

    public func ancestors(of id: Int) -> [Int] {
        var ids = [id]
        var next = nodes[id].parent
        while let parent = next { ids.append(parent); next = nodes[parent].parent }
        return ids.reversed()
    }

    public func url(for id: Int) -> URL {
        var url = URL(fileURLWithPath: payload.rootPath, isDirectory: true)
        for index in ancestors(of: id).dropFirst() { url.appendPathComponent(nodes[index].name) }
        return url
    }

    /// Select only the visible leaders. The heap root is the worst retained item.
    /// Unshown items still contribute to counts and bytes for the treemap remainder.
    public func largestChildren(of id: Int, metric: SizeMetric, limit: Int, matching query: String = "") -> ChildSelection {
        let capacity = max(0, limit)
        var heap: [Int] = []
        heap.reserveCapacity(min(capacity, children[id].count))
        var count = 0, nonzeroCount = 0
        var bytes: UInt64 = 0
        func precedes(_ left: Int, _ right: Int) -> Bool {
            let a = nodes[left], b = nodes[right]
            if a.bytes(metric) != b.bytes(metric) { return a.bytes(metric) > b.bytes(metric) }
            let order = a.name.localizedStandardCompare(b.name)
            return order == .orderedSame ? left < right : order == .orderedAscending
        }
        for child in children[id] {
            let node = nodes[child]
            if !query.isEmpty && !node.name.localizedCaseInsensitiveContains(query) { continue }
            count += 1
            bytes &+= node.bytes(metric)
            if node.bytes(metric) > 0 { nonzeroCount += 1 }
            guard capacity > 0 else { continue }
            if heap.count < capacity {
                heap.append(child)
                var index = heap.count - 1
                while index > 0 {
                    let parent = (index - 1) / 2
                    if !precedes(heap[parent], heap[index]) { break }
                    heap.swapAt(parent, index)
                    index = parent
                }
            } else if precedes(child, heap[0]) {
                heap[0] = child
                var index = 0
                while index * 2 + 1 < heap.count {
                    var worst = index * 2 + 1
                    if worst + 1 < heap.count && precedes(heap[worst], heap[worst + 1]) { worst += 1 }
                    if !precedes(heap[index], heap[worst]) { break }
                    heap.swapAt(index, worst)
                    index = worst
                }
            }
        }
        return ChildSelection(ids: heap.sorted(by: precedes), count: count, nonzeroCount: nonzeroCount, bytes: bytes)
    }

}

public struct ChildSelection: Sendable {
    public let ids: [Int]
    public let count: Int
    public let nonzeroCount: Int
    public let bytes: UInt64
    public static let empty = ChildSelection(ids: [], count: 0, nonzeroCount: 0, bytes: 0)
}

public enum ByteText {
    public static func format(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB", "PB", "EB"]
        var value = Double(bytes)
        var index = 0
        while value >= 1_000 && index < units.count - 1 { value /= 1_000; index += 1 }
        if index == 0 { return "\(bytes) B" }
        return String(format: value >= 100 ? "%.0f %@" : "%.1f %@", value, units[index])
    }

    public static func percent(_ bytes: UInt64, of total: UInt64) -> String {
        guard total > 0 else { return "0%" }
        let value = Double(bytes) / Double(total) * 100
        return value > 0 && value < 0.1 ? "<0.1%" : String(format: "%.1f%%", value)
    }
}
