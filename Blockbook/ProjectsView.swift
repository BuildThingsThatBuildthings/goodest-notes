import SwiftUI

extension LibraryReference {
    var destination: Destination {
        switch kind {
        case .paper: .paper(id, nil)
        case .workflow: .workflow(id)
        case .block: .block(id)
        }
    }
}

struct ProjectView: View {
    @EnvironmentObject private var studio: Studio
    let project: Project
    var open: (Destination) -> Void
    var create: (NewItem) -> Void
    @State private var conversation = false
    @State private var search = ""
    @State private var editing = false
    @State private var context: TextPanel?
    @State private var transfer: Transfer?
    @State private var exporting = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Label("Project", systemImage: "folder").font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
                Text(project.title).font(.system(size: 42, weight: .medium, design: .serif))
                if !project.markdown.isEmpty { MarkdownReadView(text: project.markdown) }
                HStack(spacing: 10) {
                    Menu {
                        ForEach(NewItem.allCases.filter { $0 != .project }) { kind in
                            Button(kind == .pdf ? "Import PDF" : "New " + kind.rawValue, systemImage: kind.icon) { create(kind) }
                        }
                    } label: { Label("Create in project", systemImage: "plus") }.buttonStyle(.borderedProminent)
                    Button("Conversation",systemImage:"bubble.left.and.bubble.right") { conversation=true }
                    Button("Add existing", systemImage: "link.badge.plus") { editing = true }.buttonStyle(.bordered)
                    Menu {
                        Button("Edit Markdown context", systemImage: "text.alignleft") {
                            context = TextPanel(mode: .notes, title: "Project context", text: project.markdown)
                        }
                        Button("Export project as Markdown", systemImage: "square.and.arrow.up") { export() }.disabled(exporting)
                    } label: {
                        if exporting { ProgressView() } else { Image(systemName: "ellipsis.circle").font(.title2) }
                    }.accessibilityLabel("Project actions")
                }
                TextField("Find in project", text: $search).textFieldStyle(.roundedBorder)
                let listed = project.entries.filter { ref in
                    guard let title = studio.library.title(for: ref) else { return false }
                    if search.isEmpty || title.localizedCaseInsensitiveContains(search) { return true }
                    switch ref.kind {
                    case .paper: return studio.paper(ref.id)?.pages.contains { $0.text.localizedCaseInsensitiveContains(search) } == true
                    case .workflow: return studio.workflow(ref.id)?.context?.localizedCaseInsensitiveContains(search) == true
                    case .block: return studio.block(ref.id).map { studio.library.resolved($0).values.values.joined(separator: " ").localizedCaseInsensitiveContains(search) } ?? false
                    }
                }
                if listed.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "Empty project" : "No matches", systemImage: "folder", description: Text("Add an existing item or create something in this project."))
                } else {
                    ForEach(LibraryEntry.allCases, id: \.self) { kind in
                        let items = listed.filter { $0.kind == kind }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section(kind)).font(.headline)
                                ForEach(items) { ref in
                                    if let title = studio.library.title(for: ref) {
                                        Button { open(ref.destination) } label: {
                                            HStack(spacing: 12) {
                                                Image(systemName: icon(ref))
                                                Text(title).foregroundStyle(.primary)
                                                Spacer()
                                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                                            }.padding(14).frame(maxWidth: .infinity)
                                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                                        }.buttonStyle(.plain)
                                            .contextMenu {
                                                Button("Remove from project", systemImage: "minus.circle") {
                                                    studio.change { $0.assign(ref, to: project.id, included: false) }
                                                }
                                            }
                                    }
                                }
                            }
                        }
                    }
                }
            }.padding(28).frame(maxWidth: 840, alignment: .leading).frame(maxWidth: .infinity)
        }
        .inspector(isPresented:$conversation) { ProjectConversation(project:project).inspectorColumnWidth(min:300,ideal:350,max:450) }
        .sheet(isPresented: $editing) { ProjectItems(projectID: project.id) }
        .sheet(item: $context) { item in
            TextPanelView(panel: item) { text in studio.change { $0.editProject(project.id) { $0.markdown = text } } }
        }
        .sheet(item: $transfer) { SaveToFiles(transfer: $0) }
    }

    private func section(_ kind: LibraryEntry) -> String {
        switch kind {
        case .paper: "Notebooks, whiteboards, and PDFs"
        case .workflow: "Workflows"
        case .block: "Reusable blocks"
        }
    }

    private func icon(_ ref: LibraryReference) -> String {
        switch ref.kind {
        case .paper:
            switch studio.paper(ref.id)?.kind {
            case .whiteboard: NewItem.whiteboard.icon
            case .pdf: NewItem.pdf.icon
            default: NewItem.notebook.icon
            }
        case .workflow: NewItem.workflow.icon
        case .block: NewItem.block.icon
        }
    }

    private func export() {
        exporting = true
        Task {
            defer { exporting = false }
            do { transfer = Transfer(file: try await WorkspaceMarkdown(studio: studio).writeProject(project)) }
            catch { studio.issue = error.localizedDescription }
        }
    }
}

private struct ProjectItems: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    let projectID: UUID
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let entries = studio.library.allProjects.first(where: { $0.id == projectID })?.entries ?? []
            let list = studio.library.references.compactMap { ref in studio.library.title(for: ref).map { (ref: ref, title: $0) } }
            List {
                ForEach(list.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }, id: \.ref.id) { item in
                    let inside = entries.contains(item.ref)
                    Button {
                        studio.change { $0.assign(item.ref, to: projectID, included: !inside) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).foregroundStyle(.primary)
                                Text(item.ref.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: inside ? "checkmark.circle.fill" : "circle")
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityAddTraits(inside ? .isSelected : [])
                }
                if list.isEmpty { Text("Create a notebook, canvas, workflow, or block to add it here.").foregroundStyle(.secondary) }
            }
            .searchable(text: $query)
            .navigationTitle("Project items").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
