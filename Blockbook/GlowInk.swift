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
        let layers: [(CGFloat, CGFloat)] = [(1.6, 0.07), (0.95, 0.12), (0.42, 0.22)]
        for stroke in strokes where stroke.renderBounds.insetBy(dx: -35, dy: -35).intersects(visible) {
            guard let first = stroke.path.first else { continue }
            let center = first.location.applying(stroke.transform)
            let path = CGMutablePath()
            path.move(to: center)
            for point in stroke.path.interpolatedPoints(by: .parametricStep(0.5)) { path.addLine(to: point.location.applying(stroke.transform)) }
            if stroke.path.count == 1 { path.addLine(to: CGPoint(x: center.x + 0.1, y: center.y)) }
            let width = max(1, first.size.width * hypot(stroke.transform.a, stroke.transform.b))
            for (spread, opacity) in layers {
                context.addPath(path)
                context.setLineWidth(width + min(4, max(1, width)) * spread)
                context.setStrokeColor(stroke.ink.color.withAlphaComponent(opacity).cgColor)
                context.strokePath()
            }
        }
    }
}

final class GlowInkView: UIView {
    var strokes: [PKStroke] = [] { didSet { setNeedsDisplay(); updatePulse() } }
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        NotificationCenter.default.removeObserver(self, name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        if window != nil {
            NotificationCenter.default.addObserver(self, selector: #selector(updatePulse), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        }
        updatePulse()
    }

    @objc private func updatePulse() {
        let key = "haloBreathing"
        guard window != nil, !strokes.isEmpty, !UIAccessibility.isReduceMotionEnabled else {
            layer.removeAnimation(forKey: key)
            return
        }
        guard layer.animation(forKey: key) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1
        pulse.toValue = 0.79
        pulse.duration = 1.65
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: key)
    }

    override func draw(_ rect: CGRect) {
        guard !strokes.isEmpty, let context = UIGraphicsGetCurrentContext() else { return }
        if let camera { context.concatenate(camera.projection) }
        GlowInk.paint(strokes, in: context, visible: context.boundingBoxOfClipPath)
    }
}

// Observe PencilKit's own drawing gesture so navigation and Pencil input retain
// their normal ownership. The tip and active halo are presentation layers only.
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
    private let tip = CAGradientLayer()
    private let activeHalo = CAShapeLayer()
    private let activePath = UIBezierPath()
    private var tint: UIColor?

    func configureCloud(_ color: UIColor?, width: CGFloat) {
        if tip.superlayer == nil, color != nil {
            activeHalo.fillColor = nil
            activeHalo.lineCap = .round
            activeHalo.lineJoin = .round
            activeHalo.zPosition = 9
            activeHalo.actions = ["path": NSNull(), "hidden": NSNull()]
            layer.addSublayer(activeHalo)
            tip.type = .radial
            tip.startPoint = CGPoint(x: 0.5, y: 0.5)
            tip.endPoint = CGPoint(x: 1, y: 0.5)
            tip.locations = [0, 0.16, 0.45, 1]
            tip.zPosition = 10
            tip.actions = ["position": NSNull(), "hidden": NSNull(), "bounds": NSNull(), "colors": NSNull()]
            tip.isHidden = true
            layer.addSublayer(tip)
            drawingGestureRecognizer.addTarget(self, action: #selector(trackInk(_:)))
        }
        guard let color else {
            tint = nil
            clearTip()
            return
        }
        if tint != color {
            tint = color
            tip.colors = [UIColor.white.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0.76).cgColor,
                          color.withAlphaComponent(0.31).cgColor, color.withAlphaComponent(0).cgColor]
            activeHalo.strokeColor = color.withAlphaComponent(0.19).cgColor
        }
        let diameter = max(4, min(18, width * 2.4 + 2))
        tip.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        activeHalo.lineWidth = width + min(4, max(1, width))
    }

    private func clearTip() {
        tip.isHidden = true
        activeHalo.path = nil
        activePath.removeAllPoints()
    }

    @objc private func trackInk(_ gesture: UIGestureRecognizer) {
        guard tint != nil else { return }
        switch gesture.state {
        case .began, .changed:
            let point = gesture.location(in: self)
            if gesture.state == .began || activePath.isEmpty {
                activePath.removeAllPoints()
                activePath.move(to: point)
            } else {
                activePath.addLine(to: point)
            }
            activeHalo.path = activePath.cgPath
            tip.position = point
            tip.isHidden = false
        default:
            clearTip()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearTip() }
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
