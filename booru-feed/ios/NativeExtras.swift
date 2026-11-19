#if canImport(UIKit)
import SwiftUI
import AVKit
import PDFKit
import MobileVLCKit

// MARK: - Inline VLC for formats AVPlayer cannot play (webm, mkv, avi, wmv, flv)

/// Videos AVPlayer can't open are fetched in the background through the paired session (the PC keeps requiring its
/// cookie), then played inline with VLC the moment their card is on screen. The newest few files are kept.
@MainActor
final class VideoFiles {
    static let shared = VideoFiles()
    static let vlcOnly: Set<String> = ["webm", "mkv", "avi", "wmv", "flv", "mk3d", "ogv"]
    static func needsVLC(_ post: FeedPost) -> Bool { vlcOnly.contains(URL(string: post.mediaUrl)?.pathExtension.lowercased() ?? "") }
    private let folder = FileManager.default.temporaryDirectory.appendingPathComponent("native-vlc", isDirectory: true)
    private var tasks = [String: Task<URL?, Never>](), order = [String]()
    func file(for post: FeedPost, model: FeedModel) async -> URL? {
        if let running = tasks[post.id] { return await running.value }
        let task = Task<URL?, Never> { [folder] in
            guard let url = await model.videoURL(post) else { return nil }
            let ext = URL(string: post.mediaUrl)?.pathExtension.lowercased() ?? "mp4"
            let target = folder.appendingPathComponent("\(abs(post.id.hashValue)).\(ext)")
            if FileManager.default.fileExists(atPath: target.path) { return target }
            guard let result = try? await URLSession.shared.download(for: await model.api.request(url)),
                  (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
            let temporary = result.0
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: target)
            return (try? FileManager.default.moveItem(at: temporary, to: target)) != nil ? target : nil
        }
        tasks[post.id] = task; order.append(post.id)
        while order.count > 4 { let old = order.removeFirst(); if let gone = await tasks.removeValue(forKey: old)?.value { try? FileManager.default.removeItem(at: gone) } }
        return await task.value
    }
    /// Streams through the app's loopback proxy; downloads the whole file only if the proxy cannot start.
    func url(for post: FeedPost, model: FeedModel) async -> URL? {
        guard let remote = await model.videoURL(post) else { return nil }
        if let local = await StreamProxy.shared.localURL(for: remote, api: model.api) { return local }
        return await file(for: post, model: model)
    }
    /// Nothing to download ahead any more; tube-style posts still get their file address looked up early.
    func prefetch(_ posts: [FeedPost], model: FeedModel) { for post in posts.prefix(2) where Self.needsVLC(post) && post.needsVideoLookup { Task { _ = await model.videoURL(post) } } }
}

@MainActor
final class InlineVLC: NSObject, ObservableObject, VLCMediaPlayerDelegate {
    let player = VLCMediaPlayer()
    let surface = UIView()
    @Published var playing = false
    @Published var buffering = true
    init(url: URL) {
        super.init()
        player.delegate = self
        surface.backgroundColor = .black
        player.drawable = surface
        let media = VLCMedia(url: url)
        media.addOption(":network-caching=1500")       // ~1.5 s of buffer before it starts
        media.addOption(":input-repeat=65535")          // loop like the other feed videos
        media.addOption(":no-video-title-show")
        player.media = media
    }
    func play(muted: Bool) { player.audio?.isMuted = muted; player.play(); playing = true }
    func pause() { player.pause(); playing = false }
    func toggle(muted: Bool) { playing ? pause() : play(muted: muted) }
    func stop() { player.stop(); playing = false }
    nonisolated func mediaPlayerStateChanged(_ notification: Notification) {
        Task { @MainActor in buffering = !player.isPlaying && [.opening, .buffering].contains(player.state); if player.isPlaying { buffering = false } }
    }
    nonisolated func mediaPlayerTimeChanged(_ notification: Notification) { Task { @MainActor in if buffering { buffering = false } } }
}

struct ViewHost: UIViewRepresentable {
    let view: UIView
    func makeUIView(context: Context) -> UIView { view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Full screen video

struct FullscreenVideo: View {
    let player: AVPlayer?
    let vlc: InlineVLC?
    @Environment(\.dismiss) private var dismiss
    @State private var big = UIView()   // VLC draws here while full screen, then goes back to the card's view
    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            if let player { SystemPlayer(player: player).ignoresSafeArea() }
            else if let vlc { ViewHost(view: big).ignoresSafeArea().onTapGesture { vlc.toggle(muted: false) } }
            Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.bold)).foregroundStyle(.white).frame(width: 44, height: 44).background(.black.opacity(0.5), in: Circle()) }
                .accessibilityLabel("Exit full screen").padding()
        }
        .statusBarHidden()
        .onAppear { VideoPool.soundOn(); big.backgroundColor = .black; vlc?.player.drawable = big; player?.isMuted = false; player?.play(); vlc?.play(muted: false) }
        .onDisappear { if let vlc { vlc.player.drawable = vlc.surface } }
    }
}

/// Apple's own player: scrubbing, picture in picture and rotation for full screen.
struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController(); controller.player = player; controller.allowsPictureInPicturePlayback = true; return controller
    }
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) { controller.player = player }
}

// MARK: - PDF manga books

struct PDFBookReader: View {
    let api: FeedAPI, book: JSONValue
    @State private var document: PDFDocument?
    @State private var error = ""
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let document { PDFPages(document: document, start: Int(book["page"]?.number ?? 1)) { page in save(page) } }
            else if !error.isEmpty { Text(error).foregroundStyle(.white).padding() }
            else { ProgressView("Loading book…").tint(Color.brand).foregroundStyle(.white) }
        }
        .navigationTitle(book["name"]?.string ?? "").navigationBarTitleDisplayMode(.inline)
        .task {
            guard let id = book["id"]?.string, let url = URL(string: "api/pdf/\(id)", relativeTo: api.base) else { return }
            do { document = PDFDocument(data: try await api.data(url)); if document == nil { error = "This PDF could not be opened." } }
            catch { self.error = error.localizedDescription }
        }
    }
    @State private var pending: Task<Void, Never>?
    private func save(_ page: Int) {
        pending?.cancel()
        pending = Task { try? await Task.sleep(nanoseconds: 800_000_000); guard !Task.isCancelled, let id = book["id"]?.string else { return }
            _ = try? await api.call("booru:manga:position", [.string(id), .number(Double(page))]) }
    }
}

private struct PDFPages: UIViewRepresentable {
    let document: PDFDocument, start: Int, onPage: (Int) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPage: onPage) }
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.document = document; view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = .black
        if let page = document.page(at: max(0, start - 1)) { DispatchQueue.main.async { view.go(to: page) } }
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.changed(_:)), name: .PDFViewPageChanged, object: view)
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) {}
    final class Coordinator: NSObject {
        let onPage: (Int) -> Void
        init(onPage: @escaping (Int) -> Void) { self.onPage = onPage }
        @objc func changed(_ note: Notification) { guard let view = note.object as? PDFView, let page = view.currentPage, let index = view.document?.index(for: page) else { return }; onPage(index + 1) }
    }
}
#endif
