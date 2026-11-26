import UIKit
import PencilKit
import PDFKit

enum SheetRenderer {
    static func image(rect: CGRect, paint: (CGContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = true
        format.scale = 1
        let scale = min(2, 2500 / max(rect.width, rect.height, 1))
        let size = CGSize(width: max(1, ceil(rect.width * scale)), height: max(1, ceil(rect.height * scale)))
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            UIColor.white.setFill()
            output.fill(CGRect(origin: .zero, size: size))
            output.cgContext.scaleBy(x: scale, y: scale)
            output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            paint(output.cgContext)
        }
    }

    static func background(_ ctx: CGContext, page: SheetPage, kind: PaperKind, pdf: PDFPage?) {
        let rect = CGRect(origin: .zero, size: page.size)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        if let pdf, let ref = pdf.pageRef {
            ctx.saveGState()
            ctx.translateBy(x: 0, y: rect.height)
            ctx.scaleBy(x: 1, y: -1)
            ctx.concatenate(ref.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            ctx.drawPDFPage(ref)
            for annotation in pdf.annotations where annotation.shouldDisplay { annotation.draw(with: .cropBox, in: ctx) }
            ctx.restoreGState()
        } else if kind == .notebook {
            ctx.setStrokeColor(UIColor(red: 0.82, green: 0.86, blue: 0.89, alpha: 1).cgColor)
            ctx.setLineWidth(0.65)
            for y in stride(from: 56.0, to: rect.height, by: 32) {
                ctx.move(to: CGPoint(x: 22, y: y)); ctx.addLine(to: CGPoint(x: rect.width-22, y: y))
            }
            ctx.strokePath()
        } else if kind == .whiteboard {
            grid(ctx, in: ctx.boundingBoxOfClipPath)
        }
    }

    static func grid(_ ctx: CGContext, in rect: CGRect) {
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fill(rect)
        let step = max(24, ceil(max(rect.width, rect.height) / 240 / 24) * 24)
        ctx.setFillColor(UIColor(white: 0.81, alpha: 1).cgColor)
        for x in stride(from: floor(rect.minX / step) * step, through: rect.maxX, by: step) {
            for y in stride(from: floor(rect.minY / step) * step, through: rect.maxY, by: step) {
                ctx.fillEllipse(in: CGRect(x: x, y: y, width: 1.7, height: 1.7))
            }
        }
    }

    @MainActor static func contentBounds(paper: Paper, page: SheetPage, drawing: PKDrawing) -> CGRect {
        let normal = CGRect(origin: .zero, size: page.size)
        guard paper.kind == .whiteboard else { return normal }
        let occupied = CanvasGeometry.bounds(ink: drawing, canvas: page.canvas ?? .init())
        return occupied.isNull ? normal : occupied.insetBy(dx: -40, dy: -40).integral
    }

    @MainActor static func snapshot(_ studio: Studio, paper: Paper, page: SheetPage, rect: CGRect) throws -> UIImage {
        let ink = try studio.drawing(page.id)
        let pdfPage = page.pdfIndex.flatMap { studio.pdf(paper.id)?.page(at: $0) }
        if page.pdfIndex != nil && pdfPage == nil { throw StudioError.invalidPage }
        return image(rect: rect) { ctx in
            background(ctx, page: page, kind: paper.kind, pdf: pdfPage)
            paintItems(studio, page: page, in: rect, context: ctx)
            GlowInk.paint(GlowInk.strokes(in: ink), in: ctx, visible: rect)
            let crop = ink.bounds.insetBy(dx: -3, dy: -3).intersection(rect)
            drawInk(ink, crop: crop, scale: min(2, 2500 / max(rect.width, rect.height)))
        }
    }

    @MainActor static func export(_ paper: Paper, from studio: Studio) throws -> URL {
        let file = try Conversion.temporaryFile(paper.title, ext: "pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: paper.pages[0].size))
        let drawings = try paper.pages.map { try studio.drawing($0.id) }
        let pdf = paper.kind == .pdf ? studio.pdf(paper.id) : nil
        if paper.kind == .pdf && pdf == nil { throw StudioError.invalidPage }
        try renderer.writePDF(to: file) { output in
            for (i, page) in paper.pages.enumerated() {
                autoreleasepool {
                    let ink = drawings[i], rect = contentBounds(paper: paper, page: page, drawing: ink)
                    let scale = min(1, 5000 / max(rect.width, rect.height))
                    output.beginPage(withBounds: CGRect(origin: .zero, size: CGSize(width: rect.width * scale, height: rect.height * scale)), pageInfo: [:])
                    output.cgContext.scaleBy(x: scale, y: scale)
                    output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                    background(output.cgContext, page: page, kind: paper.kind, pdf: page.pdfIndex.flatMap { pdf?.page(at: $0) })
                    paintItems(studio, page: page, in: rect, context: output.cgContext)
                    GlowInk.paint(GlowInk.strokes(in: ink), in: output.cgContext, visible: rect)
                    let crop = ink.bounds.insetBy(dx: -3, dy: -3).intersection(rect)
                    drawInk(ink, crop: crop, scale: min(2, 3000 / max(crop.width, crop.height)))
                }
                if !page.typed.isEmpty {
                    for chunk in page.typed.splitForPDF {
                        output.beginPage(withBounds: CGRect(x: 0, y: 0, width: 612, height: 792), pageInfo: [:])
                        let title = "Page \(i + 1) notes"
                        (title as NSString).draw(at: CGPoint(x: 42, y: 39), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 19)])
                        (chunk as NSString).draw(in: CGRect(x: 42, y: 82, width: 528, height: 660), withAttributes: [.font: UIFont.systemFont(ofSize: 13)])
                    }
                }
            }
        }
        return file
    }

    private static func drawInk(_ ink: PKDrawing, crop: CGRect, scale: CGFloat) {
        guard !ink.strokes.isEmpty, !crop.isEmpty, scale.isFinite,
              crop.width * scale >= 1, crop.height * scale >= 1 else { return }
        ink.image(from: crop, scale: scale).draw(in: crop)
    }

    @MainActor static func paintItems(_ studio: Studio, page: SheetPage, in rect: CGRect, context: CGContext) {
        guard let canvas = page.canvas else { return }
        let items = Dictionary(canvas.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: rect)
        context.setStrokeColor(CanvasTint.slate.color.cgColor)
        context.setLineWidth(2)
        for edge in canvas.connections {
            guard let a = items[edge.from]?.frame, let b = items[edge.to]?.frame else { continue }
            let start = CanvasLine.edge(of: a, toward: CGPoint(x: b.midX, y: b.midY))
            let end = CanvasLine.edge(of: b, toward: CGPoint(x: a.midX, y: a.midY))
            context.move(to: start)
            context.addLine(to: end)
            let angle = atan2(end.y - start.y, end.x - start.x)
            for arm in [-CGFloat.pi / 6, CGFloat.pi / 6] {
                context.move(to: end)
                context.addLine(to: CGPoint(x: end.x - 10 * cos(angle + arm), y: end.y - 10 * sin(angle + arm)))
            }
            context.strokePath()
            (edge.label as NSString).draw(at: CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2), withAttributes: [.font: UIFont.systemFont(ofSize: 12)])
        }
        for item in canvas.items where rect.intersects(item.frame) {
            let f = item.frame, path: UIBezierPath
            if item.kind == .inkContext {
                UIImage(systemName: "paperclip.circle.fill")?.withTintColor(item.tint.color, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: f.maxX - 17, y: f.minY, width: 16, height: 16))
                continue
            }
            if item.kind == .text {
                let text = NSAttributedString(string: item.title, attributes: item.titleAttributes)
                let box = f.insetBy(dx: 9, dy: 4)
                let measured = text.boundingRect(with: box.size, options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
                let layout = box.insetBy(dx: 0, dy: max(0, (box.height - measured.height) / 2))
                text.draw(with: layout, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], context: nil)
                continue
            }
            switch item.kind {
            case .ellipse: path = UIBezierPath(ovalIn: f)
            case .diamond:
                path = UIBezierPath()
                path.move(to: CGPoint(x: f.midX, y: f.minY))
                path.addLine(to: CGPoint(x: f.maxX, y: f.midY))
                path.addLine(to: CGPoint(x: f.midX, y: f.maxY))
                path.addLine(to: CGPoint(x: f.minX, y: f.midY))
                path.close()
            default: path = UIBezierPath(roundedRect: f, cornerRadius: 9)
            }
            UIColor.white.setFill(); path.fill()
            item.tint.color.setStroke(); path.lineWidth = 1.5; path.stroke()
            let diagram = [.rectangle, .ellipse, .diamond].contains(item.kind)
            let titleRect = diagram ? CGRect(x: f.minX + f.width * 0.2, y: f.midY - 10, width: f.width * 0.6, height: 30) : f.insetBy(dx: 12, dy: 10)
            (item.title as NSString).draw(in: titleRect, withAttributes: item.titleAttributes)
            guard !diagram else { continue }
            let body = CGRect(x: f.minX + 12, y: f.minY + 40, width: max(0, f.width - 24), height: max(0, f.height - 51))
            if let asset = item.asset, asset.kind == .image, let image = CanvasImages.thumbnail(at: studio.assetURL(asset)) {
                let ratio = min(body.width / image.size.width, body.height / image.size.height)
                image.draw(in: CGRect(x: body.minX, y: body.minY, width: image.size.width * ratio, height: image.size.height * ratio))
            } else {
                ((item.markdown.isEmpty ? item.link ?? item.asset?.filename ?? "" : item.markdown) as NSString).draw(in: body, withAttributes: [.font: UIFont.systemFont(ofSize: 13), .foregroundColor: UIColor.darkGray])
            }
        }
    }
}

private extension String {
    var splitForPDF: [String] {
        var result: [String] = [], page: [String] = []
        for line in components(separatedBy: "\n") {
            var text = line[...]
            repeat {
                page.append(String(text.prefix(65)))
                text = text.dropFirst(65)
                if page.count == 37 { result.append(page.joined(separator: "\n")); page.removeAll() }
            } while !text.isEmpty
        }
        if !page.isEmpty { result.append(page.joined(separator: "\n")) }
        return result
    }
}
