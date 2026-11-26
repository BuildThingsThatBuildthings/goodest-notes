import Foundation
import UniformTypeIdentifiers
import UIKit
import ImageIO

extension Studio {
    var assetFolder: URL { folder.appendingPathComponent("Assets", isDirectory: true) }

    func assetURL(_ asset: CanvasAsset) -> URL { assetFolder.appendingPathComponent(asset.storageName) }

    func importAsset(_ source: URL, filename: String? = nil) async throws -> CanvasAsset {
        let directory = assetFolder
        return try await Task.detached(priority: .userInitiated) {
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let attributes = try source.resourceValues(forKeys: [.isRegularFileKey, .contentTypeKey])
            guard attributes.isRegularFile == true else { throw CanvasError.invalidFile }
            let name = filename ?? source.lastPathComponent
            let type = UTType(filenameExtension: (name as NSString).pathExtension) ?? attributes.contentType ?? .data
            let asset = CanvasAsset(filename: name, type: type.identifier)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let target = directory.appendingPathComponent(asset.storageName)
            do { try FileManager.default.copyItem(at: source, to: target) }
            catch { try? FileManager.default.removeItem(at: target); throw error }
            return asset
        }.value
    }

    @discardableResult func updateCanvas(_ paperID: UUID, _ pageID: UUID, _ edit: (inout CanvasContent) -> Void) -> Bool {
        guard let i = library.papers.firstIndex(where: { $0.id == paperID }),
              let j = library.papers[i].pages.firstIndex(where: { $0.id == pageID }) else { return false }
        return change { next in
            var content = next.papers[i].pages[j].canvas ?? CanvasContent()
            edit(&content)
            next.papers[i].pages[j].canvas = content
        }
    }

    func removeAsset(_ asset: CanvasAsset) { removeFiles([assetURL(asset)]) }

    func deletePage(_ paperID: UUID, pageID: UUID) -> Bool {
        guard let paper = paper(paperID), paper.pages.count > 1,
              let paperIndex = library.papers.firstIndex(where: { $0.id == paperID }),
              let page = paper.pages.first(where: { $0.id == pageID }) else { return false }
        guard change({ next in
            next.papers[paperIndex].pages.removeAll { $0.id == pageID }
            for i in next.blocks.indices where next.blocks[i].source?.pageID == pageID { next.blocks[i].source = nil }
        }) else { return false }
        cancelIndex(pageID)
        removeFiles(page.teachingVisuals.map { assetFolder.appendingPathComponent($0.filename) } + [url(pageID, "drawing")] + (page.canvas?.items.flatMap(\.ownedAssets).map(assetURL) ?? []))
        return true
    }

    func deleteEntry(_ ref: LibraryReference) -> Bool {
        let deleted = ref.kind == .paper ? paper(ref.id) : nil
        var copied: [URL] = []
        if ref.kind == .block, let original = block(ref.id), let inherited = blockPreview(original) {
            do {
                for child in library.blocks where child.parentID == ref.id {
                    let destination = url(child.id, "png")
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        try FileManager.default.copyItem(at: inherited, to: destination)
                        copied.append(destination)
                    }
                }
            } catch {
                removeFiles(copied)
                issue = "A variation preview could not be preserved. " + error.localizedDescription
                return false
            }
        }
        guard change({ $0.delete(ref) }) else { removeFiles(copied); return false }
        if let deleted {
            for page in deleted.pages {
                cancelIndex(page.id)
                removeFiles(page.teachingVisuals.map { assetFolder.appendingPathComponent($0.filename) } + [url(page.id, "drawing")] + (page.canvas?.items.flatMap(\.ownedAssets).map(assetURL) ?? []))
            }
            if deleted.kind == .pdf { evictPDF(deleted.id); removeFiles([url(deleted.id, "pdf")]) }
        }
        if ref.kind == .block { removeFiles([url(ref.id, "png")]) }
        return true
    }

    func blockPreview(_ original: Block) -> URL? {
        var current: Block? = original
        var seen = Set<UUID>()
        while let item = current, seen.insert(item.id).inserted {
            let preview = url(item.id, "png")
            if FileManager.default.fileExists(atPath: preview.path) { return preview }
            current = item.parentID.flatMap(block)
        }
        return nil
    }

    private func removeFiles(_ urls: [URL]) {
        guard flushWrites() else { return }
        for file in urls where FileManager.default.fileExists(atPath: file.path) {
            do { try FileManager.default.removeItem(at: file) }
            catch { issue = "The item was removed, but a file could not be cleaned up. " + error.localizedDescription }
        }
    }
}

extension CanvasAsset {
    var kind: CanvasItemKind {
        guard let uti = UTType(type) else { return .file }
        if uti.conforms(to: .image) { return .image }
        if uti.conforms(to: .movie) || uti.conforms(to: .video) { return .video }
        if uti.conforms(to: .audio) { return .audio }
        return .file
    }
}

enum CanvasError: LocalizedError {
    case invalidFile, invalidLink, missingItem, invalidLayout, contextChanged
    var errorDescription: String? {
        switch self {
        case .invalidFile: "Choose a file that Goodest Notes can import."
        case .invalidLink: "Enter an http, https, email, or Goodest Notes link."
        case .missingItem: "This canvas item is no longer available."
        case .invalidLayout: "The item position or size is outside the supported canvas range."
        case .contextChanged: "This context changed while it was open. Reopen it before saving."
        }
    }
}

enum CanvasImages {
    static func thumbnail(at url: URL, maxPixels: Int = 640) -> UIImage? {
        let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                       kCGImageSourceCreateThumbnailWithTransform: true,
                       kCGImageSourceThumbnailMaxPixelSize: maxPixels] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
