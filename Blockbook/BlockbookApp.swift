import SwiftUI
import UniformTypeIdentifiers
import NaturalLanguage

@main struct BlockbookApp: App {
    @StateObject var studio: Studio
    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--classroom-ui-test") {
            _studio=StateObject(wrappedValue:Studio(folder:URL.applicationSupportDirectory.appendingPathComponent("ClassroomTest")));return
        }
        #endif
        _studio=StateObject(wrappedValue:Studio())
    }
    @StateObject var shared = SharedWorkspace()
    var body: some Scene {
        WindowGroup { Workspace().environmentObject(studio).environmentObject(shared).tint(.indigo).task {
            do {if !ProcessInfo.processInfo.arguments.contains("--classroom-ui-test") {try await WorkspaceConnection.importScopedDevice();if let project=WorkspaceConnection.deviceProject,!studio.library.allProjects.contains(where:{$0.id==project}) {try await shared.restore(project,studio:studio)}}}
            catch {studio.issue=error.localizedDescription}
            studio.indexScannedPages()
        } }
    }
}

enum Destination: Hashable { case desk, paper(UUID, UUID?), workflow(UUID), block(UUID), project(UUID) }
enum NewItem: String, Identifiable, CaseIterable {
    case notebook = "Notebook", whiteboard = "Whiteboard", workflow = "Workflow", block = "Block", pdf = "PDF", project = "Project"
    var id: Self { self }
    var icon: String {
        switch self { case .notebook: "book.closed"; case .whiteboard: "rectangle.and.pencil.and.ellipsis"; case .workflow: "point.3.connected.trianglepath.dotted"; case .block: "shippingbox"; case .pdf: "doc.richtext"; case .project: "folder" }
    }
}

struct Workspace: View {
    private struct AgentShareRequest: Identifiable {
        let id = UUID()
        let access: AgentAccess?
    }

    @EnvironmentObject var studio: Studio
    @State private var destination: Destination? = .desk
    @State private var restoredDestination=false
    private var destinationKey:String { "lastItem."+studio.folder.lastPathComponent }
    @State private var visibility = NavigationSplitViewVisibility.all
    @State private var nameType: NewItem?
    @State private var name = ""
    @State private var draft: BlockDraft?
    @State private var importing = false
    @EnvironmentObject private var shared: SharedWorkspace
    @State private var agentSettings = false
    @State private var busy = false
    @State private var query = ""
    @State private var results: [SearchHit] = []
    @State private var rename = false
    @State private var newTitle = ""
    @State private var creationProject: UUID?
    @State private var deleting = false
    @State private var agentShareRequest: AgentShareRequest?
    @StateObject private var agent = AgentSession()
    @FocusState private var nameFocused: Bool
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: $destination) {
                if query.isEmpty {
                    Label("Writing desk", systemImage: "rectangle.grid.2x2").tag(Destination.desk)
                    if !studio.library.allProjects.isEmpty {
                        Section("Projects") {
                            ForEach(studio.library.allProjects.reversed()) { project in
                                Label(project.title, systemImage: "folder").tag(Destination.project(project.id))
                            }
                        }
                    }
                    ForEach(PaperKind.allCases, id: \.self) { k in
                        let items = studio.library.papers.filter { $0.kind == k }
                        if !items.isEmpty {
                            Section(k == .pdf ? "PDFs" : k == .notebook ? "Notebooks" : "Whiteboards") {
                                ForEach(items.reversed()) { p in Label(p.title,systemImage: icon(k)).tag(Destination.paper(p.id,nil)) }
                            }
                        }
                    }
                    if !studio.library.workflows.isEmpty { Section("Workflows") { ForEach(studio.library.workflows.reversed()) { w in Label(w.title,systemImage: NewItem.workflow.icon).tag(Destination.workflow(w.id)) } } }
                    if !studio.library.blocks.isEmpty { Section("Reusable blocks") { ForEach(studio.library.blocks.reversed()) { b in Label(b.title,systemImage: b.parentID == nil ? "shippingbox" : "arrow.triangle.branch").tag(Destination.block(b.id)).draggable(b.id.uuidString) } } }
                } else {
                    Section("Search results") {
                        ForEach(results) { result in VStack(alignment: .leading, spacing: 3) { Text(result.title); Text(result.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2) }.tag(result.route) }
                        if results.isEmpty { Text("No matches").foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Goodest Notes").searchable(text: $query, prompt: "Search pages and blocks")
            .toolbar {
                ToolbarItem {
                    Menu {
                        ForEach(NewItem.allCases) { kind in Button(kind == .pdf ? "Import PDF" : "New " + kind.rawValue, systemImage: kind.icon) { start(kind) } }
                        Divider()
                        Button("Agent settings", systemImage: "slider.horizontal.3") { agentSettings = true }
                        Button(agent.isRunning ? "Local agent connection active" : "Agent connection", systemImage: "point.3.connected.trianglepath.dotted") { openAgent() }
                    } label: { Image(systemName: "plus.circle") }.accessibilityLabel("Create or import")
                }
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 265, max: 340)
        } detail: {
            Group {
                switch destination {
                case let .paper(id, page): PaperEditor(paperID: id, selectedPage: page).id(destination)
                case let .workflow(id): if let w = studio.workflow(id) { WorkflowView(flow: w) }
                case let .block(id): if let b = studio.block(id) { BlockDetail(raw: b) { destination = .paper($0,$1) } }
                case let .project(id):
                    if let project = studio.library.allProjects.first(where: { $0.id == id }) {
                        ProjectView(project: project, open: { destination = $0 }, create: { start($0, in: id) })
                    }
                default: desk
                }
            }
            .toolbar {
                if let title = currentTitle {
                    ToolbarItem {
                        Menu {
                            Button("Rename", systemImage: "pencil.line") { newTitle = title; rename = true }
                            if let ref = currentReference {
                                Button("Share with agent", systemImage: "point.3.connected.trianglepath.dotted") { openAgent(.items([ref])) }
                            } else if case let .project(id) = destination {
                                Button("Share project with agent", systemImage: "point.3.connected.trianglepath.dotted") { openAgent(.project(id)) }
                            }
                            if let ref = currentReference, !studio.library.allProjects.isEmpty {
                                Menu("Projects", systemImage: "folder") {
                                    ForEach(studio.library.allProjects) { project in
                                        let included = project.entries.contains(ref)
                                        Button(project.title, systemImage: included ? "checkmark.circle.fill" : "circle") {
                                            studio.change { $0.assign(ref, to: project.id, included: !included) }
                                        }
                                    }
                                }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = true }
                        } label: { Image(systemName: "ellipsis") }.accessibilityLabel("Library item actions")
                    }
                }
            }
        }
        .onAppear {
            guard !restoredDestination else{return}
            restoredDestination=true
            if let raw=UserDefaults.standard.string(forKey:destinationKey),let url=URL(string:raw),
               let ref=LibraryReference(url:url),studio.library.title(for:ref) != nil { _=follow(url) }
            else if let raw=UserDefaults.standard.string(forKey:destinationKey),let url=URL(string:raw),url.host=="project",let id=UUID(uuidString:url.lastPathComponent),studio.library.allProjects.contains(where:{$0.id==id}) { destination = .project(id) }
        }
        .onChange(of: destination) { _, next in
            switch next {
            case .paper(let id,_): UserDefaults.standard.set(LibraryReference(.paper,id).link,forKey:destinationKey)
            case .workflow(let id): UserDefaults.standard.set(LibraryReference(.workflow,id).link,forKey:destinationKey)
            case .block(let id): UserDefaults.standard.set(LibraryReference(.block,id).link,forKey:destinationKey)
            case .project(let id): UserDefaults.standard.set("goodestnotes://project/"+id.uuidString,forKey:destinationKey)
            default:UserDefaults.standard.removeObject(forKey:destinationKey)
            }

            if !query.isEmpty { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { _ = studio.flushWrites(); agent.stop() } }
        .environment(\.openURL, OpenURLAction { url in
            if ["blockbook","goodestnotes"].contains(url.scheme) { return follow(url) ? .handled : .discarded }
            return .systemAction
        })
        .onOpenURL { _ = follow($0) }
        .sheet(isPresented: $agentSettings) { AgentSettings() }
        .task(id: scenePhase) {
            while scenePhase == .active && !Task.isCancelled {
                for project in studio.library.allProjects where shared.shared(project.id) { await shared.sync(project,studio:studio) }
                try? await Task.sleep(for:.seconds(5))
            }
        }
        .task(id: SearchInput(query: query, library: studio.library)) {
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { results = []; return }
            do {
                try await Task.sleep(for: .milliseconds(160))
                let lib = studio.library, q = query
                let found = await Task.detached(priority: .userInitiated) { SearchHit.search(q, in: lib) }.value
                try Task.checkCancellation()
                results = found
            } catch {}
        }
        .sheet(item: $nameType) { type in
            NavigationStack { Form { TextField("\(type.rawValue) name", text: $name).focused($nameFocused).submitLabel(.done).onSubmit { create(type) } }.navigationTitle("New " + type.rawValue).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { nameType = nil } }
                ToolbarItem(placement: .confirmationAction) { Button("Create") { create(type) }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
            } }.presentationDetents([.medium]).task { nameFocused = true }
        }
        .sheet(item: $draft) { BlockEditor($0) { id in
            if let creationProject { studio.change { $0.assign(.init(.block, id), to: creationProject, included: true) } }
            destination = .block(id)
        } }
        .sheet(item: $agentShareRequest) { request in AgentConnectionView(session: agent, initialAccess: request.access) }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf]) { result in
            guard case let .success(file) = result else { return }
            busy = true
            let project = creationProject
            Task {
                defer { busy = false }
                do {
                    let id = try await studio.importPDF(file)
                    if let project { studio.change { $0.assign(.init(.paper, id), to: project, included: true) } }
                    destination = .paper(id, nil)
                } catch { studio.issue = error.localizedDescription }
            }
        }
        .overlay { if busy { ProgressView("Importing and indexing PDF…").padding(24).background(.regularMaterial,in: RoundedRectangle(cornerRadius: 14)) } }
        .alert("Rename", isPresented: $rename) {
            TextField("Name", text: $newTitle)
            Button("Save") { commitRename() }
            Button("Cancel",role: .cancel) {}
        }
        .confirmationDialog("Delete \(currentTitle ?? "item")?", isPresented: $deleting, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { deleteCurrent() }
        } message: {
            if case .project = destination { Text("The project will be removed. Its items will stay in your library.") }
            else if case .block = destination { Text("Its live placements will be removed. Existing variations will keep their current content.") }
            else { Text("This item will be removed from your library and projects.") }
        }
        .alert("Goodest Notes", isPresented: Binding(get: { studio.issue != nil }, set: { if !$0 { studio.issue = nil } })) { Button("OK") { studio.issue = nil } } message: { Text(studio.issue ?? "") }
    }
    var currentTitle: String? {
        if case let .project(id) = destination { return studio.library.allProjects.first(where: { $0.id == id })?.title }
        return currentReference.flatMap(studio.library.title(for:))
    }
    var currentReference: LibraryReference? {
        switch destination {
        case let .paper(id, _): .init(.paper, id)
        case let .workflow(id): .init(.workflow, id)
        case let .block(id): .init(.block, id)
        default: nil
        }
    }

    private func openAgent(_ access: AgentAccess? = nil) {
        agentShareRequest = AgentShareRequest(access: access)
    }
    func deleteCurrent() {
        let deleted: Bool
        if case let .project(id) = destination { deleted = studio.change { $0.projects?.removeAll { $0.id == id } } }
        else if let currentReference { deleted = studio.deleteEntry(currentReference) }
        else { return }
        if deleted { destination = .desk }
    }
    func follow(_ url: URL) -> Bool {
        if ["goodestnotes","blockbook"].contains(url.scheme), url.host == "project", let id = UUID(uuidString: url.lastPathComponent),
           studio.library.allProjects.contains(where: { $0.id == id }) { destination = .project(id); return true }
        guard let ref = LibraryReference(url: url), studio.library.title(for: ref) != nil else {
            if ["blockbook","goodestnotes"].contains(url.scheme) { studio.issue = "This Goodest Notes item is no longer available." }
            return false
        }
        query = ""
        if ref.kind == .paper, url.pathComponents.count == 4, url.pathComponents[2] == "page",
           let page = UUID(uuidString: url.pathComponents[3]), studio.paper(ref.id)?.pages.contains(where: { $0.id == page }) == true {
            destination = .paper(ref.id, page)
        } else { destination = ref.destination }
        return true
    }
    func commitRename() {
        let text = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        studio.change { lib in
            switch destination {
            case let .paper(id,_): if let i = lib.papers.firstIndex(where: { $0.id == id }) { lib.papers[i].title = text }
            case let .workflow(id): if let i = lib.workflows.firstIndex(where: { $0.id == id }) { lib.workflows[i].title = text }
            case let .block(id): if let i = lib.blocks.firstIndex(where: { $0.id == id }) { lib.blocks[i].title = text }
            case let .project(id): lib.editProject(id) { $0.title = text }
            default: break
            }
        }
    }
    var desk: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 25) {
                Text("Writing desk").font(.system(size: 44,weight: .medium,design: .serif)).padding(.top,30)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 16)], spacing: 16) {
                    ForEach([NewItem.notebook,.whiteboard,.workflow]) { type in
                        Button { start(type) } label: {
                            VStack(alignment: .leading, spacing: 12) {
                                Cover(type: type).aspectRatio(1.5, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 10))
                                Label("New " + type.rawValue.lowercased(),systemImage: "plus").font(.headline)
                            }.frame(maxWidth: .infinity,alignment: .leading)
                        }.buttonStyle(.plain)
                    }
                }
                HStack(spacing: 15) {
                    Button("Import PDF",systemImage: "doc.badge.plus") { start(.pdf) }
                    Button("New block",systemImage: "shippingbox") { start(.block) }
                    Button("New project", systemImage: "folder.badge.plus") { start(.project) }
                }.buttonStyle(.bordered)
                Button("Agent settings", systemImage:"slider.horizontal.3") { agentSettings=true }
                Button(agent.isRunning ? "Local agent connected" : "Connect an agent", systemImage: "point.3.connected.trianglepath.dotted") { openAgent() }
                Button("Open circuit lesson", systemImage:"lightbulb") {
                    Task { do { destination = .paper(try await CircuitLesson.add(to:studio),nil) } catch {studio.issue=error.localizedDescription} }
                }
                Divider()
                if !studio.library.papers.isEmpty {
                    Text("Pages on your desk").font(.title2.weight(.semibold))
                    ForEach(studio.library.papers.suffix(6).reversed()) { p in
                        Button { destination = .paper(p.id,nil) } label: { HStack { Label(p.title,systemImage: icon(p.kind)); Spacer(); Text("\(p.pages.count) " + (p.pages.count == 1 ? "page" : "pages")).foregroundStyle(.secondary) } }.buttonStyle(.plain)
                    }
                }
            }.padding(32).frame(maxWidth: 960,alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    func icon(_ k: PaperKind) -> String { k == .pdf ? NewItem.pdf.icon : k == .whiteboard ? NewItem.whiteboard.icon : NewItem.notebook.icon }
    func start(_ kind: NewItem, in project: UUID? = nil) {
        creationProject = project
        if kind == .pdf { importing = true } else if kind == .block { draft = BlockDraft(block: Block(title: "")) }
        else { name = ""; nameType = kind }
    }
    func create(_ kind: NewItem) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        if kind == .project {
            let project = Project(title: title)
            if studio.change({ $0.addProject(project) }) { destination = .project(project.id); nameType = nil }
        } else if kind == .workflow {
            let w = Workflow(title: title)
            if studio.change({ lib in
                lib.workflows.append(w)
                if let creationProject { lib.assign(.init(.workflow, w.id), to: creationProject, included: true) }
            }) { destination = .workflow(w.id); nameType = nil }
        } else {
            let board = kind == .whiteboard
            let paper = Paper(title: title, kind: board ? .whiteboard : .notebook, pages: [board ? SheetPage(size: CGSize(width: 2400,height: 1800)) : SheetPage()])
            if studio.change({ lib in
                lib.papers.append(paper)
                if let creationProject { lib.assign(.init(.paper, paper.id), to: creationProject, included: true) }
            }) { destination = .paper(paper.id,nil); nameType = nil }
        }
    }
}
private struct SearchInput: Equatable { var query: String; var library: Library }
struct SearchHit: Identifiable {
    let id = UUID()
    var route: Destination
    var title: String
    var excerpt: String
    static func search(_ query: String, in lib: Library) -> [Self] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        var hits = lib.papers.flatMap { d in d.pages.enumerated().map { i,p in Self(route: .paper(d.id,p.id), title: "\(d.title) · \(i+1)", excerpt: p.text) } }
        hits += lib.blocks.map { raw in let b = lib.resolved(raw); return Self(route: .block(b.id), title: b.title, excerpt: (BlockField.allCases.map { b[$0] } + [b.source?.excerpt ?? "", b.context ?? ""]).joined(separator: "\n")) }
        hits += lib.workflows.map { w in Self(route: .workflow(w.id), title: w.title, excerpt: [w.context ?? "", w.steps.compactMap { s in lib.blocks.first { $0.id == s.blockID }?.title }.joined(separator: " → ")].joined(separator: "\n")) }
        hits += lib.allProjects.map { Self(route: .project($0.id), title: $0.title, excerpt: $0.markdown) }
        let tokens = q.split(whereSeparator: \.isWhitespace)
        let embedding = tokens.count > 1 ? NLEmbedding.sentenceEmbedding(for: .english) : nil
        return hits.compactMap { hit -> (Double, Self)? in
            let all = (hit.title + " " + hit.excerpt).lowercased()
            var score = 0.0
            if hit.title.localizedCaseInsensitiveContains(q) { score += 6 }
            if all.contains(q) { score += 4 }
            if tokens.allSatisfy({ all.contains($0) }) { score += 2 }
            if score == 0, let embedding {
                let distance = embedding.distance(between: q, and: String(all.prefix(350)))
                if distance < 0.55 { score = 1-distance }
            }
            guard score > 0 else { return nil }
            var result = hit
            let lines = hit.excerpt.split(separator: "\n")
            result.excerpt = String((lines.first(where: { $0.localizedCaseInsensitiveContains(q) }) ?? lines.first ?? "").prefix(180))
            return (score, result)
        }.sorted { $0.0 == $1.0 ? $0.1.title < $1.1.title : $0.0 > $1.0 }.map(\.1)
    }
}
struct Cover: View {
    let type: NewItem
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack {
                (type == .notebook ? Color(red: 0.22,green: 0.26,blue: 0.55) : type == .whiteboard ? Color(red: 0.78,green: 0.86,blue: 0.80) : Color(red: 0.88,green: 0.71,blue: 0.54))
                Canvas { ctx,size in
                    let ink = Color.black.opacity(0.18)
                    if type == .notebook {
                        for n in 0..<5 { let x = w*0.14+CGFloat(n)*2; var p = Path(); p.move(to: .init(x:x,y:0)); p.addLine(to: .init(x:x,y:h)); ctx.stroke(p,with:.color(.white.opacity(0.13)),lineWidth:1) }
                        let label = CGRect(x:w*0.31,y:h*0.26,width:w*0.50,height:h*0.37)
                        ctx.fill(Path(roundedRect: label,cornerRadius: 3),with:.color(.white.opacity(0.88)))
                        for n in 1...2 { let y = label.minY+CGFloat(n)*label.height/3; var p = Path(); p.move(to:.init(x:label.minX+8,y:y)); p.addLine(to:.init(x:label.maxX-8,y:y)); ctx.stroke(p,with:.color(ink),lineWidth:1) }
                    } else if type == .whiteboard {
                        for x in stride(from: CGFloat(8), to:w, by:12) { for y in stride(from: CGFloat(8), to:h, by:12) { ctx.fill(Path(ellipseIn:CGRect(x:x,y:y,width:2,height:2)),with:.color(ink)) } }
                        var p = Path(); p.move(to:.init(x:w*0.17,y:h*0.72)); p.addQuadCurve(to:.init(x:w*0.47,y:h*0.43),control:.init(x:w*0.42,y:-h*0.08)); p.addQuadCurve(to:.init(x:w*0.83,y:h*0.27),control:.init(x:w*0.53,y:h*1.1)); ctx.stroke(p,with:.color(.black.opacity(0.61)),style:StrokeStyle(lineWidth:3,lineCap:.round))
                    } else {
                        let centers = [CGPoint(x:w*0.22,y:h*0.5),CGPoint(x:w*0.5,y:h*0.29),CGPoint(x:w*0.78,y:h*0.59)]
                        var p = Path(); p.addLines(centers); ctx.stroke(p,with:.color(.black.opacity(0.6)),lineWidth:2)
                        for c in centers { let rect = CGRect(x:c.x-w*0.095,y:c.y-h*0.12,width:w*0.19,height:h*0.24); ctx.fill(Path(roundedRect:rect,cornerRadius:4),with:.color(.white.opacity(0.94))); ctx.stroke(Path(roundedRect:rect,cornerRadius:4),with:.color(ink),lineWidth:1.5) }
                    }
                }
            }
        }.accessibilityHidden(true)
    }
}
