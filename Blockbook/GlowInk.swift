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
    private var secondWriter: FingerInkGesture?
    private var waitingStrokes: [(PKStroke,CAShapeLayer)] = []
    func configureDuet(_ enabled: Bool,width:CGFloat) {
        if enabled && secondWriter == nil {
            let finger=FingerInkGesture(target:nil,action:nil)
            finger.allowedTouchTypes=[NSNumber(value:UITouch.TouchType.direct.rawValue)]
            finger.cancelsTouchesInView=false;finger.delaysTouchesBegan=false
            finger.delegate=finger
            addGestureRecognizer(finger);secondWriter=finger
            drawingGestureRecognizer.addTarget(self,action:#selector(pencilStateChanged))
        }
        secondWriter?.width=width
        secondWriter?.isEnabled=enabled
        drawingPolicy=enabled ? .pencilOnly : .anyInput
    }
    func finishFinger(_ stroke:PKStroke,preview:CAShapeLayer) {
        waitingStrokes.append((stroke,preview));commitFingerIfReady()
    }
    @objc private func pencilStateChanged(){
        DispatchQueue.main.async { [weak self] in self?.commitFingerIfReady() }
    }
    private func commitFingerIfReady() {
        guard !waitingStrokes.isEmpty,drawingGestureRecognizer.state != .began,drawingGestureRecognizer.state != .changed else{return}
        let finished=waitingStrokes;waitingStrokes.removeAll()
        drawing=PKDrawing(strokes:drawing.strokes+finished.map{$0.0})
        finished.forEach{$0.1.removeFromSuperlayer()}
    }
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

private final class FingerInkGesture: UIGestureRecognizer, UIGestureRecognizerDelegate {
    var width:CGFloat=3
    private weak var contact: UITouch?
    private var started:TimeInterval=0
    private var points:[PKStrokePoint]=[]
    private var line=UIBezierPath()
    private var preview=CAShapeLayer()
    private let color=UIColor(red:0.90,green:0.25,blue:0.23,alpha:1)
    func gestureRecognizer(_ gestureRecognizer:UIGestureRecognizer,shouldRecognizeSimultaneouslyWith other:UIGestureRecognizer)->Bool {true}
    override func touchesBegan(_ touches:Set<UITouch>,with event:UIEvent){
        guard contact==nil,let touch=touches.first,let canvas=view as? CloudInkCanvas else{return}
        contact=touch;started=touch.timestamp
        line=UIBezierPath();preview=CAShapeLayer();preview.strokeColor=color.cgColor;preview.fillColor=nil
        preview.lineWidth=width;preview.lineCap = .round;preview.lineJoin = .round;preview.zPosition=11
        preview.actions=["path":NSNull()];canvas.layer.addSublayer(preview)
        sample(touch);state = .began
    }
    private func sample(_ touch:UITouch){
        let location=touch.preciseLocation(in:view)
        guard points.last?.location != location else{return}
        if points.isEmpty {line.move(to:location)} else {line.addLine(to:location)}
        points.append(PKStrokePoint(location:location,timeOffset:touch.timestamp-started,size:CGSize(width:width,height:width),opacity:1,force:1,azimuth:0,altitude:.pi/2))
        preview.path=line.cgPath
    }
    override func touchesMoved(_ touches:Set<UITouch>,with event:UIEvent){
        guard let contact,touches.contains(contact) else{return}
        for t in event.coalescedTouches(for:contact) ?? [contact] {sample(t)}
        state = .changed
    }
    override func touchesEnded(_ touches:Set<UITouch>,with event:UIEvent){
        guard let contact,touches.contains(contact),let canvas=view as? CloudInkCanvas else{return}
        sample(contact)
        let stroke=PKStroke(ink:PKInk(.pen,color:color),path:PKStrokePath(controlPoints:points,creationDate:Date()))
        handedOff=true;canvas.finishFinger(stroke,preview:preview);state = .ended
    }
    override func touchesCancelled(_ touches:Set<UITouch>,with event:UIEvent){state = .cancelled}
    override func reset(){super.reset();contact=nil;points.removeAll();if !handedOff {preview.removeFromSuperlayer()};handedOff=false}
    private var handedOff=false
}
