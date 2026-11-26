import Foundation
import CoreFoundation
import CryptoKit

@MainActor struct AgentTools {
    let studio: Studio
    let access: AgentAccess
    var onWrite: (String) -> Void = { _ in }

    func handle(_ data: Data) -> Data {
        var id: Any = NSNull()
        func response(_ payload: [String: Any]) -> Data {
            (try? JSONSerialization.data(withJSONObject: payload.merging(["jsonrpc": "2.0", "id": id]) { current, _ in current })) ?? Data()
        }
        func error(_ code: Int, _ message: String) -> Data { response(["error": ["code": code, "message": message]]) }
        do {
            guard let request = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return error(-32600, "Invalid request") }
            if let value = request["id"], value is String || value is NSNumber || value is NSNull { id = value }
            guard request["jsonrpc"] as? String == "2.0", let method = request["method"] as? String else { return error(-32600, "Invalid request") }
            guard request["id"] != nil else { return Data() }
            let params = request["params"] as? [String: Any] ?? [:]
            switch method {
            case "initialize":
                return response(["result": AgentCatalog.initialize(params)])
            case "ping": return response(["result": [:]])
            case "tools/list":
                let tools = AgentCatalog.tools.filter { canUse($0["name"] as? String ?? "") }
                return response(["result": ["tools": tools]])
            case "tools/call":
                guard let name = params["name"] as? String else { return error(-32602, "A tool name is required") }
                do {
                    let text = try call(name, params["arguments"] as? [String: Any] ?? [:])
                    return response(["result": ["content": [["type": "text", "text": text]], "isError": false]])
                } catch {
                    return response(["result": ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]])
                }
            default: return error(-32601, "Method not found")
            }
        } catch { return response(["error": ["code": -32700, "message": "Invalid JSON"]]) }
    }

    private func canUse(_ name: String) -> Bool {
        switch name {
        case "create_canvas", "create_notebook", "list_projects": access.canCreateCanvas
        case "create_project", "set_project_membership": access == .library
        default: true
        }
    }

    private func call(_ name: String, _ args: [String: Any]) throws -> String {
        guard canUse(name) else { throw AgentError.message("This tool needs a broader Goodest Notes share.") }
        let library = studio.library
        let scope = try access.references(in: library)
        let allowed = Set(scope)

        switch name {
        case "list_library":
            let query = (args["query"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let matched = scope.filter { ref in
                guard !query.isEmpty else { return true }
                return library.title(for: ref)?.localizedCaseInsensitiveContains(query) == true ||
                    library.papers.first(where: { $0.id == ref.id })?.pages.contains(where: { $0.text.localizedCaseInsensitiveContains(query) }) == true
            }
            let offset = try integer(args["offset"], default: 0, low: 0, high: 1_000_000)
            let limit = try integer(args["limit"], default: 40, low: 1, high: 100)
            let entries = matched.dropFirst(offset).prefix(limit).map { ref -> [String: Any] in
                var entry = ["id": ref.id.uuidString, "kind": ref.kind.rawValue, "title": library.title(for: ref) ?? "", "url": ref.link] as [String: Any]
                if let paper = library.papers.first(where: { $0.id == ref.id }) {
                    entry["kind"] = paper.kind.rawValue
                    entry["page_ids"] = paper.pages.map { $0.id.uuidString }
                }
                return entry
            }
            return try json(["items": entries, "total": matched.count, "next_offset": offset + entries.count < matched.count ? (offset + entries.count) as Any : NSNull()])
        case "read_markdown":
            let id = try requiredID("id", in: args)
            guard let ref = scope.first(where: { $0.id == id }) else { throw AgentError.unavailable }
            let markdown: String
            switch ref.kind {
            case .paper:
                guard let paper = studio.paper(id) else { throw AgentError.unavailable }
                let pageID = args["page_id"] == nil ? nil : try requiredID("page_id", in: args)
                if let pageID, !paper.pages.contains(where: { $0.id == pageID }) { throw AgentError.unavailable }
                markdown = try WorkspaceMarkdown(studio: studio).paper(paper, pageID: pageID, allowedLinks: allowed)
            case .workflow:
                guard let workflow = studio.workflow(id) else { throw AgentError.unavailable }
                let scoped = access.conversionLibrary(library, permitted: allowed)
                var visible = workflow
                let blocks = Set(scoped.blocks.map(\.id))
                let hiddenCount = visible.steps.filter { !blocks.contains($0.blockID) }.count
                if hiddenCount > 0 {
                    visible.steps.removeAll { !blocks.contains($0.blockID) }
                }
                markdown = Conversion(scoped, workflow: visible).markdown() + (hiddenCount == 0 ? "" : "\n\(hiddenCount) workflow steps are outside this share.\n")
            case .block:
                let scoped = access.conversionLibrary(library, permitted: allowed)
                guard let block = scoped.blocks.first(where: { $0.id == id }) else { throw AgentError.unavailable }
                markdown = Conversion(scoped, block: block).markdown()
            }
            let offset = try integer(args["offset"], default: 0, low: 0, high: 20_000_000)
            let chunk = String(markdown.dropFirst(offset).prefix(90_000))
            if offset + chunk.count < markdown.count { return chunk + "\n\nContinue with offset \(offset + chunk.count)." }
            return chunk
        case "get_canvas":
            let (paper, page) = try findPage(args, scope: scope)
            var canvas = page.canvas ?? CanvasContent()
            for i in canvas.items.indices {
                if let raw = canvas.items[i].link, let url = URL(string: raw), let ref = LibraryReference(url: url), !allowed.contains(ref) {
                    canvas.items[i].link = nil
                }
            }
            let data = try JSONEncoder().encode(canvas)
            guard data.count < 600_000 else { throw AgentError.message("This layout is too large for one response. Read the page with read_markdown and use offsets.") }
            return try json(["paper_id": paper.id.uuidString, "page_id": page.id.uuidString, "notes": page.typed,
                             "canvas": try JSONSerialization.jsonObject(with: data)])
        case "create_canvas", "create_notebook":
            return try createPaper(kind: name == "create_canvas" ? .whiteboard : .notebook, args: args, scope: allowed)
        case "add_notebook_page":
            return try addNotebookPage(args, scope: allowed)
        case "write_page_notes":
            return try writePageNotes(args, scope: scope)
        case "update_canvas_item":
            return try updateItem(args, scope: scope)
        case "list_projects":
            let projects = library.allProjects.filter { access.projectID == nil || $0.id == access.projectID }
            let offset = try integer(args["offset"], default: 0, low: 0, high: 1_000_000)
            let limit = try integer(args["limit"], default: 40, low: 1, high: 100)
            return try json(["total": projects.count, "projects": projects.dropFirst(offset).prefix(limit).map { project in
                ["id": project.id.uuidString, "title": project.title, "item_ids": project.entries.filter(allowed.contains).map { $0.id.uuidString }]
            }])
        case "create_project":
            let id = try requiredID("id", in: args)
            let title = try requiredText("title", in: args, max: 180)
            let markdown = try optionalText("markdown", in: args, max: 60_000)
            if let existing = library.allProjects.first(where: { $0.id == id }) {
                guard existing.title == title else { throw AgentError.unavailable }
            } else {
                guard !library.references.contains(where: { $0.id == id }) else { throw AgentError.unavailable }
                guard studio.change({ $0.addProject(Project(id: id, title: title, markdown: markdown)) }) else { throw AgentError.unsaved }
                onWrite("Created project " + title)
            }
            return try json(["id": id.uuidString])
        case "set_project_membership":
            let projectID = try requiredID("project_id", in: args)
            let itemID = try requiredID("item_id", in: args)
            guard let included = args["included"] as? NSNumber, CFGetTypeID(included) == CFBooleanGetTypeID(),
                  let project = library.allProjects.first(where: { $0.id == projectID }),
                  let ref = scope.first(where: { $0.id == itemID }) else { throw AgentError.unavailable }
            if project.entries.contains(ref) != included.boolValue {
                guard studio.change({ $0.assign(ref, to: projectID, included: included.boolValue) }) else { throw AgentError.unsaved }
                onWrite("Updated membership in " + project.title)
            }
            return try json(["item_id": itemID.uuidString, "project_id": projectID.uuidString, "included": included.boolValue])
        case "add_canvas_items":
            return try addItems(args, scope: scope)
        default: throw AgentError.message("Unknown tool.")
        }
    }

    private func createPaper(kind: PaperKind, args: [String: Any], scope: Set<LibraryReference>) throws -> String {
        let id = try requiredID("id", in: args)
        let title = try requiredText("title", in: args, max: 180)
        let markdown = try optionalText("markdown", in: args, max: 60_000)
        let ref = LibraryReference(.paper, id)
        let targetProject = args["project_id"] == nil ? access.projectID : try requiredID("project_id", in: args)
        let project = studio.library.allProjects.first(where: { $0.id == targetProject })
        if let targetProject {
            guard (access == .library || targetProject == access.projectID), project != nil else { throw AgentError.unavailable }
        }
        if let prior = studio.paper(id) {
            guard scope.contains(ref), prior.kind == kind, prior.title == title, let first = prior.pages.first,
                  targetProject == nil || project?.entries.contains(ref) == true else { throw AgentError.unavailable }
            return try json(["id": id.uuidString, "page_id": first.id.uuidString])
        }
        let library = studio.library
        guard !library.references.contains(where: { $0.id == id }), !library.allProjects.contains(where: { $0.id == id }) else {
            throw AgentError.unavailable
        }
        var page = SheetPage(typed: markdown)
        if kind == .whiteboard { page.size = CGSize(width: 2400, height: 1800) }
        let paper = Paper(id: id, title: title, kind: kind, pages: [page])
        guard studio.change({ next in
            next.papers.append(paper)
            if let targetProject { next.assign(ref, to: targetProject, included: true) }
        }) else { throw AgentError.unsaved }
        onWrite("Created " + title)
        return try json(["id": id.uuidString, "page_id": page.id.uuidString])
    }

    private func addNotebookPage(_ args: [String: Any], scope: Set<LibraryReference>) throws -> String {
        let notebookID = try requiredID("item_id", in: args)
        let pageID = try requiredID("page_id", in: args)
        let markdown = try optionalText("markdown", in: args, max: 60_000)
        guard scope.contains(.init(.paper, notebookID)),
              let notebook = studio.paper(notebookID), notebook.kind == .notebook else { throw AgentError.unavailable }
        if !notebook.pages.contains(where: { $0.id == pageID }) {
            guard !studio.library.papers.contains(where: { $0.pages.contains(where: { $0.id == pageID }) }) else { throw AgentError.unavailable }
            let page = SheetPage(id: pageID, typed: markdown)
            guard studio.change({ next in
                if let index = next.papers.firstIndex(where: { $0.id == notebookID }) { next.papers[index].pages.append(page) }
            }) else { throw AgentError.unsaved }
            onWrite("Added a page to " + notebook.title)
        }
        return try json(["item_id": notebookID.uuidString, "page_id": pageID.uuidString])
    }

    private func writePageNotes(_ args: [String: Any], scope: [LibraryReference]) throws -> String {
        let (paper, page) = try findPage(args, scope: scope)
        guard args["markdown"] != nil, args["expected_markdown"] != nil else {
            throw AgentError.message("Supply markdown and the exact existing expected_markdown.")
        }
        let replacement = try optionalText("markdown", in: args, max: 60_000)
        let expected = try optionalText("expected_markdown", in: args, max: 100_000)
        if page.typed != replacement {
            guard page.typed == expected else { throw AgentError.message("Page notes changed. Read the current notes again before updating.") }
            guard studio.editPage(paper.id, page.id, { $0.typed = replacement }) else { throw AgentError.unsaved }
            onWrite("Updated page notes in " + paper.title)
        }
        return try json(["item_id": paper.id.uuidString, "page_id": page.id.uuidString, "notes": replacement])
    }

    private func updateItem(_ args: [String: Any], scope: [LibraryReference]) throws -> String {
        let (paper, page) = try findPage(args, scope: scope)
        let id = try requiredID("object_id", in: args)
        guard let index = page.canvas?.items.firstIndex(where: { $0.id == id }), let original = page.canvas?.items[index] else {
            throw AgentError.unavailable
        }
        var item = original
        let frame = original.frame
        let x = try args["x"].map(number) ?? frame.origin.x
        let y = try args["y"].map(number) ?? frame.origin.y
        let width = try args["width"].map(number) ?? frame.width
        let height = try args["height"].map(number) ?? frame.height
        item.frame = CGRect(x: x, y: y, width: width, height: height)
        guard width > 0, height > 0, CanvasItem.valid(item.frame),
              paper.kind == .whiteboard || CGRect(origin: .zero, size: page.size).contains(item.frame) else { throw CanvasError.invalidLayout }
        if args["title"] != nil { item.title = try requiredText("title", in: args, max: 180) }
        if args["markdown"] != nil { item.markdown = try optionalText("markdown", in: args, max: 10_000) }
        if args["glow"] != nil { item.glow = try glow(args["glow"]) }
        if args["tint"] != nil {
            guard let tint = CanvasTint(rawValue: try optionalText("tint", in: args, max: 20)) else { throw AgentError.message("Unknown color.") }
            item.tint = tint
        }
        if args["link"] != nil {
            let raw = try optionalText("link", in: args, max: 2500)
            let link = CanvasItem.checkedLink(raw)
            guard link != nil || (raw.isEmpty && item.kind != .link) else { throw CanvasError.invalidLink }
            if let link, let ref = LibraryReference(url: link), !scope.contains(ref) { throw AgentError.unavailable }
            item.link = link?.absoluteString
        }
        if item != original {
            guard studio.updateCanvas(paper.id, page.id, { $0.items[index] = item }) else { throw AgentError.unsaved }
            onWrite("Updated " + item.title + " in " + paper.title)
        }
        return try json(["object_id": id.uuidString, "page_id": page.id.uuidString])
    }

    private func addItems(_ args: [String: Any], scope: [LibraryReference]) throws -> String {
        let (paper, page) = try findPage(args, scope: scope)
        let pageID = page.id
        let requestID = try requiredID("request_id", in: args)
        let content = page.canvas ?? CanvasContent()
        guard let items = args["items"] as? [[String: Any]], items.count <= 50 else { throw AgentError.message("Supply an items array of at most 50 objects.") }
        let suppliedConnections = args["connections"] as? [[String: Any]] ?? []
        guard args["connections"] == nil || args["connections"] is [[String: Any]], suppliedConnections.count <= 100,
              !items.isEmpty || !suppliedConnections.isEmpty else { throw AgentError.message("Supply objects or up to 100 connections.") }
        let proposed: [CanvasItem] = try items.enumerated().map { index, raw in
            guard let kind = CanvasItemKind(rawValue: raw["kind"] as? String ?? ""),
                  [.note, .text, .rectangle, .ellipse, .diamond, .link].contains(kind) else { throw AgentError.message("Unsupported canvas object.") }
            let x = try number(raw["x"]), y = try number(raw["y"])
            let size = kind.defaultSize
            let width = raw["width"] == nil ? size.width : try number(raw["width"])
            let height = raw["height"] == nil ? size.height : try number(raw["height"])
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard width > 0, height > 0, CanvasItem.valid(rect), paper.kind == .whiteboard || CGRect(origin: .zero, size: page.size).contains(rect) else { throw CanvasError.invalidLayout }
            let title = try requiredText("title", in: raw, max: 180)
            let markdown = try optionalText("markdown", in: raw, max: 10_000)
            let target = try optionalText("link", in: raw, max: 2500)
            let link = target.isEmpty ? nil : CanvasItem.checkedLink(target)
            guard (target.isEmpty && kind != .link) || link != nil else { throw CanvasError.invalidLink }
            if let link, let ref = LibraryReference(url: link), !scope.contains(ref) { throw AgentError.unavailable }
            let tint = CanvasTint(rawValue: try optionalText("tint", in: raw, max: 20)) ?? .indigo
            return CanvasItem(id: stableID(pageID, requestID, "object-\(index)"), kind: kind, title: title, markdown: markdown, link: link?.absoluteString, frame: rect, tint: tint, glow: try glow(raw["glow"]))
        }
        let possible = Set((content.items + proposed).map(\.id))
        func endpoint(_ token: Any?) throws -> UUID {
            if let value = token as? String, let id = UUID(uuidString: value), possible.contains(id) { return id }
            if let value = try? integer(token, low: 0, high: max(0, proposed.count - 1)), proposed.indices.contains(value) { return proposed[value].id }
            throw AgentError.message("Connection endpoints must refer to an existing object or an item index.")
        }
        let edges: [CanvasConnection] = try suppliedConnections.enumerated().map { index, raw in
            let from = try endpoint(raw["from"]), to = try endpoint(raw["to"])
            guard from != to else { throw AgentError.message("A connection must join two different objects.") }
            return CanvasConnection(id: stableID(pageID, requestID, "edge-\(index)"), from: from, to: to, label: try optionalText("label", in: raw, max: 180))
        }
        let existingItems = Dictionary(content.items.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let existingEdges = Dictionary(content.connections.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let result = try json(["page_id": pageID.uuidString, "item_ids": proposed.map { $0.id.uuidString }, "connection_ids": edges.map { $0.id.uuidString }])
        let savedItemCount = proposed.filter { existingItems[$0.id] != nil }.count
        let savedEdgeCount = edges.filter { existingEdges[$0.id] != nil }.count
        if savedItemCount > 0 || savedEdgeCount > 0 {
            guard savedItemCount == proposed.count, savedEdgeCount == edges.count,
                  proposed.allSatisfy({ existingItems[$0.id] == $0 }),
                  edges.allSatisfy({ existingEdges[$0.id] == $0 }) else {
                throw AgentError.message("That request ID already refers to a different or subsequently edited batch.")
            }
            return result
        }
        guard studio.updateCanvas(paper.id, pageID, { next in
            next.items.append(contentsOf: proposed)
            next.connections.append(contentsOf: edges)
        }) else { throw AgentError.unsaved }
        onWrite("Added \(proposed.count) items and \(edges.count) connections to \(paper.title)")
        return result
    }

    private func findPage(_ args: [String: Any], scope: [LibraryReference]) throws -> (Paper, SheetPage) {
        let itemID = args["item_id"] == nil ? nil : try requiredID("item_id", in: args)
        let pageID = args["page_id"] == nil ? nil : try requiredID("page_id", in: args)
        guard itemID != nil || pageID != nil else { throw AgentError.message("Supply item_id for a one-page item or page_id for a specific page.") }
        for ref in scope where ref.kind == .paper {
            guard itemID == nil || itemID == ref.id, let paper = studio.paper(ref.id) else { continue }
            if let pageID {
                if let page = paper.pages.first(where: { $0.id == pageID }) { return (paper, page) }
            } else {
                guard paper.pages.count == 1, let page = paper.pages.first else {
                    throw AgentError.message("This item has more than one page. Use one of its page IDs from list_library.")
                }
                return (paper, page)
            }
        }
        throw AgentError.unavailable
    }

    private func requiredID(_ key: String, in params: [String: Any]) throws -> UUID {
        guard let raw = params[key] as? String, let id = UUID(uuidString: raw) else { throw AgentError.message("A UUID is required for " + key + ".") }
        return id
    }

    private func optionalText(_ key: String, in raw: [String: Any], max: Int) throws -> String {
        guard let supplied = raw[key] else { return "" }
        guard let text = supplied as? String, text.count <= max, text.utf8.count <= max * 5 else { throw AgentError.message("Invalid or oversized " + key + ".") }
        return text
    }

    private func requiredText(_ key: String, in raw: [String: Any], max: Int) throws -> String {
        let value = try optionalText(key, in: raw, max: max).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { throw AgentError.message("A value is required for " + key + ".") }
        return value
    }

    private func integer(_ input: Any?, default defaultValue: Int? = nil, low: Int, high: Int) throws -> Int {
        if input == nil, let defaultValue { return defaultValue }
        let value = try number(input)
        guard value >= CGFloat(low), value <= CGFloat(high), value.rounded(.towardZero) == value else { throw AgentError.message("An integer is outside its supported range.") }
        return Int(value)
    }

    private func number(_ value: Any?) throws -> CGFloat {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw AgentError.message("Expected a finite numeric value.") }
        return CGFloat(n.doubleValue)
    }

    private func glow(_ value: Any?) throws -> Bool? {
        guard let value else { return nil }
        guard let option = value as? NSNumber, CFGetTypeID(option) == CFBooleanGetTypeID() else { throw AgentError.message("Glow must be true or false.") }
        return option.boolValue ? true : nil
    }

    private func stableID(_ page: UUID, _ request: UUID, _ slot: String) -> UUID {
        var hash = Array(SHA256.hash(data: Data((page.uuidString + request.uuidString + slot).utf8)).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x80
        hash[8] = (hash[8] & 0x3f) | 0x80
        return UUID(uuid: (hash[0], hash[1], hash[2], hash[3], hash[4], hash[5], hash[6], hash[7], hash[8], hash[9], hash[10], hash[11], hash[12], hash[13], hash[14], hash[15]))
    }

    private func json(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
    }

    enum AgentError: LocalizedError {
        case unavailable, unsaved, message(String)
        var errorDescription: String? {
            switch self {
            case .unavailable: "This item is unavailable in the shared library scope."
            case .unsaved: "Goodest Notes could not save this change."
            case .message(let text): text
            }
        }
    }
}
