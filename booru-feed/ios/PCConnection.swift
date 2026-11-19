import Foundation

enum PCConnection {
    static let defaultAddress = "https://desktop-s26voof.tail6da04d.ts.net:8443/"
    static func url(_ address: String) -> URL? {
        guard let parts = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port == nil || (1...65535).contains(parts.port!),
              let url = parts.url else { return nil }
        return url
    }
    // A file name the feed suggests, made safe: no folders, no hidden files, letters/digits/._- only, bounded length.
    static func safeName(_ suggested: String, fallback: String = "booru-media") -> String {
        let last = suggested.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? ""
        var name = String(last.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) ? Character($0) : "_" })
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = fallback }
        return String(name.suffix(120))
    }
    // The first free "name", "name (2)", "name (3)"… in a folder.
    static func unique(_ name: String, in folder: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> URL {
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = folder.appendingPathComponent(name), copy = 2
        while exists(target) { target = folder.appendingPathComponent(ext.isEmpty ? "\(base) (\(copy))" : "\(base) (\(copy)).\(ext)"); copy += 1 }
        return target
    }
}

#if canImport(UIKit)
import SwiftUI
import WebKit

// The Booru Feed web app inside the app, with a bridge: the feed can hand a post's media to the phone to save into the
// chosen library folder, or to play in the VLC player. Downloads reuse the web view's paired session cookie.
@MainActor
final class FeedBrowser: NSObject, ObservableObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    @Published var connected: URL?
    @Published var status = ""
    @Published var working = false
    let webView: WKWebView
    weak var library: Library?

    // The feed's sign-in, cookies and cached pages stay on this phone only: their folders are kept out of iCloud and
    // computer backups. Created first so the flag is in place before WebKit writes anything, and re-applied after loads.
    static func excludeWebDataFromBackup() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        for name in ["WebKit", "Cookies", "HTTPStorages"] {
            var folder = library.appendingPathComponent(name, isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try? folder.setResourceValues(values)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { Self.excludeWebDataFromBackup() }

    override init() {
        Self.excludeWebDataFromBackup()
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        webView.configuration.userContentController.add(self, name: "localMedia")
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.isOpaque = false
        webView.backgroundColor = UIColor(Color.ink)
        webView.scrollView.backgroundColor = UIColor(Color.ink)
    }
    private var webLoaded = false
    func connect(_ url: URL) { connected = url; webLoaded = false; UserDefaults.standard.set(true, forKey: "feedAutoConnect") }
    /// The web version is only loaded when it is shown (pairing, or Settings → Web version); the native tabs do not need it.
    func showWeb() { guard let connected, !webLoaded else { return }; webLoaded = true; webView.load(URLRequest(url: connected)) }
    func disconnect() { UserDefaults.standard.set(false, forKey: "feedAutoConnect"); webView.pauseAllMediaPlayback(); webView.load(URLRequest(url: URL(string: "about:blank")!)); webLoaded = false; connected = nil; status = "" }

    // Only the PC feed stays inside the app; links to boards and other sites open in Safari.
    private func isFeed(_ url: URL?) -> Bool { guard let url, let connected else { return false }; return url.host == connected.host && url.port == connected.port && url.scheme == "https" }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url else { return decisionHandler(.cancel) }
        if url.scheme == "about" || isFeed(url) { return decisionHandler(.allow) }
        // A tapped link leaves for Safari; anything else trying to load another site in the background is just blocked.
        if action.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") { UIApplication.shared.open(url) }
        decisionHandler(.cancel)
    }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if let url = action.request.url { if isFeed(url) { webView.load(action.request) } else { UIApplication.shared.open(url) } }
        return nil
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, isFeed(message.frameInfo.request.url),
              let body = message.body as? [String: Any], let action = body["action"] as? String, action == "save" || action == "play",
              let text = body["url"] as? String, let url = URL(string: text), isFeed(url) else { return }
        let name = PCConnection.safeName(body["name"] as? String ?? url.lastPathComponent)
        Task { await transfer(url, name: name, play: action == "play") }
    }

    // Native feed: the same save / play paths as the web feed's buttons, for a post it already shows.
    func save(post: FeedPost, model: FeedModel) { Task { await handOff(post, model: model, play: false) } }
    func play(post: FeedPost, model: FeedModel) { Task { await handOff(post, model: model, play: true) } }
    private func handOff(_ post: FeedPost, model: FeedModel, play: Bool) async {
        let url = post.isVideo ? await model.videoURL(post) : model.originalURL(post)
        guard let url else { status = "This post has no media address yet."; return }
        let ext = URL(string: post.mediaUrl)?.pathExtension.lowercased() ?? ""
        await transfer(url, name: PCConnection.safeName("\(post.boardName.isEmpty ? "booru" : post.boardName)-\(post.postId).\(ext.isEmpty ? (post.isVideo ? "mp4" : "jpg") : ext)"), play: play)
    }
    private func transfer(_ url: URL, name: String, play: Bool) async {
        if !play && library?.root == nil { status = "Choose a folder first (Saved → Boards → On this iPhone), then save again."; return }
        working = true; status = play ? "Loading \(name) for the player…" : "Saving \(name) to your phone…"
        defer { working = false }
        do {
            var request = URLRequest(url: url)
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies().filter { cookie in
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return url.host == domain || url.host?.hasSuffix("." + domain) == true
            }
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) { request.setValue(value, forHTTPHeaderField: field) }
            let (temporary, response) = try await URLSession.shared.download(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let files = FileManager.default
            if play {
                let folder = files.temporaryDirectory.appendingPathComponent("feed-play", isDirectory: true)
                try? files.removeItem(at: folder)   // one file at a time; the previous one is no longer needed
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                let target = folder.appendingPathComponent(name)
                try files.moveItem(at: temporary, to: target)
                await webView.pauseAllMediaPlayback()
                library?.playDownloaded(target); status = ""
            } else {
                guard let root = library?.root else { throw CocoaError(.fileNoSuchFile) }
                let access = root.startAccessingSecurityScopedResource()
                defer { if access { root.stopAccessingSecurityScopedResource() } }
                let folder = root.appendingPathComponent("Booru Feed", isDirectory: true)
                try files.createDirectory(at: folder, withIntermediateDirectories: true)
                try files.moveItem(at: temporary, to: PCConnection.unique(name, in: folder))
                status = "Saved to “\(root.lastPathComponent)/Booru Feed”."
            }
        } catch {
            status = play ? "Could not load this for the player. Check the PC is online." : "Could not save to your phone: \(error.localizedDescription)"
        }
    }
}

struct FeedWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Shown by any tab that needs the PC while the app is not connected to it.
struct ConnectForm: View {
    @EnvironmentObject var browser: FeedBrowser
    @AppStorage("pcFeedAddress") private var address = PCConnection.defaultAddress
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Sheet-style pink card holding the address and the connect button.
                VStack(alignment: .leading, spacing: 12) {
                    Label("PC address", systemImage: "desktopcomputer").font(.headline)
                    TextField("https://your-pc.ts.net:8443/", text: $address)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("PC Booru Feed address")
                        .padding(14).foregroundStyle(.white)
                        .background(Color.ink, in: Capsule())
                    Button { if let url = PCConnection.url(address) { browser.connect(url) } } label: {
                        Label("Connect to Booru Feed", systemImage: "network").font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 50)
                            .overlay(Capsule().stroke(Color.ink, lineWidth: 2))
                    }.buttonStyle(.plain).disabled(PCConnection.url(address) == nil).opacity(PCConnection.url(address) == nil ? 0.4 : 1)
                    if PCConnection.url(address) == nil {
                        Text("Enter an HTTPS address without passwords or pairing codes in the URL.").font(.footnote)
                    }
                }
                .foregroundStyle(Color.ink)
                .padding(18)
                .background(Color.brand, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                VStack(alignment: .leading, spacing: 12) {
                    Text("Before connecting").font(.headline).foregroundStyle(Color.brand)
                    Text("Keep Booru Feed running on your PC with mobile access enabled. Connect Tailscale on both devices using the same account.")
                    Text("The first time, the app asks for the pairing code shown in the PC app’s mobile access settings. After that it reconnects on its own.")
                    Text("Home, Search, Videos, Manga and Saved all use this connection. Saved posts stream straight from the save folder on your PC.")
                }
                .font(.footnote).foregroundStyle(.white.opacity(0.8))
                .padding(18)
                .background(Color.panel, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            }.padding(16)
        }
        .background(Color.black)
    }
}
#endif
