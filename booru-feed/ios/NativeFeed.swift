#if canImport(UIKit)
import SwiftUI
import WebKit
import AVFoundation
import ImageIO

// MARK: - PC connection

/// Talks to Booru Feed on the PC with the same paired session the Feed web view uses (its HttpOnly cookie).
@MainActor
final class FeedAPI {
    let base: URL
    private let cookies: WKHTTPCookieStore
    private let session: URLSession
    init(base: URL, cookies: WKHTTPCookieStore) {
        self.base = base; self.cookies = cookies
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 300 << 20)
        config.httpShouldSetCookies = false
        config.httpMaximumConnectionsPerHost = 6
        session = URLSession(configuration: config)
    }
    enum Failure: LocalizedError { case unpaired, offline, server(String)
        var errorDescription: String? {
            switch self {
            case .unpaired: return "Pair this phone first: open Web, enter the code from Booru Feed on your PC."
            case .offline: return "The PC is offline. Check it is awake and Tailscale is connected."
            case .server(let text): return text
            }
        }
    }
    /// The pairing cookies, read from the web view's store at most every 30 s. Asking the store is a trip to the
    /// web process on the main thread; doing it for every picture is what made scrolling stutter.
    private var cookieCache: (time: Date, value: [HTTPCookie])?
    func pairedCookies() async -> [HTTPCookie] {
        if let cached = cookieCache, Date().timeIntervalSince(cached.time) < 30 { return cached.value }
        guard let host = base.host else { return [] }
        let value = await cookies.allCookies().filter { cookie in
            let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
            return host == domain || host.hasSuffix("." + domain)
        }
        cookieCache = (Date(), value)
        return value
    }
    func request(_ url: URL) async -> URLRequest {
        var request = URLRequest(url: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: await pairedCookies()) { request.setValue(value, forHTTPHeaderField: field) }
        return request
    }
    /// A signed /api/media (or /api/local) path from the PC, as an absolute URL; `width` asks for a phone-sized copy.
    func media(_ path: String?, width: Int? = nil) -> URL? {
        guard let path, path.hasPrefix("/api/"), var parts = URLComponents(url: base.appendingPathComponent(String(path.dropFirst())), resolvingAgainstBaseURL: false) else { return nil }
        if let width { parts.queryItems = [URLQueryItem(name: "w", value: String(width))] }
        return parts.url
    }
    /// POST /api/call: the same envelope the web app uses. Returns the value plus the signed media map.
    func call(_ channel: String, _ args: [JSONValue]) async throws -> (value: JSONValue, media: [String: String]) {
        var request = await request(base.appendingPathComponent("api/call"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.httpBody = Data(JSONValue.object([("channel", .string(channel)), ("args", .array(args))]).text.utf8)
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(for: request) } catch { throw Failure.offline }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let body = JSONValue.parse(String(decoding: data, as: UTF8.self))
        if status == 401 { cookieCache = nil; throw Failure.unpaired }
        guard status == 200, let body else { throw Failure.server(body?["error"]?.string ?? "The PC could not complete this request.") }
        var media = [String: String](); for (key, value) in body["media"]?.entries ?? [] { if let path = value.string { media[key] = path } }
        return (body["value"] ?? .null, media)
    }
    func data(_ url: URL) async throws -> Data {
        let (data, response) = try await session.data(for: await request(url))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.server("Media unavailable.") }
        return data
    }
}

// MARK: - Images

/// Decoded, screen-sized images for the posts around the current one; fetched and decoded off the main thread.
@MainActor
final class MediaLoader: ObservableObject {
    /// One cache for the whole app: feed tiles, manga covers and pages.
    static let shared = MediaLoader()
    private let cache = NSCache<NSString, UIImage>()
    private var tasks = [String: Task<UIImage?, Never>]()
    init() { cache.totalCostLimit = 300 << 20 }   // decoded bytes, not a count: grid tiles are small, full-screen pictures big
    /// A grid tile and the full-screen picture can share an address, so decoded copies are kept per size class.
    private func key(_ url: URL, _ maxPixel: CGFloat) -> String { url.absoluteString + (maxPixel > 1000 ? "#L" : "#S") }
    /// A picture already decoded at this size, without waiting: a tile scrolled back into view shows at once.
    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? { cache.object(forKey: key(url, maxPixel) as NSString) }
    func image(_ url: URL, api: FeedAPI, maxPixel: CGFloat) async -> UIImage? {
        let id = key(url, maxPixel)
        if let hit = cache.object(forKey: id as NSString) { return hit }
        if let running = tasks[id] { return await running.value }
        let task = Task<UIImage?, Never> {
            guard let data = try? await api.data(url) else { return nil }
            return await Task.detached(priority: .userInitiated) { MediaLoader.decode(data, maxPixel: maxPixel) }.value
        }
        tasks[id] = task
        let image = await task.value
        tasks[id] = nil
        if let image { cache.setObject(image, forKey: id as NSString, cost: Int(image.size.width * image.size.height * image.scale * image.scale * 4)) }
        return image
    }
    func prefetch(_ urls: [URL], api: FeedAPI, maxPixel: CGFloat) {
        for url in urls where cache.object(forKey: key(url, maxPixel) as NSString) == nil && tasks[key(url, maxPixel)] == nil { Task { _ = await image(url, api: api, maxPixel: maxPixel) } }
    }
    nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceShouldCacheImmediately: true,
                                                                          kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: maxPixel] as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }
}

// MARK: - Video

/// Up to three players: the current video plays muted (or with sound if unmuted), its neighbours are pre-rolled.
@MainActor
final class VideoPool: ObservableObject {
    @Published var muted = true
    private var players = [String: AVPlayer]()
    private var loopers = [String: NSObjectProtocol]()
    static let playable: Set<String> = ["mp4", "m4v", "mov"]
    static func canPlay(_ url: URL) -> Bool { playable.contains(url.pathExtension.lowercased()) || url.path.hasPrefix("/api/media/") }
    func player(for key: String, url: URL, cookies: [HTTPCookie]) -> AVPlayer {
        if let existing = players[key] { return existing }
        let asset = AVURLAsset(url: url, options: [AVURLAssetHTTPCookiesKey: cookies])
        let item = AVPlayerItem(asset: asset); item.preferredForwardBufferDuration = 4
        let player = AVPlayer(playerItem: item); player.isMuted = muted; player.automaticallyWaitsToMinimizeStalling = false
        loopers[key] = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak player] _ in
            player?.seek(to: .zero); player?.play()
            NotificationCenter.default.post(name: VideoPool.completed, object: key)
        }
        players[key] = player
        return player
    }
    static let completed = Notification.Name("NativeFeedVideoCompleted")
    /// Keep only the players for `keep`; play `current`, pause the rest.
    func focus(current: String?, keep: Set<String>) {
        for (key, player) in players where !keep.contains(key) { player.pause(); players[key] = nil; if let token = loopers.removeValue(forKey: key) { NotificationCenter.default.removeObserver(token) } }
        for (key, player) in players { if key == current { player.isMuted = muted; player.play() } else { player.pause() } }
    }
    func toggleMute() { muted.toggle(); if !muted { VideoPool.soundOn() }; players.values.forEach { $0.isMuted = muted } }
    /// Sound for the feed's videos even with the ring/silent switch on (like the Library player).
    static func soundOn() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
    }
    func pauseAll() { players.values.forEach { $0.pause() } }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    final class Surface: UIView { override class var layerClass: AnyClass { AVPlayerLayer.self } }
    func makeUIView(context: Context) -> Surface { let view = Surface(); (view.layer as! AVPlayerLayer).videoGravity = .resizeAspect; view.backgroundColor = .black; return view }
    func updateUIView(_ view: Surface, context: Context) { (view.layer as! AVPlayerLayer).player = player }
}
#endif
