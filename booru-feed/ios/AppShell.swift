#if canImport(UIKit)
import SwiftUI
import UniformTypeIdentifiers

extension Font {
    /// A system font that follows the phone's text-size setting. `size` is its size at the default setting;
    /// growth stops at 1.6× so the fixed-height bars and round buttons still hold their labels.
    static func scaled(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: min(UIFontMetrics.default.scaledValue(for: size), size * 1.6), weight: weight)
    }
}

// The app's frame: five tabs (Home · Search · Videos · Manga · Saved) on a flat dark bar. Each visited tab stays alive,
// so its scroll position and opened pages are still there when you come back.

enum AppTab: CaseIterable {
    case home, search, videos, manga, saved
    var title: String { switch self { case .home: return "Home"; case .search: return "Search"; case .videos: return "Videos"; case .manga: return "Manga"; case .saved: return "Saved" } }
    var icon: String { switch self { case .home: return "house"; case .search: return "magnifyingglass"; case .videos: return "play.rectangle"; case .manga: return "book"; case .saved: return "bookmark" } }
    var selectedIcon: String { switch self { case .home: return "house.fill"; case .search: return "magnifyingglass"; case .videos: return "play.rectangle.fill"; case .manga: return "book.fill"; case .saved: return "bookmark.fill" } }
}

struct AppShell: View {
    @StateObject private var library = Library()
    @StateObject private var browser = FeedBrowser()
    @StateObject private var hub = NativeHub()
    @StateObject private var homeRouter = TabRouter()
    @StateObject private var searchRouter = TabRouter()
    @StateObject private var videosRouter = TabRouter()
    @StateObject private var savedRouter = TabRouter()
    @State private var tab = AppTab.home
    @State private var visited: Set<AppTab> = [.home]

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ForEach(AppTab.allCases, id: \.self) { item in
                    if visited.contains(item) {
                        root(item).opacity(item == tab ? 1 : 0).allowsHitTesting(item == tab).accessibilityHidden(item != tab)
                    }
                }
            }
            tabBar
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .tint(Color.brand)
        .environmentObject(hub).environmentObject(browser).environmentObject(library)
        .fileImporter(isPresented: $library.picking, allowedContentTypes: [.folder], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): library.choose(urls)
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError { library.error = "The folder could not be opened. Please try again." }
            }
        }
        .fullScreenCover(isPresented: $library.showingPlayer) { PlayerView(library: library) }
        .sheet(isPresented: $hub.needsPairing, onDismiss: { Task { await hub.start(browser, promptPairing: false) } }) { PairingSheet(browser: browser) }
        .task(id: browser.connected) { await hub.start(browser) }
        .onAppear {
            browser.library = library
            // Reconnect to the PC on launch if the last session was connected (the pairing cookie is kept).
            if browser.connected == nil, UserDefaults.standard.bool(forKey: "feedAutoConnect"),
               let url = PCConnection.url(UserDefaults.standard.string(forKey: "pcFeedAddress") ?? PCConnection.defaultAddress) { browser.connect(url) }
        }
        .onChange(of: tab) { _, _ in hub.pool.pauseAll(); browser.webView.pauseAllMediaPlayback() }
    }

    @ViewBuilder private func root(_ item: AppTab) -> some View {
        switch item {
        case .home: TabStack(router: homeRouter) { HomeTab() }
        case .search: TabStack(router: searchRouter) { SearchTab(onSaved: { select(.saved) }) }
        case .videos: TabStack(router: videosRouter) { VideosTab(shown: tab == .videos) }
        case .manga: ConnectGate { if let api = hub.api { MangaView(api: api, store: hub.store) } }
        case .saved: TabStack(router: savedRouter) { SavedTab() }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { item in
                Button { select(item) } label: {
                    VStack(spacing: 3) {
                        Image(systemName: item == tab ? item.selectedIcon : item.icon).font(.scaled(21, weight: item == tab ? .bold : .regular))
                        Text(item.title).font(.scaled(10, weight: .semibold))
                    }
                    .foregroundStyle(item == tab ? Color.white : Color.white.opacity(0.5))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(item == tab ? .isSelected : [])
            }
        }
        .padding(.top, 6)
        .background(Color.black.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 0.5) }
    }
    /// Tapping the tab you are on goes back to its first page, then to the top of it.
    private func select(_ item: AppTab) {
        guard item != tab else {
            switch item { case .home: homeRouter.root(); case .search: searchRouter.root(); case .videos: videosRouter.root(); case .saved: savedRouter.root(); case .manga: break }
            return
        }
        visited.insert(item); tab = item
    }
}

/// One tab's navigation: a closeup for any post, plus the app's other pages.
struct TabStack<Content: View>: View {
    @ObservedObject var router: TabRouter
    @EnvironmentObject private var hub: NativeHub
    let content: Content
    init(router: TabRouter, @ViewBuilder content: () -> Content) { self.router = router; self.content = content() }
    var body: some View {
        NavigationStack(path: $router.path) {
            content
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: FeedPost.self) { post in
                    if let api = hub.api, let store = hub.store { PinCloseup(post: post, api: api, store: store, media: hub.media) }
                    else { Text("Connect to your PC to open this.").foregroundStyle(.white) }
                }
                .navigationDestination(for: Route.self) { route in
                    switch route {
                    case .search(let query): SearchResults(query: query)
                    case .board(let source, let name): BoardPage(source: source, name: name)
                    case .library: LocalLibraryPage()
                    case .settings: SettingsPage()
                    case .web: WebVersionPage()
                    }
                }
        }
        .environmentObject(router)
    }
}

/// Shows its content once the PC is connected and answering; otherwise the connect form or what went wrong.
struct ConnectGate<Content: View>: View {
    @EnvironmentObject private var browser: FeedBrowser
    @EnvironmentObject private var hub: NativeHub
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        if browser.connected == nil { ConnectForm() }
        else if hub.api == nil || hub.store == nil {
            VStack(spacing: 16) {
                Spacer()
                if hub.error.isEmpty { ProgressView().controlSize(.large).tint(Color.brand) }
                else {
                    Text(hub.error).foregroundStyle(.white).multilineTextAlignment(.center)
                    Button("Try again") { Task { await hub.start(browser, promptPairing: false) } }.buttonStyle(.borderedProminent).foregroundStyle(Color.ink)
                    Button("Pair this iPhone") { hub.needsPairing = true }
                    Button("Use another address", role: .destructive) { hub.stop(); browser.disconnect() }
                }
                Spacer()
            }
            .padding(24).frame(maxWidth: .infinity).background(Color.black)
        }
        else { content }
    }
}

/// The web version, shown to enter the pairing code from the PC.
struct PairingSheet: View {
    let browser: FeedBrowser
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            FeedWebView(webView: browser.webView)
                .navigationTitle("Pair this iPhone").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Reload") { browser.webView.reload() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .onAppear { browser.showWeb() }
        }
    }
}

struct WebVersionPage: View {
    @EnvironmentObject private var browser: FeedBrowser
    var body: some View {
        FeedWebView(webView: browser.webView)
            .navigationTitle("Web version").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { browser.webView.reload() } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Reload") } }
            .onAppear { browser.showWeb() }
            .onDisappear { browser.webView.pauseAllMediaPlayback() }
    }
}

// MARK: - Home

/// Text tabs with an underline under the chosen one (Home topics, Saved sections, search orders).
struct TextTabs: View {
    let items: [String]
    let title: (String) -> String
    @Binding var selection: String
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 20) {
                    ForEach(items, id: \.self) { item in
                        Button { selection = item } label: {
                            VStack(spacing: 5) {
                                Text(title(item)).font(.scaled(16, weight: .semibold)).foregroundStyle(item == selection ? Color.white : Color.white.opacity(0.55))
                                Capsule().fill(item == selection ? Color.white : Color.clear).frame(height: 3)
                            }
                            .fixedSize()
                        }
                        .buttonStyle(.plain).id(item)
                    }
                }
                .padding(.horizontal, 14)
            }
            .onChange(of: selection) { _, now in withAnimation { proxy.scrollTo(now, anchor: .center) } }
        }
    }
}

func prettyTag(_ tag: String) -> String { tag.replacingOccurrences(of: "_", with: " ") }

struct HomeTab: View {
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @State private var topic = ""           // "" is For you
    @State private var tuning = false
    var body: some View {
        ConnectGate {
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    TextTabs(items: [""] + hub.topicTags, title: { $0.isEmpty ? "For you" : prettyTag($0) }, selection: $topic)
                    Button { tuning = true } label: { Image(systemName: "slider.horizontal.3").font(.scaled(17, weight: .semibold)).foregroundStyle(.white).frame(width: 46, height: 36) }
                        .accessibilityLabel("Tune your feed")
                }
                .padding(.top, 6).padding(.bottom, 4)
                if let model = topic.isEmpty ? hub.forYou : hub.topic(topic) {
                    MasonryGrid(model: model, top: router.top) { EmptyView() }
                        .id(ObjectIdentifier(model))
                        .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { value in step(value.translation) })
                } else { Spacer() }
            }
            .background(Color.black)
            .sheet(isPresented: $tuning) { if let model = hub.forYou, let store = hub.store { TuneSheet(model: model, store: store, hub: hub) } }
        }
    }
    /// A clearly sideways swipe moves to the next or previous topic.
    private func step(_ translation: CGSize) {
        guard abs(translation.width) > 90, abs(translation.width) > 2 * abs(translation.height) else { return }
        let all = [""] + hub.topicTags
        guard let index = all.firstIndex(of: topic) else { return }
        let next = index + (translation.width < 0 ? 1 : -1)
        if all.indices.contains(next) { withAnimation(.easeInOut(duration: 0.2)) { topic = all[next] } }
    }
}

/// Rating, quick filters and shuffle for the board feeds (stored in the shared preferences, like the web app).
struct TuneSheet: View {
    @ObservedObject var model: FeedModel
    @ObservedObject var store: SharedStore
    let hub: NativeHub
    @Environment(\.dismiss) private var dismiss
    private var tags: String { store.preferences["tags"]?.string ?? "" }
    var body: some View {
        NavigationStack {
            List {
                Section("Order and filters") {
                    ForEach(FeedFilters.presets.filter { FeedFilters.forYou.contains($0.tag) }, id: \.tag) { preset in
                        let on = preset.tag == "order:random" ? model.random : FeedFilters.terms(tags).contains(preset.tag)
                        Button {
                            if preset.tag == "order:random" { model.random.toggle(); model.reset() }      // web: Random is session-only
                            else { store.setPreference("tags", .string(FeedFilters.toggle(preset.tag, in: tags))); hub.resetFeeds() }
                        } label: { HStack { Text(preset.label).foregroundStyle(.white); Spacer(); if on { Image(systemName: "checkmark").foregroundStyle(Color.brand) } } }
                    }
                }
                Section("Content rating") {
                    ForEach([("all", "All ratings"), ("general", "General only"), ("explicit", "Explicit only")], id: \.0) { value, label in
                        Button { store.setPreference("rating", .string(value)); hub.resetFeeds() } label: {
                            HStack { Text(label).foregroundStyle(.white); Spacer(); if model.rating == value { Image(systemName: "checkmark").foregroundStyle(Color.brand) } }
                        }
                    }
                }
            }
            .navigationTitle("Tune your feed").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Search (explore grid under a search bar and topic chips)

struct SearchTab: View {
    let onSaved: () -> Void
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @State private var query = ""
    @FocusState private var typing: Bool
    @AppStorage("recentSearches") private var recentsText = ""
    @State private var topic = ""           // "" is For you
    @State private var tuning = false
    private var recents: [String] { recentsText.split(separator: "\n").map(String.init) }

    var body: some View {
        ConnectGate {
            VStack(spacing: 0) {
                searchBar
                if typing || !query.isEmpty { suggestions }
                else {
                    chips
                    if let model = topic.isEmpty ? hub.explore : hub.topic(topic) {
                        ExploreGrid(model: model, top: router.top).id(ObjectIdentifier(model))
                    } else { Spacer() }
                }
            }
            .background(Color.black)
            .sheet(isPresented: $tuning) { if let model = hub.explore, let store = hub.store { TuneSheet(model: model, store: store, hub: hub) } }
        }
    }

    private var searchBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.scaled(17, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                TextField("", text: $query, prompt: Text("Search").foregroundColor(.white.opacity(0.6)))
                    .focused($typing).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .onSubmit { run(query) }
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain).accessibilityLabel("Clear") }
            }
            .font(.scaled(17)).foregroundStyle(.white)
            .padding(.horizontal, 14).frame(height: 44)
            .background(Color(white: 0.15), in: Capsule())
            if typing || !query.isEmpty { Button("Cancel") { query = ""; typing = false }.foregroundStyle(.white) }
            else { Button(action: onSaved) { Image(systemName: "bookmark").font(.scaled(22, weight: .semibold)).foregroundStyle(.white) }.accessibilityLabel("Saved") }
        }
        .padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 8)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button { tuning = true } label: {
                    Image(systemName: "slider.horizontal.3").font(.scaled(15, weight: .semibold)).frame(width: 46, height: 36)
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1))
                }.accessibilityLabel("Tune")
                ForEach([""] + hub.topicTags, id: \.self) { tag in
                    Button { topic = tag } label: {
                        Text(tag.isEmpty ? "For you" : prettyTag(tag)).font(.scaled(15, weight: .semibold)).padding(.horizontal, 14).frame(height: 36)
                            .background(tag == topic ? Color(white: 0.22) : Color.clear, in: Capsule())
                            .overlay(Capsule().stroke(Color.white.opacity(tag == topic ? 0 : 0.25), lineWidth: 1))
                    }
                }
            }
            .foregroundStyle(.white).buttonStyle(.plain).padding(.horizontal, 12).padding(.bottom, 8)
        }
    }

    private var suggestions: some View {
        let text = query.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: " ", with: "_")
        let matches = text.isEmpty ? [] : Array(hub.suggestionTags.filter { $0.lowercased().contains(text) }.prefix(12))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if text.isEmpty {
                    if !recents.isEmpty {
                        HStack { Text("Recent").font(.scaled(17, weight: .bold)).foregroundStyle(.white); Spacer(); Button("Clear all") { recentsText = "" }.font(.scaled(14, weight: .semibold)) }
                            .padding(.horizontal, 16).padding(.vertical, 10)
                    }
                    ForEach(recents, id: \.self) { item in row("clock", item, action: { run(item) }, remove: { recentsText = recents.filter { $0 != item }.joined(separator: "\n") }) }
                } else {
                    row("magnifyingglass", query, action: { run(query) }, remove: nil)
                    ForEach(matches, id: \.self) { tag in row("number", prettyTag(tag), action: { run(tag) }, remove: nil) }
                }
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }
    private func row(_ icon: String, _ text: String, action: @escaping () -> Void, remove: (() -> Void)?) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon).font(.scaled(16, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 44).background(Color(white: 0.15), in: Circle())
            Text(text).font(.scaled(16)).foregroundStyle(.white).lineLimit(1)
            Spacer()
            if let remove { Button(action: remove) { Image(systemName: "xmark").font(.scaled(13, weight: .bold)).foregroundStyle(.white.opacity(0.6)).frame(width: 36, height: 36) }.buttonStyle(.plain).accessibilityLabel("Remove") }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
    }
    private func run(_ text: String) {
        let tags = text.trimmingCharacters(in: .whitespaces)
        guard !tags.isEmpty else { return }
        recentsText = Array(([tags] + recents.filter { $0 != tags }).prefix(15)).joined(separator: "\n")
        typing = false; query = ""
        router.go(.search(tags))
    }
}

/// Search results: the same explore grid, with the order as text tabs.
struct SearchResults: View {
    let query: String
    @EnvironmentObject private var hub: NativeHub
    @Environment(\.dismiss) private var dismiss
    @State private var order = ""
    @State private var model: FeedModel?
    private let orders = ["", "order:score", "order:favcount", "order:random"]
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.scaled(18, weight: .bold)).foregroundStyle(.white).frame(width: 40, height: 40) }.accessibilityLabel("Back")
                Text(prettyTag(query)).font(.scaled(17, weight: .semibold)).foregroundStyle(.white).lineLimit(1)
                    .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 40, alignment: .leading).background(Color(white: 0.15), in: Capsule())
            }
            .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
            TextTabs(items: orders, title: { $0.isEmpty ? "Recent" : $0 == "order:score" ? "Top" : $0 == "order:favcount" ? "Most favourited" : "Random" }, selection: $order)
                .padding(.bottom, 4)
            if let model { ExploreGrid(model: model).id(ObjectIdentifier(model)) } else { Spacer() }
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(backSwipe { dismiss() })
        .onAppear { if model == nil { rebuild() } }
        .onChange(of: order) { _, _ in rebuild() }
    }
    private func rebuild() {
        let random = order == "order:random"
        let fresh = hub.make(.search(order.isEmpty || random ? query : FeedFilters.toggle(order, in: query)))
        fresh?.random = random
        model = fresh
    }
}

// MARK: - Videos (the full-screen swipe feed)

struct VideosTab: View {
    let shown: Bool
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var browser: FeedBrowser
    @AppStorage("videosGrid") private var grid = false
    var body: some View {
        ConnectGate {
            if let videos = hub.videos, let store = hub.store {
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        FilterBar(model: videos, store: store, presets: FeedFilters.videos)
                        Button { hub.pool.pauseAll(); grid.toggle() } label: {
                            Image(systemName: grid ? "rectangle.portrait" : "square.grid.2x2").font(.scaled(17, weight: .semibold)).foregroundStyle(.white).frame(width: 44, height: 36)
                        }.accessibilityLabel(grid ? "Full-screen view" : "Grid view")
                    }
                    if grid {
                        MasonryGrid(model: videos, top: router.top) { EmptyView() }
                    } else {
                        PagedFeedView(model: videos, store: store, loader: hub.loader, videos: hub.pool, browser: browser,
                                      onSearch: { router.go(.search($0)) }, onSimilar: { router.open($0) }, visible: shown && router.path.isEmpty)
                    }
                }
                .background(Color.black)
            }
        }
    }
}

// MARK: - Saved (pins, likes, boards, the phone's own library, settings)

struct SavedTab: View {
    @EnvironmentObject private var hub: NativeHub
    @EnvironmentObject private var router: TabRouter
    @EnvironmentObject private var browser: FeedBrowser
    @EnvironmentObject private var library: Library
    @AppStorage("savedSection") private var section = "Pins"
    @State private var filter = ""
    @State private var model: FeedModel?
    @State private var boards = [SavedBoards.Board]()
    @State private var saved = [FeedPost]()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                Text("Saved").font(.scaled(28, weight: .bold)).foregroundStyle(.white)
                Spacer()
                if section != "Boards" { Button { model?.shuffle() } label: { Image(systemName: "shuffle").frame(width: 40, height: 40) }.accessibilityLabel("Shuffle") }
                Button { router.go(.settings) } label: { Image(systemName: "gearshape").frame(width: 40, height: 40) }.accessibilityLabel("Settings")
            }
            .font(.scaled(18, weight: .semibold)).foregroundStyle(.white).buttonStyle(.plain)
            .padding(.horizontal, 14).padding(.top, 6)
            TextTabs(items: ["Pins", "Liked", "Boards"], title: { $0 }, selection: $section).padding(.vertical, 6)
            if section == "Boards" { boardsPage }
            else if browser.connected == nil { ConnectForm() }
            else {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.6))
                    TextField("", text: $filter, prompt: Text(section == "Pins" ? "Search your saves" : "Search your likes").foregroundColor(.white.opacity(0.6)))
                        .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit { rebuild() }
                    if !filter.isEmpty { Button { filter = ""; rebuild() } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.5)) }.buttonStyle(.plain).accessibilityLabel("Clear") }
                }
                .font(.scaled(16)).foregroundStyle(.white).padding(.horizontal, 14).frame(height: 40)
                .background(Color(white: 0.15), in: Capsule()).padding(.horizontal, 12).padding(.bottom, 8)
                if let model { MasonryGrid(model: model, top: router.top) { EmptyView() }.id(ObjectIdentifier(model)) }
                else { Spacer() }
            }
        }
        .background(Color.black)
        .onAppear { rebuild() }
        .onChange(of: section) { _, _ in rebuild() }
        .onChange(of: hub.store == nil) { _, _ in rebuild() }
    }

    private var boardsPage: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 18) {
                Button { router.go(.library) } label: {
                    BoardCard(name: "On this iPhone", detail: library.roots.count > 1 ? "\(library.roots.count) folders" : library.roots.first?.lastPathComponent ?? "Choose a folder", posts: [], icon: "iphone")
                }
                ForEach(boards, id: \.source) { board in
                    Button { router.go(.board(source: board.source, name: board.name)) } label: {
                        BoardCard(name: board.name, detail: "\(board.count) saved", posts: board.covers.filter { saved.indices.contains($0) }.map { saved[$0] }, icon: "photo.on.rectangle")
                    }
                }
            }
            .buttonStyle(PressScale()).padding(12)
            if browser.connected == nil { Text("Connect to your PC (Home tab) to see the boards of your saved posts.").font(.footnote).foregroundStyle(.white.opacity(0.6)).padding() }
        }
        .refreshable { rebuild() }
    }

    /// Pins and Liked are rebuilt from the shared library each time they are opened, so they show what the PC has now.
    private func rebuild() {
        saved = (JSONValue.parse(hub.store?[SharedKeys.saved])?.array ?? []).map(FeedPost.init)
        boards = SavedBoards.group(saved)
        guard section != "Boards" else { model = nil; return }
        let fresh = hub.make(section == "Liked" ? .liked : .saved)
        fresh?.filter = filter
        model = fresh
    }
}

/// A board: a collage of up to three covers (one large, two small), its name and a line of detail.
struct BoardCard: View {
    let name: String, detail: String
    let posts: [FeedPost]
    let icon: String
    @EnvironmentObject private var hub: NativeHub
    @State private var covers = [URL]()
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geometry in
                let small = (geometry.size.width / 3).rounded(.down), large = geometry.size.width - small - 2
                HStack(spacing: 2) {
                    cover(0, width: large, height: geometry.size.height)
                    VStack(spacing: 2) { cover(1, width: small, height: (geometry.size.height - 2) / 2); cover(2, width: small, height: (geometry.size.height - 2) / 2) }
                }
            }
            .aspectRatio(1.45, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Text(name).font(.scaled(16, weight: .bold)).foregroundStyle(.white).lineLimit(1)
            Text(detail).font(.scaled(12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
        .task(id: posts.map(\.id).joined()) { covers = await hub.savedPictures(posts) }
    }
    @ViewBuilder private func cover(_ index: Int, width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            Color(white: 0.14)
            if covers.indices.contains(index), let api = hub.api { RemoteImage(api: api, url: covers[index]).scaledToFill().frame(width: width, height: height).clipped() }
            else if index == 0 { Image(systemName: icon).font(.scaled(30)).foregroundStyle(.white.opacity(0.5)) }
        }
        .frame(width: width, height: height).clipped()
    }
}

/// The saved posts of one board.
struct BoardPage: View {
    let source: String, name: String
    @EnvironmentObject private var hub: NativeHub
    @Environment(\.dismiss) private var dismiss
    @State private var model: FeedModel?
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Button { dismiss() } label: { Image(systemName: "chevron.left").font(.scaled(18, weight: .bold)).frame(width: 40, height: 40) }.accessibilityLabel("Back")
                Text(name).font(.scaled(22, weight: .bold)).lineLimit(1)
                Spacer()
                Button { model?.shuffle() } label: { Image(systemName: "shuffle").font(.scaled(17, weight: .semibold)).frame(width: 40, height: 40) }.accessibilityLabel("Shuffle")
            }
            .foregroundStyle(.white).buttonStyle(.plain).padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 6)
            if let model { MasonryGrid(model: model) { EmptyView() } } else { Spacer() }
        }
        .background(Color.black)
        .toolbar(.hidden, for: .navigationBar)
        .simultaneousGesture(backSwipe { dismiss() })
        .onAppear { if model == nil { model = hub.make(.savedFrom(source)) } }
    }
}
#endif
