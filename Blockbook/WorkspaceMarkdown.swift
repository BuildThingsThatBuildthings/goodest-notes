import Foundation
import PencilKit
import UIKit

@MainActor struct WorkspaceMarkdown {
    let studio: Studio

    func paper(_ paper: Paper, pageID: UUID? = nil, assets: URL? = nil, links: [LibraryReference: String] = [:], allowedLinks: Set<LibraryReference>? = nil) throws -> String {
        let ref = LibraryReference(.paper, paper.id)
        var body = header(paper.title, id: paper.id, kind: paper.kind.rawValue)
        if let assets, paper.kind == .pdf {
            let name = Conversion.slug(paper.title) + "-source-" + short(paper.id) + ".pdf"
            try copy(studio.url(paper.id, "pdf"), to: assets.appendingPathComponent(name))
            body += "\n[Original PDF](assets/\(name))\n"
        }
        for (i, page) in paper.pages.enumerated() where pageID == nil || pageID == page.id {
            body += "\n## \(paper.kind == .whiteboard ? "Canvas" : "Page \(i + 1)")\n\n"
            body += "Page ID: `\(page.id.uuidString)`\n"
            if !page.typed.isEmpty { body += "\n### Notes\n\n\(page.typed)\n" }
            if !page.inkText.isEmpty { body += "\n### Handwriting transcription\n\n\(page.inkText)\n" }
            if !page.pdfText.isEmpty { body += "\n### PDF text\n\n\(page.pdfText)\n" }

            let content = page.canvas ?? CanvasContent()
            if let assets {
                let ink = try studio.drawing(page.id)
                if !ink.strokes.isEmpty || !content.items.isEmpty {
                    let name = "page-" + short(page.id)
                    let rect = SheetRenderer.contentBounds(paper: paper, page: page, drawing: ink)
                    let image = try SheetRenderer.snapshot(studio, paper: paper, page: page, rect: rect)
                    guard let data = image.pngData() else { throw StudioError.invalidPage }
                    try data.write(to: assets.appendingPathComponent(name + ".png"), options: .atomic)
                    body += "\n![Canvas preview](assets/\(name).png)\n"
                    if !ink.strokes.isEmpty {
                        try ink.dataRepresentation().write(to: assets.appendingPathComponent(name + ".drawing"), options: .atomic)
                        body += "\n[Original PencilKit ink](assets/\(name).drawing)\n"
                    }
                }
            }
            for item in content.items.sorted(by: readingOrder) {
                body += "\n### \(inline(item.title))\n\n"
                let style = item.glow == true ? " · Glow (\(item.tint.rawValue))" : ""
                body += "\(item.kind.label)\(style) · ID `\(item.id.uuidString)` · x \(coordinate(item.frame.minX)), y \(coordinate(item.frame.minY)), width \(coordinate(item.frame.width)), height \(coordinate(item.frame.height))\n"
                if !item.markdown.isEmpty { body += "\n\(item.markdown)\n" }
                if let link = item.link, let url = CanvasItem.checkedLink(link) {
                    let ref = LibraryReference(url: url)
                    if ref.flatMap({ allowedLinks?.contains($0) }) != false {
                        let target = ref.flatMap { links[$0] } ?? url.absoluteString
                        let name = ref.flatMap(studio.library.title(for:)) ?? "Open link"
                        body += "\n[\(inline(name))](<\(target)>)\n"
                    }
                }
                if let asset = item.asset {
                    if let assets {
                        try copy(studio.assetURL(asset), to: assets.appendingPathComponent(asset.storageName))
                        let syntax = asset.kind == .image ? "!" : ""
                        body += "\n\(syntax)[\(inline(asset.filename))](assets/\(asset.storageName))\n"
                    } else {
                        body += "\nAttachment: \(inline(asset.filename))\n"
                    }
                }
                if let audio = item.audioNote {
                    if let assets {
                        try copy(studio.assetURL(audio), to: assets.appendingPathComponent(audio.storageName))
                        body += "\n[Audio note](assets/\(audio.storageName))\n"
                    } else {
                        body += "\nAudio note: \(inline(audio.filename))\n"
                    }
                }
            }
            if !content.connections.isEmpty {
                let titles = Dictionary(content.items.map { ($0.id, $0.title) }, uniquingKeysWith: { _, last in last })
                body += "\n### Connections\n\n"
                for edge in content.connections {
                    guard let from = titles[edge.from], let to = titles[edge.to] else { continue }
                    let label = edge.label.isEmpty ? "" : " — \(inline(edge.label))"
                    body += "- \(inline(from)) (`\(edge.from.uuidString)`) → \(inline(to)) (`\(edge.to.uuidString)`)\(label)\n"
                }
            }
        }
        body += "\n[Open in Goodest Notes](\(ref.link))\n"
        return body
    }

    func writePaper(_ paper: Paper, pageID: UUID? = nil) async throws -> URL {
        let title = pageID.flatMap { id in paper.pages.firstIndex(where: { $0.id == id }) }.map { paper.title + " page \($0 + 1)" } ?? paper.title
        let selected = paper.pages.filter { pageID == nil || $0.id == pageID }
        let hasAssets = paper.kind == .pdf || selected.contains {
            FileManager.default.fileExists(atPath: studio.url($0.id, "drawing").path) || $0.canvas?.items.isEmpty == false
        }
        await Task.yield()
        let target = try Conversion.temporaryFile(title, ext: "md")
        if hasAssets {
            let bundle = target.deletingPathExtension()
            let assets = bundle.appendingPathComponent("assets", isDirectory: true)
            try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
            let markdown = try self.paper(paper, pageID: pageID, assets: assets)
            try markdown.write(to: bundle.appendingPathComponent(target.lastPathComponent), atomically: true, encoding: .utf8)
            return bundle
        }
        try self.paper(paper, pageID: pageID).write(to: target, atomically: true, encoding: .utf8)
        return target
    }

    func writeProject(_ project: Project) async throws -> URL {
        let index = try Conversion.temporaryFile(project.title, ext: "md")
        let bundle = index.deletingPathExtension()
        let assets = bundle.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        let library = studio.library
        var body = header(project.title, id: project.id, kind: "project")
        if !project.markdown.isEmpty { body += "\n" + project.markdown + "\n" }
        body += "\n## Contents\n"
        var links: [LibraryReference: String] = [:]
        for ref in project.entries {
            await Task.yield()
            guard let name = library.title(for: ref) else { continue }
            links[ref] = Conversion.slug(name) + "-" + short(ref.id) + ".md"
        }
        for ref in project.entries {
            guard let filename = links[ref], let name = library.title(for: ref) else { continue }
            body += "\n- [\(inline(name))](\(filename))"
            let markdown: String
            switch ref.kind {
            case .paper:
                guard let paper = library.papers.first(where: { $0.id == ref.id }) else { continue }
                markdown = try self.paper(paper, assets: assets, links: links)
            case .workflow:
                guard let workflow = library.workflows.first(where: { $0.id == ref.id }) else { continue }
                markdown = Conversion(library, workflow: workflow).markdown()
            case .block:
                guard let block = library.blocks.first(where: { $0.id == ref.id }) else { continue }
                markdown = Conversion(library, block: block).markdown()
            }
            try markdown.write(to: bundle.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        }
        try (body + "\n").write(to: bundle.appendingPathComponent("index.md"), atomically: true, encoding: .utf8)
        return bundle
    }

    private func readingOrder(_ a: CanvasItem, _ b: CanvasItem) -> Bool {
        if a.frame.minY == b.frame.minY { return a.frame.minX < b.frame.minX }
        return a.frame.minY < b.frame.minY
    }

    private func copy(_ source: URL, to target: URL) throws {
        if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: source, to: target) }
    }
    private func coordinate(_ value: CGFloat) -> String { String(format: "%.1f", locale: Locale(identifier: "en_US_POSIX"), value) }
    private func short(_ id: UUID) -> String { id.uuidString.lowercased() }
    private func inline(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
    private func header(_ title: String, id: UUID, kind: String) -> String {
        "---\nblockbook_id: \(id.uuidString)\nkind: \(kind)\n---\n\n# \(inline(title))\n"
    }
}
