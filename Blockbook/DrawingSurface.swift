import SwiftUI
import PencilKit
import PDFKit

enum Instrument: String, CaseIterable {
    case pen, glowPen, marker, eraser, select, pan, capture, motion, laser, objects, writingTarget

    var editsInk: Bool { [.pen, .glowPen, .marker, .eraser, .select].contains(self) }

    var symbol: String {
        switch self {
        case .pen: "pencil.tip"
        case .glowPen: "sparkles"
        case .marker: "highlighter"
        case .eraser: "eraser"
        case .select: "lasso"
        case .pan: "hand.draw"
        case .capture: "viewfinder"
        case .motion: "wand.and.stars"
        case .laser: "scope"
        case .objects: "cursorarrow"
        case .writingTarget: "scope"
        }
    }

    func configureInk(_ ink: PKCanvasView, color: UIColor, width: CGFloat) {
        (ink as? CloudInkCanvas)?.configureCloud(self == .glowPen ? color : nil, width: width)
        switch self {
        case .pen: ink.tool = PKInkingTool(.pen, color: color, width: max(0.5, width))
        case .glowPen: ink.tool = PKInkingTool(.pen, color: GlowInk.color(color), width: max(0.9, width))
        case .marker: ink.tool = PKInkingTool(.marker, color: color.withAlphaComponent(0.43), width: max(1, width * 4))
        case .eraser: ink.tool = PKEraserTool(.vector)
        case .select: ink.tool = PKLassoTool()
        default: break
        }
    }
}

@MainActor protocol CanvasSurface: AnyObject {
    var worldCenter: CGPoint { get }
    var validInk: Bool { get set }
    var currentDrawing: PKDrawing { get }
    var changed: (PKDrawing) -> Void { get set }
    var inputLayer: DrawingInteractions { get }
    func showVisual(_ visual:TeachingVisual?,folder:URL)
    func configure(_ tool: Instrument, color: UIColor, width: CGFloat)
    func updateContent(_ content: CanvasContent, selected: UUID?, connecting: UUID?, assetURL: @escaping (CanvasAsset) -> URL)
    func undoInk()
    func redoInk()
    func fit()
    func zoom(by factor: CGFloat)
    func reveal(_ point: CGPoint)
    func viewportPosition(_ point: CGPoint) -> CGPoint
    func applyMagnifiedDrawing(_ drawing: PKDrawing)
}

@MainActor final class SurfaceActions: ObservableObject {
    weak var surface: (any CanvasSurface)?
    weak var writingLens: WritingLensSurface?
    func undo() { surface?.undoInk(); writingLens?.reloadDrawing() }
    func redo() { surface?.redoInk(); writingLens?.reloadDrawing() }
    func fit() { surface?.fit() }
    func zoom(_ factor: CGFloat) { surface?.zoom(by: factor) }
    func reveal(_ point: CGPoint) { surface?.reveal(point) }
    var center: CGPoint? { surface?.worldCenter }
}

private final class PaperBackground: UIView {
    var page: SheetPage!
    var kind = PaperKind.notebook
    var pdf: PDFPage?

    override func draw(_ rect: CGRect) {
        if let ctx = UIGraphicsGetCurrentContext(), let page { SheetRenderer.background(ctx, page: page, kind: kind, pdf: pdf) }
    }
}

final class SheetSurface: UIScrollView, UIScrollViewDelegate, PKCanvasViewDelegate, CanvasSurface {
    let ink = CloudInkCanvas()
    let inputLayer = DrawingInteractions()
    private let pageID: UUID
    private let playback=VisualPlayback()
    private let sheet = UIView()
    private let overlay = CanvasOverlay()
    private let glow = GlowInkView()
    private var firstLayout = true
    private var inkStyle: (Instrument, UIColor, CGFloat)?
    private var replacingDrawing = false
    var changed: (PKDrawing) -> Void = { _ in }
    var validInk = true
    var currentDrawing: PKDrawing { ink.drawing }

    init(page: SheetPage, kind: PaperKind, pdf: PDFPage?, drawing: PKDrawing) {
        pageID=page.id
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .light
        backgroundColor = UIColor(red: 0.90, green: 0.90, blue: 0.88, alpha: 1)
        delegate = self
        contentInsetAdjustmentBehavior = .never
        sheet.frame = CGRect(origin: .zero, size: page.size)
        addSubview(sheet)
        contentSize = page.size
        let background = PaperBackground(frame: sheet.bounds)
        background.page = page
        background.kind = kind
        background.pdf = pdf
        sheet.addSubview(background)

        overlay.frame = sheet.bounds
        overlay.isUserInteractionEnabled = false
        sheet.addSubview(overlay)
        glow.frame = sheet.bounds
        glow.strokes = GlowInk.strokes(in: drawing)
        sheet.addSubview(glow)
        ink.frame = sheet.bounds
        ink.isScrollEnabled = false
        ink.isOpaque = false
        ink.backgroundColor = .clear
        ink.drawingPolicy = .anyInput
        ink.drawing = drawing
        sheet.addSubview(ink)
        sheet.addSubview(playback)
        ink.delegate = self
        inputLayer.frame = sheet.bounds
        inputLayer.hitItem = { [weak self] point in self?.overlay.item(at: point) }
        inputLayer.hitWriting = { [weak self] point in
            guard let self else { return nil }
            return InkContextAnchor.item(at: point, in: self.currentDrawing, tolerance: min(24, 9 / max(self.zoomScale, 0.1)))
        }
        inputLayer.viewportPosition = { [weak self] point in self?.viewportPosition(point) ?? point }
        inputLayer.previewMove = { [weak self] id, rect in self?.overlay.move(id, to: rect) }
        inputLayer.limit = sheet.bounds
        sheet.addSubview(inputLayer)
        maximumZoomScale = 6
        accessibilityLabel = "Writing canvas"
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(_ tool: Instrument, color: UIColor, width: CGFloat) {
        ink.isUserInteractionEnabled = validInk && tool.editsInk
        inputLayer.instrument = tool
        panGestureRecognizer.minimumNumberOfTouches = tool == .pan ? 1 : 2
        if let (prior, tint, size) = inkStyle, prior == tool, tint == color, size == width { return }
        inkStyle = (tool, color, width)
        tool.configureInk(ink, color: color, width: width)
    }

    func showVisual(_ visual:TeachingVisual?,folder:URL) { playback.configure(visual,folder:folder); playback.place { $0 } }

    func updateContent(_ content: CanvasContent, selected: UUID?, connecting: UUID?, assetURL: @escaping (CanvasAsset) -> URL) {
        inputLayer.connecting = connecting != nil
        overlay.update(content, selected: selected, connecting: connecting, assetURL: assetURL)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 10, bounds.height > 10 else { return }
        minimumZoomScale = min(fitScale, 1)
        if firstLayout {
            firstLayout=false
            if let saved=UserDefaults.standard.array(forKey:"camera."+pageID.uuidString) as? [Double],saved.count==3 {
                position(at:CGPoint(x:saved[0],y:saved[1]),scale:saved[2])
            } else { fit() }
        }
        centerSheet()
    }

    private var fitScale: CGFloat {
        max(0.05, min((bounds.width - 30) / max(sheet.bounds.width, 1), (bounds.height - 30) / max(sheet.bounds.height, 1)))
    }

    var worldCenter: CGPoint { sheet.convert(CGPoint(x: bounds.midX, y: bounds.midY), from: self) }

    func viewportPosition(_ point: CGPoint) -> CGPoint {
        let converted = sheet.convert(point, to: self)
        return CGPoint(x: converted.x - bounds.minX, y: converted.y - bounds.minY)
    }

    func fit() {
        setZoomScale(min(maximumZoomScale, fitScale), animated: false)
        centerSheet()
        setContentOffset(CGPoint(x: -contentInset.left, y: -contentInset.top), animated: false)
    }

    private func remember() { if !firstLayout { UserDefaults.standard.set([worldCenter.x,worldCenter.y,zoomScale],forKey:"camera."+pageID.uuidString) } }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) { if !decelerate { remember() } }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { remember() }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view:UIView?, atScale scale:CGFloat) { remember() }
    func zoom(by factor: CGFloat) { position(at: worldCenter, scale: zoomScale * factor) }
    func reveal(_ point: CGPoint) { position(at: point, scale: max(0.45, zoomScale)) }

    private func position(at point: CGPoint, scale: CGFloat) {
        let target = min(maximumZoomScale, max(minimumZoomScale, scale))
        setZoomScale(target, animated: false)
        centerSheet()
        let x = max(-contentInset.left, min(contentSize.width - bounds.width + contentInset.right, point.x * target - bounds.width / 2))
        let y = max(-contentInset.top, min(contentSize.height - bounds.height + contentInset.bottom, point.y * target - bounds.height / 2))
        setContentOffset(CGPoint(x: x, y: y), animated: false)
        remember()
    }

    private func centerSheet() {
        let x = max(0, (bounds.width - contentSize.width) / 2), y = max(0, (bounds.height - contentSize.height) / 2)
        let inset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
        if inset != contentInset { contentInset = inset }
        inputLayer.displayScale = zoomScale
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { sheet }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerSheet() }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        glow.strokes = GlowInk.strokes(in: canvasView.drawing)
        if validInk && !replacingDrawing { changed(canvasView.drawing) }
    }
    func applyMagnifiedDrawing(_ drawing: PKDrawing) {
        guard validInk, drawing != ink.drawing else { return }
        let old = ink.drawing
        ink.undoManager?.registerUndo(withTarget: self) { $0.applyMagnifiedDrawing(old) }
        replacingDrawing = true
        ink.drawing = drawing
        glow.strokes = GlowInk.strokes(in: drawing)
        replacingDrawing = false
        changed(drawing)
    }
    func undoInk() { ink.undoManager?.undo() }
    func redoInk() { ink.undoManager?.redo() }
}

final class DrawingInteractions: UIView, UIContextMenuInteractionDelegate {
    private let outline = CAShapeLayer()
    private let writingOutline = CAShapeLayer()
    private var initial = CGPoint.zero
    private var moving: CanvasItem?
    private var pendingContext: (CanvasItem, CanvasContextMode, CGPoint)?
    private var lassoPoints: [CGPoint]=[]
    var lasso: ([CGPoint])->Void = { _ in }
    var captured: (CGRect) -> Void = { _ in }
    var itemTapped: (UUID?) -> Void = { _ in }
    var itemMoved: (UUID, CGRect) -> Void = { _, _ in }
    var hitItem: (CGPoint) -> CanvasItem? = { _ in nil }
    var hitWriting: (CGPoint) -> CanvasItem? = { _ in nil }
    var previewMove: (UUID, CGRect) -> Void = { _, _ in }
    var worldPoint: (CGPoint) -> CGPoint = { $0 }
    var localPoint: (CGPoint) -> CGPoint = { $0 }
    var writingArea: CGRect? { didSet { refreshWritingOutline() } }
    var aimWriting: (CGPoint) -> Void = { _ in }
    var viewportPosition: (CGPoint) -> CGPoint = { $0 }
    var openContext: (CanvasItem, CanvasContextMode, CGPoint) -> Void = { _, _, _ in }
    var limit: CGRect?
    var displayScale: CGFloat = 1 { didSet { refreshWritingOutline() } }
    var connecting = false
    var instrument = Instrument.pen {
        didSet { isUserInteractionEnabled = [.capture, .motion, .laser, .objects, .writingTarget].contains(instrument) }
    }

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(outline)
        layer.addSublayer(writingOutline)
        let drag = UIPanGestureRecognizer(target: self, action: #selector(trace(_:)))
        drag.minimumNumberOfTouches = 1
        drag.maximumNumberOfTouches = 1
        addGestureRecognizer(drag)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(point(_:))))
        addInteraction(UIContextMenuInteraction(delegate: self))
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func point(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        if instrument == .objects {
            let world = worldPoint(point)
            let item = hitItem(world)
            let wasConnecting = connecting
            itemTapped(item?.id)
            if !wasConnecting {
                if let item, item.kind == .text || item.kind == .inkContext || item.hasPopOut {
                    openContext(item, .read, viewportPosition(world))
                } else if item == nil, let writing = hitWriting(world) {
                    openContext(writing, .read, viewportPosition(world))
                }
            }
        }
        if instrument == .laser { laser(at: point); fadeLaser() }
        if instrument == .writingTarget { aimWriting(worldPoint(point)) }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard instrument == .objects, !connecting else { return nil }
        let world = worldPoint(location)
        guard let item = hitItem(world) ?? hitWriting(world) else { return nil }
        let anchor = viewportPosition(world)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            func action(_ title: String, symbol: String, mode: CanvasContextMode) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: symbol)) { _ in self?.pendingContext = (item, mode, anchor) }
            }
            return UIMenu(children: [
                action("Open context", symbol: "text.bubble", mode: .read),
                action(item.audioNote == nil ? "Add audio note" : "Edit audio note", symbol: "waveform", mode: .audio),
                action(item.link == nil ? "Add link" : "Edit link", symbol: "link", mode: .link),
                action(item.markdown.isEmpty ? "Add context" : "Edit context", symbol: "note.text", mode: .notes)
            ])
        }
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, willEndFor configuration: UIContextMenuConfiguration,
                                animator: (any UIContextMenuInteractionAnimating)?) {
        let show = { [weak self] in
            guard let self, let (item, mode, anchor) = self.pendingContext else { return }
            self.pendingContext = nil
            self.openContext(item, mode, anchor)
        }
        if let animator { animator.addCompletion(show) }
        else { DispatchQueue.main.async(execute: show) }
    }

    func refreshWritingOutline() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let area = writingArea else { writingOutline.path = nil; return }
        let first = localPoint(area.origin)
        let last = localPoint(CGPoint(x: area.maxX, y: area.maxY))
        let rect = enclosing(first, last)
        let minimumSide = 12 / displayScale
        let target = CGRect(x: rect.midX - max(rect.width, minimumSide) / 2,
                            y: rect.midY - max(rect.height, minimumSide) / 2,
                            width: max(rect.width, minimumSide), height: max(rect.height, minimumSide))
        writingOutline.path = UIBezierPath(roundedRect: target, cornerRadius: 3 / displayScale).cgPath
        writingOutline.strokeColor = UIColor.systemBlue.cgColor
        writingOutline.fillColor = UIColor.systemBlue.withAlphaComponent(0.09).cgColor
        writingOutline.lineWidth = 1.7 / displayScale
    }

    private func laser(at point: CGPoint) {
        outline.removeAllAnimations()
        outline.opacity = 1
        let radius = 8 / displayScale
        outline.fillColor = UIColor.systemRed.cgColor
        outline.strokeColor = UIColor.white.cgColor
        outline.lineWidth = 2 / displayScale
        outline.lineDashPattern = nil
        outline.path = UIBezierPath(ovalIn: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius)).cgPath
    }

    private func fadeLaser() {
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0
        animation.duration = 0.55
        outline.add(animation, forKey: "fade")
        outline.opacity = 0
    }

    @objc private func trace(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self)
        if instrument == .objects { dragItem(gesture, point: point); return }
        if instrument == .laser {
            laser(at: point)
            if gesture.state == .ended || gesture.state == .cancelled { fadeLaser() }
            return
        }
        if instrument == .motion {
            if gesture.state == .began { lassoPoints=[];outline.opacity=1;outline.strokeColor=UIColor.systemIndigo.cgColor;outline.fillColor=UIColor.systemIndigo.withAlphaComponent(0.12).cgColor;outline.lineWidth=2/displayScale }
            lassoPoints.append(point)
            let path=UIBezierPath()
            if let first=lassoPoints.first { path.move(to:first);lassoPoints.dropFirst().forEach { path.addLine(to:$0) };path.close() }
            outline.path=path.cgPath
            if gesture.state == .ended || gesture.state == .cancelled { outline.path=nil;if gesture.state == .ended { lasso(lassoPoints.map(worldPoint)) };lassoPoints=[] }
            return
        }
        guard instrument == .capture else { return }
        if gesture.state == .began {
            let delta = gesture.translation(in: self)
            initial = CGPoint(x: point.x - delta.x, y: point.y - delta.y)
        }
        let rect = enclosing(initial, point).intersection(bounds)
        if gesture.state == .ended || gesture.state == .cancelled {
            outline.path = nil
            if gesture.state == .ended, rect.width * displayScale > 8, rect.height * displayScale > 8 {
                captured(enclosing(worldPoint(rect.origin), worldPoint(CGPoint(x: rect.maxX, y: rect.maxY))))
            }
        } else if !rect.isEmpty {
            outline.opacity = 1
            outline.strokeColor = UIColor.systemBlue.cgColor
            outline.lineWidth = 2 / displayScale
            outline.fillColor = UIColor.systemBlue.withAlphaComponent(0.12).cgColor
            outline.lineDashPattern = [5, 3]
            outline.path = UIBezierPath(rect: rect).cgPath
        }
    }

    private func dragItem(_ gesture: UIPanGestureRecognizer, point: CGPoint) {
        guard !connecting else { return }
        let delta = gesture.translation(in: self)
        if gesture.state == .began {
            initial = worldPoint(CGPoint(x: point.x - delta.x, y: point.y - delta.y))
            moving = hitItem(initial)
            if moving?.kind == .inkContext { moving = nil }
        }
        guard let item = moving else { return }
        let world = worldPoint(point)
        var target = item.frame.offsetBy(dx: world.x - initial.x, dy: world.y - initial.y)
        if let limit {
            target.origin.x = max(limit.minX, min(target.minX, limit.maxX - target.width))
            target.origin.y = max(limit.minY, min(target.minY, limit.maxY - target.height))
        }
        switch gesture.state {
        case .began, .changed: previewMove(item.id, target)
        case .ended:
            moving = nil
            previewMove(item.id, item.frame)
            itemMoved(item.id, target)
            itemTapped(item.id)
        case .cancelled, .failed:
            moving = nil
            previewMove(item.id, item.frame)
        default: break
        }
    }

    private func enclosing(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }
}

struct DrawingSurface: UIViewRepresentable {
    @ObservedObject var studio: Studio
    let paper: Paper
    let page: SheetPage
    let tool: Instrument
    let color: UIColor
    let width: CGFloat
    let actions: SurfaceActions
    var selected: UUID?
    var connecting: UUID?
    var aimWriting: (CGPoint) -> Void = { _ in }
    var openContext: (CanvasItem, CanvasContextMode, CGPoint) -> Void = { _, _, _ in }
    var selectItem: (UUID?) -> Void = { _ in }
    var moveItem: (UUID, CGRect) -> Void = { _, _ in }
    var visual: TeachingVisual?
    var lasso: ([CGPoint])->Void = { _ in }
    var capture: (CGRect) -> Void

    func makeUIView(context: Context) -> UIView {
        let drawing = Result { try studio.drawing(page.id) }
        let ink = (try? drawing.get()) ?? PKDrawing()
        let view: UIView & CanvasSurface
        if paper.kind == .whiteboard {
            view = BoardSurface(page: page, drawing: ink)
        } else {
            let pdf = page.pdfIndex.flatMap { studio.pdf(paper.id)?.page(at: $0) }
            view = SheetSurface(page: page, kind: paper.kind, pdf: pdf, drawing: ink)
        }
        if case let .failure(error) = drawing {
            view.validInk = false
            DispatchQueue.main.async { studio.issue = "This drawing could not be read. " + error.localizedDescription }
        }
        view.changed = { studio.saveInk($0, paperID: paper.id, pageID: page.id) }
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        guard let surface = view as? any CanvasSurface else { return }
        actions.surface = surface
        surface.inputLayer.captured = capture
        surface.inputLayer.lasso=lasso
        surface.showVisual(visual,folder:studio.assetFolder)
        surface.inputLayer.itemTapped = selectItem
        surface.inputLayer.itemMoved = moveItem
        surface.inputLayer.aimWriting = aimWriting
        surface.inputLayer.openContext = openContext
        surface.updateContent(page.canvas ?? CanvasContent(), selected: selected, connecting: connecting, assetURL: studio.assetURL)
        surface.configure(tool, color: color, width: width)
    }
}

enum CanvasGeometry {
    static func bounds(ink: PKDrawing, canvas: CanvasContent) -> CGRect {
        canvas.items.reduce(ink.strokes.isEmpty ? .null : ink.bounds) { $0.union($1.frame) }
    }
}
