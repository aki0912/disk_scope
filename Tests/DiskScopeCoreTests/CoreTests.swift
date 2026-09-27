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
        XCTAssertEqual(snapshot.children, [[1], [2], []])
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

}
