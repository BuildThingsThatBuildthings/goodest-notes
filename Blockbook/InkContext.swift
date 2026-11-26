import Foundation
import PencilKit

extension InkContextAnchor {
    static func key(_ stroke: PKStroke) -> String {
        if #available(iOS 27, macCatalyst 27, *) { return stroke.id.uuidString }
        return String(stroke.randomSeed)
    }

    static func item(at point: CGPoint, in drawing: PKDrawing, tolerance: CGFloat) -> CanvasItem? {
        let candidates = drawing.strokes.filter { CanvasItem.valid(frame(for: $0.renderBounds)) }
        guard let seed = candidates.filter({ $0.renderBounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point) })
            .min(by: { distance($0.renderBounds, to: point) < distance($1.renderBounds, to: point) }) else { return nil }
        let base = seed.renderBounds
        let gap = max(7, min(40, base.height * 0.6))
        let band = max(10, min(85, base.height * 0.65))
        var region = base
        var ids: Set<String> = [key(seed)]
        let line = candidates.filter {
            abs($0.renderBounds.midY - base.midY) < band && $0.renderBounds.height < max(40, base.height * 2.7)
        }
        // Grow across tightly spaced strokes on the same line without joining the
        // next phrase or a neighboring row.
        var growing = true
        while growing && ids.count < 64 {
            growing = false
            for stroke in line where ids.count < 64 {
                let id = key(stroke), rect = stroke.renderBounds
                guard !ids.contains(id),
                      rect.minX <= region.maxX + gap, rect.maxX >= region.minX - gap,
                      region.union(rect).width < 1000 else { continue }
                region = region.union(rect)
                ids.insert(id)
                growing = true
            }
        }
        return CanvasItem(kind: .inkContext, title: "Handwriting", frame: frame(for: region),
                          inkAnchor: InkContextAnchor(strokes: ids.sorted()))
    }

    static func frame(for rect: CGRect) -> CGRect {
        let width = max(40, rect.width + 14), height = max(32, rect.height + 12)
        return CGRect(x: rect.midX - width / 2, y: rect.midY - height / 2, width: width, height: height)
    }

    func updatedFrame(using bounds: [String: CGRect]) -> CGRect? {
        let region = strokes.compactMap { bounds[$0] }.reduce(CGRect.null) { $0.union($1) }
        guard !region.isNull else { return nil }
        let frame = Self.frame(for: region)
        return CanvasItem.valid(frame) ? frame : nil
    }

    private static func distance(_ rect: CGRect, to point: CGPoint) -> CGFloat {
        let x = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let y = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(x, y)
    }
}
