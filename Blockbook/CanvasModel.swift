import Foundation

enum CanvasItemKind: String, CaseIterable, Codable, Identifiable {
    case note, text, inkContext, link, rectangle, ellipse, diamond, image, video, audio, file

    var id: Self { self }
    var label: String {
        switch self {
        case .note: "Markdown note"
        case .inkContext: "Handwriting"
        default: rawValue.capitalized
        }
    }
    var icon: String {
        switch self {
        case .note: "text.alignleft"
        case .text: "textformat"
        case .inkContext: "paperclip"
        case .link: "link"
        case .rectangle: "rectangle"
        case .ellipse: "oval"
        case .diamond: "diamond"
        case .image: "photo"
        case .video: "video"
        case .audio: "waveform"
        case .file: "doc"
        }
    }
    var defaultSize: CGSize {
        switch self {
        case .note: CGSize(width: 280, height: 178)
        case .text: CGSize(width: 300, height: 80)
        case .image, .video: CGSize(width: 300, height: 226)
        case .ellipse, .rectangle, .diamond: CGSize(width: 185, height: 125)
        default: CGSize(width: 245, height: 104)
        }
    }
}

struct CanvasItem: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: CanvasItemKind
    var title: String
    var markdown = ""
    var link: String?
    var asset: CanvasAsset?
    var frame: CGRect
    var tint: CanvasTint = .indigo
    var glow: Bool?
    var agentAuthor: String?
    var audioNote: CanvasAsset?
    var inkAnchor: InkContextAnchor?

    var hasPopOut: Bool { !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || link != nil || audioNote != nil }
    var ownedAssets: [CanvasAsset] { [asset, audioNote].compactMap { $0 } }

    func mergingContext(from original: CanvasItem, changes: CanvasItem) throws -> CanvasItem {
        func merge<Value: Equatable>(_ keyPath: KeyPath<CanvasItem, Value>) throws -> Value {
            let base = original[keyPath: keyPath], next = changes[keyPath: keyPath], current = self[keyPath: keyPath]
            if next == base { return current }
            guard current == base || current == next else { throw CanvasError.contextChanged }
            return next
        }
        var result = self
        result.markdown = try merge(\.markdown)
        result.link = try merge(\.link)
        result.audioNote = try merge(\.audioNote)
        return result
    }
}

struct InkContextAnchor: Codable, Equatable {
    var strokes: [String]
}

struct CanvasAsset: Codable, Equatable {
    var id = UUID()
    var filename: String
    var type: String

    var storageName: String {
        let ext = URL(fileURLWithPath: filename).pathExtension
        let safeExtension = ext.count <= 12 && ext.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
        return id.uuidString + (safeExtension && !ext.isEmpty ? "." + ext : "")
    }
}

struct CanvasConnection: Identifiable, Codable, Equatable {
    var id = UUID()
    var from: UUID
    var to: UUID
    var label = ""
}

struct CanvasContent: Codable, Equatable {
    var items: [CanvasItem] = []
    var connections: [CanvasConnection] = []

    mutating func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        connections.removeAll { $0.from == id || $0.to == id }
    }
}

enum LibraryEntry: String, CaseIterable, Codable {
    case paper, workflow, block
}

struct LibraryReference: Identifiable, Codable, Hashable {
    var kind: LibraryEntry
    var id: UUID

    var link: String { "blockbook://\(kind.rawValue)/\(id.uuidString)" }

    init(_ kind: LibraryEntry, _ id: UUID) { self.kind = kind; self.id = id }
    init?(url: URL) {
        guard ["blockbook", "goodestnotes"].contains(url.scheme), let host = url.host, let kind = LibraryEntry(rawValue: host),
              let id = UUID(uuidString: url.pathComponents.dropFirst().first ?? "") else { return nil }
        self.init(kind, id)
    }
}

struct Project: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var markdown = ""
    var entries: [LibraryReference] = []
}

extension Library {
    var allProjects: [Project] { projects ?? [] }
    var references: [LibraryReference] {
        papers.map { .init(.paper, $0.id) } + workflows.map { .init(.workflow, $0.id) } + blocks.map { .init(.block, $0.id) }
    }

    func title(for ref: LibraryReference) -> String? {
        switch ref.kind {
        case .paper: papers.first(where: { $0.id == ref.id })?.title
        case .workflow: workflows.first(where: { $0.id == ref.id })?.title
        case .block: blocks.first(where: { $0.id == ref.id })?.title
        }
    }

    mutating func editProject(_ id: UUID, _ edit: (inout Project) -> Void) {
        guard let i = projects?.firstIndex(where: { $0.id == id }) else { return }
        edit(&projects![i])
    }

    mutating func addProject(_ project: Project) {
        projects = allProjects + [project]
    }

    mutating func assign(_ ref: LibraryReference, to projectID: UUID, included: Bool) {
        guard title(for: ref) != nil else { return }
        editProject(projectID) { project in
            project.entries.removeAll { $0 == ref }
            if included { project.entries.append(ref) }
        }
    }

    mutating func delete(_ ref: LibraryReference) {
        switch ref.kind {
        case .paper:
            papers.removeAll { $0.id == ref.id }
            for i in blocks.indices where blocks[i].source?.documentID == ref.id {
                blocks[i].source = nil
            }
        case .workflow:
            workflows.removeAll { $0.id == ref.id }
        case .block:
            let children = blocks.filter { $0.parentID == ref.id }.map(resolved)
            for var child in children {
                child.parentID = nil
                save(child)
            }
            blocks.removeAll { $0.id == ref.id }
            for i in workflows.indices { workflows[i].steps.removeAll { $0.blockID == ref.id } }
        }
        for project in allProjects { editProject(project.id) { $0.entries.removeAll { $0 == ref } } }
        for i in papers.indices {
            for j in papers[i].pages.indices {
                guard var content = papers[i].pages[j].canvas else { continue }
                for k in content.items.indices where content.items[k].link.flatMap(URL.init(string:)).flatMap(LibraryReference.init(url:)) == ref {
                    content.items[k].link = nil
                }
                papers[i].pages[j].canvas = content
            }
        }
    }
}

extension CanvasItem {
    static func valid(_ frame: CGRect) -> Bool {
        [frame.minX, frame.minY, frame.maxX, frame.maxY].allSatisfy { $0.isFinite && abs($0) < 1_000_000_000 } &&
            (40...4000).contains(frame.width) && (32...4000).contains(frame.height)
    }

    static func checkedLink(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)), let scheme = url.scheme?.lowercased() else { return nil }
        switch scheme {
        case "https", "http": return url.host?.isEmpty == false ? url : nil
        case "mailto": return url.path.isEmpty ? nil : url
        case "blockbook", "goodestnotes": return LibraryReference(url: url) == nil ? nil : url
        default: return nil
        }
    }
}
