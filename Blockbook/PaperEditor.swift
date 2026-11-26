import SwiftUI
import PencilKit
import PhotosUI
import UniformTypeIdentifiers
import QuickLook

struct TextPanel: Identifiable {
    enum Mode { case transcript, notes, summary }
    let id = UUID()
    let mode: Mode
    let title: String
    var text: String
    var draftID: UUID? = nil
}

struct PaperEditor: View {
    @EnvironmentObject var studio: Studio
    let paperID: UUID
    @State var selectedPage: UUID?
    @State private var sketch: SketchSelection?
    @State private var playing: UUID?
    @State private var conversation: Project?
    @State private var instrument: Instrument = .pen
    @State private var color = UIColor(red: 0.10, green: 0.15, blue: 0.23, alpha: 1)
    @State private var width: CGFloat = 3
    @State private var magnifierTarget: CGPoint?
    @StateObject private var actions = SurfaceActions()
    @State private var draft: BlockDraft?
    @State private var panel: TextPanel?
    @State private var presenting = false
    @State private var generation = UUID()
    @State private var working = false
    @State private var copiedMarkdown = false
    @State private var selectedItem: UUID?
    @State private var connectFrom: UUID?
    @State private var itemDraft: CanvasDraft?
    @State private var contextDraft: CanvasContextDraft?
    @State private var connection: CanvasConnection?
    @State private var removingItem: CanvasItem?
    @State private var removingPage = false
    @State private var importingMedia = false
    @State private var pickingPhoto = false
    @State private var pickedPhoto: PhotosPickerItem?
    @State private var attachment: CanvasAttachment?
    @State private var previewFile: URL?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    var teaching = false
    var onTeachPage: (UUID) -> Void = { _ in }

    var body: some View {
        if let paper = studio.paper(paperID), let page = paper.pages.first(where: { $0.id == selectedPage }) ?? paper.pages.first {
            VStack(spacing: 0) {
                editorHeader(paper: paper, page: page)
                Divider()
                writingToolbar(paper: paper, page: page)
                if let visual=page.visual {
                    HStack {
                    if page.teachingVisuals.count>1 {
                        Menu("Saved visuals") {ForEach(page.teachingVisuals) { asset in
                            Button((asset.caption.isEmpty ? "Drawing" : asset.caption)+" · "+(asset.filename as NSString).pathExtension.uppercased()) {playing=asset.id}
                        }}
                    }
                    Button(playing != nil ? "Turn motion off" : "Play teaching visual",systemImage:playing != nil ? "pause.circle" : "play.circle") { playing = playing != nil ? nil : visual.id }.font(.footnote)
                    }
                }
                if instrument == .motion { Text("Lasso the ink you want to bring to life.").font(.footnote) }
                if instrument == .capture { Text("Drag a box around the part you want to reuse.").font(.footnote).padding(6) }
                if !teaching && instrument == .objects { itemBar(page: page) }
                paperCanvas(paper: paper, page: page)
                if let target = magnifierTarget {
                    WritingMagnifierView(studio: studio, paper: paper, page: page, actions: actions, target: target,
                                         tool: instrument, color: color, width: width,
                                         setTarget: { magnifierTarget = $0 }, close: { magnifierTarget = nil })
                }
            }
            .overlay(alignment: .bottom) {
                if copiedMarkdown {
                    Label("Markdown copied", systemImage: "checkmark.circle")
                        .padding(12).background(.regularMaterial, in: Capsule()).padding(.bottom, 12)
                        .allowsHitTesting(false)
                        .task {
                            try? await Task.sleep(for: .seconds(2))
                            if !Task.isCancelled { copiedMarkdown = false }
                        }
                }
            }
            .task(id: page.id) { if FileManager.default.fileExists(atPath: studio.url(page.id,"drawing").path) { studio.scheduleIndex(paperID: paperID, pageID: page.id) } }
            .sheet(item:$sketch) { source in SketchStudio(source:source,folder:studio.assetFolder) { result in
                if studio.editPage(paperID,page.id,{ sheet in var list=sheet.teachingVisuals;list.append(result);sheet.savedVisuals=list;sheet.visual=result }) { playing=result.id; instrument = .pen }
            } }
            .sheet(item: $draft) { BlockEditor($0) }
            .sheet(item: $panel) { item in
                TextPanelView(panel: item) { notes in
                    if studio.paper(paperID)?.pages.first(where: { $0.id == page.id })?.typed != item.text {
                        studio.issue = "The page changed while you were writing. Your draft is saved. Reopen Page notes to compare."
                    } else if studio.editPage(paperID, page.id, { $0.typed = notes }), studio.flushWrites() {
                        DraftText.clear(item.draftID)
                    }
                }
            }
            .sheet(item: $transfer) { SaveToFiles(transfer: $0) }
            .sheet(item: $itemDraft) { draft in
                CanvasItemEditor(draft: draft, close: { itemDraft = nil }) { item in save(item, page: page, paper: paper) }
            }
            .sheet(item: $attachment) { CanvasPlayback(title: $0.title, url: $0.url, kind: $0.kind) }
            .sheet(item: $connection) { edge in
                CanvasConnectionEditor(edge: edge) { label in
                    studio.updateCanvas(paperID, page.id) { content in
                        if let i = content.connections.firstIndex(where: { $0.id == edge.id }) { content.connections[i].label = label }
                    }
                } delete: {
                    studio.updateCanvas(paperID, page.id) { $0.connections.removeAll { $0.id == edge.id } }
                }
            }
            .quickLookPreview($previewFile)
            .photosPicker(isPresented: $pickingPhoto, selection: $pickedPhoto,
                          matching: .any(of: [.images, .videos]))
            .fileImporter(isPresented: $importingMedia, allowedContentTypes: [.item]) { result in
                switch result {
                case let .success(url): importMedia(url, page: page, paper: paper)
                case let .failure(error): studio.issue = error.localizedDescription
                }
            }
            .onChange(of: pickedPhoto) { _, value in
                guard let value else { return }
                pickedPhoto = nil
                Task {
                    guard !working else { return }
                    working = true
                    defer { working = false }
                    do {
                        guard let photo = try await value.loadTransferable(type: CanvasPhoto.self) else { throw CanvasError.invalidFile }
                        defer { try? FileManager.default.removeItem(at: photo.url.deletingLastPathComponent()) }
                        try await attach(photo.url, page: page, paper: paper)
                    } catch { studio.issue = error.localizedDescription }
                }
            }
            .confirmationDialog("Delete this page?", isPresented: $removingPage, titleVisibility: .visible) {
                Button("Delete page", role: .destructive) {
                    if studio.deletePage(paperID, pageID: page.id) { selectedPage = nil }
                }
            }
            .confirmationDialog("Delete canvas item?", isPresented: Binding(get: { removingItem != nil }, set: { if !$0 { removingItem = nil } }), titleVisibility: .visible, presenting: removingItem) { item in
                Button("Delete item and its connections", role: .destructive) {
                    if studio.updateCanvas(paperID, page.id, { $0.remove(item.id) }) {
                        item.ownedAssets.forEach(studio.removeAsset)
                        selectedItem = nil
                        connectFrom = nil
                    }
                    removingItem = nil
                }
            }
            .onChange(of: page.id) { _, _ in selectedItem = nil; connectFrom = nil; magnifierTarget = nil; contextDraft = nil }
            .fullScreenCover(isPresented: $presenting, onDismiss: { generation = UUID() }) {
                PaperEditor(paperID: paperID, selectedPage: page.id, teaching: true, onTeachPage: { selectedPage = $0 })
                    .onAppear { UIApplication.shared.isIdleTimerDisabled = true }.onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            }
             .inspector(isPresented:Binding(get:{ conversation != nil },set:{ if !$0 { conversation=nil } })) {
                if let project=conversation { ProjectConversation(project:project,anchor:"goodestnotes://paper/" + paperID.uuidString + "/page/" + page.id.uuidString + (selectedItem.map { "?object=" + $0.uuidString } ?? "")).inspectorColumnWidth(min:300,ideal:350,max:450) }
            }
            .onAppear {
                if selectedPage == nil, let last=UserDefaults.standard.string(forKey:"lastPage."+paperID.uuidString) { selectedPage=UUID(uuidString:last) }
                if teaching { instrument = .laser }
                else if let saved=UserDefaults.standard.string(forKey:"pencilTool"), let tool=Instrument(rawValue:saved) { instrument=tool }
            }
            .onChange(of:page.id) { _,id in UserDefaults.standard.set(id.uuidString,forKey:"lastPage."+paperID.uuidString) }
            .onChange(of:instrument) { _,tool in if !teaching { UserDefaults.standard.set(tool.rawValue,forKey:"pencilTool") } }
        }
    }
    @State private var transfer: Transfer?

    private func editorHeader(paper: Paper, page: SheetPage) -> some View {
        HStack(spacing: 12) {
            if teaching { Button("End", systemImage: "xmark") { onTeachPage(page.id); dismiss() } }
            Text(paper.title).font(.headline).lineLimit(1)
            if !teaching { Text(studio.saveError != nil ? "Save failed" : studio.pendingWrites == 0 ? "Saved on iPad" : "Saving…").font(.caption2).foregroundStyle(.secondary) }
            Spacer()
            let idx = paper.pages.firstIndex(of: page) ?? 0
            if paper.kind != .whiteboard {
                Button { selectedPage = paper.pages[idx-1].id } label: { Image(systemName: "chevron.left") }.disabled(idx == 0).accessibilityLabel("Previous page")
                Menu("\(idx+1) / \(paper.pages.count)") {
                    ForEach(Array(paper.pages.enumerated()), id: \.element.id) { i, p in Button("Page \(i+1)") { selectedPage = p.id } }
                }.monospacedDigit()
                Button { selectedPage = paper.pages[idx+1].id } label: { Image(systemName: "chevron.right") }.disabled(idx+1 == paper.pages.count).accessibilityLabel("Next page")
            }
            if !teaching {
                let projects = studio.library.allProjects.filter { $0.entries.contains(.init(.paper,paperID)) }
                if !projects.isEmpty {
                    Menu { ForEach(projects) { project in Button(project.title) { conversation=project } } } label: { Image(systemName:"bubble.left.and.bubble.right") }.accessibilityLabel("Project conversation")
                }
                Menu("Referenced by", systemImage: "link") {
                    let memberships = studio.library.allProjects.filter { $0.entries.contains(.init(.paper, paper.id)) }
                    ForEach(memberships) { project in Button(project.title) { openURL(URL(string: "goodestnotes://project/" + project.id.uuidString)!) } }
                    let links = studio.library.papers.flatMap { source in source.pages.compactMap { sheet -> Backlink? in
                        let linked = sheet.canvas?.items.contains { item in
                            guard let raw = item.link, let url = URL(string: raw), let target = LibraryReference(url: url) else { return false }
                            return target == LibraryReference(.paper, paper.id) && (url.pathComponents.count <= 2 || url.pathComponents.last?.lowercased() == page.id.uuidString.lowercased())
                        } == true
                        return linked ? Backlink(id: sheet.id, title: source.title, paperID: source.id) : nil
                    } }
                    ForEach(links) { link in Button(link.title) { openURL(URL(string: "goodestnotes://paper/\(link.paperID)/page/\(link.id)")!) } }
                    if memberships.isEmpty && links.isEmpty { Text("No references yet") }
                }.labelStyle(.iconOnly)
                if paper.kind == .notebook {
                    Button { let p = SheetPage(); if studio.change({ lib in
                        if let i = lib.papers.firstIndex(where: { $0.id == paperID }) { lib.papers[i].pages.append(p) }
                    }) { selectedPage = p.id } } label: { Image(systemName: "plus.rectangle.on.rectangle") }.accessibilityLabel("Add page")
                }
                addMenu(paper, page: page)
                Menu {
                    Button("Teach", systemImage: "play.display") { presenting = true }
                    Button("Recognize handwriting", systemImage: "text.viewfinder") { read(page, paper: paper, summarize: false) }
                    Button("Summarize page", systemImage: "text.quote") { read(page, paper: paper, summarize: true) }
                    Button(paper.kind == .whiteboard ? "Canvas notes" : "Page notes", systemImage: "note.text") { panel = TextPanel(mode: .notes, title: paper.kind == .whiteboard ? "Canvas notes" : "Page notes", text: page.typed, draftID: page.id) }
                    Button(paper.kind == .whiteboard ? "Make block from canvas" : "Make block from page", systemImage: "shippingbox") {
                        do {
                            let rect = SheetRenderer.contentBounds(paper: paper, page: page, drawing: try studio.drawing(page.id))
                            capture(page, paper: paper, rect: rect, entirePage: true)
                        } catch { studio.issue = error.localizedDescription }
                    }
                    if paper.kind != .whiteboard && paper.pages.count > 1 {
                        Button("Export this page as Markdown", systemImage: "text.document") { exportMarkdown(paper, pageID: page.id) }
                    }
                    Button("Copy page link", systemImage: "link") { UIPasteboard.general.string = "goodestnotes://paper/\(paper.id)/page/\(page.id)" }
                    Button("Copy Markdown", systemImage: "doc.on.doc") { copyMarkdown(paper) }
                    Button("Export \(paper.kind == .whiteboard ? "canvas" : "document") as Markdown", systemImage: "text.document") { exportMarkdown(paper) }
                    Button("Export marked PDF", systemImage: "square.and.arrow.up") {
                        do { transfer = Transfer(file: try SheetRenderer.export(paper, from: studio)) } catch { studio.issue = error.localizedDescription }
                    }
                    if paper.pages.count > 1 {
                        Divider()
                        Button("Delete this page", systemImage: "trash", role: .destructive) { removingPage = true }
                    }
                } label: { Image(systemName: "ellipsis.circle").frame(width: 44,height: 44) }.accessibilityLabel("Page actions")
            }
        }.padding(.horizontal, 14).frame(minHeight: 52).background(.background)
    }

    private func paperCanvas(paper: Paper, page: SheetPage) -> some View {
        let activeTool: Instrument = magnifierTarget == nil ? instrument : .writingTarget
        let view = DrawingSurface(
            studio: studio, paper: paper, page: page, tool: activeTool, color: color, width: width,
            actions: actions, selected: selectedItem, connecting: connectFrom,
            aimWriting: { magnifierTarget = $0 },
            openContext: { showContext($0, mode: $1, at: $2, page: page) },
            selectItem: { select($0, paper: paper, page: page) },
            moveItem: { move($0, to: $1, page: page) },
            visual: page.teachingVisuals.first(where:{$0.id==playing}),
            lasso: { polygon in
                do { sketch = try SketchSelection(polygon:polygon,studio:studio,paper:paper,page:page)
                    if sketch == nil { studio.issue="Draw around the ink strokes you want to animate." }
                } catch { studio.issue=error.localizedDescription }
            },
            capture: { capture(page, paper: paper, rect: $0, entirePage: false) }
        )
        return view.id("\(page.id)-\(generation)").overlay {
            if working { ProgressView().padding().background(.regularMaterial, in: Capsule()) }
        }.overlay {
            contextPopup(paper: paper, page: page)
        }
    }

    private func contextPopup(paper: Paper, page: SheetPage) -> some View {
        GeometryReader { proxy in
            let point = contextDraft?.point ?? CGPoint(x: proxy.size.width / 2, y: proxy.size.height / 2)
            Color.clear.frame(width: 18, height: 18).allowsHitTesting(false)
                .popover(item: $contextDraft, attachmentAnchor: .rect(.bounds)) { draft in
                    CanvasContextEditor(draft: draft) { item in
                        saveContext(item, draft: draft, page: page, paper: paper)
                    }
                }
                .position(x: min(max(12, point.x), max(12, proxy.size.width - 12)),
                          y: min(max(12, point.y), max(12, proxy.size.height - 12)))
        }
    }

    private func writingToolbar(paper: Paper, page: SheetPage) -> some View {
        HStack(spacing: 3) {
            ForEach(teaching ? [Instrument.laser,.pen,.glowPen,.marker,.eraser,.pan,.motion] : [.objects,.pen,.glowPen,.marker,.eraser,.select,.pan,.capture,.motion], id: \.self) { item in
                Button {
                    instrument = item
                    if !item.editsInk { magnifierTarget = nil }
                    if item != .objects { connectFrom = nil; selectedItem = nil }
                } label: {
                    Image(systemName: item.symbol).frame(minWidth: 27, idealWidth: 37, maxWidth: 42).frame(height: 42)
                        .background(item == instrument ? Color.accentColor.opacity(0.15) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel(toolLabel(item))
            }
            Divider().frame(height: 24)
            Menu {
                ForEach(0..<colors.count, id: \.self) { i in Button(colors[i].0) { color = colors[i].1 } }
                Divider()
                ForEach([CGFloat(2),4,7], id: \.self) { w in Button("\(Int(w)) pt") { width = w } }
            } label: { Circle().fill(Color(uiColor: color)).frame(width: 20,height: 20).frame(width: 42,height: 42) }.accessibilityLabel("Ink color and width")
            Spacer()
            Button { actions.undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 33,height: 42) }.accessibilityLabel("Undo")
            Button { actions.redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 33,height: 42) }.accessibilityLabel("Redo")
            if !teaching { magnifierButton(page: page) }
            Menu {
                Button("Zoom in", systemImage: "plus.magnifyingglass") { actions.zoom(1.35) }
                Button("Zoom out", systemImage: "minus.magnifyingglass") { actions.zoom(1 / 1.35) }
                Button(paper.kind == .whiteboard ? "Fit content" : "Fit page", systemImage: "arrow.down.right.and.arrow.up.left") { actions.fit() }
            } label: { Image(systemName: "magnifyingglass").frame(width: 36,height: 42) }.accessibilityLabel("Zoom")
        }.buttonStyle(.plain).padding(.horizontal, 10).background(.thinMaterial)
    }

    private func toolLabel(_ tool: Instrument) -> String {
        switch tool {
        case .motion: "Lasso a teaching visual"
        case .capture: "Draw a box to capture a block"
        case .objects: "Select or move objects"
        case .pan: "Pan canvas"
        case .glowPen: "Glow pen"
        default: tool.rawValue.capitalized
        }
    }

    private func magnifierButton(page: SheetPage) -> some View {
        let active = magnifierTarget != nil
        let fill = active ? Color.accentColor.opacity(0.15) : Color.clear
        return Button {
            if active {
                magnifierTarget = nil
            } else {
                if !instrument.editsInk { instrument = .pen }
                connectFrom = nil
                selectedItem = nil
                magnifierTarget = actions.center ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
            }
        } label: {
            Image(systemName: "plus.viewfinder").frame(width: 35, height: 42)
                .background(fill, in: RoundedRectangle(cornerRadius: 8))
        }.accessibilityLabel("Writing magnifier")
    }

    private func addMenu(_ paper: Paper, page: SheetPage) -> some View {
        Menu {
            Button("Markdown note", systemImage: "text.alignleft") { add(.note, page, paper) }
            Button("Text", systemImage: "textformat") { add(.text, page, paper) }
            Button("Link", systemImage: "link") { add(.link, page, paper) }
            Menu("Shape", systemImage: "square.on.circle") {
                ForEach([CanvasItemKind.rectangle, .ellipse, .diamond]) { kind in
                    Button(kind.label, systemImage: kind.icon) { add(kind, page, paper) }
                }
            }
            Divider()
            Button("Photo or video", systemImage: "photo.on.rectangle") { pickingPhoto = true }
            Button("Media or file", systemImage: "paperclip") { importingMedia = true }
            if let content = page.canvas, !content.items.isEmpty {
                Divider()
                Menu("Go to item", systemImage: "location.viewfinder") {
                    ForEach(content.items) { item in Button(item.title, systemImage: item.kind.icon) { reveal(item) } }
                }
            }
        } label: {
            Image(systemName: "plus.circle.fill").font(.title3).frame(width: 40, height: 40)
        }.accessibilityLabel("Add to canvas").disabled(working)
    }

    @ViewBuilder private func itemBar(page: SheetPage) -> some View {
        if connectFrom != nil {
            HStack {
                Text("Tap the item the arrow should point to.").font(.footnote)
                Spacer()
                Button("Cancel") { connectFrom = nil }
            }.padding(.horizontal, 14).padding(.vertical, 6)
        } else if let content = page.canvas, let item = content.items.first(where: { $0.id == selectedItem }) {
            HStack(spacing: 12) {
                Label(item.title, systemImage: item.kind.icon).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                if item.asset != nil || item.link != nil {
                    Menu("Open", systemImage: "arrow.up.forward.app") {
                        if let asset = item.asset { Button("Open attachment", systemImage: "paperclip") { openAsset(asset, item: item) } }
                        if let link = item.link, let url = CanvasItem.checkedLink(link) {
                            Button("Open link", systemImage: "link") { openURL(url) }
                        }
                    }.labelStyle(.iconOnly).accessibilityLabel("Open media or link")
                }
                Button {
                    let center = CGPoint(x: item.frame.midX, y: item.frame.midY)
                    showContext(item, mode: .read, at: actions.surface?.viewportPosition(center) ?? .zero, page: page)
                } label: { Image(systemName: "text.bubble") }.accessibilityLabel("Open context")
                Button { itemDraft = CanvasDraft(item: item, isNew: false) } label: { Image(systemName: "pencil") }.accessibilityLabel("Edit canvas item")
                Menu {
                    Button("Connect to another item", systemImage: "arrow.right") { connectFrom = item.id }.disabled(content.items.count < 2)
                    ForEach(content.connections.filter { $0.from == item.id || $0.to == item.id }) { edge in
                        let other = content.items.first { $0.id == (edge.from == item.id ? edge.to : edge.from) }?.title ?? "item"
                        Button(edge.label.isEmpty ? (edge.from == item.id ? "To " : "From ") + other : edge.label) { connection = edge }
                    }
                    Divider()
                    Button("Delete item", systemImage: "trash", role: .destructive) { removingItem = item }
                } label: { Image(systemName: "ellipsis.circle") }.accessibilityLabel("Canvas item actions")
            }.padding(.horizontal, 14).frame(minHeight: 36)
        }
    }

    private func showContext(_ item: CanvasItem, mode: CanvasContextMode, at point: CGPoint, page: SheetPage) {
        guard !teaching, connectFrom == nil else { return }
        let persisted = studio.paper(paperID)?.pages.first(where: { $0.id == page.id })?.canvas?.items.first(where: { $0.id == item.id })
        guard persisted != nil || item.kind == .inkContext else { return }
        contextDraft = CanvasContextDraft(item: persisted ?? item, mode: mode, point: point, isNew: persisted == nil)
    }

    private func saveContext(_ candidate: CanvasItem, draft: CanvasContextDraft, page: SheetPage, paper: Paper) -> Bool {
        guard let latest = studio.paper(paperID)?.pages.first(where: { $0.id == page.id }) else {
            studio.issue = CanvasError.missingItem.localizedDescription
            return false
        }
        var updated = candidate
        var oldAudio: CanvasAsset?
        if draft.isNew {
            if !candidate.hasPopOut { return true }
            updated.frame = fitItem(candidate.frame, page: latest, paper: paper)
            guard CanvasItem.valid(updated.frame) else { studio.issue = CanvasError.invalidLayout.localizedDescription; return false }
        } else {
            guard let current = latest.canvas?.items.first(where: { $0.id == candidate.id }) else {
                studio.issue = CanvasError.missingItem.localizedDescription
                return false
            }
            do { updated = try current.mergingContext(from: draft.item, changes: candidate) }
            catch { studio.issue = error.localizedDescription; return false }
            if current.audioNote != updated.audioNote { oldAudio = current.audioNote }
        }
        guard studio.updateCanvas(paperID, page.id, { content in
            if let index = content.items.firstIndex(where: { $0.id == updated.id }) { content.items[index] = updated }
            else { content.items.append(updated) }
        }) else { return false }
        if let oldAudio { studio.removeAsset(oldAudio) }
        return true
    }

    private func reveal(_ item: CanvasItem) {
        magnifierTarget = nil
        instrument = .objects
        selectedItem = item.id
        actions.reveal(CGPoint(x: item.frame.midX, y: item.frame.midY))
    }

    private func select(_ id: UUID?, paper: Paper, page: SheetPage) {
        if let from = connectFrom {
            guard let id, id != from, let content = page.canvas,
                  content.items.contains(where: { $0.id == from }), content.items.contains(where: { $0.id == id }) else { return }
            if let existing = content.connections.first(where: { $0.from == from && $0.to == id }) { connection = existing }
            else {
                let edge = CanvasConnection(from: from, to: id)
                if studio.updateCanvas(paperID, page.id, { $0.connections.append(edge) }) { connection = edge }
            }
            connectFrom = nil
        }
        selectedItem = id
    }

    private func move(_ id: UUID, to rect: CGRect, page: SheetPage) {
        guard CanvasItem.valid(rect) else { return }
        studio.updateCanvas(paperID, page.id) { content in
            if let i = content.items.firstIndex(where: { $0.id == id }) { content.items[i].frame = rect }
        }
    }

    private func add(_ kind: CanvasItemKind, _ page: SheetPage, _ paper: Paper) {
        let title = [.note, .link, .text].contains(kind) ? "" : kind.label
        let item = CanvasItem(kind: kind, title: title, frame: initialFrame(kind, page: page, paper: paper))
        itemDraft = CanvasDraft(item: item, isNew: true)
    }

    private func initialFrame(_ kind: CanvasItemKind, page: SheetPage, paper: Paper) -> CGRect {
        let center = actions.center ?? CGPoint(x: page.size.width / 2, y: page.size.height / 2)
        let size = kind.defaultSize
        let base = CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
        let occupied = page.canvas?.items.map(\.frame) ?? []
        for index in 0..<20 {
            let offset = CGFloat(index) * 32
            let candidate = fitItem(base.offsetBy(dx: offset, dy: offset), page: page, paper: paper)
            if !occupied.contains(where: { $0.insetBy(dx: 30, dy: 30).contains(CGPoint(x: candidate.midX, y: candidate.midY)) }) { return candidate }
        }
        return fitItem(base, page: page, paper: paper)
    }

    private func fitItem(_ frame: CGRect, page: SheetPage, paper: Paper) -> CGRect {
        guard paper.kind != .whiteboard else { return frame }
        let size = CGSize(width: min(frame.width, page.size.width), height: min(frame.height, page.size.height))
        return CGRect(x: max(0, min(frame.minX, page.size.width - size.width)),
                      y: max(0, min(frame.minY, page.size.height - size.height)), width: size.width, height: size.height)
    }

    private func save(_ proposed: CanvasItem, page: SheetPage, paper: Paper) -> Bool {
        var item = proposed
        item.frame = fitItem(proposed.frame, page: page, paper: paper)
        guard CanvasItem.valid(item.frame) else { studio.issue = CanvasError.invalidLayout.localizedDescription; return false }
        let saved = studio.updateCanvas(paperID, page.id) { content in
            if let i = content.items.firstIndex(where: { $0.id == item.id }) {
                item.audioNote = content.items[i].audioNote
                if item.inkAnchor != nil { item.frame = content.items[i].frame }
                content.items[i] = item
            }
            else { content.items.append(item) }
        }
        if saved { reveal(item) }
        return saved
    }

    private func importMedia(_ source: URL, page: SheetPage, paper: Paper) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { try await attach(source, page: page, paper: paper) }
            catch { studio.issue = error.localizedDescription }
        }
    }

    private func attach(_ source: URL, page: SheetPage, paper: Paper) async throws {
        let asset = try await studio.importAsset(source)
        let title = URL(fileURLWithPath: asset.filename).deletingPathExtension().lastPathComponent
        let item = CanvasItem(kind: asset.kind, title: title, asset: asset, frame: initialFrame(asset.kind, page: page, paper: paper))
        if !save(item, page: page, paper: paper) { studio.removeAsset(asset) }
    }

    private func openAsset(_ asset: CanvasAsset, item: CanvasItem) {
        let url = studio.assetURL(asset)
        guard FileManager.default.fileExists(atPath: url.path) else { studio.issue = CanvasError.invalidFile.localizedDescription; return }
        if asset.kind == .file { previewFile = url }
        else { attachment = CanvasAttachment(url: url, title: item.title, kind: asset.kind) }
    }

    private func exportMarkdown(_ paper: Paper, pageID: UUID? = nil) {
        guard !working else { return }
        working = true
        Task {
            defer { working = false }
            do { transfer = Transfer(file: try await WorkspaceMarkdown(studio: studio).writePaper(paper, pageID: pageID)) }
            catch { studio.issue = error.localizedDescription }
        }
    }

    private func copyMarkdown(_ paper: Paper) {
        do {
            UIPasteboard.general.string = try WorkspaceMarkdown(studio: studio).paper(paper)
            copiedMarkdown = true
        } catch { studio.issue = error.localizedDescription }
    }
    let colors: [(String, UIColor)] = [("Midnight", UIColor(red: 0.10,green: 0.15,blue: 0.23,alpha: 1)), ("Blue", .systemBlue), ("Vermilion", .systemRed), ("Green", .systemGreen), ("Gold", .systemOrange)]
    func read(_ page: SheetPage, paper: Paper, summarize: Bool) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do {
                let ink = try studio.drawing(page.id)
                let recognized = try await Task.detached { try InkAnalysis.text(in: ink) }.value
                studio.editPage(paper.id, page.id) { $0.inkText = recognized }
                var updated = page
                updated.inkText = recognized
                let source = updated.text
                let result = summarize ? await InkAnalysis.summary(source) : recognized
                panel = TextPanel(mode: summarize ? .summary : .transcript, title: summarize ? "Page summary" : "Recognized handwriting", text: result.isEmpty ? "No handwriting recognized on this page." : result)
            } catch { studio.issue = error.localizedDescription }
        }
    }
    func capture(_ page: SheetPage, paper: Paper, rect: CGRect, entirePage: Bool) {
        guard !working else { return }; working = true
        Task {
            defer { working = false }
            do {
                let image = try SheetRenderer.snapshot(studio, paper: paper, page: page, rect: rect)
                let text = try await Task.detached { try image.cgImage.map(InkAnalysis.ocr) ?? "" }.value
                let items = page.canvas?.items.filter { rect.intersects($0.frame) }.flatMap { [$0.title, $0.markdown] } ?? []
                let excerpt = ([entirePage ? page.typed : "", text] + items).filter { !$0.isEmpty }.joined(separator: "\n")
                let source = PageSource(documentID: paper.id, pageID: page.id, rect: rect, excerpt: excerpt)
                var block = Block(title: excerpt.split(separator: "\n").first.map { String($0.prefix(72)) } ?? paper.title + " capture", source: source)
                block.values = await CaptureAnalysis.organize(excerpt)
                instrument = .pen
                draft = BlockDraft(block: block, preview: image)
            } catch { studio.issue = error.localizedDescription }
        }
    }
}
struct TextPanelView: View {
    let panel: TextPanel
    let save: (String) -> Void
    @State private var value: String
    @State private var preview = false
    @State private var discard = false
    @FocusState private var focused: Bool
    @Environment(\.dismiss) var dismiss
    init(panel: TextPanel, save: @escaping (String)->Void) { self.panel = panel; self.save = save; _value = State(initialValue: DraftText.read(panel.draftID) ?? panel.text) }
    var body: some View {
        NavigationStack {
            Group {
                if panel.mode == .notes {
                    VStack(alignment: .leading, spacing: 12) {
                        Picker("Mode", selection: $preview) { Text("Write").tag(false); Text("Preview").tag(true) }.pickerStyle(.segmented)
                        if preview { ScrollView { MarkdownReadView(text: value) } }
                        else {
                            ZStack(alignment: .topLeading) {
                                if value.isEmpty { Text("Write in Markdown").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                                TextEditor(text: $value).scrollContentBackground(.hidden).focused($focused).accessibilityLabel(panel.title)
                            }
                        }
                    }.padding().onChange(of: preview) { _, showing in if showing { focused = false } }
                }
                else { ScrollView { Text(value).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding() } }
            }.navigationTitle(panel.title).toolbar {
                ToolbarItem(placement: .confirmationAction) { Button(panel.mode == .notes ? "Save" : "Done") { if panel.mode == .notes { save(value) }; dismiss() } }
                if panel.mode == .notes {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if value != panel.text { discard = true } else { dismiss() } } }
                    ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focused = false } }
                }
            }
            .task { if panel.mode == .notes { focused = true } }
            .onChange(of: value) { _, value in DraftText.save(value, for: panel.draftID) }
            .interactiveDismissDisabled(panel.mode == .notes && value != panel.text)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { DraftText.clear(panel.draftID); dismiss() }
            }
        }
    }
}


private struct Backlink: Identifiable { let id: UUID; let title: String; let paperID: UUID }
