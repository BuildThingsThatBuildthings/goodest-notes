import SwiftUI
import UniformTypeIdentifiers

struct Transfer: Identifiable { let id = UUID(); let file: URL }
struct SaveToFiles: UIViewControllerRepresentable {
    let transfer: Transfer
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [transfer.file], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}
struct ConvertMenu: View {
    @EnvironmentObject var studio: Studio
    let item: Conversion
    @State private var transfer: Transfer?
    var body: some View {
        Menu {
            ForEach(ExportKind.allCases, id: \.self) { format in
                Button(format.rawValue) {
                    do { transfer = Transfer(file: try item.write(format)) }
                    catch { studio.issue = error.localizedDescription }
                }
            }
        } label: { Label("Export", systemImage: "square.and.arrow.up") }
        .sheet(item: $transfer) { SaveToFiles(transfer: $0) }
    }
}

struct BlockDraft: Identifiable {
    var id = UUID()
    var block: Block
    var workflowID: UUID?
    var placementID: UUID?
    var preview: UIImage?
}

struct BlockEditor: View {
    @EnvironmentObject var studio: Studio
    @Environment(\.dismiss) var dismiss
    let draft: BlockDraft
    @State var block: Block
    @FocusState private var focusedField: String?
    @State private var discard = false
    var onSaved: (UUID) -> Void = { _ in }
    init(_ draft: BlockDraft, onSaved: @escaping (UUID) -> Void = { _ in }) {
        self.draft = draft; _block = State(initialValue: draft.block); self.onSaved = onSaved
    }
    var parent: Block? { block.parentID.flatMap(studio.block).map(studio.library.resolved) }
    @ViewBuilder func field(_ f: BlockField) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(f.label).font(.subheadline.weight(.semibold))
                Spacer()
                if parent != nil {
                    if block.values[f.rawValue] != nil {
                        Button("Inherit") { block.values.removeValue(forKey: f.rawValue) }.font(.caption)
                    } else { Label("Inherited", systemImage: "link").font(.caption).foregroundStyle(.secondary) }
                }
            }
            TextField(f == .now ? "An action, or Nothing" : f == .tides ? "External shifts, events, or trends" : "Add details", text: Binding(
                get: { block.values[f.rawValue] ?? parent?[f] ?? "" },
                set: { block[f] = $0 }
            ), axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).focused($focusedField, equals: f.rawValue)
        }.padding(.vertical, 3)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Block") {
                    TextField("Block name", text: $block.title).focused($focusedField, equals: "title").submitLabel(.next)
                        .onSubmit { focusedField = BlockField.outcome.rawValue }
                    if let parent { Label("Variation of \(parent.title)", systemImage: "arrow.triangle.branch").font(.caption) }
                }
                if let image = draft.preview { Section("Captured area") { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 170) } }
                Section("Decisions") { ForEach([BlockField.outcome,.evidence,.now]) { field($0) } }
                Section("Execution") { ForEach([BlockField.process,.inputs,.outputs,.resources,.locations]) { field($0) } }
                Section("4T resources") { ForEach([BlockField.tech,.talent,.tangible,.tides]) { field($0) } }
                Section("People and logistics") { ForEach([BlockField.roles,.tools,.time,.cost]) { field($0) } }
                Section("Markdown context") {
                    TextField("Add Markdown", text: Binding(get: { block.context ?? parent?.context ?? "" }, set: { block.context = $0 }), axis: .vertical)
                        .lineLimit(3...8).focused($focusedField, equals: "context")
                    if parent?.context != nil && block.context != nil { Button("Inherit context") { block.context = nil } }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle(parent == nil ? "Block editor" : "Variation editor")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if block != draft.block { discard = true } else { dismiss() } } }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focusedField = nil } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        block.title = block.title.trimmingCharacters(in: .whitespacesAndNewlines)
                        do {
                            if let data = draft.preview?.pngData() { try data.write(to: studio.url(block.id, "png"), options: .atomic) }
                            if studio.change({ $0.save(block, in: draft.workflowID, replacing: draft.placementID) }) { dismiss(); onSaved(block.id) }
                        } catch { studio.issue = error.localizedDescription }
                    }.disabled(block.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .task { if block.title.isEmpty { focusedField = "title" } }
            .interactiveDismissDisabled(block != draft.block)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
        }
    }
}

struct BlockDetail: View {
    @EnvironmentObject var studio: Studio
    let raw: Block
    var openPage: (UUID, UUID) -> Void
    @State private var draft: BlockDraft?
    var body: some View {
        let b = studio.library.resolved(raw)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Label(raw.parentID == nil ? "Library block" : "Linked variation", systemImage: "shippingbox")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(b.title).font(.system(.largeTitle, design: .serif).weight(.medium))
                if let parent = raw.parentID.flatMap(studio.block) { Text("Inherits from \(parent.title)").foregroundStyle(.secondary) }
                if let context = b.context, !context.isEmpty { MarkdownReadView(text: context) }
                HStack {
                    Button("Edit", systemImage: "pencil") { draft = BlockDraft(block: raw) }.buttonStyle(.borderedProminent)
                    Button("Create variation", systemImage: "arrow.triangle.branch") { draft = BlockDraft(block: Block(title: b.title + " variation", parentID: b.id)) }.buttonStyle(.bordered)
                    ConvertMenu(item: Conversion(studio.library, block: raw))
                }
                Divider()
                ForEach(BlockField.allCases.filter { !b[$0].isEmpty || [.outcome,.evidence,.now].contains($0) }) { f in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(f.label).font(.headline)
                        Text(b[f].isEmpty ? "Unanswered" : b[f]).foregroundStyle(b[f].isEmpty ? .secondary : .primary).textSelection(.enabled)
                    }
                }
                if let s = b.source, studio.paper(s.documentID)?.pages.contains(where: { $0.id == s.pageID }) == true {
                    Divider()
                    if let image = snapshot(for: raw) { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260) }
                    Button("Open source page", systemImage: "arrow.up.right.square") { openPage(s.documentID, s.pageID) }
                    if !s.excerpt.isEmpty { Text(s.excerpt).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }.frame(maxWidth: 760, alignment: .leading).padding(34).frame(maxWidth: .infinity, alignment: .leading)
        }.sheet(item: $draft) { BlockEditor($0) }
    }
    func snapshot(for original: Block) -> UIImage? {
        studio.blockPreview(original).flatMap { UIImage(contentsOfFile: $0.path) }
    }
}

struct WorkflowView: View {
    @EnvironmentObject var studio: Studio
    let flow: Workflow
    @State private var edit: BlockDraft?
    @State private var showLibrary = false
    @State private var filter = ""
    @State private var context: TextPanel?

    func update(_ transform: (inout [Placement]) -> Void) {
        studio.change { lib in
            if let i = lib.workflows.firstIndex(where: { $0.id == flow.id }) { transform(&lib.workflows[i].steps) }
        }
    }
    func link(_ id: UUID) {
        guard studio.block(id) != nil else { return }
        update { $0.append(Placement(blockID: id)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                Label("Workflow", systemImage: "point.3.connected.trianglepath.dotted").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                Text(flow.title).font(.system(.largeTitle, design: .serif))
                if let notes = flow.context, !notes.isEmpty { MarkdownReadView(text: notes) }
                HStack {
                    Button("Build a block", systemImage: "plus") { edit = BlockDraft(block: Block(title: ""), workflowID: flow.id) }.buttonStyle(.borderedProminent)
                    Button("Link saved block", systemImage: "link") { showLibrary = true }.buttonStyle(.bordered)
                    ConvertMenu(item: Conversion(studio.library, workflow: flow))
                    Button { context = TextPanel(mode: .notes, title: "Workflow context", text: flow.context ?? "") } label: {
                        Image(systemName: "text.alignleft")
                    }.accessibilityLabel("Edit Markdown context")
                }.padding(.bottom, 10)
                ForEach(Array(flow.steps.enumerated()), id: \.element.id) { i, step in
                    if let raw = studio.block(step.blockID) {
                        let block = studio.library.resolved(raw)
                        HStack(alignment: .top, spacing: 15) {
                            Text(String(format: "%02d", i+1)).font(.system(.headline, design: .monospaced)).foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(block.title).font(.headline)
                                if !block[.outcome].isEmpty { Text(block[.outcome]).foregroundStyle(.secondary) }
                                Label(raw.parentID == nil ? "Live link" : "Linked variation", systemImage: "link").font(.caption)
                            }
                            Spacer()
                            Menu {
                                Button("Edit shared block") { edit = BlockDraft(block: raw) }
                                Button("Make a variation here") { edit = BlockDraft(block: Block(title: block.title + " variation", parentID: block.id), workflowID: flow.id, placementID: step.id) }
                                Button("Move up") { update { $0.swapAt(i, i-1) } }.disabled(i == 0)
                                Button("Move down") { update { $0.swapAt(i, i+1) } }.disabled(i+1 >= flow.steps.count)
                                Button("Remove this link", role: .destructive) { update { $0.removeAll { $0.id == step.id } } }
                            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }.accessibilityLabel("Options for \(block.title)")
                        }.padding().background(.background, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
                        if i+1 < flow.steps.count { Image(systemName: "arrow.down").foregroundStyle(.tertiary).padding(.leading, 20) }
                    }
                }
                if flow.steps.isEmpty { ContentUnavailableView("Add your first block", systemImage: "square.stack.3d.up", description: Text("Build a block here or link one from your library.")) }
            }.padding(30).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
        }
        .dropDestination(for: String.self) { items, _ in
            let ids = items.compactMap(UUID.init(uuidString:)).filter { studio.block($0) != nil }
            guard !ids.isEmpty else { return false }
            update { $0.append(contentsOf: ids.map { Placement(blockID: $0) }) }; return true
        }
        .sheet(item: $edit) { BlockEditor($0) }
        .sheet(item: $context) { item in
            TextPanelView(panel: item) { text in
                studio.change { lib in
                    if let i = lib.workflows.firstIndex(where: { $0.id == flow.id }) { lib.workflows[i].context = text }
                }
            }
        }
        .sheet(isPresented: $showLibrary) {
            NavigationStack {
                List(studio.library.blocks.filter { filter.isEmpty || $0.title.localizedCaseInsensitiveContains(filter) }) { block in
                    Button { link(block.id); showLibrary = false } label: { Label(block.title, systemImage: "link") }
                }.overlay { if studio.library.blocks.isEmpty { ContentUnavailableView("Your block library is empty", systemImage: "shippingbox", description: Text("Use Build a block to create the first one.")) } }
                .searchable(text: $filter).navigationTitle("Link a block")
                .toolbar { Button("Done") { showLibrary = false } }
            }
        }
    }
}
