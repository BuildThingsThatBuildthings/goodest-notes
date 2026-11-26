import SwiftUI
import CryptoKit
import CoreImage.CIFilterBuiltins
import Network
import Darwin

@MainActor final class AgentSession: ObservableObject {
    struct Pairing {
        let address: String
        let port: NWEndpoint.Port
        let key: String
        var code: String { AgentPairingCode(address: address, port: port.rawValue, key: key).value }
    }

    @Published private(set) var pairing: Pairing?
    @Published private(set) var activeAccess: AgentAccess?
    @Published private(set) var starting = false
    @Published private(set) var lastWrite: String?
    @Published private(set) var lastClientActivity: String?
    @Published private(set) var failure: String?
    private var listener: NWListener?
    private var clients: [UUID: NWConnection] = [:]
    private var expirations: [Data: Date] = [:]
    private var deadline: Task<Void, Never>?
    private var generation = UUID()

    var isRunning: Bool { pairing != nil }

    func start(studio: Studio, access: AgentAccess, host: String? = nil) {
        stop()
        failure = nil
        lastWrite = nil
        lastClientActivity = nil
        do {
            if case .items = access, try access.references(in: studio.library).isEmpty {
                failure = "Choose at least one item to share."
                return
            }
            guard let host = host ?? Self.wifiAddress(), let ip = IPv4Address(host) else {
                failure = "Connect the iPad to the same private Wi-Fi network as your agent."
                return
            }
            let key = SymmetricKey(size: .bits256)
            let pairingCode = key.withUnsafeBytes { Data($0).base64EncodedString() }
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(ip), port: .any)
            let listener = try NWListener(using: parameters)
            self.listener = listener
            activeAccess = access
            starting = true
            let session = generation
            let tools = AgentTools(studio: studio, access: access, onWrite: { [weak self] operation in self?.lastWrite = operation })
            listener.newConnectionHandler = { [weak self] client in
                Task { @MainActor in
                    guard let self, self.generation == session else { client.cancel(); return }
                    self.accept(client, key: key, tools: tools, session: session)
                }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                Task { @MainActor in
                    guard let self, self.generation == session else { return }
                    switch state {
                    case .ready:
                        guard let port = listener?.port else { return }
                        self.pairing = Pairing(address: host, port: port, key: pairingCode)
                        self.starting = false
                        self.failure = nil
                    case let .failed(error):
                        self.stop()
                        self.failure = error.localizedDescription
                    case let .waiting(error):
                        self.failure = error.localizedDescription
                    default: break
                    }
                }
            }
            listener.start(queue: .main)
            deadline = Task { [weak self] in
                try? await Task.sleep(for: .seconds(30 * 60))
                if !Task.isCancelled { self?.stop() }
            }
        } catch {
            stop()
            failure = error.localizedDescription
        }
    }

    func stop() {
        generation = UUID()
        deadline?.cancel()
        deadline = nil
        listener?.cancel()
        listener = nil
        clients.values.forEach { $0.cancel() }
        clients.removeAll()
        expirations.removeAll()
        pairing = nil
        activeAccess = nil
        starting = false
    }

    private func accept(_ client: NWConnection, key: SymmetricKey, tools: AgentTools, session: UUID) {
        guard clients.count < 12 else { client.cancel(); return }
        let id = UUID()
        clients[id] = client
        client.start(queue: .main)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            self?.finish(id)
        }
        AgentWire.receive(client) { [weak self] result in
            Task { @MainActor in
                guard let self, self.generation == session, self.clients[id] != nil else { return }
                do {
                    let request = try result.get()
                    let json = try AgentWire.openRequest(request, key: key)
                    let nonce = Data(request.prefix(12))
                    let now = Date()
                    self.expirations = self.expirations.filter { $0.value > now }
                    guard self.expirations[nonce] == nil, self.expirations.count < 4096 else { self.finish(id); return }
                    self.expirations[nonce] = now.addingTimeInterval(180)
                    self.lastClientActivity = "Authenticated request received"
                    let reply = try AgentWire.frame(AgentWire.reply(tools.handle(json), for: request, key: key))
                    client.send(content: reply, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] error in
                        if error != nil { Task { @MainActor in self?.finish(id) }; return }
                        client.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                            Task { @MainActor in self?.finish(id) }
                        }
                    })
                } catch {
                    self.lastClientActivity = "A client disconnected or could not be authenticated"
                    self.finish(id)
                }
            }
        }
    }

    private func finish(_ id: UUID) { clients.removeValue(forKey: id)?.cancel() }

    private static func wifiAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(first) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            let entry = current.pointee
            node = entry.ifa_next
            guard String(cString: entry.ifa_name) == "en0", let address = entry.ifa_addr, address.pointee.sa_family == AF_INET else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: buffer)
            let octets = ip.split(separator: ".").compactMap { Int($0) }
            guard octets.count == 4 else { continue }
            if octets[0] == 10 || (octets[0] == 172 && (16...31).contains(octets[1])) ||
                (octets[0] == 192 && octets[1] == 168) || (octets[0] == 169 && octets[1] == 254) { return ip }
        }
        return nil
    }
}

struct AgentConnectionView: View {
    @ObservedObject var session: AgentSession
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    var initialAccess: AgentAccess?
    private enum Scope: String, CaseIterable { case items = "Selected items", project = "One project", library = "Entire library" }
    @State private var scope: Scope = .items
    @State private var projectID: UUID?
    @State private var selection: Set<LibraryReference> = []
    @State private var choosingItems = false
    @State private var scopeChosen = false
    @State private var copied = false
    @State private var revealing = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Library access") {
                    Picker("Share with this agent", selection: $scope) {
                        Text(Scope.items.rawValue).tag(Scope.items)
                        if !studio.library.allProjects.isEmpty { Text(Scope.project.rawValue).tag(Scope.project) }
                        Text(Scope.library.rawValue).tag(Scope.library)
                    }.disabled(session.isRunning || session.starting)
                    if scope == .items {
                        Button {
                            choosingItems = true
                        } label: {
                            LabeledContent("Choose items", value: selection.isEmpty ? "None" : "\(selection.count) selected")
                        }.disabled(session.isRunning || session.starting)
                        ForEach(studio.library.references.filter(selection.contains)) { ref in
                            if let title = studio.library.title(for: ref) {
                                Label(title, systemImage: "checkmark.circle").foregroundStyle(.secondary).font(.subheadline)
                            }
                        }
                    } else if scope == .project {
                        Picker("Project", selection: $projectID) {
                            ForEach(studio.library.allProjects) { project in Text(project.title).tag(Optional(project.id)) }
                        }.disabled(session.isRunning || session.starting)
                    }
                    Text(accessDescription)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let pairing = session.pairing {
                    Section("Connect on your Mac") {
                        Button(copied ? "Connection code copied" : "Copy connection code", systemImage: "doc.on.doc") {
                            UIPasteboard.general.setItems([["public.utf8-plain-text": pairing.code]],
                                options: [.localOnly: false, .expirationDate: Date().addingTimeInterval(120)])
                            copied = true
                        }
                        Button(revealing ? "Hide connection code" : "Show connection code", systemImage: revealing ? "eye.slash" : "eye") { revealing.toggle() }
                        if revealing {
                            VStack(spacing: 12) {
                                PairingQR(code: pairing.code)
                                Text(pairing.code).font(.caption.monospaced()).textSelection(.enabled)
                            }.frame(maxWidth: .infinity)
                        }
                        Text("Copy the code, then open Connect Goodest Notes on your Mac. Use the same Wi-Fi and keep Goodest Notes open. The session ends after 30 minutes or when Goodest Notes goes to the background.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let write = session.lastWrite {
                        Section("Latest agent change") { Label(write, systemImage: "checkmark.circle") }
                    } else if let activity = session.lastClientActivity {
                        Section("Connection activity") { Text(activity) }
                    }
                    Section { Button("Disconnect agent", systemImage: "stop.circle", role: .destructive) { session.stop(); copied = false; revealing = false } }
                } else {
                    Section {
                        if session.starting {
                            HStack { ProgressView(); Text("Starting connection"); Spacer(); Button("Cancel") { session.stop() } }
                        } else {
                            Button("Start encrypted session", systemImage: "bolt.horizontal.circle") {
                                if let access = requestedAccess { session.start(studio: studio, access: access) }
                            }.disabled(requestedAccess == nil)
                        }
                        if let failure = session.failure { Text(failure).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("Agent connection").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $choosingItems) { AgentItemPicker(selection: $selection) }
            .onAppear {
                if !scopeChosen {
                    projectID = studio.library.allProjects.last?.id
                    switch session.activeAccess ?? initialAccess {
                    case let .items(refs): scope = .items; selection = refs
                    case let .project(id): scope = .project; projectID = id
                    case .library: scope = .library
                    case nil: scope = .items
                    }
                    scopeChosen = true
                }
            }
            .onChange(of: scope) { _, mode in
                if mode == .project, projectID == nil { projectID = studio.library.allProjects.last?.id }
            }
        }
    }

    private var accessDescription: String {
        switch scope {
        case .items: "The agent can read these items, edit their notes and canvas objects, and add pages to shared notebooks."
        case .project: "The agent can edit pages and canvas objects and create notebooks and whiteboards in this project."
        case .library: "The agent can read the full library, edit pages and canvas objects, create notebooks and whiteboards, and organize items into projects."
        }
    }

    private var requestedAccess: AgentAccess? {
        switch scope {
        case .items:
            let available = selection.filter { studio.library.title(for: $0) != nil }
            return available.isEmpty ? nil : .items(available)
        case .project: return projectID.map(AgentAccess.project)
        case .library: return .library
        }
    }
}

private struct AgentItemPicker: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @Binding var selection: Set<LibraryReference>
    @State private var query = ""

    var body: some View {
        NavigationStack {
            let matches = studio.library.references.filter { ref in
                query.isEmpty || studio.library.title(for: ref)?.localizedCaseInsensitiveContains(query) == true
            }
            List {
                if matches.isEmpty { ContentUnavailableView("No matching items", systemImage: "magnifyingglass") }
                ForEach(LibraryEntry.allCases, id: \.self) { kind in
                    let section = matches.filter { $0.kind == kind }
                    if !section.isEmpty {
                        Section(sectionTitle(kind)) {
                            ForEach(section) { ref in
                                let selected = selection.contains(ref)
                                if let title = studio.library.title(for: ref) {
                                    Button {
                                        if selected { selection.remove(ref) } else { selection.insert(ref) }
                                    } label: {
                                        HStack {
                                            Label(title, systemImage: icon(ref)).foregroundStyle(.primary)
                                            Spacer()
                                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                        }.contentShape(Rectangle())
                                    }.accessibilityAddTraits(selected ? .isSelected : [])
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $query, prompt: "Find a whiteboard or library item")
            .navigationTitle("Choose items to share").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private func sectionTitle(_ kind: LibraryEntry) -> String {
        switch kind {
        case .paper: "Whiteboards, notebooks, and PDFs"
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
}

private struct PairingQR: View {
    let code: String

    var body: some View {
        if let bitmap {
            Image(decorative: bitmap, scale: 1).resizable().interpolation(.none).scaledToFit()
                .frame(width: 156, height: 156).padding(10).background(.white)
                .accessibilityLabel("Pairing code QR")
        }
    }

    private var bitmap: CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        guard let output = filter.outputImage else { return nil }
        return CIContext().createCGImage(output, from: output.extent)
    }
}
