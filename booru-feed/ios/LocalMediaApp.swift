import SwiftUI
import AVFoundation
import MobileVLCKit
import UniformTypeIdentifiers
import ImageIO

@main
struct LocalMediaApp: App {
    var body: some Scene { WindowGroup { AppShell() } }
}

@MainActor
final class Library: ObservableObject {
    /// Every folder or drive chosen in Files, in the order they were added.
    @Published var roots = [URL]()
    /// The chosen folder being browsed and played from; its permission is the one held open.
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
    /// The folder picker is open (shown by the app shell, asked for from the Library and Settings pages).
    @Published var picking = false
    // A file the Feed tab downloaded for the player: it lives in temporary storage, outside the chosen folder.
    @Published var tempPlayback = false
    private var scoped = false
    /// Each chosen folder's saved permission, as Files handed it over.
    private var bookmarks = [URL: Data]()
    private static let foldersKey = "selectedFolders"
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
        // The single folder older versions remembered is carried over as the first of the list.
        var saved = UserDefaults.standard.array(forKey: Self.foldersKey) as? [Data] ?? []
        if saved.isEmpty, let old = UserDefaults.standard.data(forKey: "selectedFolder") { saved = [old] }
        for data in saved {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale), !roots.contains(url) else { continue }
            roots.append(url); bookmarks[url] = data
        }
        if roots.isEmpty { if !saved.isEmpty { self.error = "Reconnect your drive, then choose its folder again." }; return }
        // One folder opens straight away; with several, the list of folders is the starting point.
        if roots.count == 1 { activate(roots[0]) }
    }

    func cancel() { generation = UUID(); job?.cancel(); job = nil; busy = false }
    /// A folder picked in Files: remember it and open it.
    func choose(_ url: URL) { add(url); activate(url) }
    /// Several picked at once: remember them all, open the first.
    func choose(_ urls: [URL]) {
        for url in urls { add(url) }
        if let first = urls.first { activate(first) }
    }
    private func add(_ url: URL) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        if let data = try? url.bookmarkData(options: [.minimalBookmark], includingResourceValuesForKeys: nil, relativeTo: nil) { bookmarks[url] = data }
        if !roots.contains(url) { roots.append(url) }
        save()
    }
    private func save() {
        UserDefaults.standard.set(roots.compactMap { bookmarks[$0] }, forKey: Self.foldersKey)
        UserDefaults.standard.removeObject(forKey: "selectedFolder")
    }
    /// Browse one of the chosen folders. Only the folder in use keeps its permission open.
    func activate(_ url: URL) {
        cancel()
        if scoped { root?.stopAccessingSecurityScopedResource() }
        scoped = url.startAccessingSecurityScopedResource()
        root = url; queue = []; showingPlayer = false
        browse(url)
    }
    /// The top: the list of chosen folders when there are several, otherwise the top of the only one.
    func home() {
        guard roots.count > 1 else { if let root { browse(root) }; return }
        cancel(); folder = nil; rows = []; error = ""; message = ""
    }
    /// Stop remembering a folder. Its files are not touched.
    func forget(_ url: URL) {
        roots.removeAll { $0 == url }; bookmarks[url] = nil; save()
        guard url == root else { return }
        cancel(); showingPlayer = false; queue = []; rows = []; folder = nil
        if scoped { url.stopAccessingSecurityScopedResource() }
        root = nil; scoped = false; error = ""; message = ""
        if roots.count == 1 { activate(roots[0]) }
    }
    func forget() { if let root { forget(root) } }
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
                    self.queue = result.rows; self.position = 0; self.tempPlayback = false; self.showingPlayer = !result.rows.isEmpty
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
    func playDownloaded(_ url: URL) {
        let ext = url.pathExtension.lowercased()
        queue = [MediaFile(url: url, kind: MediaFiles.images.contains(ext) ? .image : .video)]
        position = 0; tempPlayback = true; showingPlayer = true
    }
    func open(_ row: MediaFile) {
        if row.kind == .folder { browse(row.url); return }
        tempPlayback = false
        queue = rows.filter(\.playable)
        position = queue.firstIndex(where: { $0.id == row.id }) ?? 0
        showingPlayer = !queue.isEmpty
    }
}

extension Color {
    static let brand = Color(red: 0.95, green: 0.67, blue: 0.78)
    static let ink = Color(red: 0.13, green: 0.11, blue: 0.14)
    static let panel = Color(red: 0.16, green: 0.13, blue: 0.18)
}

// A round dark button with a pink icon, dimmed when it cannot be used.
struct RudderButton: View {
    let icon: String, label: String, size: CGFloat
    var tint: Color = Color.brand, caption: String? = nil
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: size * 0.38, weight: .bold)).foregroundStyle(tint)
                    .frame(width: size, height: size).background(Color.ink, in: Circle())
                if let caption { Text(caption).font(.caption2.weight(.semibold)) }
            }
        }.buttonStyle(.plain).opacity(enabled ? 1 : 0.35).accessibilityLabel(label)
    }
}

/// The phone's own folder (Saved → Boards → On this iPhone): folders and files as pink tiles, two to a row.
struct LocalLibraryPage: View {
    @EnvironmentObject var library: Library
    @AppStorage("shuffleSubfolders") private var recursive = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let root = library.root, let folder = library.folder {
                    HStack(spacing: 10) {
                        circle("arrow.up", "Up") { library.browse(folder.deletingLastPathComponent()) }.disabled(folder == root)
                        circle(library.roots.count > 1 ? "square.grid.2x2" : "house", library.roots.count > 1 ? "All folders" : "Root") { library.home() }
                        circle("arrow.clockwise", "Refresh folder") { library.browse(folder) }
                        Spacer()
                        circle("shuffle", "Shuffle") { library.shuffle(recursive: recursive) }
                        circle("folder.badge.plus", "Add folder or drive") { library.picking = true }
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
                } else if !library.busy && !library.roots.isEmpty {
                    // Several folders chosen: pick which one to open, or add another.
                    Text("Your folders").font(.headline)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
                        ForEach(library.roots, id: \.self) { url in
                            Button { library.activate(url) } label: { folderTile(url.lastPathComponent, icon: "folder.fill", filled: true) }.buttonStyle(.plain)
                        }
                        Button { library.picking = true } label: { folderTile("Add folder or drive", icon: "folder.badge.plus", filled: false) }.buttonStyle(.plain)
                    }
                } else if !library.busy {
                    ContentUnavailableView {
                        Label("Your media, on your iPhone", systemImage: "play.rectangle")
                    } description: {
                        Text("Choose one or more folders in Files, including a connected external drive. Files stay where they are.")
                    } actions: {
                        Button("Choose folder") { library.picking = true }.buttonStyle(.borderedProminent).foregroundStyle(Color.ink)
                    }.padding(.top, 60)
                }
            }.padding(16)
        }
        .background(Color.black)
        .navigationTitle(library.folder?.lastPathComponent ?? "On this iPhone")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
    }
    private func circle(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.body.weight(.semibold)).frame(width: 44, height: 44).background(Color.panel, in: Circle()) }
            .accessibilityLabel(label)
    }
    private func folderTile(_ name: String, icon: String, filled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon).font(.title2)
            Spacer(minLength: 0)
            Text(name).font(.footnote.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading)
        }
        .foregroundStyle(filled ? Color.ink : Color.white)
        .padding(14).frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
        .background(filled ? Color.brand : Color.panel, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
}

/// Settings (the gear on the Saved tab).
struct SettingsPage: View {
    @EnvironmentObject var library: Library
    @EnvironmentObject var browser: FeedBrowser
    @EnvironmentObject var hub: NativeHub
    @EnvironmentObject var router: TabRouter
    @AppStorage("shuffleSubfolders") private var recursive = true
    var body: some View {
        List {
            Section("Booru Feed on your PC") {
                if let connected = browser.connected {
                    LabeledContent("Connected to", value: connected.host ?? "PC")
                    Button { router.go(.web) } label: { Label("Web version", systemImage: "globe") }
                    Button(role: .destructive) { hub.stop(); browser.disconnect() } label: { Label("Disconnect from PC", systemImage: "wifi.slash") }
                } else {
                    Text("Not connected. Open Home to connect.").foregroundStyle(.secondary)
                }
            }
            Section("On this iPhone") {
                ForEach(library.roots, id: \.self) { url in
                    HStack {
                        Label(url.lastPathComponent, systemImage: "folder")
                        Spacer()
                        Button("Forget", role: .destructive) { library.forget(url) }.buttonStyle(.borderless).disabled(library.busy)
                            .accessibilityLabel("Forget \(url.lastPathComponent)")
                    }
                }
                Button { library.picking = true } label: { Label("Add folder or drive", systemImage: "folder.badge.plus") }
                Toggle("Shuffle includes subfolders", isOn: $recursive)
            }
            Section {
                Text("Powered by VLC for broad video format support. Damaged or DRM-protected files may not play. Images are shown as still previews.").font(.footnote).foregroundStyle(.secondary)
                NavigationLink("VLC & open-source notices") { ScrollView { Text(Bundle.main.url(forResource: "VLC-LICENSE", withExtension: "txt").flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "VLCKit — LGPL 2.1 or later. Source: https://code.videolan.org/videolan/VLCKit/-/tree/3.7.4").font(.footnote).padding() }.navigationTitle("Open-source notices") }
            }
        }
        .scrollContentBackground(.hidden).background(Color.black)
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
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
    @State private var fullscreen = false
    /// Full screen only: the controls over the media (a tap shows or hides them; they hide themselves after a moment).
    @State private var chrome = true
    /// Full screen only: the media fills the screen, cropping its edges, instead of fitting inside it (double tap).
    @State private var zoomed = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSize
    var body: some View {
        VStack(spacing: 0) {
            // Three dots: a pink top bar with back and a menu for the less frequent actions.
            if !fullscreen { HStack(spacing: 12) {
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
            .background(Color.brand.ignoresSafeArea(edges: .top)) }
            GeometryReader { proxy in
                ZStack {
                    Color.black
                    Group {
                        if library.current?.kind == .video { VLCVideoSurface(surface: playback.surface) }
                        if let image = playback.image {
                            Image(uiImage: image).resizable().scaledToFit()
                        }
                    }.scaleEffect(fillScale(proxy.size))
                    if playback.busy { ProgressView().tint(Color.brand).accessibilityLabel("Loading media") }
                    if !playback.error.isEmpty { Text(playback.error).foregroundStyle(.white).padding().multilineTextAlignment(.center) }
                    // Full screen: the media alone, edge to edge, under the status bar and the home indicator.
                    // A tap shows the controls for a few seconds; a double tap fills the screen.
                    if fullscreen && chrome { fullscreenControls }
                }
                .frame(width: proxy.size.width, height: proxy.size.height).clipped()
            }
            .ignoresSafeArea(edges: fullscreen ? .all : [])
            .onTapGesture(count: 2) { if fullscreen { withAnimation { zoomed.toggle() } } }
            .onTapGesture { if fullscreen { withAnimation { chrome.toggle() } } }
            .gesture(DragGesture().onEnded { value in
                if scrubbing { return }
                if value.translation.height < -60 { move(1) }
                else if value.translation.height > 60 { move(-1) }
            })
            // Sheet: the controls sit on a pink panel, with rudder-style previous / play / next at the bottom.
            if !fullscreen { VStack(spacing: 14) {
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
                // Transport: labelled previous / play / next, with delete and full screen either side.
                HStack(alignment: .top, spacing: 18) {
                    RudderButton(icon: "trash.fill", label: "Delete file", size: 44, tint: Color(red: 1, green: 0.45, blue: 0.5), caption: "Delete") { confirmingDelete = true }.disabled(library.current == nil)
                    Spacer(minLength: 0)
                    RudderButton(icon: "backward.end.fill", label: "Previous", size: 52, caption: "Previous") { move(-1) }.disabled(library.position == 0)
                    if library.current?.kind == .video {
                        RudderButton(icon: playback.playing ? "pause.fill" : "play.fill", label: playback.playing ? "Pause" : "Play", size: 68, caption: playback.playing ? "Pause" : "Play") { playback.toggle() }
                    }
                    RudderButton(icon: "forward.end.fill", label: "Next", size: 52, caption: "Next") { move(1) }.disabled(library.position + 1 >= library.queue.count)
                    Spacer(minLength: 0)
                    RudderButton(icon: "arrow.up.left.and.arrow.down.right", label: "Full screen", size: 44, caption: "Full") { withAnimation { fullscreen = true; chrome = true } }
                }
            }
            .foregroundStyle(Color.ink)
            .buttonStyle(.plain)
            .padding(.horizontal, 20).padding(.top, 8).padding(.bottom, 10)
            .background(UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28, style: .continuous).fill(Color.brand).ignoresSafeArea(edges: .bottom)) }
        }
        .statusBarHidden(fullscreen)
        .persistentSystemOverlays(fullscreen ? .hidden : .automatic)
        .background(Color.ink.ignoresSafeArea())
        // Turning the phone sideways leaves no room for the control panel, so the media takes the whole screen.
        .onAppear { if verticalSize == .compact { fullscreen = true } }
        .onChange(of: verticalSize) { _, size in if size == .compact { withAnimation { fullscreen = true; chrome = true } } }
        .task(id: "\(fullscreen) \(chrome) \(scrubbing)") {
            guard fullscreen, chrome, !scrubbing else { return }
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            if !Task.isCancelled { withAnimation { chrome = false } }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog("Delete \(library.current?.name ?? "this file")?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete permanently", role: .destructive) { playback.stop(); library.delete() }
        } message: { Text("This removes the file from the drive. It cannot be undone.") }
        .task(id: library.current?.id) {
            if let row = library.current, let root = library.tempPlayback ? FileManager.default.temporaryDirectory : library.root {
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
    /// How much to enlarge fitted media so it covers the whole area (1 when not filling, or before its size is known).
    private func fillScale(_ area: CGSize) -> CGFloat {
        let media = library.current?.kind == .video ? playback.player.videoSize : (playback.image?.size ?? .zero)
        guard fullscreen, zoomed, media.width > 0, media.height > 0, area.width > 0, area.height > 0 else { return 1 }
        let across = area.width / media.width, down = area.height / media.height
        return max(across, down) / min(across, down)
    }
    private var fullscreenControls: some View {
        VStack {
            HStack {
                Spacer()
                Button { withAnimation { fullscreen = false } } label: { Image(systemName: "arrow.down.right.and.arrow.up.left").font(.title3.weight(.semibold)).foregroundStyle(Color.brand).frame(width: 44, height: 44).background(Color.ink.opacity(0.7), in: Circle()) }
                    .accessibilityLabel("Exit full screen").padding()
            }
            Spacer()
            if library.current?.kind == .video {
                HStack(spacing: 12) {
                    Button { playback.toggle() } label: { Image(systemName: playback.playing ? "pause.fill" : "play.fill").font(.title3.weight(.semibold)).frame(width: 44, height: 44) }
                        .accessibilityLabel(playback.playing ? "Pause" : "Play")
                    Slider(value: $seekPosition, in: 0...1, onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing && playback.player.isSeekable { playback.player.position = seekPosition }
                    }).tint(Color.brand).accessibilityLabel("Playback position")
                    Text(playback.elapsed).font(.caption.weight(.semibold)).monospacedDigit()
                }
                .foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.ink.opacity(0.7), in: Capsule()).padding(.horizontal, 16).padding(.bottom, 24)
            }
        }
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
