import Foundation
import CoreGraphics

public struct WeightedItem: Sendable {
    public let id: Int
    public let weight: Double
    public init(id: Int, weight: Double) { self.id = id; self.weight = weight }
}

public struct MapRect: Sendable {
    public let id: Int
    public let rect: CGRect
}

/// Squarified treemap. Uninset rectangle areas are proportional to positive weights.
public enum Treemap {
    public static func layout(_ items: [WeightedItem], in bounds: CGRect) -> [MapRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [] }
        let items = items.filter { $0.weight > 0 && $0.weight.isFinite }.sorted { $0.weight > $1.weight }
        let total = items.reduce(0) { $0 + $1.weight }
        guard total > 0 && total.isFinite else { return [] }
        let scale = bounds.width * bounds.height / total
        let areas = items.map { $0.weight * scale }
        var remaining = bounds
        var output: [MapRect] = []
        var index = 0
        while index < items.count && remaining.width > 0 && remaining.height > 0 {
            let short = min(remaining.width, remaining.height)
            var end = index + 1
            var sum = areas[index]
            var worst = aspect(sum: sum, min: areas[index], max: areas[index], side: short)
            while end < items.count {
                let nextSum = sum + areas[end]
                let nextWorst = aspect(sum: nextSum, min: areas[end], max: areas[index], side: short)
                if nextWorst > worst { break }
                worst = nextWorst; sum = nextSum; end += 1
            }
            if remaining.width >= remaining.height {
                let width = end == items.count ? remaining.width : min(remaining.width, sum / remaining.height)
                var y = remaining.minY
                for i in index..<end {
                    let height = i == end - 1 ? remaining.maxY - y : areas[i] / width
                    output.append(MapRect(id: items[i].id, rect: CGRect(x: remaining.minX, y: y, width: width, height: height)))
                    y += height
                }
                remaining.origin.x += width; remaining.size.width -= width
            } else {
                let height = end == items.count ? remaining.height : min(remaining.height, sum / remaining.width)
                var x = remaining.minX
                for i in index..<end {
                    let width = i == end - 1 ? remaining.maxX - x : areas[i] / height
                    output.append(MapRect(id: items[i].id, rect: CGRect(x: x, y: remaining.minY, width: width, height: height)))
                    x += width
                }
                remaining.origin.y += height; remaining.size.height -= height
            }
            index = end
        }
        return output
    }

    private static func aspect(sum: Double, min: Double, max: Double, side: Double) -> Double {
        guard min > 0, side > 0 else { return .infinity }
        return Swift.max(side * side * max / (sum * sum), sum * sum / (side * side * min))
    }
}
