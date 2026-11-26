import SwiftUI
import PencilKit
import PDFKit

enum WritingMagnifier {
    static func camera(center: CGPoint, size: CGSize, scale: CGFloat, page: CGSize?) -> BoardCamera {
        var center = center
        var scale = scale
        if let page, page.width > 0, page.height > 0 {
            scale = max(scale, size.width / page.width, size.height / page.height)
            let halfWidth = min(page.width, size.width / scale) / 2
            let halfHeight = min(page.height, size.height / scale) / 2
            center.x = min(page.width - halfWidth, max(halfWidth, center.x))
            center.y = min(page.height - halfHeight, max(halfHeight, center.y))
        }
        var camera = BoardCamera(center: center, size: size)
        camera.zoom(to: scale, holding: center, at: CGPoint(x: size.width / 2, y: size.height / 2))
        return camera
    }
}

struct WritingMagnifierView: View {
    let studio: Studio
    let paper: Paper
    let page: SheetPage
    let actions: SurfaceActions
    let target: CGPoint
    let tool: Instrument
    let color: UIColor
    let width: CGFloat
    var setTarget: (CGPoint) -> Void
    var close: () -> Void
    @State private var zoom: CGFloat = 2
    @State private var lineStart: CGFloat?
    @State private var lastNavigation: CGPoint?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 15) {
                Text("Writing magnifier").font(.subheadline.bold())
                Spacer(minLength: 4)
                Menu {
                    ForEach([CGFloat(1.5), 2, 3, 4], id: \.self) { level in
                        Button(level.formatted() + "×") { zoom = level }
                    }
                } label: {
                    Text(zoom.formatted() + "×").monospacedDigit()
                }.accessibilityLabel("Magnifier zoom")
                Button("Previous area", systemImage: "chevron.left") { advance(-1) }.labelStyle(.iconOnly)
                Button("Next area", systemImage: "chevron.right") { advance(1) }.labelStyle(.iconOnly)
                Button("Next line", systemImage: "return") {
                    let center = actions.writingLens?.camera?.center ?? target
                    navigate(CGPoint(x: lineStart ?? center.x, y: center.y + 32))
                }.labelStyle(.iconOnly)
                Button("Close magnifier", systemImage: "xmark.circle.fill", action: close).labelStyle(.iconOnly)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 43)
            Divider()
            WritingLens(studio: studio, paper: paper, page: page, actions: actions, target: target, zoom: zoom,
                        tool: tool, color: color, width: width)
                .frame(height: 155)
        }
        .background(.regularMaterial)
        .onChange(of: target) { _, point in
            if point != lastNavigation { lineStart = nil }
        }
    }

    private func advance(_ direction: CGFloat) {
        guard let camera = actions.writingLens?.camera else { return }
        if lineStart == nil { lineStart = camera.center.x }
        navigate(CGPoint(x: camera.center.x + camera.visibleWorld.width * 0.78 * direction, y: camera.center.y))
    }

    private func navigate(_ point: CGPoint) {
        lastNavigation = point
        setTarget(point)
    }
}

private struct WritingLens: UIViewRepresentable {
    let studio: Studio
    let paper: Paper
    let page: SheetPage
    let actions: SurfaceActions
    let target: CGPoint
    let zoom: CGFloat
    let tool: Instrument
    let color: UIColor
    let width: CGFloat

    func makeUIView(context: Context) -> WritingLensSurface {
        let pdf = page.pdfIndex.flatMap { studio.pdf(paper.id)?.page(at: $0) }
        return WritingLensSurface(page: page, kind: paper.kind, pdf: pdf, actions: actions)
    }

    func updateUIView(_ view: WritingLensSurface, context: Context) {
        actions.writingLens = view
        view.configure(item: page.canvas ?? CanvasContent(), assetURL: studio.assetURL,
                       target: target, zoom: zoom, tool: tool, color: color, width: width)
    }

    static func dismantleUIView(_ view: WritingLensSurface, coordinator: ()) {
        view.clearTarget()
    }
}

final class WritingLensSurface: UIView, PKCanvasViewDelegate {
    private weak var actions: SurfaceActions?
    private let backdrop: LensPaper
    private let overlay = CanvasOverlay()
    private let glow = GlowInkView()
    private let ink = PKCanvasView()
    private var target = CGPoint.zero
    private var zoom: CGFloat = 2
    private var inkWindow: BoardInkWindow?
    private var loadedDrawing: PKDrawing?
    private var presentingDrawing = false
    private var content = CanvasContent()
    private var assetURL: (CanvasAsset) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }
    private var style: (Instrument, UIColor, CGFloat)?
    private(set) var camera: BoardCamera?

    init(page: SheetPage, kind: PaperKind, pdf: PDFPage?, actions: SurfaceActions) {
        backdrop = LensPaper(page: page, kind: kind, pdf: pdf)
        self.actions = actions
        super.init(frame: .zero)
        overrideUserInterfaceStyle = .light
        clipsToBounds = true
        backdrop.isUserInteractionEnabled = false
        overlay.isUserInteractionEnabled = false
        ink.isScrollEnabled = false
        ink.isOpaque = false
        ink.backgroundColor = .clear
        ink.drawingPolicy = .anyInput
        ink.delegate = self
        ink.accessibilityLabel = "Magnified writing area"
        [backdrop, overlay, glow, ink].forEach(addSubview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(item: CanvasContent, assetURL: @escaping (CanvasAsset) -> URL, target: CGPoint,
                   zoom: CGFloat, tool: Instrument, color: UIColor, width: CGFloat) {
        self.target = target
        self.zoom = zoom
        self.content = item
        self.assetURL = assetURL
        let writingTool = tool.editsInk ? tool : .pen
        if style?.0 != writingTool || style?.1 != color || style?.2 != width {
            style = (writingTool, color, width)
            installTool()
        }
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [backdrop, overlay, glow, ink] { view.frame = bounds }
        refresh()
    }

    private func refresh() {
        guard bounds.width > 1, bounds.height > 1, let main = actions?.surface else { return }
        let pageSize = backdrop.kind == .whiteboard ? nil : backdrop.page.size
        let next = WritingMagnifier.camera(center: target, size: bounds.size, scale: zoom, page: pageSize)
        if camera != next {
            camera = next
            backdrop.camera = next
            glow.camera = next
            backdrop.setNeedsDisplay()
            main.inputLayer.writingArea = next.visibleWorld
            installTool()
            loadedDrawing = nil
        }
        overlay.update(content, camera: next, selected: nil, connecting: nil, assetURL: assetURL)
        ink.isUserInteractionEnabled = main.validInk
        reloadDrawing()
    }

    private func installTool() {
        guard let (tool, color, width) = style, let camera else { return }
        tool.configureInk(ink, color: color, width: width * camera.scale)
    }

    func reloadDrawing() {
        guard let camera, let drawing = actions?.surface?.currentDrawing, loadedDrawing != drawing else { return }
        let projection = BoardInkWindow(drawing: drawing, camera: camera)
        loadedDrawing = drawing
        glow.strokes = GlowInk.strokes(in: drawing)
        inkWindow = projection
        presentingDrawing = true
        ink.drawing = projection.projectedDrawing
        presentingDrawing = false
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !presentingDrawing, let main = actions?.surface, main.validInk, var projection = inkWindow,
              canvasView.drawing != projection.projectedDrawing else { return }
        let changed = projection.merge(canvasView.drawing)
        inkWindow = projection
        loadedDrawing = changed
        glow.strokes = GlowInk.strokes(in: changed)
        main.applyMagnifiedDrawing(changed)
    }

    func clearTarget() { actions?.surface?.inputLayer.writingArea = nil }
}

private final class LensPaper: UIView {
    let page: SheetPage
    let kind: PaperKind
    let pdf: PDFPage?
    var camera: BoardCamera?

    init(page: SheetPage, kind: PaperKind, pdf: PDFPage?) {
        self.page = page
        self.kind = kind
        self.pdf = pdf
        super.init(frame: .zero)
        backgroundColor = .white
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let camera else { return }
        context.concatenate(camera.projection)
        SheetRenderer.background(context, page: page, kind: kind, pdf: pdf)
    }
}
