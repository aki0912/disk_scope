import XCTest
import CoreGraphics
@testable import DiskScopeCore

final class CoreTests: XCTestCase {
    func testTreemapPreservesAreaAndDoesNotOverlap() {
        for size in [CGSize(width: 1000, height: 650), CGSize(width: 80, height: 900), CGSize(width: 1, height: 1)] {
            let bounds = CGRect(origin: CGPoint(x: 10, y: 20), size: size)
            let items = (0..<200).map { WeightedItem(id: $0, weight: Double(($0 * 71) % 103 + 1)) }
            let result = Treemap.layout(items, in: bounds)
            let total = items.reduce(0) { $0 + $1.weight }
            XCTAssertEqual(result.count, items.count)
            for tile in result {
                XCTAssertEqual(tile.rect.width * tile.rect.height, size.width * size.height * items[tile.id].weight / total, accuracy: 0.00001)
                XCTAssertTrue(bounds.insetBy(dx: -0.00001, dy: -0.00001).contains(tile.rect))
            }
            for i in result.indices {
                for j in result.indices where j > i {
                    let intersection = result[i].rect.intersection(result[j].rect)
                    XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.00001)
                }
            }
        }
    }

    func testTreemapEmptyZeroAndExtremeSizes() {
        let bounds = CGRect(x: 0, y: 0, width: 700, height: 400)
        XCTAssertTrue(Treemap.layout([], in: bounds).isEmpty)
        XCTAssertTrue(Treemap.layout([WeightedItem(id: 0, weight: 0)], in: bounds).isEmpty)
        XCTAssertTrue(Treemap.layout([WeightedItem(id: 0, weight: 2)], in: .zero).isEmpty)
        let tiles = Treemap.layout([WeightedItem(id: 0, weight: 1e15), WeightedItem(id: 1, weight: 1)], in: bounds)
        XCTAssertEqual(tiles.count, 2)
        XCTAssertTrue(tiles.allSatisfy { $0.rect.width.isFinite && $0.rect.height.isFinite })
    }

    func testSnapshotHierarchyAndURLs() throws {
        let data = Data("""
        {"rootPath":"/fixture","elapsed":0.1,"fileCount":1,"directoryCount":2,"issueCount":0,"excludedCount":0,"duplicateCount":0,"issues":[],"nodes":[
        {"id":0,"name":"fixture","parent":null,"kind":"directory","logical":7,"allocated":4096,"modified":0,"duplicate":false,"excluded":false,"unreadable":false},
        {"id":1,"name":"nested","parent":0,"kind":"directory","logical":7,"allocated":4096,"modified":0,"duplicate":false,"excluded":false,"unreadable":false},
        {"id":2,"name":"日本語.txt","parent":1,"kind":"file","logical":7,"allocated":4096,"modified":0,"duplicate":false,"excluded":false,"unreadable":false}]}
        """.utf8)
        let snapshot = try ScanSnapshot(data: data)
        XCTAssertEqual(snapshot.children.map(Array.init), [[1], [2], []])
        XCTAssertEqual(snapshot.descendantFiles, [1, 1, 1])
        XCTAssertEqual(snapshot.ancestors(of: 2), [0, 1, 2])
        XCTAssertEqual(snapshot.url(for: 2).lastPathComponent, "日本語.txt")
        XCTAssertEqual(snapshot.nodes[2].category, .document)
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteText.format(0), "0 B")
        XCTAssertEqual(ByteText.format(1_500_000), "1.5 MB")
        XCTAssertEqual(ByteText.percent(1, of: 100_000), "<0.1%")
        XCTAssertEqual(ByteText.percent(0, of: 0), "0%")
    }
    func testVisibleSelectionMatchesFullSortIncludingHiddenSearchMatches() throws {
        let count = 2048
        var records: [[String: Any]] = [["id": 0, "name": "fixture", "parent": NSNull(), "kind": "directory", "logical": 0, "allocated": 0, "modified": 0, "duplicate": false, "excluded": false, "unreadable": false]]
        for id in 1...count {
            records.append(["id": id, "name": "file-\((id * 7919) % count).txt", "parent": 0, "kind": "file", "logical": (id % 13) * 100, "allocated": (id % 11) * 4096, "modified": 0, "duplicate": false, "excluded": false, "unreadable": false])
        }
        let payload: [String: Any] = ["rootPath": "/fixture", "elapsed": 0, "fileCount": count, "directoryCount": 1, "issueCount": 0, "excludedCount": 0, "duplicateCount": 0, "issues": [], "nodes": records]
        let snapshot = try ScanSnapshot(data: JSONSerialization.data(withJSONObject: payload))
        for query in ["file", "no-match"] {
            var checks = 0
            XCTAssertThrowsError(try snapshot.largestChildren(of: 0, metric: .allocated, limit: 300,
                                                              matching: query, checkCancellation: {
                checks += 1
                if checks == 2 { throw CancellationError() }
            })) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertEqual(checks, 2, "Cancellation must run even when nothing matches")
        }
        for metric in SizeMetric.allCases {
            for query in ["", "file-1", "FILE-20", "no-match"] {
                let matching = snapshot.children[0].filter { query.isEmpty || snapshot.nodes[$0].name.localizedCaseInsensitiveContains(query) }
                let reference = matching.sorted {
                    let a = snapshot.nodes[$0], b = snapshot.nodes[$1]
                    if a.bytes(metric) != b.bytes(metric) { return a.bytes(metric) > b.bytes(metric) }
                    let order = a.name.localizedStandardCompare(b.name)
                    return order == .orderedSame ? $0 < $1 : order == .orderedAscending
                }
                for limit in [-1, 0, 1, 45, 180, 300, 3000] {
                    let selected = snapshot.largestChildren(of: 0, metric: metric, limit: limit, matching: query)
                    XCTAssertEqual(selected.ids, Array(reference.prefix(max(0, limit))))
                    XCTAssertEqual(selected.count, matching.count)
                    XCTAssertEqual(selected.nonzeroCount, matching.filter { snapshot.nodes[$0].bytes(metric) > 0 }.count)
                    XCTAssertEqual(selected.bytes, matching.reduce(UInt64(0)) { $0 + snapshot.nodes[$1].bytes(metric) })
                    let shown = selected.ids.prefix(180).filter { snapshot.nodes[$0].bytes(metric) > 0 }
                    let shownBytes = shown.reduce(UInt64(0)) { $0 + snapshot.nodes[$1].bytes(metric) }
                    XCTAssertGreaterThanOrEqual(selected.bytes, shownBytes)
                    XCTAssertGreaterThanOrEqual(selected.nonzeroCount, shown.count)
                }
            }
        }
    }

    func testPackedKindsPreserveWireValuesAndFullWidthMetadata() throws {
        for (kind, wireName) in [(NodeKind.file, "file"), (.directory, "directory"), (.symlink, "symlink"), (.unknown, "unknown")] {
            let node = ScanNode(id: 123, name: "日本語-\"test\".txt", parent: 12, kind: kind,
                                logical: .max, allocated: .max, modified: .min,
                                duplicate: true, excluded: true, unreadable: true)
            let data = try JSONEncoder().encode(node)
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(json["kind"] as? String, wireName)
            let decoded = try JSONDecoder().decode(ScanNode.self, from: data)
            XCTAssertEqual(decoded.kind, kind)
            XCTAssertEqual(decoded.parent, 12)
            XCTAssertEqual(decoded.id, 123)
            XCTAssertEqual(decoded.name, node.name)
            XCTAssertEqual(decoded.logical, UInt64.max)
            XCTAssertEqual(decoded.allocated, UInt64.max)
            XCTAssertEqual(decoded.modified, Int64.min)
            XCTAssertTrue(decoded.duplicate && decoded.excluded && decoded.unreadable)
            if kind == .symlink { XCTAssertEqual(decoded.category, .link) }
        }
    }

    func testCompactSnapshotMatchesReferenceForMixedAndDeepTrees() throws {
        for (count, chain) in [(1, false), (2, false), (4096, false), (512, true)] {
            var parents = [Int?](repeating: nil, count: count)
            var expected = [[Int]](repeating: [], count: count)
            var random: UInt64 = 42
            for id in 1..<count {
                random = random &* 6364136223846793005 &+ 1
                let parent = chain ? id - 1 : Int(random % UInt64(id))
                parents[id] = parent
                expected[parent].append(id)
            }
            let nodes = (0..<count).map { id in
                ScanNode(id: id, name: "日本語-\(id)", parent: parents[id],
                         kind: id == 0 || !expected[id].isEmpty || id % 4 == 0 ? .directory : (id % 4 == 1 ? .file : (id % 4 == 2 ? .symlink : .unknown)),
                         logical: UInt64(id), allocated: UInt64(id) * 4096, modified: 0,
                         duplicate: id % 7 == 0, excluded: id % 11 == 0, unreadable: id % 13 == 0)
            }
            var counts = [Int](repeating: 0, count: count)
            for id in nodes.indices where !nodes[id].isDirectory {
                var next: Int? = id
                while let current = next { counts[current] += 1; next = parents[current] }
            }
            let payload = ScanPayload(rootPath: "/fixture", elapsed: 0, fileCount: UInt64(counts[0]),
                                      directoryCount: UInt64(nodes.filter(\.isDirectory).count), issueCount: 0,
                                      excludedCount: 0, duplicateCount: 0, nodes: nodes, issues: [])
            let snapshot = try ScanSnapshot(data: JSONEncoder().encode(payload))
            XCTAssertEqual(snapshot.children.map(Array.init), expected)
            XCTAssertEqual(snapshot.descendantFiles, counts)
            XCTAssertEqual(snapshot.children.count, count)
            if chain { XCTAssertEqual(snapshot.ancestors(of: count - 1), Array(0..<count)) }
        }
    }

    func testInvalidHierarchyIsRejectedBeforeIndexConstruction() throws {
        for (id, parent) in [(0, Optional(-1)), (0, Optional(0)), (1, nil)] {
            let node = ScanNode(id: id, name: "invalid", parent: parent, kind: .directory,
                                logical: 0, allocated: 0, modified: 0, duplicate: false, excluded: false, unreadable: false)
            let payload = ScanPayload(rootPath: "/fixture", elapsed: 0, fileCount: 0, directoryCount: 1,
                                      issueCount: 0, excludedCount: 0, duplicateCount: 0, nodes: [node], issues: [])
            XCTAssertThrowsError(try ScanSnapshot(data: JSONEncoder().encode(payload)))
        }
    }

}
