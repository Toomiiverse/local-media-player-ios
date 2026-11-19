#if canImport(UIKit)
import SwiftUI
import AVFoundation

// MARK: - Shared library state (same keys, same edits, same compare-and-swap writes as the web app)

@MainActor
final class SharedStore: ObservableObject {
    @Published private(set) var raw = [String: String]()
    @Published var syncError = ""
    let api: FeedAPI
    private var chain: Task<Void, Never>?
    init(api: FeedAPI) { self.api = api }

    func refresh() async throws { apply(try await api.call("booru:state-read", []).value) }
    private func apply(_ state: JSONValue) {
        var next = [String: String]()
        for (key, value) in state.entries ?? [] { if let text = value.string { next[key] = text } }
        if !next.isEmpty { raw = next }
    }
    subscript(key: String) -> String? { raw[key] }

    /// web setSharedItem: update locally at once, then write (key, before, after) to the PC in order.
    func write(_ key: String, _ after: String) {
        let before = raw[key] ?? SharedKeys.empty(key)
        guard before != after else { return }
        raw[key] = after
        let previous = chain
        chain = Task { [api] in
            await previous?.value
            do { apply(try await api.call("booru:state-write", [.string(key), .string(before), .string(after)]).value); syncError = "" }
            catch { syncError = "Could not sync with the PC: \(error.localizedDescription) Repeat the action when connected." }
        }
    }

    // Derived views
    var preferences: JSONValue { JSONValue.parse(raw[SharedKeys.preferences]) ?? .object([]) }
    var hidden: Set<String> { SharedEdit.hidden(raw[SharedKeys.neverShow]) }
    var blocked: Set<String> { SharedEdit.blocked(raw[SharedKeys.preferences]) }
    func isLiked(_ post: FeedPost) -> Bool { SharedEdit.reactions(raw[SharedKeys.reactions]).liked.contains { $0.0 == post.id } }
    func isDisliked(_ post: FeedPost) -> Bool { SharedEdit.reactions(raw[SharedKeys.reactions]).disliked.contains { $0.0 == post.id } }
    func isSaved(_ post: FeedPost) -> Bool { SharedEdit.isSaved(post, current: raw[SharedKeys.saved]) }

    // Actions (web: react, hideForever, toggleBlocked, bookmark), plus the taste-model update the web does from its import effect.
    func react(_ post: FeedPost, kind: String, fromVideos: Bool) {
        let result = SharedEdit.react(post, kind: kind, reactions: raw[SharedKeys.reactions], likedPosts: raw[SharedKeys.likedPosts], fromVideos: fromVideos, now: Date().timeIntervalSince1970 * 1000)
        write(SharedKeys.reactions, result.reactions)
        if let liked = result.likedPosts { write(SharedKeys.likedPosts, liked) }
        if result.newLike { write(SharedKeys.savedActivity, SharedEdit.activity(post, kind: "like", current: raw[SharedKeys.savedActivity], now: Date().timeIntervalSince1970 * 1000)) }
        teach(post)
    }
    func hide(_ post: FeedPost) { write(SharedKeys.neverShow, SharedEdit.neverShow(post, current: raw[SharedKeys.neverShow])) }
    func block(_ tag: String) { write(SharedKeys.preferences, SharedEdit.toggleBlocked(tag, preferences: raw[SharedKeys.preferences])) }
    func setPreference(_ key: String, _ value: JSONValue) { var prefs = preferences; prefs[key] = value; write(SharedKeys.preferences, prefs.text) }
    func save(_ post: FeedPost) async throws {
        let removing = isSaved(post)
        if !removing { _ = try await api.call("booru:download-post", [post.raw]) }
        write(SharedKeys.saved, SharedEdit.saved(post, removing: removing, current: raw[SharedKeys.saved]))
        if !removing { write(SharedKeys.savedActivity, SharedEdit.activity(post, kind: "save", current: raw[SharedKeys.savedActivity], now: Date().timeIntervalSince1970 * 1000)) }
        teach(post)
    }
    /// web import effect, delta for one post: its current saved/liked/disliked flags.
    private func teach(_ post: FeedPost) {
        var entry: [(String, JSONValue)] = [("key", .string(post.id)), ("tags", .string(String(post.tagText.prefix(2000))))]
        if isSaved(post) { entry.append(("saved", .bool(true))) }
        if isLiked(post) { entry.append(("liked", .bool(true))) }
        if isDisliked(post) { entry.append(("disliked", .bool(true))) }
        let prefer = preferences["preferenceTags"] ?? .array([])
        Task { [api] in _ = try? await api.call("booru:recommendations:import", [.object([("initial", .bool(false)), ("delta", .bool(true)), ("reactions", .array([.object(entry)])), ("prefer", prefer)])]) }
    }
}

// MARK: - Feeds

/// Media addresses shared by every feed, so any screen (a closeup, a board cover) can show any post it is handed.
@MainActor
final class MediaMap {
    /// Board media address → the PC's signed /api/media path (valid for a day).
    var signed = [String: String]()
    /// Post key → the saved copy in the PC's save folder (/api/local/…).
    var local = [String: String]()
    func remember(_ fresh: [String: String]) { signed.merge(fresh) { _, new in new }; if signed.count > 30000 { signed = fresh } }
}

@MainActor
final class FeedModel: ObservableObject {
    enum Kind: Equatable { case forYou, videos, search(String), topic(String), similar(FeedPost), saved, liked, savedFrom(String) }
    @Published private(set) var posts = [FeedPost]()
    /// The furthest post seen. Not published: it changes as every tile appears, and redrawing the whole grid
    /// each time was the main cause of laggy scrolling. Nothing on screen displays it.
    var current = 0
    @Published var error = ""
    @Published var random = false
    @Published private(set) var loading = false
    private(set) var exhausted = false
    /// How many posts to keep ready beyond the last one seen; grids keep more than the full-screen video feed.
    var ahead = FeedPlanner.ahead
    /// Saved / Liked only: keep posts whose tags or artist contain this text.
    var filter = ""
    let kind: Kind, api: FeedAPI, store: SharedStore, media: MediaMap
    private var seen = [String](), first = true, pages = [String: Int](), shownAt = Date()
    private var library = [FeedPost](), offset = 0, impressed = Set<String>(), boards = [JSONValue]()
    private var generation = 0, loadToken = 0, emptyRounds = 0, filling = false
    private var feedbackChain: Task<Void, Never>?
    init(kind: Kind, api: FeedAPI, store: SharedStore, media: MediaMap) { self.kind = kind; self.api = api; self.store = store; self.media = media }

    var tags: String {
        let base = store.preferences["tags"]?.string ?? ""
        switch kind {
        case .forYou: return FeedFilters.withRandom(base, random: random)
        case .videos: return FeedFilters.withRandom([base, "media:video"].filter { !$0.isEmpty }.joined(separator: ","), random: random)
        case .search(let text), .topic(let text): return FeedFilters.withRandom(text, random: random)
        case .similar, .saved, .liked, .savedFrom: return ""
        }
    }
    var rating: String { store.preferences["rating"]?.string ?? "all" }
    private var isLibrary: Bool { switch kind { case .saved, .liked, .savedFrom: return true; default: return false } }
    /// web: For You uses preferences.sources minus tube boards; Videos uses tube boards plus video-capable sources, minus hidden ones.
    private func sources() async throws -> [String] {
        if boards.isEmpty { boards = try await api.call("booru:boards", []).value.array ?? [] }
        var engines = [String: String]()
        for board in boards { if let id = board["id"]?.string { engines[id] = board["engine"]?.string ?? "" } }
        let prefs = store.preferences, chosen = (prefs["sources"]?.strings ?? []).filter { engines[$0] != nil }
        guard kind == .videos else { return chosen.filter { engines[$0] != "tube" } }
        let hidden = Set(prefs["videoHidden"]?.strings ?? [])
        let pool = prefs["videoSources"]?.array != nil ? (prefs["videoSources"]?.strings ?? []) : chosen
        var list = engines.filter { $0.value == "tube" }.map(\.key).sorted()
        for source in pool where !["gallery", "imageboard"].contains(engines[source] ?? "") && !list.contains(source) { list.append(source) }
        return list.filter { !hidden.contains($0) }
    }

    private func clear() {
        generation += 1; loading = false
        posts = []; current = 0; seen = []; pages = [:]; library = []; offset = 0; impressed = []; exhausted = false; first = true; error = ""; emptyRounds = 0
    }
    func reset() { clear(); Task { await more() } }
    /// Pull to refresh: waits for the first page.
    func reload() async { clear(); await more() }
    /// Page turns: load until there are `count` posts, or the source has no more. Scrolling only keeps a dozen ready.
    func fill(to count: Int) async {
        let usual = ahead
        ahead = max(usual, count - current + 1)
        defer { ahead = usual }
        for _ in 0..<40 {
            if posts.count >= count || exhausted { break }
            // Another load is already running (a tile just appeared): let it finish, then look again.
            if loading { try? await Task.sleep(nanoseconds: 150_000_000); continue }
            let before = posts.count
            await more()
            if posts.count == before && !loading { break }
        }
    }
    func more() async {
        guard !loading, !exhausted, posts.count - current - 1 < ahead else { return }
        loadToken += 1
        let token = loadToken, generation = self.generation
        loading = true
        defer { if token == loadToken { loading = false } }
        do {
            if isLibrary { try await libraryPage(generation) }
            else {
                let sources = try await sources()
                guard generation == self.generation else { return }
                guard !sources.isEmpty else { error = "Choose your boards in the web version first (Saved → Settings → Web version)."; exhausted = true; return }
                var fresh = [FeedPost]()
                if case .similar(let seed) = kind { fresh = try await similar(seed, sources) }
                else if case .search = kind { fresh = try await paged(sources, channel: "booru:feed") }
                else if kind != .videos, FeedFilters.isQuickFilter(tags) { fresh = try await paged(sources, channel: "booru:fyp") }
                else {
                    let input: JSONValue = .object([("sources", .array(sources.map(JSONValue.string))), ("tags", .string(tags)), ("rating", .string(rating)),
                                                    ("exclude", .array(seen.suffix(10000).map(JSONValue.string))), ("refresh", .bool(first))])
                    let (value, signed) = try await api.call("booru:recommendations:batch", [input]); media.remember(signed)
                    fresh = (value["posts"]?.array ?? []).map(FeedPost.init)
                    if fresh.isEmpty && value["pending"]?.bool != true { exhausted = true }
                }
                guard generation == self.generation else { return }
                first = false
                let hidden = store.hidden, blocked = store.blocked
                var known = Set(posts.map(\.id))
                let shown = fresh.filter { known.insert($0.id).inserted && SharedEdit.visible($0, hidden: hidden, blocked: blocked) && (kind != .videos || $0.isVideo) }
                seen += fresh.map(\.id); posts += shown; error = ""
                if shown.isEmpty && !exhausted {
                    // Nothing usable yet (the PC is still collecting, or a whole page was hidden): try again, but not forever.
                    emptyRounds += 1
                    if emptyRounds > 30 { exhausted = true }
                    else {
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        guard generation == self.generation else { return }
                        loading = false; await more(); return
                    }
                } else { emptyRounds = 0 }
            }
            if exhausted && posts.isEmpty && error.isEmpty { error = "Nothing to show here yet. Pull down to try again." }
        } catch {
            if generation == self.generation { self.error = error.localizedDescription }
        }
    }
    /// Saved / Liked: the shared library lists, 60 at a time. Saved files are mapped to their copy on this PC.
    private func libraryPage(_ generation: Int) async throws {
        if first {
            first = false
            var all: [FeedPost]
            if kind == .liked { all = (JSONValue.parse(store[SharedKeys.likedPosts])?.array ?? []).compactMap { $0["post"] }.map(FeedPost.init) }
            else { all = (JSONValue.parse(store[SharedKeys.saved])?.array ?? []).map(FeedPost.init) }
            if case .savedFrom(let source) = kind { all = all.filter { $0.source == source } }
            let needle = filter.trimmingCharacters(in: .whitespaces).lowercased()
            if !needle.isEmpty {
                let tag = needle.replacingOccurrences(of: " ", with: "_")
                all = all.filter { $0.tagText.lowercased().contains(tag) || $0.artist.lowercased().contains(needle) }
            }
            if random { all.shuffle() }
            library = all
            if library.isEmpty {
                error = !needle.isEmpty ? "Nothing matches that." : kind == .liked ? "Nothing liked yet. Double-tap a picture to like it." : "Nothing saved yet. Tap Save on a picture."
                exhausted = true; return
            }
        }
        let page = Array(library.dropFirst(offset).prefix(60))
        guard !page.isEmpty else { exhausted = true; return }
        let ids: [JSONValue] = page.map { .object([("source", .string($0.source)), ("id", .number(Double($0.postId))), ("originalUrl", .string($0.originalUrl))]) }
        if let files = try? await api.call("booru:saved-media", [.array(ids)]).value.entries {
            for (key, value) in files { if let saved = value.string, saved.hasPrefix("booru-saved://media/") { media.local[key] = "/api/local/" + saved.dropFirst("booru-saved://media/".count) } }
        }
        // Posts without a saved file use the board's addresses; saved videos still need their preview picture for the grid.
        let remote = page.flatMap { post in media.local[post.id] == nil ? [post.mediaUrl, post.previewUrl, post.originalUrl] : (post.isVideo ? [post.previewUrl] : []) }.filter { $0.hasPrefix("https:") }
        if !remote.isEmpty, let signed = try? await api.call("booru:saved-gallery", [.array(Array(remote.prefix(400)).map(JSONValue.string))]) { media.remember(signed.media) }
        guard generation == self.generation else { return }
        offset += page.count; posts += page; error = ""
        if offset >= library.count { exhausted = true }
    }
    private func similar(_ seed: FeedPost, _ sources: [String]) async throws -> [FeedPost] {
        let page = pages[seed.id] ?? 1
        guard page > 0 else { exhausted = true; return [] }
        let input: JSONValue = .object([("source", .string(seed.source)), ("id", .number(Double(seed.postId))), ("page", .number(Double(page))), ("rating", .string(rating)),
                                        ("tags", .string(seed.tagText)), ("artist", .string(seed.artist)), ("sources", .array(sources.map(JSONValue.string))),
                                        ("exclude", .array(seen.suffix(2000).map(JSONValue.string))), ("videos", .bool(seed.isVideo)), ("mode", .string("tags"))])  // tags: quick; people (commenters) reads comment pages and is slow
        let (value, signed) = try await api.call("booru:similar", [input]); media.remember(signed)
        pages[seed.id] = value["nextPage"]?.number.map(Int.init) ?? 0
        if pages[seed.id] == 0 { exhausted = true }
        return (value["posts"]?.array ?? []).map(FeedPost.init).filter { $0.id != seed.id }
    }
    private func paged(_ sources: [String], channel: String) async throws -> [FeedPost] {
        var out = [FeedPost]()
        for source in sources {
            let page = pages[source] ?? 1; if page <= 0 { continue }
            let input: JSONValue = .object([("source", .string(source)), ("tags", .string(tags)), ("page", .number(Double(page))), ("rating", .string(rating))])
            let (value, signed) = try await api.call(channel, [input]); media.remember(signed)
            out += (value["posts"]?.array ?? []).map(FeedPost.init)
            pages[source] = value["nextPage"]?.number.map(Int.init) ?? 0
        }
        if pages.values.allSatisfy({ $0 == 0 }) && !pages.isEmpty { exhausted = true }
        return out
    }

    // Addresses. ponytail: the PC only makes 1080-wide copies, so grid tiles use those too; add a smaller size on the PC if grids feel slow.
    /// Grid tile picture (a video's preview picture; a GIF's still preview).
    func tileURL(_ post: FeedPost) -> URL? {
        if post.isVideo { return api.media(media.signed[post.previewUrl], width: 1080) }
        if let file = media.local[post.id] { return api.media(file) }
        let full = post.mediaUrl.isEmpty ? post.previewUrl : post.mediaUrl
        let source = full.lowercased().contains(".gif") && !post.previewUrl.isEmpty ? post.previewUrl : full
        return api.media(media.signed[source], width: 1080)
    }
    /// Full-screen picture (a video's preview picture).
    func imageURL(_ post: FeedPost) -> URL? {
        if post.isVideo { return api.media(media.signed[post.previewUrl]) }
        if let file = media.local[post.id] { return api.media(file) }
        let source = post.mediaUrl.isEmpty ? post.previewUrl : post.mediaUrl
        return api.media(media.signed[source], width: source.lowercased().contains(".gif") ? nil : 1080)
    }
    /// The original file, for saving to the phone.
    func originalURL(_ post: FeedPost) -> URL? { api.media(media.local[post.id] ?? media.signed[post.mediaUrl.isEmpty ? post.previewUrl : post.mediaUrl]) }
    func videoURL(_ post: FeedPost) async -> URL? {
        if let file = media.local[post.id] { return api.media(file) }
        if !post.needsVideoLookup { return api.media(media.signed[post.mediaUrl]) }
        guard let result = try? await api.call("booru:video-source", [.object([("source", .string(post.source)), ("id", .number(Double(post.postId))), ("url", .string(post.url))])]),
              let url = result.value["url"]?.string else { return nil }
        media.remember(result.media); return api.media(media.signed[url])
    }

    /// Full-screen feed: the snapped card changed. Report the old one, announce the new one, top up the list.
    func show(_ index: Int) {
        if posts.indices.contains(current), index != current {
            let ms = Int(Date().timeIntervalSince(shownAt) * 1000)
            switch FeedPlanner.leave(after: ms) { case .skip: feedback(posts[current], "skip"); case .view(let ms): feedback(posts[current], "view", ms: ms) }
        }
        current = index; shownAt = Date()
        if posts.indices.contains(index) { feedback(posts[index], "impression") }
        Task { await more() }
    }
    /// Grids: a tile came on screen. Remember how far the user got, tell the taste model once, keep posts ready ahead.
    func appeared(_ index: Int) {
        guard posts.indices.contains(index) else { return }
        if index > current { current = index }
        let post = posts[index]
        if !isLibrary, impressed.insert(post.id).inserted { feedback(post, "impression") }
        guard !filling else { return }
        filling = true
        Task {
            for _ in 0..<8 {
                let before = posts.count
                await more()
                if posts.count == before { break }
            }
            filling = false
        }
    }
    /// One event at a time, so reporting never competes with picture downloads.
    func feedback(_ post: FeedPost, _ kind: String, ms: Int = 0) {
        let event: JSONValue = .object([("id", .string(UUID().uuidString.lowercased())), ("key", .string(post.id)), ("kind", .string(kind)), ("ms", .number(Double(ms)))])
        let previous = feedbackChain
        feedbackChain = Task { [api] in await previous?.value; _ = try? await api.call("booru:recommendations:feedback", [event]) }
    }
    /// Shuffle: saved/liked lists are mixed on the phone each time; board feeds switch the session-only Random order (web: order:random).
    func shuffle() { if isLibrary { random = true } else { random.toggle() }; reset() }
    func drop(_ post: FeedPost) { posts.removeAll { $0.id == post.id }; current = min(current, max(0, posts.count - 1)) }
}

// MARK: - Paged feed view

struct PagedFeedView: View {
    @ObservedObject var model: FeedModel
    @ObservedObject var store: SharedStore
    @ObservedObject var loader: MediaLoader
    @ObservedObject var videos: VideoPool
    let browser: FeedBrowser
    var onSearch: (String) -> Void = { _ in }
    var onSimilar: (FeedPost) -> Void = { _ in }
    var start: String? = nil
    /// False while its tab is hidden or covered: nothing plays.
    var visible = true
    @State private var position: String?
    @State private var details: FeedPost?
    var body: some View {
        GeometryReader { geometry in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(model.posts) { post in
                        PostCardView(post: post, model: model, store: store, loader: loader, videos: videos, browser: browser, active: post.id == position && visible, size: geometry.size) { details = post }
                            .containerRelativeFrame([.horizontal, .vertical])
                            .id(post.id)
                    }
                    if !model.error.isEmpty { Text(model.error).foregroundStyle(.white).padding().containerRelativeFrame([.horizontal, .vertical]) }
                    else if model.posts.isEmpty { ProgressView().tint(Color.brand).containerRelativeFrame([.horizontal, .vertical]) }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .refreshable { await model.reload() }   // pull down at the top to reload
            .onChange(of: visible) { _, now in if now { prepare(around: model.current, size: geometry.size) } else { videos.pauseAll() } }
            .scrollPosition(id: $position)
            .scrollIndicators(.hidden)
            .background(Color.black)
            .onChange(of: position) { _, key in
                guard let key, let index = model.posts.firstIndex(where: { $0.id == key }) else { return }
                model.show(index); prepare(around: index, size: geometry.size)
            }
            .onChange(of: model.posts.count) { _, _ in if position == nil, let first = model.posts.first { position = first.id; model.show(0) }; prepare(around: model.current, size: geometry.size) }
            .task { if model.posts.isEmpty { await model.more() } }
            .onAppear { if let start, model.posts.contains(where: { $0.id == start }) { position = start } }
        }
        .sheet(item: $details) { post in PostDetailsSheet(post: post, model: model, store: store, browser: browser, onSearch: { tag in details = nil; onSearch(tag) }, onSimilar: { post in details = nil; onSimilar(post) }) }
    }
    private func prepare(around index: Int, size: CGSize) {
        let window = FeedPlanner.window(current: index, count: model.posts.count)
        let posts = Array(model.posts[window])
        loader.prefetch(posts.compactMap(model.imageURL), api: model.api, maxPixel: max(size.width, size.height) * UIScreen.main.scale)
        let current = model.posts.indices.contains(index) ? model.posts[index].id : nil
        guard visible else { return }
        videos.focus(current: current, keep: Set(posts.filter(\.isVideo).map(\.id).prefix(3)))
        VideoFiles.shared.prefetch(posts.filter { $0.isVideo && $0.id != current }, model: model)
    }
}

struct PostCardView: View {
    let post: FeedPost
    @ObservedObject var model: FeedModel
    @ObservedObject var store: SharedStore
    @ObservedObject var loader: MediaLoader
    @ObservedObject var videos: VideoPool
    let browser: FeedBrowser
    let active: Bool
    let size: CGSize
    /// True: full-screen card with the side rail. False: just the media with small video buttons (the closeup).
    var chrome = true
    let onDetails: () -> Void
    @State private var image: UIImage?
    @State private var player: AVPlayer?
    @State private var vlc: InlineVLC?
    @State private var loadingVideo = false
    @State private var fullscreen = false
    @State private var userPaused = false
    @State private var avBuffering = false
    @State private var heart = false
    @State private var saving = false
    var body: some View {
        ZStack {
            Color.black
            if let player { VideoSurface(player: player) }
            else if let vlc { ViewHost(view: vlc.surface) }
            else if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { ProgressView().tint(Color.brand) }
            if post.isVideo && (loadingVideo || avBuffering || (vlc?.buffering ?? false)) && !userPaused {
                ProgressView().controlSize(.large).tint(.white).padding(18).background(.black.opacity(0.45), in: Circle()).accessibilityLabel("Video loading")
            }
            if userPaused {
                Image(systemName: "pause.fill").font(.scaled(44, weight: .bold)).foregroundStyle(.white).frame(width: 96, height: 96)
                    .background(.black.opacity(0.45), in: Circle()).allowsHitTesting(false).transition(.opacity).accessibilityLabel("Paused")
            }
            if heart { Image(systemName: "heart.fill").font(.system(size: 96)).foregroundStyle(.white).shadow(radius: 12).transition(.scale.combined(with: .opacity)) }
            if chrome { overlay } else if post.isVideo { corners }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if !store.isLiked(post) { store.react(post, kind: "liked", fromVideos: model.kind == .videos) }; withAnimation(.spring) { heart = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { withAnimation { heart = false } } }
        .onTapGesture {
            guard post.isVideo, player != nil || vlc != nil else { return }
            withAnimation(.easeOut(duration: 0.15)) { userPaused.toggle() }
            if userPaused { player?.pause(); vlc?.pause() } else { player?.play(); vlc?.play(muted: videos.muted) }
        }
        .onReceive(Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()) { _ in
            if let player, active { avBuffering = player.timeControlStatus == .waitingToPlayAtSpecifiedRate || (player.currentItem?.status ?? .unknown) == .unknown }
        }
        .task(id: post.id) { await load() }
        .onChange(of: active) { _, now in
            userPaused = false
            if now, let player { player.isMuted = videos.muted; player.play() }
            if now { vlc?.play(muted: videos.muted) } else { vlc?.pause() }
        }
        .onChange(of: videos.muted) { _, muted in vlc?.player.audio?.isMuted = muted }
        .onDisappear { vlc?.stop(); if !chrome { player?.pause() } }
        .fullScreenCover(isPresented: $fullscreen, onDismiss: { player?.isMuted = videos.muted; vlc?.player.audio?.isMuted = videos.muted; if active { player?.play() } }) {
            FullscreenVideo(player: player, vlc: vlc)
        }
    }
    private var overlay: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(post.artist.isEmpty ? post.boardName : post.artist).font(.headline)
                Text(post.tags.prefix(6).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")).font(.caption).lineLimit(2).opacity(0.85)
            }.foregroundStyle(.white).shadow(radius: 4)
            Spacer()
            VStack(spacing: 18) {
                rail(store.isLiked(post) ? "heart.fill" : "heart", "Like", tint: store.isLiked(post) ? .pink : .white) { store.react(post, kind: "liked", fromVideos: model.kind == .videos) }
                rail(store.isDisliked(post) ? "hand.thumbsdown.fill" : "hand.thumbsdown", "Less like this") { store.react(post, kind: "disliked", fromVideos: model.kind == .videos) }
                rail(store.isSaved(post) ? "bookmark.fill" : "bookmark", saving ? "Saving…" : "Save to PC") { saving = true; Task { do { try await store.save(post) } catch { store.syncError = error.localizedDescription }; saving = false } }
                if post.isVideo { rail(videos.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", videos.muted ? "Unmute" : "Mute") { videos.toggleMute() } }
                if post.isVideo { rail("arrow.up.left.and.arrow.down.right", "Full screen") { fullscreen = true }.disabled(player == nil && vlc == nil) }
                rail("ellipsis", "More", action: onDetails)
            }
        }
        .padding(.horizontal, 16).padding(.bottom, 28)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .center, endPoint: .bottom).allowsHitTesting(false))
    }
    /// Closeup: mute and full screen in the bottom corners of a video.
    private var corners: some View {
        HStack {
            corner(videos.muted ? "speaker.slash.fill" : "speaker.wave.2.fill", videos.muted ? "Unmute" : "Mute") { videos.toggleMute() }
            Spacer()
            corner("arrow.up.left.and.arrow.down.right", "Full screen") { fullscreen = true }.disabled(player == nil && vlc == nil)
        }
        .padding(12).frame(maxHeight: .infinity, alignment: .bottom)
    }
    private func corner(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.scaled(14, weight: .bold)).foregroundStyle(.white).frame(width: 36, height: 36).background(.black.opacity(0.55), in: Circle()) }.accessibilityLabel(label)
    }
    private func rail(_ icon: String, _ label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).font(.title2.weight(.semibold)).foregroundStyle(tint).frame(width: 44, height: 44).shadow(radius: 4) }.accessibilityLabel(label)
    }
    private func load() async {
        let maxPixel = max(size.width, size.height) * UIScreen.main.scale
        if let url = model.imageURL(post) { image = await loader.image(url, api: model.api, maxPixel: maxPixel) }
        guard post.isVideo else { return }
        if VideoFiles.needsVLC(post) {
            loadingVideo = true
            let source = await VideoFiles.shared.url(for: post, model: model)
            loadingVideo = false
            guard let source else { return }
            let inline = InlineVLC(url: source); vlc = inline
            if active { inline.play(muted: videos.muted) }
            return
        }
        guard let url = await model.videoURL(post) else { return }
        let created = videos.player(for: post.id, url: url, cookies: await model.api.pairedCookies())
        player = created
        if active { created.isMuted = videos.muted; created.play() }
    }
}

struct PostDetailsSheet: View {
    let post: FeedPost
    @ObservedObject var model: FeedModel
    @ObservedObject var store: SharedStore
    let browser: FeedBrowser
    let onSearch: (String) -> Void
    var onSimilar: (FeedPost) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    /// web: "See more" from the same artist; without an artist, the post's first tag.
    private var moreTag: String? { post.artist.isEmpty ? post.tags.first : post.artist.replacingOccurrences(of: " ", with: "_") }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { onSimilar(post) } label: { Label("Similar posts", systemImage: "square.stack.3d.up") }
                    if let moreTag { Button { onSearch(moreTag) } label: { Label(post.artist.isEmpty ? "See more: \(moreTag.replacingOccurrences(of: "_", with: " "))" : "See more from \(post.artist)", systemImage: "person.crop.rectangle.stack") } }
                }
                Section {
                    Button("Save to phone") { browser.save(post: post, model: model); dismiss() }
                    if post.isVideo { Button("Play in VLC") { browser.play(post: post, model: model); dismiss() } }
                    Button("Do not show again", role: .destructive) { store.hide(post); model.drop(post); dismiss() }
                    if let url = URL(string: post.url), url.scheme == "https" { Link("Open original", destination: url) }
                }
                Section("Tags · tap to search, hold to hide posts with it") {
                    ForEach(post.tags, id: \.self) { tag in
                        let blocked = store.blocked.contains(SharedEdit.normalTag(tag))
                        Text(tag.replacingOccurrences(of: "_", with: " ")).strikethrough(blocked)
                            .onTapGesture { onSearch(tag) }
                            .contextMenu { Button(blocked ? "Show posts with this tag" : "Hide posts with this tag") { store.block(tag) } }
                    }
                }
                Section("Post") {
                    LabeledContent("Board", value: post.boardName.isEmpty ? post.source : post.boardName)
                    LabeledContent("Artist", value: post.artist.isEmpty ? "Unknown" : post.artist)
                    LabeledContent("Rating", value: post.rating)
                }
            }
            .navigationTitle("Post").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Filters bar (web quick filters + content rating, stored in the shared preferences)

struct FilterBar: View {
    @ObservedObject var model: FeedModel
    @ObservedObject var store: SharedStore
    let presets: [String]
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(FeedFilters.presets.filter { presets.contains($0.tag) }, id: \.tag) { preset in
                    let on = preset.tag == "order:random" ? model.random : FeedFilters.terms(store.preferences["tags"]?.string ?? "").contains(preset.tag)
                    chip(preset.label, on: on) {
                        // web togglePreset: orderings are one choice, Random included; Random stays session-only.
                        let tags = store.preferences["tags"]?.string ?? ""
                        if preset.tag == "order:random" {
                            model.random.toggle()
                            if model.random && FeedFilters.terms(tags).contains(where: FeedFilters.isOrder) { store.setPreference("tags", .string(FeedFilters.withoutOrders(tags))) }
                        } else {
                            if FeedFilters.isOrder(preset.tag) { model.random = false }
                            store.setPreference("tags", .string(FeedFilters.toggle(preset.tag, in: tags)))
                        }
                        model.reset()
                    }
                }
                Menu {
                    ForEach([("all", "All ratings"), ("general", "General only"), ("explicit", "Explicit only")], id: \.0) { value, label in
                        Button(label) { store.setPreference("rating", .string(value)); model.reset() }
                    }
                } label: { chipLabel(["all": "All ratings", "general": "General only", "explicit": "Explicit only"][model.rating] ?? "Rating", on: false) }
            }.padding(.horizontal, 12).padding(.vertical, 6)
        }.scrollIndicators(.hidden)
    }
    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View { Button(action: action) { chipLabel(label, on: on) }.buttonStyle(.plain) }
    private func chipLabel(_ label: String, on: Bool) -> some View {
        Text(label).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? Color.ink : .white).background(on ? Color.brand : Color.white.opacity(0.15), in: Capsule())
    }
}

// MARK: - Manga (catalog browsing and downloaded-book reader with synced position)

struct MangaView: View {
    let api: FeedAPI
    var store: SharedStore? = nil
    enum Shelf: String, CaseIterable { case browse = "Browse", library = "Library" }
    enum SearchKind: String, CaseIterable { case title = "Titles", tag = "Tags", artist = "Artists" }
    @State private var section = Shelf.browse
    @State private var books = [JSONValue]()
    @State private var bookFilter = ""
    @State private var query = ""
    @State private var kind = SearchKind.title
    @State private var popular = false
    @State private var random = false
    @AppStorage("mangaEnglishOnly") private var englishOnly = false
    /// The ticked providers, comma-separated; empty means the default.
    @AppStorage("mangaProviders") private var providerList = ""
    @State private var galleries = [JSONValue]()
    @State private var media = [String: String]()
    /// Site → the next page to ask it for; a site drops out when it has no more (or failed).
    @State private var nextPages = [String: Int]()
    /// Sites started on a random page for Random; one that comes back empty falls back to its first page.
    @State private var jumped = Set<String>()
    /// Site → why it could not be read (web: "providers need attention").
    @State private var failures = [String: String]()
    @State private var loading = false
    @State private var loadedOnce = false
    /// Bumped by every fresh search, so an answer to an older one is dropped instead of mixed in.
    @State private var generation = 0
    @State private var error = ""
    /// Browse shows one page of covers at a time; Next asks the providers for more only when it is pressed.
    @State private var page = 0
    @State private var turning = false
    static let pageSize = 30
    static let sites = ["https://hentaifox.com", "https://imhentai.xxx", "https://hentairox.com", "https://doujins.com", "https://hentai2read.com", "https://nhentai.net", "https://hitomi.la", "https://hentairead.com", "https://multporn.net"]
    /// web: these two page by link rather than by number, so Random cannot start them mid-catalogue.
    static let noJump: Set<String> = ["https://doujins.com", "https://hentai2read.com"]
    static func name(_ site: String) -> String { URL(string: site)?.host ?? site }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $section) { ForEach(Shelf.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).padding(12)
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red).padding(.horizontal) }
                if section == .library { bookList } else { catalog }
            }
            .background(Color.ink).navigationTitle("Manga").navigationBarTitleDisplayMode(.inline)
        }
        .task { await loadBooks() }
    }

    // MARK: Shared pieces
    /// web: the manga preference tags shared with the PC; matching titles come first on each page.
    private var preferenceTags: [String] { JSONValue.parse(store?[SharedKeys.mangaPreferences])?.strings ?? [] }
    private var providers: [String] {
        let chosen = providerList.split(separator: ",").map(String.init).filter { Self.sites.contains($0) }
        return chosen.isEmpty ? [Self.sites[0]] : chosen
    }
    /// What the box and the search-type menu mean together; a typed "tag:" or "artist:" still wins.
    private var search: (term: String, tag: Bool) {
        let parsed = MangaSearch.parse(query)
        if parsed.tag || kind == .title || parsed.term.isEmpty { return parsed }
        return kind == .artist ? ("artist:" + parsed.term.lowercased(), true) : (parsed.term, true)
    }
    private func reload() { Task { await loadCatalog(reset: true) } }
    private func emptyNote(_ title: String, _ detail: String) -> some View {
        VStack(spacing: 6) {
            Text(title).font(.headline).foregroundStyle(.white)
            Text(detail).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
    private func chipLabel(_ label: String, on: Bool) -> some View {
        Text(label).font(.footnote.weight(.semibold)).padding(.horizontal, 12).padding(.vertical, 7)
            .foregroundStyle(on ? Color.ink : .white).background(on ? Color.brand : Color.white.opacity(0.15), in: Capsule())
    }
    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(label, on: on) }.buttonStyle(.plain).accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Library (books downloaded to the PC)
    private var shownBooks: [JSONValue] {
        let filter = MangaSearch.parse(bookFilter)
        guard !filter.term.isEmpty else { return books }
        return books.filter { book in
            filter.tag ? MangaSearch.tagsMatch(book["tags"]?.strings ?? [], filter.term) : MangaSearch.titleMatches(book["name"]?.string ?? "", filter.term)
        }
    }
    private var bookList: some View {
        VStack(spacing: 8) {
            let shown = shownBooks
            TextField("Search your library, or tag:", text: $bookFilter).textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never).padding(.horizontal, 12)
            if books.isEmpty { emptyNote("No downloaded books yet", "Books you download to the PC appear here.") }
            else if shown.isEmpty { emptyNote("No books match", "Try fewer words, or tag: to search by tag.") }
            else {
                List(shown.indices, id: \.self) { index in
                    let book = shown[index]
                    NavigationLink { if book["format"]?.string == "pdf" { PDFBookReader(api: api, book: book) } else { MangaReader(api: api, book: book) } } label: {
                        VStack(alignment: .leading) { Text(book["name"]?.string ?? "Book").lineLimit(2); Text("Page \(Int(book["page"]?.number ?? 1)) of \(Int(book["pages"]?.number ?? 0))").font(.caption).foregroundStyle(.secondary) }
                    }
                }.scrollContentBackground(.hidden).refreshable { await loadBooks() }
            }
        }
    }
    private func loadBooks() async { do { books = try await api.call("booru:manga:list", []).value.array ?? [] } catch { self.error = error.localizedDescription } }

    // MARK: Browse (web: search type, order, language, providers)
    private var catalog: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Menu {
                    Picker("Search by", selection: $kind) { ForEach(SearchKind.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                } label: { chipLabel(kind.rawValue + " ▾", on: false) }.accessibilityLabel("Search by \(kind.rawValue)")
                TextField(kind == .title ? "Search titles" : kind == .tag ? "Search a tag" : "Search an artist", text: $query)
                    .textFieldStyle(.roundedBorder).autocorrectionDisabled().textInputAutocapitalization(.never).submitLabel(.search)
                    .onSubmit { reload() }
                if !query.isEmpty {
                    Button { query = ""; reload() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(.horizontal, 12)
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    chip("Latest", on: !popular && !random) { popular = false; random = false; reload() }
                    chip("Popular", on: popular && !random) { popular = true; random = false; reload() }
                    chip("Random", on: random) { random = true; reload() }
                    chip("English", on: englishOnly) { englishOnly.toggle(); reload() }
                    Menu {
                        ForEach(Self.sites, id: \.self) { site in
                            Button { toggleProvider(site) } label: { Label(Self.name(site), systemImage: providers.contains(site) ? "checkmark.circle.fill" : "circle") }
                        }
                    } label: { chipLabel("Providers \(providers.count)/\(Self.sites.count)", on: false) }
                    chip("Refresh", on: false) { reload() }
                }.padding(.horizontal, 12)
            }.scrollIndicators(.hidden)
            if !failures.isEmpty {
                DisclosureGroup("\(failures.count) provider\(failures.count == 1 ? "" : "s") need\(failures.count == 1 ? "s" : "") attention") {
                    ForEach(failures.keys.sorted(), id: \.self) { site in
                        Text("\(Self.name(site)): \(failures[site] ?? "")").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.font(.footnote.weight(.semibold)).tint(Color.brand).padding(.horizontal, 12)
            }
            if galleries.isEmpty && loading { ProgressView().tint(Color.brand).frame(maxWidth: .infinity, maxHeight: .infinity) }
            else if galleries.isEmpty && loadedOnce { emptyNote("No titles found", query.isEmpty ? "Nothing came back. Try another provider." : "Try fewer words, another search type, or more providers.") }
            else { catalogPage }
        }
        .onChange(of: kind) { _, _ in if !query.isEmpty { reload() } }
        .task { if !loadedOnce && galleries.isEmpty { await loadCatalog(reset: true) } }
    }
    /// One page of covers and the page controls (split out so the compiler can type-check Browse).
    private var turnedPage: Int { min(page, max(0, (galleries.count - 1) / Self.pageSize)) }
    private func pageGalleries(_ turned: Int) -> [JSONValue] { Array(galleries.dropFirst(turned * Self.pageSize).prefix(Self.pageSize)) }
    private static func key(_ gallery: JSONValue) -> String { (gallery["source"]?.string ?? "") + ":" + (gallery["id"]?.string ?? "") }
    /// One page of covers and the page controls (split out so the compiler can type-check Browse).
    private var catalogPage: some View {
        let turned: Int = turnedPage
        let shown: [JSONValue] = pageGalleries(turned)
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                ForEach(shown.indices, id: \.self) { (index: Int) in
                    coverTile(shown[index]).id(Self.key(shown[index]))
                }
            }.padding(12)
            pager(turned)
        }
        .id(turned)   // a new page starts at its top
        .refreshable { await loadCatalog(reset: true) }
    }
    private func coverTile(_ gallery: JSONValue) -> some View {
        NavigationLink {
            GalleryDetail(api: api, gallery: gallery, cover: api.media(media[gallery["coverUrl"]?.string ?? ""]), onSearch: { term in applySearch(term) })
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                RemoteImage(api: api, url: api.media(media[gallery["coverUrl"]?.string ?? ""]), maxPixel: 480).aspectRatio(0.7, contentMode: .fill).clipped().clipShape(RoundedRectangle(cornerRadius: 8))
                Text(gallery["name"]?.string ?? "").font(.caption2.weight(.semibold)).lineLimit(2).multilineTextAlignment(.leading).foregroundStyle(.white)
                Text(Self.name(gallery["source"]?.string ?? "") + (gallery["language"]?.string == "english" ? " · English" : "")).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
        }
    }
    private func pager(_ turned: Int) -> some View {
        HStack(spacing: 14) {
            Button { page = turned - 1 } label: { chipLabel("‹ Previous", on: false) }.buttonStyle(.plain)
                .disabled(turned == 0 || turning).opacity(turned == 0 || turning ? 0.4 : 1)
            Text("Page \(turned + 1)").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
            let hasNext = galleries.count > (turned + 1) * Self.pageSize || !nextPages.isEmpty
            Button { Task { await nextPage(after: turned) } } label: { chipLabel(turning ? "Loading…" : "Next ›", on: false) }.buttonStyle(.plain)
                .disabled(!hasNext || turning || loading).opacity(!hasNext || turning || loading ? 0.4 : 1)
        }.padding(.vertical, 16).frame(maxWidth: .infinity)
    }
    /// Next: ask the providers for more only if the page after this one is not loaded yet.
    private func nextPage(after turned: Int) async {
        turning = true
        var rounds = 0
        while galleries.count <= (turned + 1) * Self.pageSize && !nextPages.isEmpty && rounds < 6 { await loadCatalog(reset: false); rounds += 1 }
        turning = false
        if galleries.count > (turned + 1) * Self.pageSize { page = turned + 1 }
    }
    /// At least one provider stays ticked.
    private func toggleProvider(_ site: String) {
        var list = providers
        if list.contains(site) { if list.count > 1 { list.removeAll { $0 == site } } } else { list.append(site) }
        providerList = Self.sites.filter { list.contains($0) }.joined(separator: ",")
        reload()
    }
    /// A tag, artist or Similar chosen on a gallery page: search for it here.
    private func applySearch(_ term: String) {
        let parsed = MangaSearch.parse(term)
        if parsed.term.hasPrefix("artist:") { kind = .artist; query = String(parsed.term.dropFirst(7)) }
        else { kind = parsed.tag ? .tag : .title; query = parsed.term }
        section = .browse; random = false
        reload()
    }
    /// One page from each ticked provider still in play. ponytail: providers are asked one after another; make it concurrent if several feel slow.
    private func loadCatalog(reset: Bool) async {
        let search = self.search
        if reset {
            generation += 1; galleries = []; failures = [:]; loading = false; loadedOnce = false; page = 0
            let upper = search.term.isEmpty ? (popular ? 150 : 600) : 25
            var pages = [String: Int](), starts = Set<String>()
            for site in providers {
                let jump = random && !Self.noJump.contains(site)
                pages[site] = jump ? Int.random(in: 2...upper) : 1
                if jump { starts.insert(site) }
            }
            nextPages = pages; jumped = starts
        }
        guard !loading, !nextPages.isEmpty else { return }
        let token = generation, pages = nextPages, preferences = preferenceTags, shuffled = random
        var filters = [(String, JSONValue)]()
        if search.tag { filters.append(("tag", .bool(true))) }
        if englishOnly { filters.append(("englishOnly", .bool(true))) }
        if popular { filters.append(("popular", .bool(true))) }
        var retry = false
        loading = true
        for source in Self.sites {
            guard let page = pages[source] else { continue }
            do {
                let (value, signed) = try await api.call("booru:manga:catalog", [.string(source), .number(Double(page)), .string(search.term), .object(filters)])
                guard token == generation else { return }
                media.merge(signed) { _, new in new }
                let found = value["galleries"]?.array ?? []
                // A random start past the end of a short listing falls back to its first page.
                if found.isEmpty && jumped.contains(source) { jumped.remove(source); nextPages[source] = 1; retry = true; continue }
                jumped.remove(source)
                let preferred = shuffled ? found.shuffled() : MangaSearch.preferFirst(found, preferences: preferences) { $0["tags"]?.strings ?? [] }
                galleries += search.tag || shuffled ? preferred : MangaSearch.fullMatchesFirst(preferred, query: search.term) { $0["name"]?.string ?? "" }
                if let next = value["nextPage"]?.number { nextPages[source] = Int(next) } else { nextPages[source] = nil }
                failures[source] = nil
            } catch {
                guard token == generation else { return }
                if jumped.contains(source) { jumped.remove(source); nextPages[source] = 1; retry = true; continue }
                nextPages[source] = nil; failures[source] = error.localizedDescription
            }
        }
        loading = false; loadedOnce = true
        if retry { await loadCatalog(reset: false) }
    }
}

/// An online gallery before reading it: cover, facts, actions and tags (web: the gallery page).
struct GalleryDetail: View {
    let api: FeedAPI, gallery: JSONValue, cover: URL?
    /// Search the catalogue from here ("artist:…" or "tag:…"); the page closes so the results show.
    var onSearch: (String) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @State private var pages = [URL]()
    @State private var tags = [String]()
    @State private var language = ""
    @State private var loading = true
    @State private var error = ""
    @State private var downloading = false
    @State private var notice = ""
    private var source: String { gallery["source"]?.string ?? "" }
    private var id: String { gallery["id"]?.string ?? "" }
    private var title: String { gallery["name"]?.string ?? "Gallery" }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(api: api, url: cover, maxPixel: 480).aspectRatio(0.7, contentMode: .fit).frame(width: 130).clipShape(RoundedRectangle(cornerRadius: 10))
                    VStack(alignment: .leading, spacing: 8) {
                        Text(MangaView.name(source)).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(title).font(.headline).foregroundStyle(.white)
                        fact("Pages", loading ? "…" : pages.isEmpty ? "—" : String(pages.count))
                        fact("Language", language == "english" ? "English" : language == "other" ? "Other" : "Unconfirmed")
                        if let artist = tags.first(where: { $0.hasPrefix("artist:") }) { fact("Artist", String(artist.dropFirst(7)).replacingOccurrences(of: "_", with: " ")) }
                    }
                }
                HStack(spacing: 10) {
                    NavigationLink { GalleryReader(api: api, title: title, pages: pages) } label: { action("Read", icon: "book.fill", filled: true) }.disabled(pages.isEmpty)
                    if let term = MangaSearch.similarTerm(tags, common: MangaSearch.commonTags) {
                        Button { onSearch(term); dismiss() } label: { action("Similar", icon: "square.stack.3d.up", filled: false) }
                    }
                    Button { Task { await download() } } label: { action(downloading ? "Saving…" : "Download", icon: "arrow.down.circle", filled: false) }.disabled(downloading || pages.isEmpty)
                }.buttonStyle(.plain)
                if loading { ProgressView().tint(Color.brand).frame(maxWidth: .infinity) }
                if !notice.isEmpty { Text(notice).font(.footnote.weight(.semibold)).foregroundStyle(.white) }
                if !error.isEmpty { Text(error).font(.footnote).foregroundStyle(.red) }
                if !tags.isEmpty {
                    Text("Tags · \(tags.count)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    // Tap a tag (or the artist) to search the catalogue for it.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 8)], alignment: .leading, spacing: 8) {
                        ForEach(tags, id: \.self) { tag in
                            Button { onSearch(tag.hasPrefix("artist:") ? tag : "tag:" + tag); dismiss() } label: {
                                Text(tag.replacingOccurrences(of: "_", with: " ")).font(.caption.weight(.semibold)).lineLimit(1).padding(.horizontal, 10).padding(.vertical, 6)
                                    .frame(maxWidth: .infinity).foregroundStyle(.white).background(Color.white.opacity(0.15), in: Capsule())
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(16)
        }
        .background(Color.ink).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
        .task {
            do {
                let (value, media) = try await api.call("booru:manga:details", [.string(source), .string(id)])
                pages = (value["pages"]?.strings ?? []).compactMap { api.media(media[$0]) }
                tags = value["tags"]?.strings ?? []
                language = value["language"]?.string ?? ""
            } catch { self.error = error.localizedDescription }
            loading = false
        }
    }
    private func fact(_ name: String, _ value: String) -> some View {
        HStack(spacing: 6) { Text(name).foregroundStyle(.secondary); Text(value).foregroundStyle(.white) }.font(.footnote)
    }
    private func action(_ label: String, icon: String, filled: Bool) -> some View {
        Label(label, systemImage: icon).font(.footnote.weight(.semibold)).lineLimit(1).padding(.horizontal, 12).padding(.vertical, 9)
            .frame(maxWidth: .infinity).foregroundStyle(filled ? Color.ink : .white).background(filled ? Color.brand : Color.white.opacity(0.15), in: Capsule())
    }
    /// The PC does the download; say plainly whether it worked.
    private func download() async {
        downloading = true; notice = ""
        do { _ = try await api.call("booru:manga:download", [.string(source), .string(id)]); notice = "Downloaded to your PC." }
        catch { notice = "Download failed: \(error.localizedDescription)" }
        downloading = false
    }
}

/// Online gallery pages, top to bottom. The addresses were signed by the PC when the gallery page loaded.
struct GalleryReader: View {
    let api: FeedAPI, title: String, pages: [URL]
    /// Pages are decoded to the screen's width in pixels, not the full scan.
    static let pagePixels = min(2048, UIScreen.main.bounds.width * UIScreen.main.scale)
    var body: some View {
        // Each page holds a portrait shape until it loads, and the next three are fetched before they scroll in.
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(pages.enumerated()), id: \.offset) { index, page in
                    RemoteImage(api: api, url: page, maxPixel: Self.pagePixels, placeholderAspect: 0.7).frame(maxWidth: .infinity)
                        .onAppear { MediaLoader.shared.prefetch(Array(pages.dropFirst(index + 1).prefix(3)), api: api, maxPixel: Self.pagePixels) }
                }
            }
        }
            .background(Color.black).navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// Downloaded CBZ book: pages come from the PC as data URLs; the reading position is saved back like the web reader.
struct MangaReader: View {
    let api: FeedAPI, book: JSONValue
    @State private var page = 1
    @State private var image: UIImage?
    var pages: Int { Int(book["pages"]?.number ?? 1) }
    var body: some View {
        VStack {
            ZStack { Color.black; if let image { Image(uiImage: image).resizable().scaledToFit() } else { ProgressView().tint(Color.brand) } }
                .gesture(DragGesture().onEnded { value in if value.translation.width < -50 { go(page + 1) } else if value.translation.width > 50 { go(page - 1) } })
                .onTapGesture { go(page + 1) }
            Text("\(page) / \(pages)").font(.caption).foregroundStyle(.white)
        }
        .background(Color.black).navigationTitle(book["name"]?.string ?? "").navigationBarTitleDisplayMode(.inline)
        .task { page = max(1, Int(book["page"]?.number ?? 1)); await show() }
    }
    private func go(_ next: Int) { guard (1...pages).contains(next) else { return }; page = next; Task { await show() } }
    private func show() async {
        guard let id = book["id"]?.string, let result = try? await api.call("booru:manga:page", [.string(id), .number(Double(page))]),
              let text = result.value.string, let comma = text.firstIndex(of: ","), let data = Data(base64Encoded: String(text[text.index(after: comma)...])) else { return }
        image = UIImage(data: data)
        _ = try? await api.call("booru:manga:position", [.string(id), .number(Double(page))])
    }
}

struct RemoteImage: View {
    let api: FeedAPI, url: URL?
    /// Longest side to decode to; covers ask for far less than reader pages.
    var maxPixel: CGFloat = 2048
    /// Width ÷ height to hold while a reader page loads, so the pages below do not jump when it arrives.
    var placeholderAspect: CGFloat? = nil
    @State private var image: UIImage?
    var body: some View {
        let shown = image ?? url.flatMap { MediaLoader.shared.cached($0, maxPixel: maxPixel) }
        let picture = ZStack { Color.panel; if let shown { Image(uiImage: shown).resizable().scaledToFit() } }
            .task(id: url) { if let url, image == nil { image = await MediaLoader.shared.image(url, api: api, maxPixel: maxPixel) } }
        if let placeholderAspect {
            picture.aspectRatio(shown.map { $0.size.width / max(1, $0.size.height) } ?? placeholderAspect, contentMode: .fit)
        } else {
            picture
        }
    }
}

// MARK: - One connection, library state and media caches shared by every tab

@MainActor
final class NativeHub: ObservableObject {
    @Published private(set) var api: FeedAPI?
    @Published private(set) var store: SharedStore?
    @Published var error = ""
    /// The PC answered "not paired": the shell shows the web version so the pairing code can be entered.
    @Published var needsPairing = false
    /// Pinned tags first, then the strongest taste tags: the topic tabs on Home and the chips on Search.
    @Published private(set) var topicTags = [String]()
    private(set) var suggestionTags = [String]()
    private(set) var forYou: FeedModel?, videos: FeedModel?, explore: FeedModel?
    private var topics = [String: FeedModel]()
    let loader = MediaLoader.shared, pool = VideoPool(), media = MediaMap()
    private var base: URL?

    func start(_ browser: FeedBrowser, promptPairing: Bool = true) async {
        guard let connected = browser.connected else { return }
        if base == connected, api != nil { return }
        base = connected; error = ""
        let api = FeedAPI(base: connected, cookies: browser.webView.configuration.websiteDataStore.httpCookieStore), store = SharedStore(api: api)
        do { try await store.refresh() }
        catch {
            base = nil; self.error = error.localizedDescription
            if let failure = error as? FeedAPI.Failure, case .unpaired = failure, promptPairing { needsPairing = true }
            return
        }
        topics = [:]
        self.api = api; self.store = store
        forYou = make(.forYou)
        videos = FeedModel(kind: .videos, api: api, store: store, media: media)
        explore = make(.forYou); explore?.random = true      // a shuffled mix, separate from Home's ranked feed
        // Topics: pinned tags, then what the taste model leans on most.
        let pinned = store.preferences["preferenceTags"]?.strings ?? []
        let taste = ((try? await api.call("booru:recommendations:status", []))?.value["tasteTags"]?.array ?? []).compactMap { $0["tag"]?.string }
        var all = [String]()
        for tag in pinned + taste where !all.contains(tag) { all.append(tag) }
        suggestionTags = all; topicTags = Array(all.prefix(10))
    }
    func stop() { pool.pauseAll(); api = nil; store = nil; forYou = nil; videos = nil; explore = nil; topics = [:]; topicTags = []; suggestionTags = []; base = nil; error = "" }
    /// A grid feed: keeps about three screens of posts ready.
    func make(_ kind: FeedModel.Kind) -> FeedModel? {
        guard let api, let store else { return nil }
        let model = FeedModel(kind: kind, api: api, store: store, media: media); model.ahead = 24
        return model
    }
    func topic(_ tag: String) -> FeedModel? {
        if let hit = topics[tag] { return hit }
        let model = make(.topic(tag)); topics[tag] = model
        return model
    }
    /// After the rating or filters change, every board feed starts over.
    func resetFeeds() { forYou?.reset(); videos?.reset(); explore?.reset(); topics.values.forEach { $0.reset() } }
    /// Local file paths on the PC for saved posts, as small grid pictures (board covers).
    func savedPictures(_ posts: [FeedPost]) async -> [URL] {
        guard let api, !posts.isEmpty else { return [] }
        let ids: [JSONValue] = posts.map { .object([("source", .string($0.source)), ("id", .number(Double($0.postId))), ("originalUrl", .string($0.originalUrl))]) }
        guard let files = try? await api.call("booru:saved-media", [.array(ids)]).value.entries else { return [] }
        var urls = [URL]()
        for post in posts {
            guard let saved = files.first(where: { $0.0 == post.id })?.1.string, saved.hasPrefix("booru-saved://media/") else { continue }
            let path = "/api/local/" + saved.dropFirst("booru-saved://media/".count)
            media.local[post.id] = path
            if let url = api.media(path) { urls.append(url) }
        }
        return urls
    }
}
#endif
