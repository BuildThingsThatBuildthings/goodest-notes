import UIKit
import PencilKit

struct BoardCamera: Equatable {
    static let minScale: CGFloat = 0.00000001
    static let maxScale: CGFloat = 6
    static let editingScale: CGFloat = 0.06

    var center: CGPoint
    var size: CGSize = .zero
    private(set) var scale: CGFloat = 0.85

    var visibleWorld: CGRect {
        CGRect(x: center.x - size.width / scale / 2, y: center.y - size.height / scale / 2,
               width: size.width / scale, height: size.height / scale)
    }

    var projection: CGAffineTransform {
        CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: size.width / 2 - center.x * scale, ty: size.height / 2 - center.y * scale)
    }

    func screen(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - center.x) * scale + size.width / 2, y: (point.y - center.y) * scale + size.height / 2)
    }

    func world(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - size.width / 2) / scale + center.x, y: (point.y - size.height / 2) / scale + center.y)
    }

    mutating func fit(_ rect: CGRect) {
        let margin: CGFloat = 28
        guard size.width > margin * 2, size.height > margin * 2, !rect.isNull else { return }
        let fit = min((size.width - margin * 2) / max(rect.width, 1), (size.height - margin * 2) / max(rect.height, 1))
        center = CGPoint(x: rect.midX, y: rect.midY)
        scale = boundedScale(min(1, fit))
    }

    mutating func pan(_ delta: CGPoint) {
        center = boundedCenter(CGPoint(x: center.x - delta.x / scale, y: center.y - delta.y / scale))
    }

    mutating func zoom(to desired: CGFloat, holding point: CGPoint, at position: CGPoint) {
        scale = boundedScale(desired)
        center = boundedCenter(CGPoint(x: point.x - (position.x - size.width / 2) / scale,
                                       y: point.y - (position.y - size.height / 2) / scale))
    }

    private func boundedScale(_ desired: CGFloat) -> CGFloat { min(Self.maxScale, max(Self.minScale, desired)) }

    private func boundedCenter(_ desired: CGPoint) -> CGPoint {
        let bound: CGFloat = 1_000_000_000
        return CGPoint(x: min(bound, max(-bound, desired.x)), y: min(bound, max(-bound, desired.y)))
    }
}

final class BoardSurface: UIScrollView, CanvasSurface, UIScrollViewDelegate, UIGestureRecognizerDelegate, PKCanvasViewDelegate {
    let inputLayer = DrawingInteractions()
    let ink = PKCanvasView()
    private let playback=VisualPlayback()
    private let grid = BoardGrid()
    private let overlay = CanvasOverlay()
    private let glow = GlowInkView()
    private let inkPreview = BoardInkPreview()
    private let status = UILabel()
    private lazy var pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
    private var pinching: (anchor: CGPoint, scale: CGFloat)?
    private var cameraMoving = false
    private var fittingOnFirstLayout = true
    private var presentingInk = false
    private var editingWindow: BoardInkWindow?
    private var undoDrawings: [PKDrawing] = []
    private var redoDrawings: [PKDrawing] = []
    private var content: CanvasContent
    private var assetURL: (CanvasAsset) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }
    private var selected: UUID?
    private var connecting: UUID?
    private var instrument = Instrument.pen
    private var color = UIColor.black
    private var width: CGFloat = 3
    private var installedTool: (Instrument, UIColor, CGFloat)?
    private let scrollHome = CGPoint(x: 20_000, y: 20_000)
    private var priorOffset = CGPoint.zero
    private var centeringScroll = false
    private let pageID: UUID
    private let home: CGPoint

    private(set) var camera: BoardCamera
    private(set) var worldDrawing: PKDrawing
    var currentDrawing: PKDrawing { worldDrawing }
    var worldCenter: CGPoint { camera.center }
    func viewportPosition(_ point: CGPoint) -> CGPoint { camera.screen(point) }
    var validInk = true
    var changed: (PKDrawing) -> Void = { _ in }

    init(page: SheetPage, drawing: PKDrawing) {
        let origin = CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        pageID=page.id
        home = origin
        camera = BoardCamera(center: origin)
        content = page.canvas ?? CanvasContent()
        worldDrawing = drawing
        super.init(frame: .zero)
        inkPreview.strokes = drawing.strokes
        glow.strokes = GlowInk.strokes(in: drawing)
        accessibilityLabel = "Whiteboard canvas"
        overrideUserInterfaceStyle = .light
        backgroundColor = .white
        clipsToBounds = true
        delegate = self
        contentInsetAdjustmentBehavior = .never
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bounces = false
        delaysContentTouches = false
        decelerationRate = .fast
        for layer in [grid, overlay, glow, inkPreview] { layer.isUserInteractionEnabled = false; addSubview(layer) }
        ink.isScrollEnabled = false
        ink.isOpaque = false
        ink.backgroundColor = .clear
        ink.drawingPolicy = .anyInput
        ink.delegate = self
        addSubview(ink)
        addSubview(playback)
        addSubview(inputLayer)
        inputLayer.worldPoint = { [weak self] point in self?.camera.world(point) ?? point }
        inputLayer.localPoint = { [weak self] point in self?.camera.screen(point) ?? point }
        inputLayer.viewportPosition = { [weak self] point in self?.viewportPosition(point) ?? point }
        inputLayer.hitItem = { [weak self] point in
            guard let self else { return nil }
            return self.overlay.item(at: point, tolerance: self.camera.scale < 0.28 ? 5 / self.camera.scale : 0)
        }
        inputLayer.hitWriting = { [weak self] point in
            guard let self else { return nil }
            return InkContextAnchor.item(at: point, in: self.worldDrawing, tolerance: min(38, 9 / self.camera.scale))
        }
        inputLayer.previewMove = { [weak self] id, rect in self?.overlay.move(id, to: rect) }
        addGestureRecognizer(pinch)
        pinch.delegate = self
        panGestureRecognizer.minimumNumberOfTouches = 2

        status.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        status.textColor = UIColor(white: 0.28, alpha: 1)
        status.backgroundColor = UIColor(white: 0.95, alpha: 0.94)
        status.textAlignment = .center
        status.layer.cornerRadius = 8
        status.clipsToBounds = true
        addSubview(status)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 58, bounds.height > 58 else { return }
        guard camera.size != bounds.size else { layoutViewport(); return }
        camera.size = bounds.size
        resetScrollDriver(resize: true)
        layoutViewport()
        if fittingOnFirstLayout {
            fittingOnFirstLayout = false
            if let value=UserDefaults.standard.array(forKey:"camera."+pageID.uuidString) as? [Double],value.count==3 {
                camera.zoom(to:value[2],holding:CGPoint(x:value[0],y:value[1]),at:cameraMidpoint);refresh(reloadInk:true)
            } else { fit() }
        } else {
            refresh(reloadInk: true)
        }
    }

    func configure(_ tool: Instrument, color: UIColor, width: CGFloat) {
        instrument = tool
        self.color = color
        self.width = width
        inputLayer.instrument = tool
        panGestureRecognizer.minimumNumberOfTouches = tool == .pan ? 1 : 2
        setInkTool()
        updateInkVisibility()
    }

    func updateContent(_ content: CanvasContent, selected: UUID?, connecting: UUID?, assetURL: @escaping (CanvasAsset) -> URL) {
        self.content = content
        self.selected = selected
        self.connecting = connecting
        self.assetURL = assetURL
        inputLayer.connecting = connecting != nil
        updateOverlay()
    }

    func fit() {
        let extent = CanvasGeometry.bounds(ink: worldDrawing, canvas: content)
        if extent.isNull {
            camera.center = home
            camera.zoom(to: 0.85, holding: home, at: cameraMidpoint)
        } else {
            camera.fit(extent.insetBy(dx: -32, dy: -32))
        }
        refresh(reloadInk: true)
    }

    func zoom(by factor: CGFloat) {
        camera.zoom(to: camera.scale * factor, holding: camera.center, at: cameraMidpoint)
        refresh(reloadInk: true)
    }

    func reveal(_ point: CGPoint) {
        camera.zoom(to: max(0.65, min(1.4, camera.scale)), holding: point, at: cameraMidpoint)
        refresh(reloadInk: true)
    }

    /// Apply deltas in view points without imposing the scroll driver's bounds on the board.
    func moveViewport(by delta: CGPoint) {
        camera.pan(delta)
        refresh(reloadInk: !cameraMoving)
    }

    private var cameraMidpoint: CGPoint { CGPoint(x: camera.size.width / 2, y: camera.size.height / 2) }

    func showVisual(_ visual:TeachingVisual?,folder:URL) { playback.configure(visual,folder:folder);placeVisual() }
    private func placeVisual() { playback.place { point in let p=camera.screen(point);return CGPoint(x:p.x+bounds.minX,y:p.y+bounds.minY) } }
    private func layoutViewport() {
        placeVisual()
        // UIScrollView supplies the native gesture and momentum. The render surfaces
        // follow its bounds, so their memory footprint is only the visible viewport.
        for layer in [grid, overlay, glow, inkPreview, ink, inputLayer] where layer.frame != bounds { layer.frame = bounds }
        positionStatus()
    }

    private func resetScrollDriver(resize: Bool = false) {
        centeringScroll = true
        if resize { contentSize = CGSize(width: bounds.width + 2 * scrollHome.x, height: bounds.height + 2 * scrollHome.y) }
        setContentOffset(scrollHome, animated: false)
        priorOffset = contentOffset
        centeringScroll = false
    }

    private func refresh(reloadInk: Bool) {
        placeVisual()
        if !fittingOnFirstLayout && !cameraMoving { UserDefaults.standard.set([camera.center.x,camera.center.y,camera.scale],forKey:"camera."+pageID.uuidString) }
        grid.camera = camera
        grid.setNeedsDisplay()
        updateOverlay()
        inkPreview.camera = camera
        glow.camera = camera
        inputLayer.refreshWritingOutline()
        updateInkVisibility()
        if reloadInk, camera.scale >= BoardCamera.editingScale { loadInk() }
        setInkTool()
    }

    private func updateOverlay() {
        overlay.update(content, camera: camera, selected: selected, connecting: connecting, assetURL: assetURL)
    }

    private func updateInkVisibility() {
        let overview = camera.scale < BoardCamera.editingScale || cameraMoving
        ink.isHidden = overview
        inkPreview.isHidden = !overview
        if overview { inkPreview.setNeedsDisplay() }
        ink.isUserInteractionEnabled = !overview && validInk && instrument.editsInk
        let percent = camera.scale * 100
        let scaleText = percent < 1 ? "<1%" : "\(Int(percent.rounded()))%"
        status.text = camera.scale < BoardCamera.editingScale && instrument.editsInk ? "  \(scaleText) · Use Writing magnifier  " : "  \(scaleText)  "
        positionStatus()
    }

    private func positionStatus() {
        let width = status.sizeThatFits(.zero).width
        status.frame = CGRect(x: bounds.minX + max(6, bounds.width - width - 12), y: bounds.minY + max(6, bounds.height - 36), width: width, height: 25)
    }

    private func setInkTool() {
        let liveWidth = max(0.85, width * camera.scale)
        if let (prior, tint, size) = installedTool, prior == instrument, tint == color, size == liveWidth { return }
        installedTool = (instrument, color, liveWidth)
        instrument.configureInk(ink, color: color, width: liveWidth)
    }

    private func loadInk() {
        let slice = BoardInkWindow(drawing: worldDrawing, camera: camera)
        editingWindow = slice
        presentingInk = true
        ink.drawing = slice.projectedDrawing
        presentingInk = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard validInk, !presentingInk, !cameraMoving, !ink.isHidden, var slice = editingWindow,
              canvasView.drawing != slice.projectedDrawing else { return }
        rememberDrawing()
        worldDrawing = slice.merge(canvasView.drawing)
        editingWindow = slice
        inkPreview.strokes = worldDrawing.strokes
        glow.strokes = GlowInk.strokes(in: worldDrawing)
        changed(worldDrawing)
    }

    private func rememberDrawing() {
        undoDrawings.append(worldDrawing)
        if undoDrawings.count > 24 { undoDrawings.removeFirst() }
        redoDrawings.removeAll()
    }

    func applyMagnifiedDrawing(_ drawing: PKDrawing) {
        guard validInk, drawing != worldDrawing else { return }
        rememberDrawing()
        replaceInk(drawing)
    }

    func undoInk() {
        guard let drawing = undoDrawings.popLast() else { return }
        redoDrawings.append(worldDrawing)
        replaceInk(drawing)
    }

    func redoInk() {
        guard let drawing = redoDrawings.popLast() else { return }
        undoDrawings.append(worldDrawing)
        replaceInk(drawing)
    }

    private func replaceInk(_ drawing: PKDrawing) {
        worldDrawing = drawing
        inkPreview.strokes = drawing.strokes
        glow.strokes = GlowInk.strokes(in: drawing)
        refresh(reloadInk: true)
        changed(drawing)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === pinch && other === panGestureRecognizer
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) { beginCameraMove() }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        let offset = contentOffset
        let delta = CGPoint(x: priorOffset.x - offset.x, y: priorOffset.y - offset.y)
        priorOffset = offset
        guard camera.size != .zero, !centeringScroll else { return }
        layoutViewport()
        if pinching == nil && delta != .zero { moveViewport(by: delta) }
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                   targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        // Keep a quick drag useful at overview scales, where a screen point represents many world points.
        let proposed = targetContentOffset.pointee
        let limitX = bounds.width * 0.2
        let limitY = bounds.height * 0.2
        targetContentOffset.pointee = CGPoint(
            x: min(contentOffset.x + limitX, max(contentOffset.x - limitX, proposed.x)),
            y: min(contentOffset.y + limitY, max(contentOffset.y - limitY, proposed.y))
        )
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate && pinching == nil { endCameraMove() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if pinching == nil { endCameraMove() }
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer) {
        let position = gesture.location(in: grid)
        switch gesture.state {
        case .began:
            beginCameraMove()
            pinching = (camera.world(position), camera.scale)
        case .changed:
            guard let pinching else { return }
            camera.zoom(to: pinching.scale * gesture.scale, holding: pinching.anchor, at: position)
            refresh(reloadInk: false)
        case .ended, .cancelled, .failed:
            pinching = nil
            if !isDragging && !isDecelerating { endCameraMove() }
        default: break
        }
    }

    private func beginCameraMove() {
        guard !cameraMoving else { return }
        canvasViewDrawingDidChange(ink)
        cameraMoving = true
        updateInkVisibility()
    }

    private func endCameraMove() {
        cameraMoving = false
        resetScrollDriver()
        layoutViewport()
        refresh(reloadInk: true)
    }
}

struct BoardInkWindow {
    private var world: [PKStroke]
    private var positions: [Int]
    private let projection: CGAffineTransform
    private(set) var projectedDrawing: PKDrawing

    init(drawing: PKDrawing, camera: BoardCamera) {
        let strokes = drawing.strokes
        world = strokes
        projection = camera.projection
        let region = camera.visibleWorld.insetBy(dx: -80 / camera.scale, dy: -80 / camera.scale)
        positions = strokes.indices.filter { strokes[$0].renderBounds.intersects(region) }
        projectedDrawing = PKDrawing(strokes: positions.map { strokes[$0] }).transformed(using: projection)
    }

    mutating func merge(_ edited: PKDrawing) -> PKDrawing {
        let prior = projectedDrawing.strokes
        let next = edited.strokes
        let inWorld = edited.transformed(using: projection.inverted()).strokes
        // PencilKit keeps the stroke seed through lasso moves. Match the currently loaded
        // strokes so distant ink and the original stacking order survive an edit.
        let originals = Dictionary(grouping: prior.indices, by: { identity(prior[$0]) })
        var consumed: [StrokeIdentity: Int] = [:]
        var sourceSlots: [Int: Int] = [:]
        var unchanged = Set<Int>()
        var additions: [Int] = []
        for i in next.indices {
            let key = identity(next[i])
            let slot = consumed[key, default: 0]
            if let candidates = originals[key], candidates.indices.contains(slot) {
                let old = candidates[slot]
                sourceSlots[positions[old]] = i
                if PKDrawing(strokes: [next[i]]) == PKDrawing(strokes: [prior[old]]) { unchanged.insert(i) }
                consumed[key] = slot + 1
            } else { additions.append(i) }
        }

        let editable = Set(positions)
        var combined: [PKStroke] = []
        var relocated: [Int: Int] = [:]
        for i in world.indices {
            if let index = sourceSlots[i] {
                relocated[index] = combined.count
                combined.append(unchanged.contains(index) ? world[i] : inWorld[index])
            } else if !editable.contains(i) { combined.append(world[i]) }
        }
        for index in additions {
            relocated[index] = combined.count
            combined.append(inWorld[index])
        }
        world = combined
        positions = next.indices.compactMap { relocated[$0] }
        projectedDrawing = edited
        return PKDrawing(strokes: world)
    }

    private enum StrokeIdentity: Hashable { case id(UUID), seed(UInt32) }

    private func identity(_ stroke: PKStroke) -> StrokeIdentity {
        if #available(iOS 27, macCatalyst 27, *) { return .id(stroke.id) }
        return .seed(stroke.randomSeed)
    }
}

private final class BoardGrid: UIView {
    var camera: BoardCamera?

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let camera else { return }
        UIColor.white.setFill()
        context.fill(rect)
        var spacing: CGFloat = 24
        while spacing * camera.scale < 16 { spacing *= 2 }
        let screenStep = spacing * camera.scale
        let origin = camera.world(rect.origin)
        let x0 = camera.screen(CGPoint(x: floor(origin.x / spacing) * spacing, y: floor(origin.y / spacing) * spacing))
        context.setFillColor(UIColor(white: 0.81, alpha: 1).cgColor)
        for x in stride(from: x0.x, through: rect.maxX, by: screenStep) {
            for y in stride(from: x0.y, through: rect.maxY, by: screenStep) {
                context.fillEllipse(in: CGRect(x: x, y: y, width: 1.2, height: 1.2))
            }
        }
    }
}

private final class BoardInkPreview: UIView {
    var camera: BoardCamera?
    var strokes: [PKStroke] = []

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let camera else { return }
        let world = camera.visibleWorld
        context.setLineCap(.round)
        context.setLineJoin(.round)
        for stroke in strokes where stroke.renderBounds.intersects(world) {
            guard let first = stroke.path.first else { continue }
            let color = stroke.ink.color
            let point = camera.screen(first.location.applying(stroke.transform))
            let penWidth = max(0.7, min(60, first.size.width * hypot(stroke.transform.a, stroke.transform.b) * camera.scale))
            context.setStrokeColor(color.cgColor)
            context.setFillColor(color.cgColor)
            context.setLineWidth(penWidth)
            context.setAlpha(first.opacity)
            if stroke.path.count == 1 {
                context.fillEllipse(in: CGRect(x: point.x - penWidth / 2, y: point.y - penWidth / 2, width: penWidth, height: penWidth))
            } else {
                context.beginPath()
                context.move(to: point)
                var last = point
                for sample in stroke.path.dropFirst() {
                    let p = camera.screen(sample.location.applying(stroke.transform))
                    if hypot(p.x - last.x, p.y - last.y) > 0.65 { context.addLine(to: p); last = p }
                }
                if last == point {
                    context.fillEllipse(in: CGRect(x: point.x - penWidth / 2, y: point.y - penWidth / 2, width: penWidth, height: penWidth))
                } else { context.strokePath() }
            }
        }
    }
}
