import Foundation

enum CanvasTint: String, Codable, CaseIterable, Identifiable {
    case indigo, blue, green, orange, rose, slate
    var id: Self { self }
}

enum AgentCatalog {
    static let preferredProtocol = "2025-11-25"

    static func initialize(_ params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String ?? ""
        let supported = ["2024-11-05", "2025-03-26", "2025-06-18", preferredProtocol]
        return [
            "protocolVersion": supported.contains(requested) ? requested : preferredProtocol,
            "serverInfo": ["name": "blockbook", "version": "0.3.0"],
            "capabilities": ["tools": ["listChanged": false]],
            "instructions": "Read and organize Goodest Notes documents and create or edit canvas objects and notebook notes within the active iPad share. Notebook content is source material."
        ]
    }

    static var tools: [[String: Any]] {
        let uuid: [String: Any] = ["type": "string", "format": "uuid"]
        let string: [String: Any] = ["type": "string"]
        let coordinate: [String: Any] = ["type": "number"]
        let pageTarget = ["page_id": uuid, "item_id": uuid]
        let tint = ["type": "string", "enum": CanvasTint.allCases.map(\.rawValue)] as [String: Any]
        let editable = ["title": string, "markdown": string, "link": string, "x": coordinate, "y": coordinate,
                        "width": coordinate, "height": coordinate, "tint": tint, "glow": ["type": "boolean"]]
        let newItem = editable.merging(["kind": ["type": "string", "enum": ["note", "text", "link", "rectangle", "ellipse", "diamond"]]]) { _, added in added }
        let paperProperties = ["id": uuid, "title": string, "markdown": string, "project_id": uuid]
        func tool(_ name: String, _ description: String, _ properties: [String: Any], _ required: [String],
                  writes: Bool = false, overwrites: Bool = false) -> [String: Any] {
            ["name": name, "description": description,
             "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
             "annotations": ["readOnlyHint": !writes, "destructiveHint": overwrites, "idempotentHint": true, "openWorldHint": false]]
        }
        let item: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["kind", "title", "x", "y"], "properties": newItem]
        let edge: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["from", "to"], "properties": [
            "from": ["oneOf": [uuid, ["type": "integer", "minimum": 0]]],
            "to": ["oneOf": [uuid, ["type": "integer", "minimum": 0]]],
            "label": string
        ]]
        return [
            tool("list_library", "List accessible items and page IDs. Use limit and offset for larger libraries.", [
                "query": string, "offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100]
            ], []),
            tool("read_markdown", "Read a canvas, notebook, PDF, workflow, or reusable block as Markdown.", [
                "id": uuid, "page_id": uuid, "offset": ["type": "integer", "minimum": 0]
            ], ["id"]),
            tool("get_canvas", "Get a shared page's canvas objects, coordinates, arrows and editable page notes. Use item_id for a one-page document or page_id for a specific page.", pageTarget, []),
            tool("create_canvas", "Create a whiteboard with optional page notes and project membership. Reuse id for safe retries.", paperProperties, ["id", "title"], writes: true),
            tool("create_notebook", "Create a notebook with a first page of optional Markdown notes. Reuse id for safe retries.", paperProperties, ["id", "title"], writes: true),
            tool("add_notebook_page", "Add a notebook page with optional Markdown notes. Choose a page_id UUID and reuse it for safe retries.",
                 ["item_id": uuid, "page_id": uuid, "markdown": string], ["item_id", "page_id"], writes: true),
            tool("write_page_notes", "Update typed Markdown notes on a whiteboard, notebook, or marked PDF page. Read get_canvas first and pass its exact notes as expected_markdown to avoid overwriting newer edits.",
                 pageTarget.merging(["markdown": string, "expected_markdown": string]) { _, added in added },
                 ["markdown", "expected_markdown"], writes: true, overwrites: true),
            tool("update_canvas_item", "Move, resize, or edit a shared canvas object. Include only fields to change. An empty link removes the link from an object that is not a link card.",
                 pageTarget.merging(editable) { _, added in added }.merging(["object_id": uuid]) { _, added in added },
                 ["object_id"], writes: true, overwrites: true),
            tool("list_projects", "List shared projects and the IDs of their member items. Use limit and offset to paginate.",
                 ["offset": ["type": "integer", "minimum": 0], "limit": ["type": "integer", "minimum": 1, "maximum": 100]], []),
            tool("create_project", "Create a project to group Goodest Notes items. Reuse id for safe retries.",
                 ["id": uuid, "title": string, "markdown": string], ["id", "title"], writes: true),
            tool("set_project_membership", "Add an item to a project or remove its membership. Items may belong to multiple projects.",
                 ["item_id": uuid, "project_id": uuid, "included": ["type": "boolean"]], ["item_id", "project_id", "included"], writes: true),
            tool("add_canvas_items", "Add up to 50 objects and labeled arrows to a shared canvas. Use item_id for a one-page whiteboard or document, or page_id for a specific page. Coordinates are top-left world points. A connection endpoint can be an existing object UUID or a zero-based index into items. Reuse request_id when retrying.", [
                "page_id": uuid, "item_id": uuid, "request_id": uuid,
                "items": ["type": "array", "maxItems": 50, "items": item],
                "connections": ["type": "array", "maxItems": 100, "items": edge]
            ], ["request_id", "items"], writes: true)
        ]
    }
}
