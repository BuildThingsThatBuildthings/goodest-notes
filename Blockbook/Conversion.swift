import Foundation

enum ExportKind: String, CaseIterable { case markdown = "Markdown", graph = "Knowledge graph", skill = "Claude skill" }

struct Conversion {
    let library: Library
    let title: String
    let id: UUID
    let workflow: Workflow?
    let blocks: [Block]

    init(_ library: Library, block: Block) {
        self.library = library; title = block.title; id = block.id; workflow = nil
        blocks = [library.resolved(block)]
    }
    init(_ library: Library, workflow: Workflow) {
        self.library = library; title = workflow.title; id = workflow.id; self.workflow = workflow
        blocks = workflow.steps.compactMap { step in library.blocks.first(where: { $0.id == step.blockID }).map(library.resolved) }
    }

    static func slug(_ name: String) -> String {
        let plain = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let parts = plain.components(separatedBy: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789").inverted).filter { !$0.isEmpty }
        return parts.isEmpty ? "untitled" : String(parts.joined(separator: "-").prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
    static func temporaryFile(_ name: String, ext: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(slug(name)).appendingPathExtension(ext)
    }

    func markdown() -> String {
        var text = "---\nblockbook_id: \(id.uuidString)\nkind: \(workflow == nil ? "block" : "workflow")\n---\n\n# \(title)\n"
        if let context = workflow?.context, !context.isEmpty { text += "\n\(context)\n" }
        for (i, b) in blocks.enumerated() {
            if workflow != nil { text += "\n## \(i+1). \(b.title)\n\nBlock ID: \(b.id.uuidString)\n" }
            if let parent = b.parentID { text += "\nVariation of: \(parent.uuidString)\n" }
            if let context = b.context, !context.isEmpty { text += "\n### Context\n\n\(context)\n" }
            for f in BlockField.allCases where !b[f].isEmpty { text += "\n### \(f.label)\n\n\(b[f])\n" }
            if let s = b.source {
                text += "\n### Source page\n\nDocument \(s.documentID.uuidString), page \(s.pageID.uuidString)\n"
                if !s.excerpt.isEmpty { text += "\n" + s.excerpt + "\n" }
            }
        }
        return text
    }

    struct Graph: Codable {
        struct Node: Codable { var id: String; var type: String; var label: String }
        struct Edge: Codable, Hashable { var from: String; var relation: String; var to: String; var position: Int? }
        var nodes: [Node] = []
        var edges: [Edge] = []
    }

    func graph() -> Graph {
        var graph = Graph(), seen: Set<String> = [], edges: Set<Graph.Edge> = []
        func node(_ id: String, _ type: String, _ label: String) {
            if seen.insert(id).inserted { graph.nodes.append(.init(id: id, type: type, label: label)) }
        }
        func edge(_ from: String, _ relation: String, _ to: String, _ index: Int? = nil) {
            let item = Graph.Edge(from: from, relation: relation, to: to, position: index)
            if edges.insert(item).inserted { graph.edges.append(item) }
        }
        if let w = workflow { node(w.id.uuidString, "workflow", w.title) }
        for (i, b) in blocks.enumerated() {
            let key = b.id.uuidString
            node(key, "block", b.title)
            if let w = workflow { edge(w.id.uuidString, "uses", key, i+1) }
            if let p = b.parentID {
                node(p.uuidString, "block", library.blocks.first(where: { $0.id == p })?.title ?? "Parent block")
                edge(key, "variationOf", p.uuidString)
            }
            if let s = b.source { node(s.pageID.uuidString, "page", s.excerpt); edge(key, "capturedFrom", s.pageID.uuidString) }
            for field in BlockField.allCases {
                for (line, raw) in b[field].split(separator: "\n").enumerated() {
                    let value = raw.trimmingCharacters(in: .whitespaces)
                    guard !value.isEmpty else { continue }
                    let resourceID = field.rawValue + ":" + value.precomposedStringWithCanonicalMapping.lowercased()
                    node(resourceID, field.rawValue, value)
                    edge(key, field.rawValue, resourceID, line+1)
                }
            }
        }
        return graph
    }

    func write(_ kind: ExportKind) throws -> URL {
        let body = markdown()
        switch kind {
        case .markdown:
            let file = try Self.temporaryFile(title, ext: "md")
            try body.write(to: file, atomically: true, encoding: .utf8)
            return file
        case .graph:
            let file = try Self.temporaryFile(title, ext: "json")
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(graph()).write(to: file, options: .atomic)
            return file
        case .skill:
            let shortID = id.uuidString.lowercased().prefix(8)
            let stem = Self.slug(title).replacingOccurrences(of: "anthropic", with: "agent").replacingOccurrences(of: "claude", with: "agent")
            let name = "run-\(stem)-\(shortID)"
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent(name)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let desc = "Use when the user requests the workflow for " + title + ". " + (blocks.first?[.outcome] ?? "")
            let clean = String(desc.replacingOccurrences(of: "<", with: "").replacingOccurrences(of: ">", with: "").prefix(950))
            let quoted = String(decoding: try JSONEncoder().encode(clean), as: UTF8.self)
            var skill = "---\nname: \(name)\ndescription: \(quoted)\n---\n\n# \(title)\n\nWork through the following blocks in order. Consult [the source notes](source.md) for resources, constraints, and page references. Ask the user for any missing prerequisite before relying on it.\n"
            for (i, b) in blocks.enumerated() {
                skill += "\n## \(i+1). \(b.title)\n"
                for (field, heading): (BlockField, String) in [(.outcome,"Target outcome"), (.inputs,"Gather"), (.process,"Procedure"), (.outputs,"Produce"), (.evidence,"Verify effectiveness"), (.now,"Immediate action")] where !b[field].isEmpty {
                    skill += "\n### \(heading)\n\n\(b[field])\n"
                }
            }
            try body.write(to: root.appendingPathComponent("source.md"), atomically: true, encoding: .utf8)
            try skill.write(to: root.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
            return root
        }
    }
}
