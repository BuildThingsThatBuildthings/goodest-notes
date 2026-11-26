import UIKit
import PencilKit

enum GlowInk {
    // Blockbook's regular pen colors are opaque. Reserve a nearly opaque alpha
    // for the glow pen so PencilKit keeps the style through moves and serialization.
    private static let glowAlpha: CGFloat = 240.0 / 255.0

    static func color(_ selected: UIColor) -> UIColor {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        if selected.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha),
           saturation > 0.3, brightness > 0.35 {
            return UIColor(hue: hue, saturation: max(saturation, 0.82), brightness: 0.86, alpha: glowAlpha)
        }
        return UIColor(red: 0.45, green: 0.20, blue: 0.92, alpha: glowAlpha)
    }

    static func strokes(in drawing: PKDrawing) -> [PKStroke] {
        drawing.strokes.filter {
            $0.ink.inkType == .pen && abs($0.ink.color.cgColor.alpha - glowAlpha) < 0.003
        }
    }

    static func paint(_ strokes: [PKStroke], in context: CGContext, visible: CGRect) {
        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        defer { context.restoreGState() }
        let layers: [(CGFloat, CGFloat)] = [(3.6, 0.07), (2.8, 0.10), (2.0, 0.15), (1.45, 0.22)]
        for stroke in strokes where stroke.renderBounds.insetBy(dx: -35, dy: -35).intersects(visible) {
            guard let first = stroke.path.first else { continue }
            let center = first.location.applying(stroke.transform)
            let path = CGMutablePath()
            path.move(to: center)
            for point in stroke.path.dropFirst() { path.addLine(to: point.location.applying(stroke.transform)) }
            if stroke.path.count == 1 { path.addLine(to: CGPoint(x: center.x + 0.1, y: center.y)) }
            let width = max(1, first.size.width * hypot(stroke.transform.a, stroke.transform.b))
            for (spread, opacity) in layers {
                context.addPath(path)
                context.setLineWidth(width * spread)
                context.setStrokeColor(stroke.ink.color.withAlphaComponent(opacity).cgColor)
                context.strokePath()
            }
        }
    }
}

final class GlowInkView: UIView {
    var strokes: [PKStroke] = [] { didSet { setNeedsDisplay() } }
    var camera: BoardCamera? {
        didSet { if camera != oldValue, !strokes.isEmpty { setNeedsDisplay() } }
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard !strokes.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        if let camera { context.concatenate(camera.projection) }
        GlowInk.paint(strokes, in: context, visible: context.boundingBoxOfClipPath)
    }
}
