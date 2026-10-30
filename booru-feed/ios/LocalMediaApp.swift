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
            var failure: Error?
            NSFileCoordinator().coordinate(writingItemAt: row.url, options: .forMoving, writingItemAt: target, options: .forReplacing, error: nil) { from, to in
                do { try FileManager.default.moveItem(at: from, to: to) } catch { failure = error }
            }
            if let failure { throw failure }
            let moved = MediaFile(url: target, kind: row.kind)
            queue[position] = moved
            if let index = rows.firstIndex(where: { $0.id == row.id }) { rows.remove(at: index) }
            message = "Rated \(stars) star\(stars == 1 ? "" : "s") · moved to \(folder.lastPathComponent)."
        } catch { self.error = "The file could not be moved: \(error.localizedDescription)" }
    }
    // Deleting is permanent: drives in Files have no Recently Deleted.
    func delete() {
        guard let root, let row = current, row.kind != .folder else { return }
        let access = root.startAccessingSecurityScopedResource()
        defer { if access { root.stopAccessingSecurityScopedResource() } }
        var failure: Error?
        NSFileCoordinator().coordinate(writingItemAt: row.url, options: .forDeleting, error: nil) { url in
            do { try FileManager.default.removeItem(at: url) } catch { failure = error }
        }
        if let failure { self.error = "The file could not be deleted: \(failure.localizedDescription)"; return }
        queue.remove(at: position)
        if let index = rows.firstIndex(where: { $0.id == row.id }) { rows.remove(at: index) }
        if queue.isEmpty { showingPlayer = false } else { position = min(position, queue.count - 1) }
        message = "Deleted \(row.name)."
    }
    func open(_ row: MediaFile) {
        if row.kind == .folder { browse(row.url); return }
        queue = rows.filter(\.playable)
        position = queue.firstIndex(where: { $0.id == row.id }) ?? 0
        showingPlayer = !queue.isEmpty
    }
}

extension Color {
    static let brand = Color(red: 0.89, green: 0.72, blue: 0.26)
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let panel = Color(red: 0.19, green: 0.19, blue: 0.19)
}

// A round dark button with a yellow icon, dimmed when it cannot be used.
struct RudderButton: View {
    let icon: String, label: String, size: CGFloat, action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(Color.brand)
                .frame(width: size, height: size).background(Color.ink, in: Circle())
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }
}

struct LibraryView: View {
    enum Page { case library, pc, settings }
    @StateObject private var library = Library()
    @State private var picking = false
    @State private var page = Page.library
    @AppStorage("shuffleSubfolders") private var recursive = true
    var body: some View {
        VStack(spacing: 0) {
            NavigationStack {
                Group {
                    switch page {
                    case .library: libraryPage
                    case .pc: PCConnectionView()
                    case .settings: settingsPage
                    }
                }
                .toolbarBackground(Color.ink, for: .navigationBar)
            }
            tabBar
        }
        .background(Color.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Color.brand)
        .fileImporter(isPresented: $picking, allowedContentTypes: [.folder]) { result in
            switch result {
            case .success(let url): library.choose(url); page = .library
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { library.error = "The folder could not be opened. Please try again." }
            }
        }
        .fullScreenCover(isPresented: $library.showingPlayer) { PlayerView(library: library) }
    }

    // Tab bar: yellow, with the folder picker as the raised centre button.
    private var tabBar: some View {
        HStack {
            tabButton(.library, icon: "house.fill", label: "Library")
            Spacer()
            Button { page = .library; library.shuffle(recursive: recursive) } label: { tabLabel(icon: "shuffle", label: "Shuffle", selected: false) }
                .disabled(library.folder == nil || library.busy).opacity(library.folder == nil ? 0.4 : 1)
            Spacer()
            RudderButton(icon: "plus", label: "Choose folder or drive", size: 56) { picking = true }.disabled(library.busy)
            Spacer()
            tabButton(.pc, icon: "desktopcomputer", label: "PC")
            Spacer()
            tabButton(.settings, icon: "gearshape.fill", label: "Settings")
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.ink)
        .padding(.horizontal, 22).padding(.top, 10).padding(.bottom, 2)
        .background(UnevenRoundedRectangle(topLeadingRadius: 24, topTrailingRadius: 24, style: .continuous).fill(Color.brand).ignoresSafeArea(edges: .bottom))
    }
    private func tabButton(_ target: Page, icon: String, label: String) -> some View {
        Button { page = target } label: { tabLabel(icon: icon, label: label, selected: page == target) }
            .accessibilityAddTraits(page == target ? .isSelected : [])
    }
    private func tabLabel(icon: String, label: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.title3)
            Text(label).font(.caption2.weight(.semibold))
        }.opacity(selected ? 1 : 0.6).frame(minWidth: 44, minHeight: 44)
    }

    // Grid: folders and files as yellow tiles, two to a row.
    private var libraryPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let root = library.root, let folder = library.folder {
                    HStack(spacing: 10) {
                        circle("arrow.up", "Up") { library.browse(folder.deletingLastPathComponent()) }.disabled(folder == root)
                        circle("house", "Root") { library.browse(root) }
                        circle("arrow.clockwise", "Refresh folder") { library.browse(folder) }
                    }.disabled(library.busy)
                }
                if library.busy {
                    HStack { ProgressView(); Text("Reading folder…"); Spacer(); Button("Cancel") { library.cancel() } }
                        .padding().background(Color.panel, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                if !library.error.isEmpty { Text(library.error).foregroundStyle(.red).accessibilityAddTraits(.updatesFrequently) }
                if !library.message.isEmpty { Text(library.message).foregroundStyle(.secondary) }
                if library.folder != nil {
                    if library.rows.isEmpty && !library.busy { Text("This folder is empty.").foregroundStyle(.secondary) }
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(library.rows.prefix(library.visibleCount)) { row in
                            Button { library.open(row) } label: { tile(row) }.buttonStyle(.plain).disabled(library.busy || row.kind == .file)
                        }
                    }
                    if library.visibleCount < library.rows.count {
                        Button("Show more files") { library.visibleCount += 30 }.frame(maxWidth: .infinity)
                            .onAppear { library.visibleCount += 30 }
                    }
                } else if !library.busy {
                    ContentUnavailableView {
                        Label("Your media, on your iPhone", systemImage: "play.rectangle")
                    } description: {
                        Text("Choose a folder in Files, including a connected external drive. Files stay where they are.")
                    } actions: {
                        Button("Choose folder") { picking = true }.buttonStyle(.borderedProminent).foregroundStyle(Color.ink)
                    }.padding(.top, 60)
                }
            }.padding(16)
        }
        .background(Color.ink)
        .navigationTitle(library.folder?.lastPathComponent ?? "Local Media")
    }
    private func circle(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 44, height: 44).background(Color.panel, in: Circle()) }
            .accessibilityLabel(label)
    }
    private func tile(_ row: MediaFile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: row.kind == .folder ? "folder.fill" : row.kind == .video ? "play.rectangle.fill" : row.kind == .image ? "photo.fill" : "doc").font(.title2)
            Spacer(minLength: 0)
            Text(row.name).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .foregroundStyle(row.kind == .file ? Color.white.opacity(0.5) : Color.ink)
        .padding(14).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(row.kind == .file ? Color.panel : Color.brand, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var settingsPage: some View {
        List {
            Section {
                Button { picking = true } label: { Label("Choose folder or drive", systemImage: "folder.badge.plus") }
                Toggle("Shuffle includes subfolders", isOn: $recursive)
                if library.root != nil { Button("Forget this folder", role: .destructive) { library.forget(); page = .library }.disabled(library.busy) }
            }
            Section {
                Text("Powered by VLC for broad video format support. Damaged or DRM-protected files may not play. Images are shown as still previews.").font(.footnote).foregroundStyle(.secondary)
                NavigationLink("VLC & open-source notices") { ScrollView { Text(Bundle.main.url(forResource: "VLC-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "VLCKit — LGPL 2.1 or later. Source: https://code.videolan.org/videolan/VLCKit/-/tree/3.7.4").font(.footnote).padding() }.navigationTitle("Open-source notices") }
            }
        }
        .scrollContentBackground(.hidden).background(Color.ink)
        .navigationTitle("Settings")
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
    @State private var confirmingDelete = false
    @State private var seekPosition: Float = 0
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        VStack(spacing: 0) {
            // Three dots: a yellow top bar with back and a menu for the less frequent actions.
            HStack(spacing: 12) {
                Button { library.showingPlayer = false } label: { Image(systemName: "arrow.left").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("Close player")
                Text(library.current?.name ?? "Media").font(.headline).lineLimit(1)
                Spacer()
                Menu {
                    if library.current?.kind == .video {
                        Menu("Speed") { ForEach([Float(0.5), 1, 1.5, 2], id: \.self) { rate in Button("\(rate.formatted())×") { playback.player.rate = rate } } }
                        Button { playback.toggleMute() } label: { Label(playback.muted ? "Unmute" : "Mute", systemImage: playback.muted ? "speaker.wave.2.fill" : "speaker.slash.fill") }
                    }
                    if library.current != nil { Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete file", systemImage: "trash") } }
                } label: { Image(systemName: "ellipsis").rotationEffect(.degrees(90)).font(.title3.weight(.semibold)).frame(width: 44, height: 44) }.accessibilityLabel("More")
            }
            .foregroundStyle(Color.ink).padding(.horizontal, 12)
            .background(Color.brand.ignoresSafeArea(edges: .top))
            ZStack {
                Color.black
                if library.current?.kind == .video { VLCVideoSurface(surface: playback.surface) }
                if let image = playback.image {
                    Image(uiImage: image).resizable().scaledToFit()
                }
                if playback.busy { ProgressView().tint(Color.brand).accessibilityLabel("Loading media") }
                if !playback.error.isEmpty { Text(playback.error).foregroundStyle(.white).padding().multilineTextAlignment(.center) }
            }
            .gesture(DragGesture().onEnded { value in
                if value.translation.height < -60 { move(1) }
                else if value.translation.height > 60 { move(-1) }
            })
            // Sheet: the controls sit on a yellow panel, with rudder-style previous / play / next at the bottom.
            VStack(spacing: 14) {
                Capsule().fill(Color.ink.opacity(0.25)).frame(width: 36, height: 5)
                if library.current?.kind == .video {
                    Slider(value: $seekPosition, in: 0...1, onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing && playback.player.isSeekable { playback.player.position = seekPosition }
                    }).tint(Color.ink).accessibilityLabel("Playback position")
                }
                HStack {
                    if library.current?.kind == .video { Text(playback.elapsed) }
                    Spacer()
                    Text("\(library.position + 1) / \(library.queue.count)")
                }.font(.caption.weight(.semibold)).monospacedDigit()
                if let row = library.current {
                    HStack(spacing: 10) {
                        ForEach(1...5, id: \.self) { value in
                            Button { playback.stop(); library.rate(value) } label: { Image(systemName: (library.stars(of: row) ?? 0) >= value ? "star.fill" : "star").frame(width: 40, height: 40) }
                                .accessibilityLabel("Rate \(value) star\(value == 1 ? "" : "s")")
                        }
                    }.font(.title3)
                    if !library.error.isEmpty { Label(library.error, systemImage: "exclamationmark.triangle.fill").font(.footnote.weight(.semibold)) }
                }
                HStack(spacing: 28) {
                    RudderButton(icon: "chevron.up", label: "Previous", size: 48) { move(-1) }.disabled(library.position == 0)
                    if library.current?.kind == .video {
                        RudderButton(icon: playback.playing ? "pause.fill" : "play.fill", label: playback.playing ? "Pause" : "Play", size: 64) { playback.toggle() }
                    }
                    RudderButton(icon: "chevron.down", label: "Next", size: 48) { move(1) }.disabled(library.position + 1 >= library.queue.count)
                }
            }
            .foregroundStyle(Color.ink)
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
            .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous).fill(Color.brand).ignoresSafeArea(edges: .bottom))
        }
        .background(Color.ink.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete \(library.current?.name ?? "this file")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { playback.stop(); library.delete() }
        } message: { Text("This removes the file from the drive. It cannot be undone.") }
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
