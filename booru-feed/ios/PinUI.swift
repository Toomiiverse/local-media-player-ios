#if canImport(UIKit)
import SwiftUI
import AVFoundation

// The redesigned browsing pieces: a two-column masonry grid, an explore grid (tall cells with wide tiles for landscape
// videos), their tiles, and the closeup a tile opens (media, actions, tags, then more like it).

// MARK: - Navigation inside a tab

enum Route: Hashable { case search(String), board(source: String, name: String), library, settings, web }

@MainActor
final class TabRouter: ObservableObject {
    @Published var path = NavigationPath()
    /// Bumped when the tab is tapped again at its root: grids scroll back to the top.
    @Published var top = 0
    func open(_ post: FeedPost) { path.append(post) }
    func go(_ route: Route) { path.append(route) }
    func root() { if path.isEmpty { top += 1 } else { path = NavigationPath() } }
}

/// Keeps the edge swipe-back working on pages that hide the navigation bar.
extension UINavigationController: UIGestureRecognizerDelegate {
    override open func viewDidLoad() { super.viewDidLoad(); interactivePopGestureRecognizer?.delegate = self }
    public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool { viewControllers.count > 1 }
}

/// A clearly sideways swipe to the right (not a scroll): go back.
func backSwipe(_ action: @escaping () -> Void) -> some Gesture {
    DragGesture(minimumDistance: 40).onEnded { value in
        if value.translation.width > 90, value.translation.width > 2 * abs(value.translation.height) { action() }
    }
}

// MARK: - Tiles

struct PressScale: ButtonStyle {
    var scale: CGFloat = 0.97
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? scale : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Long-press menu shared by every tile.
@MainActor @ViewBuilder
func pinMenu(_ post: FeedPost, model: FeedModel, store: SharedStore?, more: @escaping () -> Void) -> some View {
    if let store {
        Button { Task { try? await store.save(post) } } label: { Label(store.isSaved(post) ? "Remove from Saved" : "Save", systemImage: store.isSaved(post) ? "bookmark.slash" : "bookmark") }
        Button { store.react(post, kind: "liked", fromVideos: false) } label: { Label(store.isLiked(post) ? "Unlike" : "Like", systemImage: store.isLiked(post) ? "heart.slash" : "heart") }
        Button(action: more) { Label("More", systemImage: "ellipsis") }
        if let url = URL(string: post.url), url.scheme == "https" { ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") } }
        Button(role: .destructive) { store.hide(post); model.drop(post) } label: { Label("Hide", systemImage: "eye.slash") }
    }
}

/// A tile's picture, cropped to fill. It is let go when the tile scrolls away, so long grids stay light on memory.
struct TileImage: View {
    let post: FeedPost
    let model: FeedModel
    let loader: MediaLoader
    let width: CGFloat, height: CGFloat
    @State private var image: UIImage?
    private var maxPixel: CGFloat { min(900, max(width, height) * UIScreen.main.scale) }   // ≤ 900 keeps tiles in the small cache class
    var body: some View {
        let url = model.tileURL(post), shown = image ?? url.flatMap { loader.cached($0, maxPixel: maxPixel) }
        ZStack {
            Color(white: 0.12)
            if let shown { Image(uiImage: shown).resizable().scaledToFill().frame(width: width, height: height) }
        }
        .frame(width: width, height: height).clipped()
        .task(id: post.id) {
            guard let url, shown == nil else { return }
            image = await loader.image(url, api: model.api, maxPixel: maxPixel)
        }
        .onDisappear { image = nil }
    }
}

struct IndexedPost: Identifiable {
    let index: Int
    let post: FeedPost
    var id: String { post.id }
}

/// Masonry tile: rounded picture sized by the post's shape, then a slim row with the artist and "•••".
struct PinTile: View {
    let post: FeedPost
    let model: FeedModel
    let width: CGFloat, height: CGFloat
    let onMore: () -> Void
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button { router.open(post) } label: {
                TileImage(post: post, model: model, loader: hub.loader, width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) { if post.isVideo { VideoBadge().padding(8) } }
                    .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(PressScale())
            .contextMenu { pinMenu(post, model: model, store: hub.store, more: onMore) }
            HStack(spacing: 4) {
                Text(post.artist.replacingOccurrences(of: "_", with: " ")).font(.scaled(12, weight: .medium)).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onMore) { Image(systemName: "ellipsis").font(.scaled(14, weight: .bold)).foregroundStyle(.white.opacity(0.85)).frame(width: 32, height: 24).contentShape(Rectangle()) }
                    .buttonStyle(.plain).accessibilityLabel("More")
            }
            .frame(height: 24)
        }
        .frame(width: width)
    }
}

struct VideoBadge: View {
    var body: some View {
        Image(systemName: "play.fill").font(.scaled(10, weight: .bold)).foregroundStyle(.white)
            .frame(width: 24, height: 24).background(.black.opacity(0.55), in: Circle()).accessibilityLabel("Video")
    }
}

func compactCount(_ value: Double) -> String {
    value >= 1_000_000 ? String(format: "%.1fM", value / 1_000_000) : value >= 1000 ? String(format: "%.1fK", value / 1000) : String(Int(value))
}

/// Explore tile: edge-to-edge picture; videos carry a play mark and their score, the hero adds a title.
struct ExploreTile: View {
    let post: FeedPost
    let model: FeedModel
    let width: CGFloat, height: CGFloat
    var hero = false
    let onMore: () -> Void
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    var body: some View {
        Button { router.open(post) } label: {
            TileImage(post: post, model: model, loader: hub.loader, width: width, height: height)
                .overlay(alignment: .topTrailing) {
                    if post.isVideo { Image(systemName: "play.fill").font(.scaled(13, weight: .bold)).foregroundStyle(.white).shadow(radius: 3).padding(8) }
                    else if post.galleryCount > 1 { Image(systemName: "square.on.square.fill").font(.scaled(13, weight: .bold)).foregroundStyle(.white).shadow(radius: 3).padding(8) }
                }
                .overlay(alignment: .bottomLeading) {
                    if hero {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(post.artist.isEmpty ? post.boardName : post.artist.replacingOccurrences(of: "_", with: " ")).font(.scaled(17, weight: .bold))
                            Text(post.tags.prefix(5).map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: " · ")).font(.scaled(13)).lineLimit(1).opacity(0.9)
                        }
                        .foregroundStyle(.white).shadow(radius: 4).padding(10)
                    } else if post.isVideo, post.score > 0 {
                        Label(compactCount(post.score), systemImage: "heart.fill").font(.scaled(12, weight: .bold)).foregroundStyle(.white).shadow(radius: 3).padding(8)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(PressScale(scale: 1))
        .contextMenu { pinMenu(post, model: model, store: hub.store, more: onMore) }
    }
}

// MARK: - Grids

/// Two columns of rounded tiles under an optional header (Home, Saved, and "More to explore" in a closeup).
struct MasonryGrid<Header: View>: View {
    @ObservedObject var model: FeedModel
    let top: Int
    let header: Header
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var browser: FeedBrowser
    @State private var details: FeedPost?
    /// One page of posts at a time, turned with Previous / Next, instead of an endless scroll.
    @State private var page = 0
    private let pageSize = 30
    private let spacing: CGFloat = 8, caption: CGFloat = 26

    init(model: FeedModel, top: Int = 0, @ViewBuilder header: () -> Header) { self.model = model; self.top = top; self.header = header() }

    var body: some View {
        GeometryReader { geometry in
            let width = max(60, ((geometry.size.width - spacing * 3) / 2).rounded(.down))
            let turned = min(page, max(0, (model.posts.count - 1) / pageSize)), start = turned * pageSize
            let slice = Array(model.posts.dropFirst(start).prefix(pageSize))
            let columns = Masonry.columns(heights: slice.map { 1 / $0.tileAspect + Double(caption / width) }, count: 2)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    header
                    HStack(alignment: .top, spacing: spacing) {
                        ForEach(0..<2, id: \.self) { column in
                            LazyVStack(spacing: spacing) {
                                ForEach(columns[column].filter { slice.indices.contains($0) }.map { IndexedPost(index: start + $0, post: slice[$0]) }) { item in
                                    PinTile(post: item.post, model: model, width: width, height: (width / CGFloat(item.post.tileAspect)).rounded(), onMore: { details = item.post })
                                        .onAppear { model.appeared(item.index) }
                                }
                            }
                            .frame(width: width)
                        }
                    }
                    .padding(.horizontal, spacing)
                    GridFooter(model: model)
                    PageTurner(model: model, page: turned, pageSize: pageSize) { target in page = target; proxy.scrollTo("top", anchor: .top) }
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.reload() }
                .onChange(of: top) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
                .onChange(of: model.posts.isEmpty) { _, empty in if empty { page = 0 } }
            }
        }
        .task { if model.posts.isEmpty { await model.more() } }
        .sheet(item: $details) { post in
            if let store = hub.store {
                PostDetailsSheet(post: post, model: model, store: store, browser: browser,
                                 onSearch: { tag in details = nil; router.go(.search(tag)) }, onSimilar: { other in details = nil; router.open(other) })
            }
        }
    }
}

/// Explore grid: three tall cells per row, with wide tiles for landscape videos (Search).
struct ExploreGrid: View {
    @ObservedObject var model: FeedModel
    var top = 0
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var browser: FeedBrowser
    @State private var details: FeedPost?
    @State private var page = 0
    private let pageSize = 30
    private let gap: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let cell = max(40, ((geometry.size.width - gap * 2) / 3).rounded(.down)), rowHeight = (cell * 4 / 3).rounded()
            let turned = min(page, max(0, (model.posts.count - 1) / pageSize)), start = turned * pageSize
            let slice = Array(model.posts.dropFirst(start).prefix(pageSize))
            // A full page closes its last row even while more posts exist beyond it.
            let rows = ExploreLayout.rows(wide: slice.map(\.isWideTile), complete: model.exhausted || slice.count == pageSize)
            ScrollViewReader { proxy in
                ScrollView {
                    Color.clear.frame(height: 0).id("top")
                    LazyVStack(spacing: gap) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            rowView(row, cell: cell, rowHeight: rowHeight, full: geometry.size.width, start: start)
                        }
                    }
                    GridFooter(model: model)
                    PageTurner(model: model, page: turned, pageSize: pageSize) { target in page = target; proxy.scrollTo("top", anchor: .top) }
                }
                .scrollIndicators(.hidden)
                .refreshable { await model.reload() }
                .onChange(of: top) { _, _ in withAnimation { proxy.scrollTo("top", anchor: .top) } }
                .onChange(of: model.posts.isEmpty) { _, empty in if empty { page = 0 } }
            }
        }
        .task { if model.posts.isEmpty { await model.more() } }
        .sheet(item: $details) { post in
            if let store = hub.store {
                PostDetailsSheet(post: post, model: model, store: store, browser: browser,
                                 onSearch: { tag in details = nil; router.go(.search(tag)) }, onSimilar: { other in details = nil; router.open(other) })
            }
        }
    }

    /// Row indices count from the start of the page; `start` turns them back into positions in the feed.
    @ViewBuilder private func rowView(_ row: ExploreLayout.Row, cell: CGFloat, rowHeight: CGFloat, full: CGFloat, start: Int) -> some View {
        switch row {
        case .hero(let index):
            tile(start + index, width: full, height: (full * 9 / 16).rounded(), hero: true)
        case .wide(let wide, let other, let wideOnLeft):
            HStack(spacing: gap) {
                if wideOnLeft { tile(start + wide, width: cell * 2 + gap, height: rowHeight) }
                if let other { tile(start + other, width: cell, height: rowHeight) }
                if !wideOnLeft { tile(start + wide, width: cell * 2 + gap, height: rowHeight) }
                Spacer(minLength: 0)
            }
        case .cells(let indices):
            HStack(spacing: gap) {
                ForEach(indices, id: \.self) { index in tile(start + index, width: cell, height: rowHeight) }
                Spacer(minLength: 0)
            }
        }
    }
    @ViewBuilder private func tile(_ index: Int, width: CGFloat, height: CGFloat, hero: Bool = false) -> some View {
        if model.posts.indices.contains(index) {
            let post = model.posts[index]
            ExploreTile(post: post, model: model, width: width, height: height, hero: hero, onMore: { details = post })
                .onAppear { model.appeared(index) }
                .id(post.id)   // rows are reused from page to page; the tile must not keep the last page's picture
        }
    }
}

/// Previous / Next under a grid: one page of posts at a time. Next loads the following page only when pressed.
struct PageTurner: View {
    @ObservedObject var model: FeedModel
    let page: Int, pageSize: Int
    let turn: (Int) -> Void
    @State private var turning = false
    var body: some View {
        let hasNext = model.posts.count > (page + 1) * pageSize || !model.exhausted
        if !model.posts.isEmpty {
            HStack(spacing: 14) {
                Button { turn(page - 1) } label: { label("Previous", icon: "chevron.left", leading: true) }
                    .disabled(page == 0 || turning).opacity(page == 0 || turning ? 0.4 : 1)
                Text("Page \(page + 1)").font(.footnote.weight(.semibold)).monospacedDigit().foregroundStyle(.white.opacity(0.8))
                Button { Task { await next() } } label: { label(turning ? "Loading…" : "Next", icon: "chevron.right", leading: false) }
                    .disabled(!hasNext || turning).opacity(!hasNext || turning ? 0.4 : 1)
            }
            .buttonStyle(.plain).padding(.vertical, 20).frame(maxWidth: .infinity)
        }
    }
    private func label(_ text: String, icon: String, leading: Bool) -> some View {
        HStack(spacing: 6) {
            if leading { Image(systemName: icon) }
            Text(text)
            if !leading { Image(systemName: icon) }
        }
        .font(.footnote.weight(.semibold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 10)
        .background(Color.white.opacity(0.15), in: Capsule())
    }
    private func next() async {
        turning = true
        await model.fill(to: (page + 2) * pageSize)
        turning = false
        if model.posts.count > (page + 1) * pageSize { turn(page + 1) }
    }
}

/// Under a grid: the spinner while loading, or why there is nothing.
struct GridFooter: View {
    @ObservedObject var model: FeedModel
    var body: some View {
        if !model.error.isEmpty {
            Text(model.error).font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center).padding(28).frame(maxWidth: .infinity)
        } else if model.loading || model.posts.isEmpty {
            ProgressView().controlSize(.large).tint(Color.brand).padding(28).frame(maxWidth: .infinity)
        }
    }
}

// MARK: - Closeup

/// Wrapping row of chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > limit { x = 0; y += row + spacing; row = 0 }
            x += size.width + spacing; row = max(row, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + row)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, row: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX { x = bounds.minX; y += row + spacing; row = 0 }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing; row = max(row, size.height)
        }
    }
}

/// One post, opened: the picture or video, its actions and tags, then a grid of similar posts to keep exploring.
struct PinCloseup: View {
    let post: FeedPost
    @ObservedObject var store: SharedStore
    @StateObject private var related: FeedModel
    @StateObject private var pool = VideoPool()
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var browser: FeedBrowser
    @Environment(\.dismiss) private var dismiss
    @State private var showing = false
    @State private var details = false
    @State private var saving = false
    @State private var opened = Date()

    init(post: FeedPost, api: FeedAPI, store: SharedStore, media: MediaMap) {
        self.post = post; self.store = store
        _related = StateObject(wrappedValue: { let model = FeedModel(kind: .similar(post), api: api, store: store, media: media); model.ahead = 24; return model }())
    }

    private var mediaSize: CGSize {
        let screen = UIScreen.main.bounds.size
        let aspect = post.width > 0 && post.height > 0 ? min(2.4, max(0.45, post.width / post.height)) : (post.isVideo ? 16.0 / 9.0 : 0.75)
        return CGSize(width: screen.width, height: min(screen.width / CGFloat(aspect), screen.height * 0.72).rounded())
    }

    var body: some View {
        MasonryGrid(model: related) { detail }
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.scaled(17, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40).background(.black.opacity(0.55), in: Circle()) }
                    .accessibilityLabel("Back").padding(.leading, 12).padding(.top, 8)
            }
            .toolbar(.hidden, for: .navigationBar)
            .simultaneousGesture(backSwipe { dismiss() })
            .onAppear { showing = true; opened = Date(); pool.muted = hub.pool.muted; related.feedback(post, "open") }
            .onDisappear {
                showing = false; pool.pauseAll()
                let ms = Int(Date().timeIntervalSince(opened) * 1000)
                if ms >= 1500 { related.feedback(post, "view", ms: min(ms, 120_000)) }
            }
            .onChange(of: pool.muted) { _, muted in hub.pool.muted = muted }
            .sheet(isPresented: $details) {
                PostDetailsSheet(post: post, model: related, store: store, browser: browser,
                                 onSearch: { tag in details = false; router.go(.search(tag)) }, onSimilar: { other in details = false; if other.id != post.id { router.open(other) } })
            }
    }

    private var detail: some View {
        let size = mediaSize, liked = store.isLiked(post), saved = store.isSaved(post)
        let blocked = store.blocked
        return VStack(alignment: .leading, spacing: 14) {
            PostCardView(post: post, model: related, store: store, loader: hub.loader, videos: pool, browser: browser, active: showing, size: size, chrome: false) { details = true }
                .frame(width: size.width, height: size.height)
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            HStack(spacing: 22) {
                Button { UIImpactFeedbackGenerator(style: .light).impactOccurred(); store.react(post, kind: "liked", fromVideos: false) } label: {
                    Image(systemName: liked ? "heart.fill" : "heart").foregroundStyle(liked ? Color.brand : .white)
                }.accessibilityLabel(liked ? "Unlike" : "Like")
                if let url = URL(string: post.url), url.scheme == "https" { ShareLink(item: url) { Image(systemName: "square.and.arrow.up").foregroundStyle(.white) }.accessibilityLabel("Share") }
                Button { details = true } label: { Image(systemName: "ellipsis").foregroundStyle(.white).frame(height: 24) }.accessibilityLabel("More")
                Spacer()
                Button {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred(); saving = true
                    Task { do { try await store.save(post) } catch { store.syncError = error.localizedDescription }; saving = false }
                } label: {
                    Text(saving ? "Saving…" : saved ? "Saved" : "Save").font(.scaled(16, weight: .bold))
                        .foregroundStyle(saved ? Color.white : Color.ink).padding(.horizontal, 22).frame(height: 44)
                        .background(saved ? Color(white: 0.22) : Color.brand, in: Capsule())
                }.disabled(saving)
            }
            .font(.scaled(22, weight: .semibold)).buttonStyle(.plain).padding(.horizontal, 16)
            VStack(alignment: .leading, spacing: 4) {
                Text(post.artist.isEmpty ? "Unknown artist" : post.artist.replacingOccurrences(of: "_", with: " ")).font(.scaled(20, weight: .bold)).foregroundStyle(.white)
                Text(post.boardName.isEmpty ? (URL(string: post.source)?.host ?? "") : post.boardName).font(.scaled(13)).foregroundStyle(.white.opacity(0.6))
            }.padding(.horizontal, 16)
            FlowLayout(spacing: 8) {
                ForEach(Array(post.tags.prefix(16)), id: \.self) { tag in
                    Text(tag.replacingOccurrences(of: "_", with: " ")).font(.scaled(13, weight: .semibold)).strikethrough(blocked.contains(SharedEdit.normalTag(tag)))
                        .foregroundStyle(.white).padding(.horizontal, 12).frame(height: 32).background(Color(white: 0.16), in: Capsule())
                        .onTapGesture { router.go(.search(tag)) }
                        .contextMenu { Button(blocked.contains(SharedEdit.normalTag(tag)) ? "Show posts with this tag" : "Hide posts with this tag") { store.block(tag) } }
                }
            }.padding(.horizontal, 16)
            if !store.syncError.isEmpty { Text(store.syncError).font(.footnote).foregroundStyle(Color.brand).padding(.horizontal, 16) }
            Text("More to explore").font(.scaled(18, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.top, 6)
        }
        .padding(.bottom, 4)
    }
}
#endif
