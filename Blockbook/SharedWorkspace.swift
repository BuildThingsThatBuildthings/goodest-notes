import Foundation
import CryptoKit
import Security
import SwiftUI

enum WorkspaceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

struct WorkspaceConnection {
    static let endpointKey = "sharedWorkspace.origin"
    static var origin: String { UserDefaults.standard.string(forKey: endpointKey) ?? "https://goodest-notes.netlify.app" }
    private static func credential(_ origin: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Goodest Notes workspace", kSecAttrAccount as String: origin]
    }

    static func importDeviceConfiguration() throws {
        let file=URL.applicationSupportDirectory.appendingPathComponent("GoodestNotesConnection.json")
        guard FileManager.default.fileExists(atPath:file.path) else {return}
        let input=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:file))
        guard let endpoint=input["endpoint"],let key=input["ownerKey"] else {throw WorkspaceError.message("Invalid device configuration.")}
        try save(endpoint,key:key);try FileManager.default.removeItem(at:file)
    }
    static func save(_ endpoint: String, key: String) throws {
        guard let url = URL(string: endpoint), url.scheme == "https", url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, ["","/"].contains(url.path) else { throw WorkspaceError.message("Enter the HTTPS address of your workspace.") }
        let origin = String(endpoint.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        if !key.isEmpty {
            guard key.utf8.count >= 32 else { throw WorkspaceError.message("Enter your workspace owner key.") }
            let query = credential(origin)
            let data = [kSecValueData as String: Data(key.utf8), kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly] as [String: Any]
            let result = SecItemUpdate(query as CFDictionary, data as CFDictionary)
            if result == errSecItemNotFound {
                guard SecItemAdd(query.merging(data) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw WorkspaceError.message("Could not save the workspace key in Keychain.") }
            } else if result != errSecSuccess { throw WorkspaceError.message("Could not update the workspace key in Keychain.") }
        }
        UserDefaults.standard.set(origin, forKey: endpointKey)
    }
    static func request(_ path: String, _ payload: [String:Any]? = nil) async throws -> Any {
        let origin = Self.origin
        var query = credential(origin)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else { throw WorkspaceError.message("Connect your shared workspace in Agent settings.") }
        guard let url = URL(string: origin + path) else { throw WorkspaceError.message("Invalid workspace address.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 90)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        if let payload {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        }
        let (bytes, response) = try await URLSession.shared.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: bytes)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), let json else { throw WorkspaceError.message((json as? [String:Any])?["error"] as? String ?? "The workspace could not complete the request.") }
        return json
    }
    static func action(_ name: String, project: UUID, args: [String:Any] = [:]) async throws -> [String:Any] {
        var fields = args
        fields["project"] = project.uuidString.lowercased()
        let result = try await request("/v1/action", ["op":name,"args":fields])
        guard let object = result as? [String:Any] else { throw WorkspaceError.message("Invalid workspace response.") }
        return object
    }
}

private struct RecordSnapshot {
    var id: String
    var kind: String
    var body: [String:Any]
    var hash: String
    init(_ kind: String, _ id: UUID, _ body: [String:Any]) throws {
        self.id = kind + ":" + id.uuidString.lowercased()
        self.kind = kind
        self.body = body
        hash = try Self.hash(body)
    }
    init(file:WorkspaceFile) throws {
        id="asset:"+file.relative.lowercased();kind="asset";body=file.body;hash=try Self.hash(file.body)
    }
    static func hash(_ body: [String:Any]) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])).map { String(format: "%02x",$0) }.joined()
    }
    static func object<T: Encodable>(_ value: T) throws -> [String:Any] {
        guard let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String:Any] else { throw WorkspaceError.message("Invalid notebook record.") }
        return object
    }
    static func records(_ lib: Library, for project: Project) throws -> [RecordSnapshot] {
        var entries: [RecordSnapshot] = []
        for entry in project.entries {
            switch entry.kind {
            case .paper:
                guard let paper = lib.papers.first(where: { $0.id == entry.id }) else { continue }
                entries.append(try .init("paper",paper.id,["title":paper.title,"type":paper.kind.rawValue,"pages":paper.pages.map { $0.id.uuidString.lowercased() }]))
                for var page in paper.pages {
                    entries.append(try .init("note",page.id,["text":page.typed]))
                    page.typed = ""
                    var metadata = try object(page); metadata["paper"] = paper.id.uuidString.lowercased()
                    entries.append(try .init("page",page.id,metadata))
                }
            case .workflow:
                if let flow = lib.workflows.first(where: { $0.id == entry.id }) { entries.append(try .init("workflow",flow.id,object(flow))) }
            case .block:
                if let block = lib.blocks.first(where: { $0.id == entry.id }) { entries.append(try .init("block",block.id,object(lib.resolved(block)))) }
            }
        }
        return entries
    }
}

@MainActor final class SharedWorkspace: ObservableObject {
    @Published var status: [UUID:String] = [:]
    @Published var projectsInFlight: Set<UUID> = []
    private func key(_ project: UUID, _ field: String) -> String { WorkspaceConnection.origin + "." + project.uuidString + "." + field }
    func shared(_ id: UUID) -> Bool { UserDefaults.standard.bool(forKey: key(id,"shared")) }

    func restore(_ id:UUID,studio:Studio) async throws {
        guard !studio.library.allProjects.contains(where:{$0.id==id}) else {throw WorkspaceError.message("This project is already on your iPad.")}
        let state=try await WorkspaceConnection.action("read_space",project:id)
        guard let metadata=state["project"] as? [String:Any],let title=metadata["title"] as? String,let records=state["records"] as? [[String:Any]] else {throw WorkspaceError.message("Invalid project.")}
        let staging=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString,isDirectory:true)
        defer { try? FileManager.default.removeItem(at:staging) }
        var files:[String]=[]
        let destination=studio.folder
        for row in records where row["kind"] as? String=="asset" {
            try await WorkspaceFile.restore(row,project:id,into:staging)
            if let path=(row["body"] as? [String:Any])?["path"] as? String {files.append(path)}
        }
        var project=Project(id:id,title:title)
        var pages:[UUID:SheetPage]=[:], notes:[UUID:String]=[:], papers:[Paper]=[], blocks:[Block]=[], flows:[Workflow]=[]
        for row in records {
            guard let body=row["body"] as? [String:Any],let key=row["id"] as? String,let suffix=key.split(separator:":").last,let uuid=UUID(uuidString:String(suffix)) else {continue}
            let bytes=try JSONSerialization.data(withJSONObject:body)
            switch row["kind"] as? String {
            case "page": pages[uuid]=try JSONDecoder().decode(SheetPage.self,from:bytes)
            case "note": notes[uuid]=body["text"] as? String
            case "block": blocks.append(try JSONDecoder().decode(Block.self,from:bytes));project.entries.append(.init(.block,uuid))
            case "workflow": flows.append(try JSONDecoder().decode(Workflow.self,from:bytes));project.entries.append(.init(.workflow,uuid))
            default:break
            }
        }
        for row in records where row["kind"] as? String=="paper" {
            guard let body=row["body"] as? [String:Any],let key=row["id"] as? String,let uuid=UUID(uuidString:String(key.dropFirst(6))),let name=body["title"] as? String,let kind=PaperKind(rawValue:body["type"] as? String ?? ""),let order=body["pages"] as? [String] else { throw WorkspaceError.message("Invalid paper in project.") }
            let sheets=try order.map { raw -> SheetPage in
                guard let id=UUID(uuidString:raw),var page=pages[id] else {throw WorkspaceError.message("A shared page is missing.")}
                page.typed=notes[id] ?? "";return page
            }
            papers.append(.init(id:uuid,title:name,kind:kind,pages:sheets));project.entries.append(.init(.paper,uuid))
        }
        try await Task.detached(priority:.utility) {
            for path in files {
                let target=destination.appendingPathComponent(path),source=staging.appendingPathComponent(path)
                try FileManager.default.createDirectory(at:target.deletingLastPathComponent(),withIntermediateDirectories:true)
                if FileManager.default.fileExists(atPath:target.path) {
                    guard FileManager.default.contentsEqual(atPath:target.path,andPath:source.path) else {throw WorkspaceError.message("An attachment on this iPad has a different version. Both copies have been preserved in their workspaces.")}
                } else { try FileManager.default.copyItem(at:source,to:target) }
            }
        }.value
        guard studio.change({ lib in
            for paper in papers where !lib.papers.contains(where:{$0.id==paper.id}) {lib.papers.append(paper)}
            for flow in flows where !lib.workflows.contains(where:{$0.id==flow.id}) {lib.workflows.append(flow)}
            for block in blocks where !lib.blocks.contains(where:{$0.id==block.id}) {lib.blocks.append(block)}
            lib.addProject(project)
        }),studio.flushWrites() else {throw WorkspaceError.message("Could not save the project on iPad.")}
        UserDefaults.standard.set(true,forKey:key(id,"shared"))
        await sync(project,studio:studio)
    }
    func share(_ project: Project, studio: Studio) async throws {
        _ = try await WorkspaceConnection.request("/v1/projects", ["id":project.id.uuidString,"title":project.title])
        UserDefaults.standard.set(true,forKey:key(project.id,"shared"))
        await sync(project,studio:studio)
    }

    func sync(_ project: Project, studio: Studio) async {
        let id = project.id
        guard shared(id), projectsInFlight.insert(id).inserted else { return }
        defer { projectsInFlight.remove(id) }
        do {
            let library = studio.library
            let directory=studio.folder
            let local = try await Task.detached(priority: .utility) {
                var records=try RecordSnapshot.records(library,for:project)
                for path in WorkspaceFile.sources(library,project:project,folder:directory).sorted() {
                    records.append(try await RecordSnapshot(file:WorkspaceFile.publish(path,folder:directory)))
                }
                return records
            }.value
            let defaults = UserDefaults.standard
            var baselines = defaults.dictionary(forKey:key(id,"hash")) as? [String:String] ?? [:]
            var versions = defaults.dictionary(forKey:key(id,"versions")) as? [String:Int] ?? [:]
            let changes = local.filter { baselines[$0.id] != $0.hash }
            let removed = Set(baselines.keys).subtracting(local.map(\.id))
            for record in changes {
                let fields: [String:Any] = ["changes":[["id":record.id,"kind":record.kind,"base":versions[record.id] ?? 0,"body":record.body]]]
                let requestKey = key(id,"retry." + record.id)
                let signature = record.hash + ".\(versions[record.id] ?? 0)"
                let previous = defaults.stringArray(forKey:requestKey)
                let requestID = previous?.first == signature ? previous!.last! : UUID().uuidString
                defaults.set([signature,requestID],forKey:requestKey)
                let ack = try await WorkspaceConnection.action("sync",project:id,args:fields.merging(["request_id":requestID]) { _,new in new })
                guard let result = (ack["results"] as? [[String:Any]])?.first, let rev = result["rev"] as? Int else { throw WorkspaceError.message("Missing sync receipt.") }
                versions[record.id] = rev
                baselines[record.id] = record.hash
                defaults.set(baselines,forKey:key(id,"hash"))
                defaults.set(versions,forKey:key(id,"versions"))
                defaults.removeObject(forKey:requestKey)
            }
            if !removed.isEmpty {
                _ = try await WorkspaceConnection.action("sync",project:id,args:["detach":Array(removed),"changes":[],"request_id":UUID().uuidString])
                for key in removed { baselines.removeValue(forKey:key); versions.removeValue(forKey:key) }
            }
            let state = try await WorkspaceConnection.action("read_space",project:id)
            let records = state["records"] as? [[String:Any]] ?? []
            let conflicts = state["conflicts"] as? [[String:Any]] ?? []
            for row in records {
                guard row["kind"] as? String == "note", let record = row["id"] as? String, let version = row["rev"] as? Int, let body = row["body"] as? [String:Any], let text = body["text"] as? String, let page = UUID(uuidString:String(record.dropFirst(5))), let old = local.first(where: { $0.id == record }), let paper = studio.library.papers.first(where: { $0.pages.contains(where: { $0.id == page }) }), let current = paper.pages.first(where: { $0.id == page }) else { continue }
                if current.typed != old.body["text"] as? String { continue }
                if current.typed != text { _ = studio.editPage(paper.id,page) { $0.typed = text } }
                versions[record] = version; baselines[record] = try RecordSnapshot.hash(body)
            }
            guard studio.flushWrites() else { throw WorkspaceError.message("Could not save downloaded notes.") }
            defaults.set(baselines,forKey:key(id,"hash")); defaults.set(versions,forKey:key(id,"versions"))
            status[id] = conflicts.isEmpty ? "Synced" : "\(conflicts.count) conflicting edits"
        } catch { status[id] = error.localizedDescription }
    }
}
