import SwiftUI
import CoreTransferable
import PhotosUI
import UniformTypeIdentifiers
import AVKit
import QuickLook

struct CanvasDraft: Identifiable {
    var item: CanvasItem
    var isNew: Bool
    var id: UUID { item.id }
}

struct CanvasItemEditor: View {
    @EnvironmentObject private var studio: Studio
    @FocusState private var focus: Field?
    private enum Field { case title, markdown, link }
    let draft: CanvasDraft
    let save: (CanvasItem) -> Bool
    let close: () -> Void
    @State private var item: CanvasItem
    @State private var address: String
    @State private var preview = false

    init(draft: CanvasDraft, close: @escaping () -> Void, save: @escaping (CanvasItem) -> Bool) {
        self.draft = draft
        self.close = close
        self.save = save
        _item = State(initialValue: draft.item)
        _address = State(initialValue: draft.item.link ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(item.kind.label) {
                    TextField(item.kind == .text ? "Text" : draft.isNew ? "Title (optional)" : "Title", text: $item.title)
                        .focused($focus, equals: .title).submitLabel(.next)
                        .onSubmit { focus = item.kind == .link ? .link : .markdown }
                    Picker("Color", selection: $item.tint) {
                        ForEach(CanvasTint.allCases) { tint in
                            Label(tint.rawValue.capitalized, systemImage: "circle.fill")
                                .foregroundStyle(Color(uiColor: tint.color)).tag(tint)
                        }
                    }
                    Toggle("Glow text", isOn: Binding(get: { item.glow == true }, set: { item.glow = $0 ? true : nil }))
                    Stepper("Width · \(Int(item.frame.width)) pt", value: $item.frame.size.width, in: 80...1200, step: 20)
                    Stepper("Height · \(Int(item.frame.height)) pt", value: $item.frame.size.height, in: 64...1000, step: 20)
                }
                Section("Markdown context") {
                    Picker("Mode", selection: $preview) {
                        Text("Write").tag(false)
                        Text("Preview").tag(true)
                    }.pickerStyle(.segmented)
                    if preview { MarkdownReadView(text: item.markdown) }
                    else {
                        ZStack(alignment: .topLeading) {
                            if item.markdown.isEmpty { Text("Add notes in Markdown").foregroundStyle(.secondary).padding(.top, 8).padding(.leading, 5).allowsHitTesting(false) }
                            TextEditor(text: $item.markdown).scrollContentBackground(.hidden).frame(minHeight: 145)
                                .focused($focus, equals: .markdown).accessibilityLabel("Markdown context")
                        }
                    }
                }
                Section("Link") {
                    TextField("https:// or Goodest Notes link", text: $address).keyboardType(.URL)
                        .focused($focus, equals: .link)
                        .textContentType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !studio.library.references.isEmpty {
                        Menu("Link to Goodest Notes item", systemImage: "link") {
                            ForEach(studio.library.references) { ref in
                                if let title = studio.library.title(for: ref) { Button(title) { address = ref.link } }
                            }
                        }
                    }
                    if !address.isEmpty && CanvasItem.checkedLink(address) == nil {
                        Text("Use an http, https, email, or Goodest Notes link.").font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if let asset = item.asset { Section("Attachment") { Label(asset.filename, systemImage: item.kind.icon) } }
            }
            .navigationTitle(draft.isNew ? (item.kind == .text && item.glow == true ? "Add glowing text" : "Add " + item.kind.label.lowercased()) : "Edit canvas item")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) {
                        focus = nil
                        close()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(draft.isNew ? "Add" : "Save") {
                        item.title = resolvedTitle
                        item.link = CanvasItem.checkedLink(address)?.absoluteString
                        if save(item) { close() }
                    }.disabled((item.kind == .text && item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ||
                               (!address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && CanvasItem.checkedLink(address) == nil) ||
                               (item.kind == .link && CanvasItem.checkedLink(address) == nil))
                }
                ToolbarItemGroup(placement: .keyboard) { Spacer(); Button("Hide Keyboard") { focus = nil } }
            }
            .task { if draft.isNew { focus = item.kind == .link ? .link : .title } }
            .interactiveDismissDisabled(dirty)
        }
    }

    private var dirty: Bool { item != draft.item || address != (draft.item.link ?? "") }

    private var resolvedTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }
        if item.kind == .link { return CanvasItem.checkedLink(address)?.host() ?? item.kind.label }
        let lead = item.markdown.split(whereSeparator: \.isNewline).first?
            .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#-*")))
        return lead.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? item.kind.label
    }
}

struct MarkdownReadView: View {
    let text: String
    var body: some View {
        if text.isEmpty {
            Text("No Markdown yet").foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                    if line.hasPrefix("# ") { formatted(String(line.dropFirst(2))).font(.title2.bold()) }
                    else if line.hasPrefix("## ") { formatted(String(line.dropFirst(3))).font(.headline) }
                    else if line.hasPrefix("### ") { formatted(String(line.dropFirst(4))).font(.subheadline.bold()) }
                    else if line.hasPrefix("- ") { formatted("• " + line.dropFirst(2)) }
                    else if !line.isEmpty { formatted(line) }
                }
            }.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
    }

    private func formatted(_ line: String) -> Text {
        Text((try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(line))
    }
}

struct CanvasPhoto: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { try preserve($0.file) }
        FileRepresentation(importedContentType: .movie) { try preserve($0.file) }
    }

    private static func preserve(_ source: URL) throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(source.lastPathComponent)
        try FileManager.default.copyItem(at: source, to: url)
        return Self(url: url)
    }
}

struct CanvasPlayback: View {
    let title: String
    let url: URL
    let kind: CanvasItemKind
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var image: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if kind == .image {
                    if let image { Image(uiImage: image).resizable().scaledToFit().padding() }
                    else { ContentUnavailableView("Image unavailable", systemImage: "photo") }
                } else if kind == .audio {
                    if let player {
                        VStack(spacing: 22) {
                            Image(systemName: "waveform").font(.system(size: 70)).foregroundStyle(.indigo)
                            HStack(spacing: 20) {
                                Button("Play", systemImage: "play.fill") { player.play() }
                                Button("Pause", systemImage: "pause.fill") { player.pause() }
                                Button("Restart", systemImage: "backward.end") { player.seek(to: .zero); player.play() }
                            }.buttonStyle(.bordered)
                        }
                    }
                } else if let player { VideoPlayer(player: player) }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task {
            if kind == .image { image = await Task.detached { CanvasImages.thumbnail(at: url, maxPixels: 3000) }.value }
            else { player = AVPlayer(url: url) }
        }
        .onDisappear { player?.pause() }
    }
}

struct CanvasAttachment: Identifiable {
    let id = UUID()
    var url: URL
    var title: String
    var kind: CanvasItemKind
}

struct CanvasConnectionEditor: View {
    let edge: CanvasConnection
    var save: (String) -> Void
    var delete: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @FocusState private var focused: Bool

    init(edge: CanvasConnection, save: @escaping (String) -> Void, delete: @escaping () -> Void) {
        self.edge = edge
        self.save = save
        self.delete = delete
        _label = State(initialValue: edge.label)
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("Connection label (optional)", text: $label).focused($focused)
                Button("Delete connection", systemImage: "trash", role: .destructive) { delete(); dismiss() }
            }.navigationTitle("Connection").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save(label); dismiss() } }
            }
        }.presentationDetents([.medium])
    }
}
