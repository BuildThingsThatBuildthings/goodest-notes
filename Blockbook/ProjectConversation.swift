import SwiftUI

func displayModel(_ id: String) -> String {
    ["gemini-4-neon":"Gemini 4 Neon","grok-4.7":"Grok 4.7","claude-opus-5-5":"Claude Opus 5.5","claude-fable-5-2":"Claude Fable 5.2","claude-sonnet-5-5":"Claude Sonnet 5.5","gpt-6.2-astra":"GPT-6.2 Astra","gpt-6.2-sol":"GPT-6.2 Sol"][id] ?? id
}

struct AgentSettings: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var workspace: SharedWorkspace
    @State private var remoteProjects: [Project]=[]
    @State private var endpoint = WorkspaceConnection.origin
    @State private var key = ""
    @State private var main = ""
    @State private var models: [String] = []
    @State private var balances: [String] = []
    @State private var info = ""
    @State private var providers = ""
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    private func load(connect: Bool = false, selected: String? = nil) async {
        busy = true; defer { busy = false }
        do {
            if connect { try WorkspaceConnection.save(endpoint,key:key); key = "" }
            guard let data = try await WorkspaceConnection.request("/v1/settings",selected.map { ["main":$0] }) as? [String:Any] else { return }
            main = data["main"] as? String ?? ""
            models = data["models"] as? [String] ?? []
            balances = (data["accounts"] as? [[String:Any]] ?? []).map { row in
                String(format:"%@   $%.2f spent · $%.2f reserved · $%.2f remaining", (row["provider"] as? String ?? "").capitalized,row["spent"] as? Double ?? 0,row["reserved"] as? Double ?? 0,row["remaining"] as? Double ?? 0)
            }
            let keys = data["providers"] as? [String:Bool] ?? [:]
            providers = ["anthropic","openai","google","xai"].map { $0.capitalized + (keys[$0] == true ? " key configured" : " key needed") }.joined(separator:" · ")
            if let projects=try await WorkspaceConnection.request("/v1/projects") as? [[String:Any]] {
                remoteProjects=projects.compactMap { row in guard let raw=row["id"] as? String,let id=UUID(uuidString:raw),let name=row["title"] as? String else {return nil};return Project(id:id,title:name) }
            }
            if data["role"] as? String=="device" {info="Connected to one project. Enter the owner key to manage the full workspace.";return}
            info = selected == nil ? "Workspace connected" : "Main agent updated for future assignments."
        } catch { info = error.localizedDescription }
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Private workspace") {
                    TextField("HTTPS address",text:$endpoint).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("Workspace owner key",text:$key)
                    Button("Connect") { Task { await load(connect:true) } }
                    Text(info).font(.footnote)
                }
                if !models.isEmpty {
                    Section("Agent team") {
                        Picker("Main agent",selection:Binding(get:{ main },set:{ choice in Task { await load(selected:choice) } })) { ForEach(models,id:\.self) { Text(displayModel($0)).tag($0) } }
                        Text("New assignments use this main agent. Each assignment keeps its model and reviewer in the project conversation.").font(.footnote)
                        Text(providers).font(.footnote)
                        Button("Check available models") {
                            Task { do {
                                let data = try await WorkspaceConnection.request("/v1/providers") as? [String:[String:Any]] ?? [:]
                                providers = data.keys.sorted().map { key in key.capitalized + " · " + ((data[key]?["models"] as? [String])?.map(displayModel).joined(separator:", ").nonempty ?? "No verified models") }.joined(separator:"\n")
                            } catch { info = error.localizedDescription } }
                        }
                    }
                    if !remoteProjects.isEmpty {
                        Section("Download projects") {
                            ForEach(remoteProjects.filter { p in !studio.library.allProjects.contains(where:{$0.id==p.id}) }) { p in
                                Button(p.title,systemImage:"arrow.down.circle") { Task { busy=true;defer {busy=false}; do {try await workspace.restore(p.id,studio:studio);info="Downloaded "+p.title} catch { info=error.localizedDescription } } }
                            }
                        }
                    }
                    Section("Monthly API budget") { ForEach(balances,id:\.self) { Text($0) } }
                }
            }.disabled(busy).navigationTitle("Agent settings")
                .toolbar { Button("Done") { dismiss() } }.task { await load() }
        }
    }
}

private extension String { var nonempty: String? { isEmpty ? nil : self } }
private struct Post: Identifiable {
    let id: String, author: String, body: String, anchor: String?, reply: String?, seq: Int
    init?(_ row: [String:Any]) {
        guard let id = row["id"] as? String, let author = row["author"] as? String, let body = row["body"] as? String else { return nil }
        self.id=id; self.author=author; self.body=body; anchor=row["anchor"] as? String; reply=row["reply"] as? String; seq=Int(String(describing:row["seq"] ?? "0")) ?? 0
    }
}
private struct Assignment: Identifiable {
    let id: String, brief: String, state: String, models: [String]
    init?(_ row: [String:Any]) {
        guard let id = row["id"] as? String, let brief = row["brief"] as? String, let state = row["state"] as? String else { return nil }
        self.id=id; self.brief=brief; self.state=state; models=row["models"] as? [String] ?? []
    }
}
struct ProjectConversation: View {
    @EnvironmentObject private var studio: Studio
    @EnvironmentObject private var workspace: SharedWorkspace
    @Environment(\.openURL) private var openURL
    let project: Project
    var anchor: String?
    private let canvasAgents = ["claude-opus-5-5","gpt-6.2-sol","gemini-4-neon","grok-4.7"]
    @State private var chosen: Set<String> = ["claude-opus-5-5","gpt-6.2-sol"]
    @State private var posts: [Post] = []
    @State private var tasks: [Assignment] = []
    @State private var draft = ""
    @State private var reply: String?
    @State private var settings = false
    @State private var status = ""
    @State private var saving = false
    @State private var pending: [String:String] = [:]

    func refresh() async throws {
        let data = try await WorkspaceConnection.action("read_conversation",project:project.id,args:["after":posts.last?.seq ?? 0])
        let messages = (data["messages"] as? [[String:Any]] ?? []).compactMap(Post.init)
        let known = Set(posts.map(\.id))
        posts.append(contentsOf:messages.filter { !known.contains($0.id) })
        if !messages.isEmpty { await workspace.sync(project,studio:studio) }
        tasks = (data["tasks"] as? [[String:Any]] ?? []).compactMap(Assignment.init)
    }
    func send(_ action: String, extra: [String:Any] = [:]) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                var args = extra
                if extra["agents"] != nil, let anchor,let url=URL(string:anchor),
                   let pageID=UUID(uuidString:url.lastPathComponent),
                   let paper=studio.library.papers.first(where:{$0.pages.contains(where:{$0.id==pageID})}),
                   let page=paper.pages.first(where:{$0.id==pageID}) {
                    let drawing=try studio.drawing(pageID)
                    let objectID=URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems?.first(where:{$0.name=="object"})?.value.flatMap{UUID(uuidString:$0)}
                    let bounds=page.canvas?.items.first(where:{$0.id==objectID})?.frame.insetBy(dx:-50,dy:-50) ?? SheetRenderer.contentBounds(paper:paper,page:page,drawing:drawing)
                    let image=try SheetRenderer.snapshot(studio,paper:paper,page:page,rect:bounds)
                    let scale=min(1,320/max(image.size.width,image.size.height,1))
                    let size=CGSize(width:max(1,image.size.width*scale),height:max(1,image.size.height*scale))
                    let format=UIGraphicsImageRendererFormat();format.scale=1;format.opaque=true
                    let thumbnail=UIGraphicsImageRenderer(size:size,format:format).image { _ in image.draw(in:CGRect(origin:.zero,size:size)) }
                    guard let data=thumbnail.pngData(),data.count<=262500 else {throw WorkspaceError.message("Select a smaller canvas region for this assignment.")}
                    args["snapshot"]=["png":data.base64EncodedString(),"rect":[bounds.minX,bounds.minY,bounds.width,bounds.height]] as [String:Any]
                }
                args["text"] = draft; args["anchor"] = anchor; args["reply"] = reply
                let signature = String(decoding:try JSONSerialization.data(withJSONObject:args,options:[.sortedKeys]),as:UTF8.self) + action
                let request = pending[signature] ?? UUID().uuidString
                pending[signature] = request; args["request_id"] = request
                _ = try await WorkspaceConnection.action(action,project:project.id,args:args)
                pending.removeValue(forKey:signature)
                if action != "control_task" { draft = ""; reply = nil }
                try await refresh(); status = ""
            } catch { status = error.localizedDescription }
        }
    }
    var body: some View {
        VStack(alignment:.leading,spacing:10) {
            HStack { Text("Project conversation").font(.headline); Spacer(); Button { settings=true } label:{ Image(systemName:"gearshape") }.accessibilityLabel("Agent settings") }
            Text(project.title).font(.subheadline)
            if workspace.shared(project.id) {
                Text(workspace.status[project.id] ?? "Connecting…").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:12) {
                        ForEach(posts) { post in
                            VStack(alignment:.leading,spacing:4) {
                                Text(displayModel(post.author)).font(.caption.bold())
                                if let parent = posts.first(where:{ $0.id == post.reply }) { Text("Reply to " + parent.author).font(.caption2) }
                                Text(post.body).textSelection(.enabled)
                                HStack {
                                    Button("Reply") { reply=post.id }
                                    if let link=post.anchor, let url=URL(string:link), ["goodestnotes","blockbook"].contains(url.scheme) { Button("Open page") { openURL(url) } }
                                }.font(.caption)
                            }
                        }
                        ForEach(tasks) { task in
                            Divider()
                            Text(task.brief).font(.subheadline.bold())
                            Text(task.state + " · " + task.models.map(displayModel).joined(separator:" → ")).font(.caption)
                            if !["completed","cancelled"].contains(task.state) {
                                HStack { Button(task.state=="queued" ? "Pause" : "Start or resume") { send("control_task",extra:["command":task.state=="queued" ? "pause":"resume","task":task.id]) }
                                    Button("Cancel task",role:.destructive) { send("control_task",extra:["command":"cancel","task":task.id]) } }.font(.caption)
                            }
                        }
                    }.frame(maxWidth:.infinity,alignment:.leading)
                }
                if reply != nil { Button("Cancel reply") { reply=nil }.font(.caption) }
                if anchor != nil {
                    Menu("Canvas agents · "+String(chosen.count),systemImage:"person.3") {
                        ForEach(canvasAgents,id: \.self) { agent in
                            Button(displayModel(agent),systemImage:chosen.contains(agent) ? "checkmark.circle.fill" : "circle") {
                                if chosen.contains(agent) { chosen.remove(agent) } else { chosen.insert(agent) }
                            }
                        }
                    }
                }
                TextField("Message or assignment",text:$draft,axis:.vertical).textFieldStyle(.roundedBorder)
                HStack { Button("Post") { send("post_message") }; Button(WorkspaceConnection.deviceProject != nil ? "Propose assignment" : (anchor == nil ? "Assign to team" : "Edit canvas")) {
                    send("assign_task",extra:anchor == nil ? [:] : ["agents":canvasAgents.filter(chosen.contains)])
                }.disabled(anchor != nil && chosen.isEmpty) }.disabled(saving || draft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            } else {
                Text("Share this project's page text, drawings, and attachments with your private workspace. You can then grant each chat access to the project.").font(.subheadline)
                Button("Share project") { Task { do { try await workspace.share(project,studio:studio); try await refresh(); status="" } catch { status=error.localizedDescription } } }.buttonStyle(.borderedProminent)
            }
            if !status.isEmpty { Text(status).font(.caption).foregroundStyle(.secondary) }
            Button("Copy project ID") { UIPasteboard.general.string=project.id.uuidString }.font(.caption)
        }.padding().sheet(isPresented:$settings) { AgentSettings() }.task(id:project.id) {
            posts=[]; tasks=[]
            while !Task.isCancelled {
                if workspace.shared(project.id) { do { try await refresh(); status="" } catch { status=error.localizedDescription } }
                try? await Task.sleep(for:.seconds(1))
            }
        }
    }
}
