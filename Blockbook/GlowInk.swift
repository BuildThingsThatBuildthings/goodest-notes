import UIKit
import PencilKit

enum GlowInk {
    // Blockbook's regular pen colors are opaque. Reserve a nearly opaque alpha
    // for the glow pen so PencilKit keeps the style through moves and serialization.
    private static let glowAlpha: CGFloat = 240.0 / 255.0

    static func color(_ selected: UIColor) -> UIColor {
        selected.withAlphaComponent(glowAlpha)
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

// Observe PencilKit's own drawing gesture so navigation and Pencil input retain
// their normal ownership. Only transient particles live on this layer.
final class CloudInkCanvas: PKCanvasView {
    private let mist = CAEmitterLayer()
    private var tint: UIColor?
    private var diameter: CGFloat = 0
    private static let puff: CGImage? = UIGraphicsImageRenderer(size: CGSize(width: 48,height: 48)).image { render in
        let colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.44).cgColor, UIColor.white.withAlphaComponent(0).cgColor]
        guard let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors as CFArray, locations: [0,0.34,1]) else { return }
        let center = CGPoint(x: 24,y: 24)
        render.cgContext.drawRadialGradient(gradient,startCenter:center,startRadius:0,endCenter:center,endRadius:24,options:[])
    }.cgImage

    func configureCloud(_ color: UIColor?, width: CGFloat) {
        if mist.superlayer == nil, color != nil {
            mist.birthRate = 0
            mist.zPosition = 10
            mist.actions = ["emitterPosition": NSNull(), "birthRate": NSNull()]
            layer.addSublayer(mist)
            drawingGestureRecognizer.addTarget(self, action: #selector(trackInk(_:)))
        }
        guard color != tint || width != diameter else { return }
        tint = color
        diameter = width
        guard let color else { mist.birthRate = 0; return }
        let cloud = CAEmitterCell()
        cloud.contents = Self.puff
        cloud.contentsScale = UIScreen.main.scale
        cloud.color = color.resolvedColor(with: traitCollection).cgColor
        cloud.birthRate = 100
        cloud.lifetime = 0.42
        cloud.scale = min(1.1, 0.33 + width / 45)
        cloud.scaleSpeed = 0.75
        cloud.velocity = 13
        cloud.velocityRange = 9
        cloud.emissionRange = .pi * 2
        cloud.alphaSpeed = -2.2
        let core = CAEmitterCell()
        core.contents = cloud.contents
        core.contentsScale = cloud.contentsScale
        core.color = UIColor.white.withAlphaComponent(0.85).cgColor
        core.birthRate = 72
        core.lifetime = 0.15
        core.scale = cloud.scale * 0.55
        core.scaleSpeed = 0.25
        core.alphaSpeed = -5
        mist.emitterCells = [cloud, core]
    }

    @objc private func trackInk(_ gesture: UIGestureRecognizer) {
        guard tint != nil, !UIAccessibility.isReduceMotionEnabled,
              gesture.state == .began || gesture.state == .changed else { mist.birthRate = 0; return }
        mist.emitterPosition = gesture.location(in: self)
        mist.birthRate = 1
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { mist.birthRate = 0 }
    }
}
