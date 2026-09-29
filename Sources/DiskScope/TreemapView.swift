import SwiftUI
import DiskScopeCore

private struct RenderTile {
    let nodeID: Int?
    let parentID: Int
    let rect: CGRect
    let title: String
    let bytes: UInt64
    let category: FileCategory
    let hasChildren: Bool
    let depth: Int
}

struct TreemapView: View {
    @ObservedObject var model: ScannerModel
    @State private var tiles: [RenderTile] = []
    @State private var hovered: Int?
    @State private var pointer = CGPoint.zero

    var body: some View {
        // Read render inputs while evaluating body, so changes invalidate Canvas
        // even when no hover event occurs. The renderer captures these values.
        let tiles = self.tiles
        let hovered = self.hovered
        let selectedID = model.selectedID
        let totalBytes = model.current?.bytes(model.metric) ?? 0
        return GeometryReader { geometry in
            Canvas { context, _ in
                for (index, tile) in tiles.enumerated() {
                    let rect = tile.rect.insetBy(dx: 2, dy: 2)
                    guard rect.width > 0, rect.height > 0 else { continue }
                    let shape = Path(roundedRect: rect, cornerRadius: tile.depth == 0 ? 7 : 4)
                    let color = Theme.color(tile.category)
                    context.fill(shape, with: .color(color.opacity(tile.hasChildren ? 0.42 : (tile.depth == 0 ? 0.88 : 0.80))))
                    if hovered == index { context.fill(shape, with: .color(.white.opacity(0.12))) }
                    if tile.nodeID != nil && tile.nodeID == selectedID {
                        context.stroke(shape, with: .color(Theme.accent), lineWidth: 2)
                    } else {
                        context.stroke(shape, with: .color(.white.opacity(0.08)), lineWidth: 0.5)
                    }
                    guard rect.width > 62, rect.height > 25 else { continue }
                    var clipped = context
                    clipped.clip(to: Path(rect.insetBy(dx: 8, dy: 3)))
                    let fontSize: CGFloat = tile.depth == 0 ? 12 : 10
                    var titleWidth = rect.width - 20
                    if tile.hasChildren {
                        let total = context.resolve(Text(ByteText.format(tile.bytes))
                            .font(.system(size: 10, weight: .medium, design: .rounded)).foregroundColor(.white.opacity(0.85)))
                        let totalWidth = total.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width
                        titleWidth -= totalWidth + 10
                        clipped.draw(total, at: CGPoint(x: rect.maxX - 10, y: rect.minY + 10), anchor: .topTrailing)
                    }
                    let title = fittedText(tile.title, font: .system(size: fontSize, weight: .medium),
                                           width: titleWidth, context: context)
                    clipped.draw(title, at: CGPoint(x: rect.minX + 10, y: rect.minY + 9), anchor: .topLeading)
                    if !tile.hasChildren && rect.height > 53 {
                        clipped.draw(Text(ByteText.format(tile.bytes)).font(.system(size: rect.width > 180 && rect.height > 100 ? 22 : 12, weight: .semibold, design: .rounded)).foregroundColor(.white), at: CGPoint(x: rect.minX + 10, y: rect.minY + 29), anchor: .topLeading)
                        if rect.height > 92 {
                            clipped.draw(Text(ByteText.percent(tile.bytes, of: totalBytes)).font(.system(size: 10, design: .monospaced)).foregroundColor(.white.opacity(0.60)), at: CGPoint(x: rect.minX + 10, y: rect.maxY - 13), anchor: .bottomLeading)
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered, tiles.indices.contains(hovered) {
                    let tile = tiles[hovered]
                    VStack(alignment: .leading, spacing: 3) {
                        Text(tile.title).font(.system(size: 11, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                        Text("\(ByteText.format(tile.bytes)) · \(ByteText.percent(tile.bytes, of: totalBytes))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.muted)
                    }
                    .padding(10).frame(maxWidth: 220, alignment: .leading)
                    .background(Theme.background.opacity(0.97), in: RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.line))
                    .offset(x: max(0, min(pointer.x + 14, geometry.size.width - 230)), y: max(0, min(pointer.y + 16, geometry.size.height - 74)))
                    .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    pointer = point
                    self.hovered = tiles.indices.reversed().first { tiles[$0].rect.contains(point) }
                case .ended: self.hovered = nil
                }
            }
            .onTapGesture(count: 2) {
                guard let hovered, tiles.indices.contains(hovered) else { return }
                let tile = tiles[hovered]
                if let id = tile.nodeID { model.navigate(id) }
                else { model.navigate(tile.parentID) }
            }
            .onTapGesture {
                guard let hovered, tiles.indices.contains(hovered) else { return }
                model.selectedID = tiles[hovered].nodeID ?? tiles[hovered].parentID
            }
            .task(id: "\(geometry.size)-\(model.currentID)-\(model.metric)-\(model.snapshot?.nodes.count ?? 0)") {
                self.hovered = nil
                self.tiles = makeTiles(in: CGRect(origin: .zero, size: geometry.size))
            }
            .accessibilityLabel("容量ツリーマップ。各項目の詳細とフォルダ移動は下の一覧から操作できます。")
        }
    }

    private func fittedText(_ value: String, font: Font, width: CGFloat, context: GraphicsContext) -> GraphicsContext.ResolvedText {
        func resolve(_ text: String) -> GraphicsContext.ResolvedText {
            context.resolve(Text(text).font(font).foregroundColor(.white.opacity(0.95)))
        }
        func fits(_ text: GraphicsContext.ResolvedText) -> Bool {
            text.measure(in: CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)).width <= width
        }
        let full = resolve(value)
        if fits(full) { return full }
        guard fits(resolve("…")) else { return resolve("") }
        let characters = Array(value)
        var lower = 0
        var upper = characters.count
        while lower < upper {
            let middle = (lower + upper + 1) / 2
            if fits(resolve(String(characters.prefix(middle)) + "…")) { lower = middle }
            else { upper = middle - 1 }
        }
        return resolve(String(characters.prefix(lower)) + "…")
    }

    private func makeTiles(in bounds: CGRect) -> [RenderTile] {
        guard let snapshot = model.snapshot else { return [] }
        var result: [RenderTile] = []
        func append(parent: Int, bounds: CGRect, depth: Int) {
            let limit = depth == 0 ? 180 : 45
            let selection = parent == model.currentID ? model.currentSelection : snapshot.largestChildren(of: parent, metric: model.metric, limit: limit)
            let shown = Array(selection.ids.prefix(limit).filter { snapshot.nodes[$0].bytes(model.metric) > 0 })
            let otherCount = selection.nonzeroCount - shown.count
            let shownBytes = shown.reduce(UInt64(0)) { $0 &+ snapshot.nodes[$1].bytes(model.metric) }
            let otherBytes = selection.bytes - shownBytes
            var weights = shown.map { WeightedItem(id: $0, weight: Double(snapshot.nodes[$0].bytes(model.metric))) }
            if otherBytes > 0 { weights.append(WeightedItem(id: -1, weight: Double(otherBytes))) }
            for tile in Treemap.layout(weights, in: bounds) {
                if tile.id == -1 {
                    result.append(RenderTile(nodeID: nil, parentID: parent, rect: tile.rect, title: "その他 \(otherCount) 項目", bytes: otherBytes, category: .other, hasChildren: false, depth: depth))
                    continue
                }
                let node = snapshot.nodes[tile.id]
                let nested = depth == 0 && node.isDirectory && tile.rect.width > 140 && tile.rect.height > 105 && !snapshot.children[tile.id].isEmpty
                result.append(RenderTile(nodeID: tile.id, parentID: parent, rect: tile.rect, title: node.name, bytes: node.bytes(model.metric), category: node.category, hasChildren: nested, depth: depth))
                if nested {
                    append(parent: tile.id, bounds: CGRect(x: tile.rect.minX + 5, y: tile.rect.minY + 29, width: tile.rect.width - 10, height: tile.rect.height - 34), depth: depth + 1)
                }
            }
        }
        append(parent: model.currentID, bounds: bounds, depth: 0)
        return result
    }
}
