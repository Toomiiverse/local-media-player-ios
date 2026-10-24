import SwiftUI
import AVFoundation
import MobileVLCKit
import UniformTypeIdentifiers
import ImageIO

@main
struct LocalMediaApp: App {
    var body: some Scene { WindowGroup { LibraryView() } }
}

@MainActor
final class Library: ObservableObject {
    @Published var root: URL?
    @Published var folder: URL?
    @Published var rows = [MediaFile]()
    @Published var queue = [MediaFile]()
    @Published var position = 0
    @Published var visibleCount = 30
    @Published var busy = false
    @Published var message = ""
    @Published var error = ""
    @Published var showingPlayer = false
    private var scoped = false
    private var job: Task<Void, Never>?
    private var generation = UUID()
    var current: MediaFile? { queue.indices.contains(position) ? queue[position] : nil }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--codec-check") {
            choose(FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Fixtures"))
            return
        }
        #endif
        guard let data = UserDefaults.standard.data(forKey: "selectedFolder") else { return }
        do {
            var stale = false
            let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
            choose(url)
        } catch { self.error = "Reconnect your drive, then choose its folder again." }
    }

    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    func choose(_ url: URL) {
        cancel()
        if scoped { root?.stopAccessingSecurityScopedResource() }
        scoped = url.startAccessingSecurityScopedResource()
        root = url; queue = []; showingPlayer = false
        do {
            let data = try url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil)
            UserDefaults.standard.set(data, forKey: "selectedFolder")
        } catch { UserDefaults.standard.removeObject(forKey: "selectedFolder") }
        browse(url)
    }
    func forget() {
        cancel(); showingPlayer = false; queue = []; rows = []; folder = nil
        if scoped { root?.stopAccessingSecurityScopedResource() }
        root = nil; scoped = false; error = ""; message = ""
        UserDefaults.standard.removeObject(forKey: "selectedFolder")
    }
    func browse(_ url: URL) { load(url, shuffle: false, recursive: false) }
    func shuffle(recursive: Bool) { if let folder { load(folder, shuffle: true, recursive: recursive) } }
    private func load(_ url: URL, shuffle: Bool, recursive: Bool) {
        guard let root else { return }
        cancel(); busy = true; error = ""; message = ""
        let request = generation
        job = Task {
            let worker = Task.detached(priority: .userInitiated) { () throws -> MediaFiles.Sample in
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                if shuffle { return try MediaFiles.shuffle(url, root: root, recursive: recursive) }
                return try MediaFiles.Sample(rows: MediaFiles.list(url, root: root), total: 0, skipped: 0)
            }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard !Task.isCancelled, request == self.generation else { return }
                if shuffle {
                    self.queue = result.rows; self.position = 0; self.showingPlayer = !result.rows.isEmpty
                    self.message = result.rows.isEmpty ? "No images or videos in this folder." : "Shuffled \(result.rows.count) of \(result.total) files."
                    if result.skipped > 0 { self.message += " Some folders could not be read." }
                } else {
                    self.folder = url; self.rows = result.rows; self.visibleCount = 30
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--codec-check"), let first = result.rows.first(where: \.playable) { self.open(first) }
                    #endif
                }
            } catch {
                guard !Task.isCancelled, request == self.generation else { return }
                self.error = "This folder is unavailable. Reconnect the drive or choose another folder."
            }
            if request == self.generation { self.busy = false }
        }
    }
    func stars(of row: MediaFile) -> Int? {
        let name = row.url.deletingLastPathComponent().lastPathComponent
        guard name.count == 7, name.hasSuffix("-stars"), let value = Int(name.prefix(1)), (1...5).contains(value) else { return nil }
        return value
    }
    func rate(_ stars: Int) {
        guard let root, let row = current, row.kind != .folder, (1...5).contains(stars) else { return }
        let folder = root.appendingPathComponent("\(stars)-stars", isDirectory: true)
        if row.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let base = row.url.deletingPathExtension().lastPathComponent, ext = row.url.pathExtension
            var target = folder.appendingPathComponent(row.url.lastPathComponent)
            var copy = 2
            while FileManager.default.fileExists(atPath: target.path) {
                target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(copy))" : "\(base) (\(copy)).\(ext)"); copy += 1
            }
            try FileManager.default.moveItem(at: row.url, to: target)
            let moved = MediaFile(url: target, kind: row.kind)
            queue[position] = moved
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows.remove(at: index) }
            message = "Rated \(stars) star\(stars == 1 ? "" : "s") · moved to \(folder.lastPathComponent)."
        } catch { self.error = "The file could not be moved. It may be in use or the drive is read-only." }
    }
    func open(_ row: MediaFile) {
        if row.kind == .folder { browse(row.url); return }
        queue = rows.filter(\.playable)
        position = queue.firstIndex(where: { $0.id == row.id }) ?? 0
        showingPlayer = !queue.isEmpty
    }
}

struct LibraryView: View {
    @StateObject private var library = Library()
    @State private var picking = false
    @AppStorage("shuffleSubfolders") private var recursive = true
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink { PCConnectionView() } label: { Label("Connect to PC · Booru Feed", systemImage: "desktopcomputer") }
                }
                Section {
                    Button { picking = true } label: { Label("Choose folder or drive", systemImage: "folder.badge.plus") }
                    if let root = library.root, let folder = library.folder {
                        HStack {
                            Button { library.browse(folder.deletingLastPathComponent()) } label: { Label("Up", systemImage: "arrow.up") }.disabled(folder == root)
                            Spacer()
                            Button("Root") { library.browse(root) }
                            Button { library.browse(folder) } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh folder")
                        }.buttonStyle(.borderless)
                        Toggle("Include subfolders", isOn: $recursive)
                        Button { library.shuffle(recursive: recursive) } label: { Label("Shuffle & play", systemImage: "shuffle") }
                    }
                }.disabled(library.busy)
                if library.busy {
                    Section { HStack { ProgressView(); Text("Reading folder…"); Spacer(); Button("Cancel") { library.cancel() } } }
                }
                if !library.error.isEmpty { Section { Text(library.error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) } }
                if !library.message.isEmpty { Section { Text(library.message).foregroundStyle(.secondary) } }
                if let folder = library.folder {
                    Section(folder.lastPathComponent) {
                        if library.rows.isEmpty && !library.busy { Text("This folder is empty.").foregroundStyle(.secondary) }
                        ForEach(library.rows.prefix(library.visibleCount)) { row in
                            Button { library.open(row) } label: {
                                Label { Text(row.name).lineLimit(2).foregroundStyle(.primary) } icon: {
                                    Image(systemName: row.kind == .folder ? "folder" : row.kind == .video ? "play.rectangle" : row.kind == .image ? "photo" : "doc")
                                }.padding(.vertical, 5)
                            }.disabled(library.busy || row.kind == .file)
                        }
                        if library.visibleCount < library.rows.count {
                            Button("Show more files") { library.visibleCount += 30 }
                                .onAppear { library.visibleCount += 30 }
                        }
                    }
                } else if !library.busy {
                    Section {
                        ContentUnavailableView("Your media, on your iPhone", systemImage: "play.rectangle", description: Text("Choose a folder in Files, including a connected external drive. Files stay where they are."))
                    }
                }
                Section {
                    Text("Powered by VLC for broad video format support. Damaged or DRM-protected files may not play. Images are shown as still previews.").font(.footnote).foregroundStyle(.secondary)
                    NavigationLink("VLC & open-source notices") { ScrollView { Text(Bundle.main.url(forResource: "VLC-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "VLCKit — LGPL 2.1 or later. Source: https://code.videolan.org/videolan/VLCKit/-/tree/3.7.4").font(.footnote).padding() }.navigationTitle("Open-source notices") }
                    if library.root != nil { Button("Forget this folder", role: .destructive) { library.forget() }.disabled(library.busy) }
                }
            }
            .navigationTitle("Local Media Player")
            .tint(Color(red: 0.70, green: 0.29, blue: 0.48))
            .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
                switch result {
                case .success(let url): library.choose(url)
                case .failure(let error):
                    if (error as NSError).code != NSUserCancelledError { library.error = "The folder could not be opened. Please try again." }
                }
            }
            .fullScreenCover(isPresented: $library.showingPlayer) { PlayerView(library: library) }
        }
    }
}

@MainActor
final class Playback: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let surface = UIView()
    @Published var image: UIImage?
    @Published var busy = false
    @Published var error = ""
    @Published var playing = false
    @Published var progress: Float = 0
    @Published var elapsed = "0:00"
    @Published var ended = 0
    @Published var muted = false
    private var active = false
    private var generation = UUID()
    override init() {
        super.init()
        surface.backgroundColor = .black
        player.drawable = surface
        player.delegate = self
    }
    func stop() {
        generation = UUID(); active = false; player.stop()
        image = nil; playing = false; progress = 0; elapsed = "0:00"
    }
    func load(_ row: MediaFile, root: URL) async {
        stop(); busy = true; error = ""
        let request = generation
        defer { if request == generation { busy = false } }
        do {
            guard MediaFiles.contains(row.url, in: root), FileManager.default.isReadableFile(atPath: row.url.path) else { throw CocoaError(.fileReadNoSuchFile) }
            if row.kind == .image {
                let thumbnail = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                    guard let source = CGImageSourceCreateWithURL(row.url as CFURL, nil) else { return nil }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2048, kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
                }.value
                try Task.checkCancellation()
                guard request == generation else { return }
                guard let thumbnail else { throw CocoaError(.fileReadCorruptFile) }
                image = UIImage(cgImage: thumbnail)
            } else {
                try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
                try AVAudioSession.sharedInstance().setActive(true)
                let media = VLCMedia(url: row.url)
                media.addOption(":no-video-title-show")
                media.addOption(":no-sub-autodetect-file")
                player.media = media; active = true; player.play()
            }
        } catch {
            if !Task.isCancelled && request == generation { self.error = "This file is unavailable. Try another file or reconnect the drive." }
        }
    }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.playing = self.player.isPlaying
            self.busy = !self.player.isPlaying && (self.player.state == .opening || self.player.state == .buffering)
            if self.player.state == .error { self.error = "VLC could not play this file. It may be damaged, protected or on a disconnected drive."; self.busy = false }
            if self.player.state == .ended { self.active = false; self.ended += 1 }
        }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) {
        Task { @MainActor [weak self] in
            guard let self, self.active else { return }
            self.busy = false
            self.progress = max(0, min(1, self.player.position))
            self.elapsed = self.player.time.stringValue
        }
    }
    func toggle() { if player.isPlaying { player.pause() } else { player.play() } }
    func toggleMute() { muted.toggle(); player.audio?.isMuted = muted }
}

struct VLCVideoSurface: UIViewRepresentable {
    let surface: UIView
    func makeUIView(context: Context) -> UIView { surface }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct PlayerView: View {
    @ObservedObject var library: Library
    @StateObject private var playback = Playback()
    @State private var scrubbing = false
    @State private var seekPosition: Float = 0
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(library.current?.name ?? "Media").font(.headline).lineLimit(2)
                Spacer()
                Button { library.showingPlayer = false } label: { Image(systemName: "xmark.circle.fill").font(.title) }.accessibilityLabel("Close player")
            }.padding(.horizontal)
            ZStack {
                Color.black
                if library.current?.kind == .video { VLCVideoSurface(surface: playback.surface) }
                if let image = playback.image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                if playback.busy { ProgressView().tint(.white).accessibilityLabel("Loading media") }
                if !playback.error.isEmpty { Text(playback.error).foregroundStyle(.white).padding().multilineTextAlignment(.center) }
            }
            .gesture(DragGesture().onEnded { value in
                if value.translation.height < -60 { move(1) }
                else if value.translation.height > 60 { move(-1) }
            })
            if library.current?.kind == .video {
                VStack {
                    Slider(value: $seekPosition, in: 0...1, onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing && playback.player.isSeekable { playback.player.position = seekPosition }
                    }).accessibilityLabel("Playback position")
                    HStack {
                        Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill") }.accessibilityLabel(playback.playing ? "Pause" : "Play")
                        Text(playback.elapsed).font(.caption).monospacedDigit()
                        Spacer()
                        Menu("Speed") { ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { playback.player.rate = rate } } }
                        Button { playback.toggleMute() } label: { Image(systemName: playback.muted ? "speaker.slash.fill" : "speaker.wave.2.fill") }.accessibilityLabel(playback.muted ? "Unmute" : "Mute")
                    }.buttonStyle(.bordered)
                }.padding(.horizontal)
            }
            if let row = library.current {
                HStack(spacing: 6) {
                    ForEach(1...5, id: \.self) { value in
                        Button { library.rate(value) } label: { Image(systemName: (library.stars(of: row) ?? 0) >= value ? "star.fill" : "star") }
                            .accessibilityLabel("Rate \(value) star\(value == 1 ? "" : "s")")
                    }
                }.buttonStyle(.borderless).font(.title3).tint(.yellow)
            }
            HStack {
                Button { move(-1) } label: { Label("Previous", systemImage: "chevron.up") }.disabled(library.position == 0)
                Spacer()
                Text("\(library.position + 1) / \(library.queue.count)").font(.caption).monospacedDigit()
                Spacer()
                Button { move(1) } label: { Label("Next", systemImage: "chevron.down") }.disabled(library.position + 1 >= library.queue.count)
            }.buttonStyle(.bordered).padding(.horizontal)
        }
        .padding(.vertical)
        .task(id: library.current?.id) {
            if let row = library.current, let root = library.root {
                await playback.load(row, root: root)
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--codec-check") { await codecCheck(row) }
                #endif
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { playback.player.pause() } }
        .onChange(of: playback.ended) { _, _ in move(1) }
        .onChange(of: playback.progress) { _, value in if !scrubbing { seekPosition = value } }
        .onDisappear { playback.stop(); try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }
    private func move(_ delta: Int) {
        let next = library.position + delta
        guard library.queue.indices.contains(next) else { return }
        playback.stop(); library.position = next
    }

    #if DEBUG
    // Generated media only, enabled explicitly by the simulator cloud check.
    private func codecCheck(_ row: MediaFile) async {
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        do {
            for _ in 0..<100 {
                if playback.player.hasVideoOut && playback.player.time.intValue > 400 { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            guard playback.player.hasVideoOut, playback.player.time.intValue > 400 else { throw CocoaError(.fileReadCorruptFile) }
            playback.player.position = 0.5
            try await Task.sleep(nanoseconds: 800_000_000)
            guard playback.player.position > 0.35 else { throw CocoaError(.fileReadUnknown) }
            playback.player.pause()
            try await Task.sleep(nanoseconds: 200_000_000)
            guard !playback.player.isPlaying else { throw CocoaError(.fileReadUnknown) }
            playback.toggleMute()
            guard playback.player.audio?.isMuted == true else { throw CocoaError(.fileReadUnknown) }
            playback.toggleMute()
            let report = documents.appendingPathComponent("codec-results.txt")
            let previous = (try? String(contentsOf: report, encoding: .utf8)) ?? ""
            try (previous + "PASS \(row.name): VLC video output, seeking, pause, mute\n").write(to: report, atomically: true, encoding: .utf8)
            if library.position + 1 < library.queue.count { move(1) }
            else { try "PASS".write(to: documents.appendingPathComponent("codec-complete.txt"), atomically: true, encoding: .utf8) }
        } catch {
            try? "FAIL \(row.name): \(error)".write(to: documents.appendingPathComponent("codec-complete.txt"), atomically: true, encoding: .utf8)
        }
    }
    #endif
}
