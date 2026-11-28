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

// Keep the colored tube continuously lit. A second, fine filament moves along
// the centerline, so the motion follows the handwriting through each turn.
private final class LuminousStroke {
    let tube = CAShapeLayer()
    private let filament = CAShapeLayer()
    private let cycle: CGFloat

    init(color: UIColor, width: CGFloat) {
        let w = max(0.9, width)
        cycle = max(26, w * 12)
        for shape in [tube, filament] {
            shape.fillColor = nil
            shape.lineCap = .round
            shape.lineJoin = .round
            shape.actions = ["path": NSNull(), "shadowPath": NSNull(), "hidden": NSNull()]
        }
        tube.strokeColor = color.withAlphaComponent(0.98).cgColor
        tube.lineWidth = w
        tube.shadowColor = color.cgColor
        tube.shadowOpacity = 0.95
        tube.shadowOffset = .zero
        tube.shadowRadius = min(8, max(2.5, w * 1.25))
        filament.strokeColor = UIColor.white.withAlphaComponent(0.88).cgColor
        filament.lineWidth = max(0.55, w * 0.38)
        filament.lineDashPattern = [NSNumber(value: Double(cycle * 0.58)), NSNumber(value: Double(cycle * 0.42))]
        tube.addSublayer(filament)
        setMotion()
    }

    func setPath(_ path: CGPath) {
        tube.path = path
        filament.path = path
        tube.shadowPath = path.copy(strokingWithWidth: tube.lineWidth * 1.25, lineCap: .round, lineJoin: .round, miterLimit: 1)
    }

    func setMotion() {
        if UIAccessibility.isReduceMotionEnabled {
            filament.removeAnimation(forKey: "flow")
            filament.lineDashPattern = nil
            filament.opacity = 0.7
        } else {
            guard filament.animation(forKey: "flow") == nil else { return }
            filament.lineDashPattern = [NSNumber(value: Double(cycle * 0.58)), NSNumber(value: Double(cycle * 0.42))]
            filament.opacity = 1
            let flow = CABasicAnimation(keyPath: "lineDashPhase")
            flow.fromValue = 0
            flow.toValue = -cycle
            flow.duration = 2.15
            flow.repeatCount = .infinity
            flow.timingFunction = CAMediaTimingFunction(name: .linear)
            filament.add(flow, forKey: "flow")
        }
    }
}

final class GlowInkView: UIView {
    var strokes: [PKStroke] = [] { didSet { refresh() } }
    var camera: BoardCamera? { didSet { if camera != oldValue { refresh() } } }
    private let world = CALayer()
    private var lights: [ObjectIdentifier: LuminousStroke] = [:]

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        layer.addSublayer(world)
        NotificationCenter.default.addObserver(self, selector: #selector(updateMotion), name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() { super.layoutSubviews(); refresh() }

    @objc private func updateMotion() { lights.values.forEach { $0.setMotion() } }

    private func refresh() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        world.setAffineTransform(camera?.projection ?? .identity)
        let visible = camera?.visibleWorld ?? bounds
        var next: [ObjectIdentifier: LuminousStroke] = [:]
        for stroke in strokes where stroke.renderBounds.insetBy(dx: -24, dy: -24).intersects(visible) {
            let key = ObjectIdentifier(stroke as PKStrokeReference)
            if let existing = lights[key] { next[key] = existing; continue }
            guard let first = stroke.path.first else { continue }
            let path = CGMutablePath()
            let ranges = stroke.mask == nil ? [CGFloat(0)...CGFloat(stroke.path.count - 1)] : stroke.maskedPathRanges
            for range in ranges {
                let start = stroke.path.interpolatedLocation(at: range.lowerBound).applying(stroke.transform)
                path.move(to: start)
                if range.lowerBound == range.upperBound {
                    path.addLine(to: CGPoint(x: start.x + 0.01, y: start.y))
                } else {
                    for point in stroke.path.interpolatedPoints(in: range, by: .parametricStep(0.5)) {
                        path.addLine(to: point.location.applying(stroke.transform))
                    }
                    path.addLine(to: stroke.path.interpolatedLocation(at: range.upperBound).applying(stroke.transform))
                }
            }
            let light = LuminousStroke(color: stroke.ink.color, width: first.size.width * hypot(stroke.transform.a, stroke.transform.b))
            light.setPath(path)
            world.addSublayer(light.tube)
            next[key] = light
        }
        for (key, light) in lights where next[key] == nil { light.tube.removeFromSuperlayer() }
        lights = next
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
    private var liveLight: LuminousStroke?
    private var liveWidth: CGFloat = 0
    private let activePath = UIBezierPath()
    private var tint: UIColor?

    func configureCloud(_ color: UIColor?, width: CGFloat) {
        if tip.superlayer == nil, color != nil {
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
        if tint != color || liveWidth != width {
            liveWidth = width
            liveLight?.tube.removeFromSuperlayer()
            let light = LuminousStroke(color: color, width: width)
            light.tube.zPosition = 9
            layer.addSublayer(light.tube)
            liveLight = light
            tint = color
            tip.colors = [UIColor.white.withAlphaComponent(0.85).cgColor, color.withAlphaComponent(0.76).cgColor,
                          color.withAlphaComponent(0.31).cgColor, color.withAlphaComponent(0).cgColor]
        }
        let diameter = max(12, min(32, width * 3 + 6))
        tip.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
    }

    private func clearTip() {
        tip.isHidden = true
        liveLight?.tube.isHidden = true
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
            liveLight?.tube.isHidden = false
            liveLight?.setPath(activePath.cgPath)
            tip.position = point
            tip.isHidden = false
        case .ended:
            // Leave a short bridge while PencilKit commits its final geometry.
            tip.isHidden = true
            let finished = liveLight
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self, self.activePath.isEmpty else { return }
                finished?.tube.isHidden = true
            }
            activePath.removeAllPoints()
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
