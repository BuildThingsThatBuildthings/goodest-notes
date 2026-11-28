import UIKit

extension CanvasTint {
    var color: UIColor {
        switch self {
        case .indigo: UIColor(red: 0.26, green: 0.30, blue: 0.62, alpha: 1)
        case .blue: UIColor(red: 0.10, green: 0.42, blue: 0.68, alpha: 1)
        case .green: UIColor(red: 0.14, green: 0.48, blue: 0.34, alpha: 1)
        case .orange: UIColor(red: 0.66, green: 0.34, blue: 0.10, alpha: 1)
        case .rose: UIColor(red: 0.65, green: 0.23, blue: 0.40, alpha: 1)
        case .slate: UIColor(red: 0.29, green: 0.35, blue: 0.44, alpha: 1)
        }
    }

    var halo: UIColor {
        switch self {
        case .indigo: UIColor(red: 0.59, green: 0.50, blue: 1, alpha: 1)
        case .blue: UIColor(red: 0.23, green: 0.83, blue: 1, alpha: 1)
        case .green: UIColor(red: 0.27, green: 0.97, blue: 0.56, alpha: 1)
        case .orange: UIColor(red: 1, green: 0.72, blue: 0.22, alpha: 1)
        case .rose: UIColor(red: 1, green: 0.43, blue: 0.67, alpha: 1)
        case .slate: UIColor(red: 0.62, green: 0.77, blue: 1, alpha: 1)
        }
    }
}

extension CanvasItem {
    var titleAttributes: [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: kind == .text ? 29 : 16, weight: kind == .text || glow == true ? .bold : .semibold),
            .foregroundColor: kind == .text || glow == true ? tint.color : UIColor(red: 0.11, green: 0.15, blue: 0.24, alpha: 1)
        ]
        if glow == true {
            let shadow = NSShadow()
            shadow.shadowColor = tint.halo.withAlphaComponent(0.70)
            shadow.shadowOffset = .zero
            shadow.shadowBlurRadius = kind == .text ? 3.5 : 2.5
            attributes[.shadow] = shadow
        }
        return attributes
    }
}

final class CanvasOverlay: UIView {
    private var cards: [UUID: CanvasCard] = [:]
    private var lines: [UUID: CanvasLine] = [:]
    private var content = CanvasContent()
    private var camera: BoardCamera?
    private var selected: UUID?
    private var connecting: UUID?
    private var assetURL: (CanvasAsset) -> URL = { _ in URL(fileURLWithPath: "/dev/null") }

    func update(_ content: CanvasContent, camera: BoardCamera? = nil, selected: UUID?, connecting: UUID?, assetURL: @escaping (CanvasAsset) -> URL) {
        guard self.content != content || self.camera != camera || self.selected != selected || self.connecting != connecting else { return }
        self.content = content
        self.camera = camera
        self.selected = selected
        self.connecting = connecting
        self.assetURL = assetURL
        render()
    }

    func item(at worldPoint: CGPoint, tolerance: CGFloat = 0) -> CanvasItem? {
        content.items.last { $0.frame.insetBy(dx: -tolerance, dy: -tolerance).contains(worldPoint) }
    }

    func move(_ id: UUID, to frame: CGRect) {
        guard let idx = content.items.firstIndex(where: { $0.id == id }) else { return }
        content.items[idx].frame = frame
        render()
    }

    private func render() {
        let byID = Dictionary(content.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let visible = camera?.visibleWorld.insetBy(dx: -12 / (camera?.scale ?? 1), dy: -12 / (camera?.scale ?? 1))
        let items = content.items.filter { item in visible?.intersects(item.frame) ?? true }
        let visibleIDs = Set(items.map(\.id))
        for id in Array(cards.keys) where !visibleIDs.contains(id) { cards.removeValue(forKey: id)?.removeFromSuperview() }
        var renderedConnections = Set<UUID>()
        let viewport = camera.map { CGRect(origin: .zero, size: $0.size).insetBy(dx: -16, dy: -16) }
        let scale = camera?.scale ?? 1
        for edge in content.connections {
            guard let from = byID[edge.from], let to = byID[edge.to] else {
                continue
            }
            let line = lines[edge.id] ?? CanvasLine()
            let start = CanvasLine.edge(of: from.frame, toward: CGPoint(x: to.frame.midX, y: to.frame.midY))
            let end = CanvasLine.edge(of: to.frame, toward: CGPoint(x: from.frame.midX, y: from.frame.midY))
            let a = screen(start), b = screen(end)
            let segment: CanvasSegment
            if let viewport {
                guard let visible = CanvasSegment(start: a, end: b).clipped(to: viewport) else { continue }
                segment = visible
            } else { segment = CanvasSegment(start: a, end: b) }
            let center = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let label = scale >= 0.34 && (viewport?.contains(center) ?? true) ? edge.label : ""
            line.update(from: segment.start, to: segment.end, label: label, arrow: viewport?.contains(b) ?? true, scale: scale)
            if lines[edge.id] == nil { lines[edge.id] = line; insertSubview(line, at: 0) }
            renderedConnections.insert(edge.id)
        }
        for id in Array(lines.keys) where !renderedConnections.contains(id) { lines.removeValue(forKey: id)?.removeFromSuperview() }
        for item in items {
            let card = cards[item.id] ?? CanvasCard()
            let compact = scale < 0.28
            card.bounds.size = compact ? CGSize(width: max(5, item.frame.width * scale), height: max(5, item.frame.height * scale)) : item.frame.size
            card.center = screen(CGPoint(x: item.frame.midX, y: item.frame.midY))
            let renderScale = compact ? 1 : scale
            card.transform = CGAffineTransform(scaleX: renderScale, y: renderScale)
            card.update(item, selected: item.id == selected || item.id == connecting, compact: compact, assetURL: assetURL)
            if cards[item.id] == nil { cards[item.id] = card; addSubview(card) }
        }
    }

    private func screen(_ point: CGPoint) -> CGPoint { camera?.screen(point) ?? point }
}

struct CanvasSegment {
    var start: CGPoint
    var end: CGPoint

    func clipped(to rect: CGRect) -> Self? {
        let dx = end.x - start.x, dy = end.y - start.y
        var lo: CGFloat = 0, hi: CGFloat = 1
        for (delta, distance) in [(-dx, start.x - rect.minX), (dx, rect.maxX - start.x), (-dy, start.y - rect.minY), (dy, rect.maxY - start.y)] {
            if delta == 0 {
                if distance < 0 { return nil }
            } else if delta < 0 { lo = max(lo, distance / delta) }
            else { hi = min(hi, distance / delta) }
            if lo > hi { return nil }
        }
        return Self(start: CGPoint(x: start.x + lo * dx, y: start.y + lo * dy), end: CGPoint(x: start.x + hi * dx, y: start.y + hi * dy))
    }
}

final class CanvasLine: UIView {
    private let pathLayer = CAShapeLayer()
    private let caption = UILabel()

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        layer.addSublayer(pathLayer)
        pathLayer.strokeColor = UIColor(red: 0.30, green: 0.35, blue: 0.47, alpha: 1).cgColor
        pathLayer.fillColor = UIColor.clear.cgColor
        pathLayer.lineWidth = 2.5
        pathLayer.lineCap = .round
        caption.font = .systemFont(ofSize: 12, weight: .medium)
        caption.textColor = .darkGray
        caption.backgroundColor = .white
        caption.textAlignment = .center
        caption.layer.cornerRadius = 5
        caption.clipsToBounds = true
        addSubview(caption)
    }

    required init?(coder: NSCoder) { fatalError() }

    static func edge(of rect: CGRect, toward point: CGPoint) -> CGPoint {
        let dx = point.x - rect.midX, dy = point.y - rect.midY
        let factor = max(abs(dx) / max(rect.width / 2, 1), abs(dy) / max(rect.height / 2, 1))
        guard factor > 0 else { return CGPoint(x: rect.midX, y: rect.midY) }
        return CGPoint(x: rect.midX + dx / factor, y: rect.midY + dy / factor)
    }

    func update(from: CGPoint, to: CGPoint, label: String, arrow: Bool = true, scale: CGFloat = 1) {
        let left = min(from.x, to.x), top = min(from.y, to.y)
        frame = CGRect(x: left, y: top, width: abs(from.x - to.x) + 1, height: abs(from.y - to.y) + 1).insetBy(dx: -14, dy: -14)
        let p = CGPoint(x: from.x - frame.minX, y: from.y - frame.minY)
        let q = CGPoint(x: to.x - frame.minX, y: to.y - frame.minY)
        let path = UIBezierPath()
        path.move(to: p); path.addLine(to: q)
        let angle = atan2(q.y - p.y, q.x - p.x)
        if arrow {
            let length = max(4, min(16, 10 * scale))
            for delta in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                path.move(to: q)
                path.addLine(to: CGPoint(x: q.x - length * cos(angle + delta), y: q.y - length * sin(angle + delta)))
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pathLayer.lineWidth = max(0.85, min(5, 2.5 * scale))
        pathLayer.path = path.cgPath
        CATransaction.commit()
        caption.text = label
        caption.isHidden = label.isEmpty
        let width = min(200, caption.sizeThatFits(CGSize(width: 200, height: 22)).width + 14)
        caption.frame = CGRect(x: (p.x + q.x - width) / 2, y: (p.y + q.y) / 2 - 9, width: width, height: 18)
    }
}

private final class CanvasCard: UIView {
    private let shape = CAShapeLayer()
    private let title = UILabel()
    private let detail = UILabel()
    private let image = UIImageView()
    private let badge = UIImageView()
    private let contextBadge = UIImageView(image: UIImage(systemName: "paperclip.circle.fill"))
    private var item: CanvasItem?
    private var selected = false
    private var compact = false
    private var imageJob: Task<Void, Never>?

    override init(frame: CGRect = .zero) {
        super.init(frame: frame)
        layer.addSublayer(shape)
        title.font = .systemFont(ofSize: 16, weight: .semibold)
        title.textColor = UIColor(red: 0.11, green: 0.15, blue: 0.24, alpha: 1)
        title.numberOfLines = 2
        detail.textColor = UIColor(red: 0.24, green: 0.29, blue: 0.37, alpha: 1)
        detail.numberOfLines = 0
        badge.contentMode = .scaleAspectFit
        image.contentMode = .scaleAspectFill
        image.clipsToBounds = true
        image.layer.cornerRadius = 7
        contextBadge.contentMode = .scaleAspectFit
        [image, badge, title, detail, contextBadge].forEach(addSubview)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { imageJob?.cancel() }

    func update(_ item: CanvasItem, selected: Bool, compact: Bool, assetURL: (CanvasAsset) -> URL) {
        guard self.item != item || self.selected != selected || self.compact != compact else { return }
        if self.item?.asset != item.asset || self.compact != compact {
            imageJob?.cancel()
            image.image = nil
            if !compact, let asset = item.asset, asset.kind == .image {
                let url = assetURL(asset)
                imageJob = Task { [weak self] in
                    let loaded = await Task.detached { CanvasImages.thumbnail(at: url) }.value
                    if !Task.isCancelled { self?.image.image = loaded; self?.setNeedsLayout() }
                }
            }
        }
        self.item = item
        self.selected = selected
        self.compact = compact
        let label=NSMutableAttributedString(string:item.title,attributes:item.titleAttributes)
        if let author=item.agentAuthor {
            label.append(NSAttributedString(string:"  · "+displayModel(author),attributes:[.font:UIFont.systemFont(ofSize:11,weight:.medium),.foregroundColor:UIColor.secondaryLabel]))
        }
        title.attributedText=label
        title.adjustsFontSizeToFitWidth = item.kind == .text
        title.minimumScaleFactor = 0.45
        if !item.markdown.isEmpty, let formatted = try? AttributedString(markdown: item.markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            let text = NSMutableAttributedString(attributedString: NSAttributedString(formatted))
            text.addAttribute(.font, value: UIFont.systemFont(ofSize: 13), range: NSRange(location: 0, length: text.length))
            detail.attributedText = text
        } else {
            detail.font = .systemFont(ofSize: 13)
            detail.text = item.link ?? item.asset?.filename ?? item.markdown
        }
        badge.image = UIImage(systemName: item.kind.icon)
        badge.tintColor = item.tint.color
        contextBadge.tintColor = item.tint.color
        accessibilityLabel = "\(item.kind.label), \(item.title)" + (item.hasPopOut ? ", has context" : "")
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let item else { return }
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path: UIBezierPath
        let diagram = [.rectangle, .ellipse, .diamond].contains(item.kind)
        switch item.kind {
        case .ellipse: path = UIBezierPath(ovalIn: rect)
        case .diamond:
            path = UIBezierPath()
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
            path.close()
        default: path = UIBezierPath(roundedRect: rect, cornerRadius: 11)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.path = path.cgPath
        let text = item.kind == .text
        let ink = item.kind == .inkContext
        let fill = compact ? item.tint.color.withAlphaComponent(0.38) :
            text || ink ? UIColor.clear : diagram ? item.tint.color.withAlphaComponent(0.13) : UIColor(white: 1, alpha: 0.97)
        shape.fillColor = fill.cgColor
        shape.strokeColor = item.tint.color.withAlphaComponent(selected ? 1 : (text || ink) && !compact ? 0 : 0.48).cgColor
        shape.lineWidth = compact ? (selected ? 2 : 0.85) : (selected ? 3 : 1.5)
        CATransaction.commit()

        title.isHidden = compact || ink
        badge.isHidden = diagram || compact || text || ink
        image.isHidden = compact || image.image == nil
        contextBadge.isHidden = compact || !item.hasPopOut
        contextBadge.frame = CGRect(x: max(1, bounds.width - 19), y: 1, width: 17, height: 17)
        if compact { detail.isHidden = true; return }
        if ink { detail.isHidden = true }
        else if text {
            title.textAlignment = .left
            title.frame = CGRect(x: 9, y: 4, width: max(1, bounds.width - (item.hasPopOut ? 29 : 18)), height: max(1, bounds.height - 8))
            detail.isHidden = true
        } else if diagram {
            title.textAlignment = .center
            title.frame = CGRect(x: bounds.width * 0.19, y: 0, width: bounds.width * 0.62, height: bounds.height)
            detail.isHidden = true
        } else {
            title.textAlignment = .left
            badge.frame = CGRect(x: 13, y: 12, width: 20, height: 20)
            title.frame = CGRect(x: 42, y: 7, width: max(0, bounds.width - 54), height: 31)
            image.frame = CGRect(x: 12, y: 42, width: max(0, bounds.width - 24), height: max(0, bounds.height - 54))
            detail.isHidden = !image.isHidden
            detail.frame = CGRect(x: 14, y: 39, width: max(0, bounds.width - 28), height: max(0, bounds.height - 49))
        }
    }
}
