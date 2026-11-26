import SwiftUI
import AVFoundation

enum CanvasContextMode: Hashable { case read, notes, link, audio }

struct CanvasContextDraft: Identifiable {
    let id = UUID()
    let item: CanvasItem
    let mode: CanvasContextMode
    let point: CGPoint
    let isNew: Bool
}

struct CanvasContextEditor: View {
    @EnvironmentObject private var studio: Studio
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @StateObject private var voice = CanvasVoiceNote()
    @FocusState private var focused: CanvasContextMode?
    @State private var notes: String
    @State private var address: String
    @State private var mode: CanvasContextMode
    @State private var removingAudio = false
    @State private var saving = false
    @State private var error: String?
    let draft: CanvasContextDraft
    let save: (CanvasItem) -> Bool

    init(draft: CanvasContextDraft, save: @escaping (CanvasItem) -> Bool) {
        self.draft = draft
        self.save = save
        _notes = State(initialValue: draft.item.markdown)
        _address = State(initialValue: draft.item.link ?? "")
        _mode = State(initialValue: draft.mode)
    }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .read: overview
                case .notes: noteFields
                case .link: linkFields
                case .audio: audioFields
                }
                if let message = error ?? voice.error {
                    Section { Text(message).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(draft.item.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(dirty ? "Cancel" : "Close", role: .cancel) { close() }
                        .disabled(saving)
                }
                if mode != .read || dirty {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") { commit() }
                            .disabled(!dirty || saving || voice.recording || voice.preparing || invalidLink)
                    }
                }
            }
            .task(id: mode) { focused = mode == .notes || mode == .link ? mode : nil }
        }
        .frame(idealWidth: 390, idealHeight: 390)
        .interactiveDismissDisabled(dirty || voice.recording || voice.preparing || saving)
        .onDisappear { voice.dispose() }
    }

    private var overview: some View {
        Group {
            if !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Context") { MarkdownReadView(text: notes) }
            }
            Section {
                Button(notes.isEmpty ? "Add context" : "Edit context", systemImage: "note.text") { mode = .notes }
                if let url = CanvasItem.checkedLink(address) {
                    Button("Open link", systemImage: "arrow.up.right") { close(); openURL(url) }
                }
                Button(address.isEmpty ? "Add link" : "Edit link", systemImage: "link") { mode = .link }
                if let audioURL {
                    Button(voice.playing ? "Stop audio" : "Play audio note", systemImage: voice.playing ? "stop.fill" : "play.fill") {
                        voice.togglePlayback(audioURL)
                    }
                }
                Button(audioURL == nil ? "Add audio note" : "Edit audio note", systemImage: "waveform") { mode = .audio }
            }
        }
    }

    private var noteFields: some View {
        Section("Markdown context") {
            TextEditor(text: $notes).frame(minHeight: 130)
                .focused($focused, equals: .notes).accessibilityLabel("Context notes")
        }
    }

    private var linkFields: some View {
        Section("Link") {
            TextField("Web or Goodest Notes link", text: $address)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                .focused($focused, equals: .link)
            Menu("Link to Goodest Notes item", systemImage: "link") {
                ForEach(studio.library.references) { ref in
                    if let title = studio.library.title(for: ref) { Button(title) { address = ref.link } }
                }
            }
            if invalidLink { Text("Enter an HTTPS, HTTP, email, or Goodest Notes link.").font(.footnote).foregroundStyle(.secondary) }
        }
    }

    private var audioFields: some View {
        Section("Audio note") {
            if voice.recording {
                Button("Stop recording", systemImage: "stop.circle.fill") { voice.stopRecording() }
            } else {
                Button(audioURL == nil ? "Record audio note" : "Record replacement", systemImage: "mic") {
                    Task { await voice.startRecording() }
                }.disabled(voice.preparing || saving)
                if let audioURL {
                    Button(voice.playing ? "Stop playback" : "Play", systemImage: voice.playing ? "stop.fill" : "play.fill") {
                        voice.togglePlayback(audioURL)
                    }
                    Button("Remove audio note", systemImage: "trash", role: .destructive) {
                        voice.removeTake()
                        removingAudio = true
                    }
                }
            }
        }
    }

    private var audioURL: URL? {
        voice.take ?? (removingAudio ? nil : draft.item.audioNote.map(studio.assetURL))
    }

    private var invalidLink: Bool {
        !address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && CanvasItem.checkedLink(address) == nil
    }

    private var dirty: Bool {
        notes != draft.item.markdown || address != (draft.item.link ?? "") ||
            voice.take != nil || (removingAudio && draft.item.audioNote != nil)
    }

    private func close() {
        focused = nil
        voice.dispose()
        dismiss()
    }

    private func commit() {
        focused = nil
        saving = true
        error = nil
        Task {
            defer { saving = false }
            var candidate = draft.item
            candidate.markdown = notes
            candidate.link = CanvasItem.checkedLink(address)?.absoluteString
            if removingAudio { candidate.audioNote = nil }
            var added: CanvasAsset?
            do {
                if let take = voice.take {
                    let asset = try await studio.importAsset(take, filename: "Audio note.m4a")
                    added = asset
                    candidate.audioNote = asset
                }
                if save(candidate) { close() }
                else {
                    if let added { studio.removeAsset(added) }
                    error = studio.issue ?? "The context could not be saved."
                }
            } catch { self.error = error.localizedDescription }
        }
    }
}

@MainActor private final class CanvasVoiceNote: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var take: URL?
    @Published private(set) var recording = false
    @Published private(set) var playing = false
    @Published private(set) var preparing = false
    @Published private(set) var error: String?
    private var recorder: AVAudioRecorder?
    private var player: AVAudioPlayer?
    private var audioActive = false
    private var permissionRequest = UUID()

    func startRecording() async {
        guard !recording, !preparing else { return }
        preparing = true
        error = nil
        let request = UUID()
        permissionRequest = request
        let allowed = await AVAudioApplication.requestRecordPermission()
        guard permissionRequest == request else { return }
        preparing = false
        guard allowed else {
            error = "Allow Goodest Notes to use the microphone in Settings to record a note."
            return
        }
        stopPlayback()
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        do {
            try activate(.playAndRecord)
            let next = try AVAudioRecorder(url: destination, settings: [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1, AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
            guard next.record() else { throw CanvasError.invalidFile }
            recorder = next
            recording = true
        } catch {
            try? FileManager.default.removeItem(at: destination)
            deactivate()
            self.error = error.localizedDescription
        }
    }

    func stopRecording() {
        guard let recorder else { return }
        let duration = recorder.currentTime
        recorder.stop()
        self.recorder = nil
        recording = false
        deactivate()
        guard duration > 0.05, FileManager.default.fileExists(atPath: recorder.url.path) else {
            try? FileManager.default.removeItem(at: recorder.url)
            error = "Record a little longer, then tap Stop recording."
            return
        }
        removeTake()
        take = recorder.url
    }

    func togglePlayback(_ url: URL) {
        if playing { stopPlayback(); return }
        guard !recording else { return }
        error = nil
        do {
            try activate(.playback)
            let next = try AVAudioPlayer(contentsOf: url)
            next.delegate = self
            guard next.play() else { throw CanvasError.invalidFile }
            player = next
            playing = true
        } catch {
            deactivate()
            self.error = "The audio note could not be played."
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in if self?.player === player { self?.stopPlayback() } }
    }

    private func stopPlayback() {
        guard let player else { return }
        player.stop()
        self.player = nil
        playing = false
        deactivate()
    }

    func removeTake() {
        stopPlayback()
        if let take { try? FileManager.default.removeItem(at: take); self.take = nil }
    }

    func dispose() {
        permissionRequest = UUID()
        preparing = false
        if let recorder {
            recorder.stop()
            try? FileManager.default.removeItem(at: recorder.url)
            self.recorder = nil
        }
        recording = false
        removeTake()
        deactivate()
    }

    private func activate(_ category: AVAudioSession.Category) throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(category, mode: .default, options: category == .playAndRecord ? [.defaultToSpeaker] : [])
        try session.setActive(true)
        audioActive = true
    }

    private func deactivate() {
        guard audioActive else { return }
        audioActive = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }
}
