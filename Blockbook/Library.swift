import Foundation

enum BlockField: String, CaseIterable, Identifiable, Codable {
    case outcome, evidence, now, process, resources, locations, tech, talent, tangible, tides, roles, inputs, outputs, tools, time, cost
    var id: Self { self }
    var label: String {
        switch self {
        case .outcome: return "What outcome does this get?"
        case .evidence: return "How will we know it’s effective?"
        case .now: return "What needs to happen right now?"
        case .process: return "Process"
        case .resources: return "Resources"
        case .locations: return "Locations"
        case .tech: return "Tech"
        case .talent: return "Talent"
        case .tangible: return "Tangible assets"
        case .tides: return "Tides"
        case .roles: return "People / roles"
        case .inputs: return "Inputs"
        case .outputs: return "Outputs"
        case .tools: return "Tools / links"
        case .time: return "Time"
        case .cost: return "Cost"
        }
    }
}

struct PageSource: Codable, Equatable {
    var documentID: UUID
    var pageID: UUID
    var rect: CGRect?
    var excerpt: String
}

struct Block: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var parentID: UUID?
    // Presence, including an empty string, means this field overrides the parent.
    var values: [String: String] = [:]
    var source: PageSource?
    var context: String?
    subscript(_ field: BlockField) -> String {
        get { values[field.rawValue] ?? "" }
        set { values[field.rawValue] = newValue }
    }
}

struct Placement: Identifiable, Codable, Equatable {
    var id = UUID()
    var blockID: UUID
}

struct Workflow: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var steps: [Placement] = []
    var context: String?
}

enum PaperKind: String, Codable, CaseIterable { case notebook, whiteboard, pdf }
struct SheetPage: Codable, Identifiable, Equatable {
    var id = UUID()
    var size = CGSize(width: 768, height: 1024)
    var pdfIndex: Int?
    var typed = ""
    var pdfText = ""
    var inkText = ""
    var visual: TeachingVisual?
    var needsPDFIndex: Bool?
    var canvas: CanvasContent?
    var text: String {
        ([typed, inkText, pdfText] + (canvas?.items.flatMap { [$0.title, $0.markdown, $0.link ?? ""] } ?? []) + (canvas?.connections.map(\.label) ?? []))
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }
}
struct Paper: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var kind: PaperKind
    var pages: [SheetPage]
}
struct Library: Codable, Equatable {
    var version = 1
    var papers: [Paper] = []
    var workflows: [Workflow] = []
    var blocks: [Block] = []
    var projects: [Project]?

    func resolved(_ block: Block) -> Block {
        var result = block
        var ancestor = block.parentID
        var seen: Set<UUID> = [block.id]
        while let id = ancestor, seen.insert(id).inserted, let parent = blocks.first(where: { $0.id == id }) {
            result.values.merge(parent.values) { child, _ in child }
            if result.source == nil { result.source = parent.source }
            if result.context == nil { result.context = parent.context }
            ancestor = parent.parentID
        }
        return result
    }

    mutating func save(_ block: Block, in workflowID: UUID? = nil, replacing placementID: UUID? = nil) {
        if let i = blocks.firstIndex(where: { $0.id == block.id }) { blocks[i] = block } else { blocks.append(block) }
        guard let w = workflows.firstIndex(where: { $0.id == workflowID }) else { return }
        if let placementID {
            if let s = workflows[w].steps.firstIndex(where: { $0.id == placementID }) { workflows[w].steps[s].blockID = block.id }
        } else { workflows[w].steps.append(Placement(blockID: block.id)) }
    }
}
