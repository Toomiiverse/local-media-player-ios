import Foundation

// Foundation-only pieces of the native feed, kept free of UIKit so the cloud check compiles and tests them with swiftc:
// JSON that round-trips the web app's shared state byte-for-byte (key order included), the exact same edits the web
// feed makes for like / dislike / hide / block / save, and the feed's small paging decisions.

// MARK: - Ordered JSON (matches JavaScript JSON.parse / JSON.stringify)

/// Any JSON value. Objects keep their key order, because the web app's caps (e.g. the first 200 reactions) depend on it.
indirect enum JSONValue: Equatable, Sendable {
    case null, bool(Bool), number(Double), string(String), array([JSONValue]), object([(String, JSONValue)])

    static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)): return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }
    subscript(key: String) -> JSONValue? {
        get { if case .object(let o) = self { return o.first { $0.0 == key }?.1 }; return nil }
        set {
            guard case .object(var o) = self else { return }
            if let i = o.firstIndex(where: { $0.0 == key }) { if let newValue { o[i].1 = newValue } else { o.remove(at: i) } }
            else if let newValue { o.append((key, newValue)) }   // a new key goes last, like JS {...o, [key]: v}
            self = .object(o)
        }
    }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var number: Double? { if case .number(let v) = self { return v }; return nil }
    var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    var entries: [(String, JSONValue)]? { if case .object(let v) = self { return v }; return nil }
    var strings: [String] { array?.compactMap(\.string) ?? [] }

    // JSON.stringify without spacing.
    var text: String { var out = ""; write(&out); return out }
    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let v): out += v ? "true" : "false"
        case .number(let v): out += JSONValue.format(v)
        case .string(let v): JSONValue.quote(v, &out)
        case .array(let v): out += "["; for (i, e) in v.enumerated() { if i > 0 { out += "," }; e.write(&out) }; out += "]"
        case .object(let v): out += "{"; for (i, (k, e)) in v.enumerated() { if i > 0 { out += "," }; JSONValue.quote(k, &out); out += ":"; e.write(&out) }; out += "}"
        }
    }
    static func format(_ v: Double) -> String {
        guard v.isFinite else { return "null" }
        if v == v.rounded(), abs(v) < 1e21 { return String(format: "%.0f", v) == "-0" ? "0" : String(format: "%.0f", v) }
        return "\(v)"
    }
    static func quote(_ s: String, _ out: inout String) {
        out += "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 || (0xD800...0xDFFF).contains(u.value) { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        out += "\""
    }

    // JSON.parse
    static func parse(_ text: String?) -> JSONValue? {
        guard let text else { return nil }
        var p = Parser(Array(text.utf8)); guard let v = p.value() else { return nil }
        p.space(); return p.i == p.b.count ? v : nil
    }
    private struct Parser {
        let b: [UInt8]; var i = 0
        init(_ b: [UInt8]) { self.b = b }
        mutating func space() { while i < b.count, [0x20, 0x0A, 0x0D, 0x09].contains(b[i]) { i += 1 } }
        mutating func literal(_ s: String) -> Bool { let u = Array(s.utf8); guard i + u.count <= b.count, Array(b[i..<i + u.count]) == u else { return false }; i += u.count; return true }
        mutating func value() -> JSONValue? {
            space(); guard i < b.count else { return nil }
            switch b[i] {
            case UInt8(ascii: "n"): return literal("null") ? .null : nil
            case UInt8(ascii: "t"): return literal("true") ? .bool(true) : nil
            case UInt8(ascii: "f"): return literal("false") ? .bool(false) : nil
            case UInt8(ascii: "\""): return str().map(JSONValue.string)
            case UInt8(ascii: "["):
                i += 1; var a = [JSONValue](); space()
                if i < b.count, b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }
                while true { guard let v = value() else { return nil }; a.append(v); space(); guard i < b.count else { return nil }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }; if b[i] == UInt8(ascii: "]") { i += 1; return .array(a) }; return nil }
            case UInt8(ascii: "{"):
                i += 1; var o = [(String, JSONValue)](); space()
                if i < b.count, b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }
                while true {
                    space(); guard i < b.count, b[i] == UInt8(ascii: "\""), let k = str() else { return nil }
                    space(); guard i < b.count, b[i] == UInt8(ascii: ":") else { return nil }; i += 1
                    guard let v = value() else { return nil }
                    if let dup = o.firstIndex(where: { $0.0 == k }) { o[dup].1 = v } else { o.append((k, v)) }   // JS keeps the first position, last value
                    space(); guard i < b.count else { return nil }
                    if b[i] == UInt8(ascii: ",") { i += 1; continue }; if b[i] == UInt8(ascii: "}") { i += 1; return .object(o) }; return nil
                }
            default:
                let start = i
                while i < b.count, "+-0123456789.eE".utf8.contains(b[i]) { i += 1 }
                return Double(String(decoding: b[start..<i], as: UTF8.self)).map(JSONValue.number)
            }
        }
        mutating func str() -> String? {
            i += 1; var scalars = String.UnicodeScalarView(), run = [UInt8]()
            func flush() { scalars.append(contentsOf: String(decoding: run, as: UTF8.self).unicodeScalars); run.removeAll() }
            while i < b.count {
                let c = b[i]
                if c == UInt8(ascii: "\"") { i += 1; flush(); return String(scalars) }
                if c == UInt8(ascii: "\\") {
                    flush(); i += 1; guard i < b.count else { return nil }
                    let e = b[i]; i += 1
                    switch e {
                    case UInt8(ascii: "n"): scalars.append("\n"); case UInt8(ascii: "r"): scalars.append("\r"); case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "b"): scalars.append("\u{08}"); case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "u"):
                        guard i + 4 <= b.count, var code = UInt32(String(decoding: b[i..<i + 4], as: UTF8.self), radix: 16) else { return nil }; i += 4
                        if (0xD800...0xDBFF).contains(code), i + 6 <= b.count, b[i] == UInt8(ascii: "\\"), b[i + 1] == UInt8(ascii: "u"),
                           let low = UInt32(String(decoding: b[i + 2..<i + 6], as: UTF8.self), radix: 16), (0xDC00...0xDFFF).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00); i += 6
                        }
                        scalars.append(Unicode.Scalar(code) ?? "\u{FFFD}")
                    default: scalars.append(Unicode.Scalar(e))
                    }
                } else { run.append(c); i += 1 }
            }
            return nil
        }
    }
}

// MARK: - Posts

/// A post as the PC sends it. Typed accessors for what the native feed reads; `raw` is the whole object, written back
/// unchanged wherever the web app stores posts (saved, liked-posts).
struct FeedPost: Identifiable, Equatable, Sendable {
    let raw: JSONValue
    var source: String { raw["source"]?.string ?? "" }
    var postId: Int { Int(raw["id"]?.number ?? 0) }
    var id: String { "\(source):\(postId)" }        // the web app's postKey
    var mediaUrl: String { raw["mediaUrl"]?.string ?? "" }
    var previewUrl: String { raw["previewUrl"]?.string ?? "" }
    var originalUrl: String { raw["originalUrl"]?.string ?? "" }
    var tagText: String { raw["tags"]?.string ?? "" }
    var tags: [String] { tagText.split(whereSeparator: \.isWhitespace).map(String.init) }
    var artist: String { raw["artist"]?.string ?? "" }
    var rating: String { raw["rating"]?.string ?? "" }
    var isVideo: Bool { raw["mediaType"]?.string == "video" }
    var width: Double { raw["width"]?.number ?? 0 }
    var height: Double { raw["height"]?.number ?? 0 }
    var url: String { raw["url"]?.string ?? "" }
    var boardName: String { raw["boardName"]?.string ?? "" }
    var videoPage: String { raw["videoPage"]?.string ?? "" }
    /// Tube-style posts only name a page; the playable file is looked up on the PC first (web: `tube`).
    var needsVideoLookup: Bool { isVideo && ((!url.isEmpty && videoPage == url) || source == "https://rule34.tube") }
}

// MARK: - Shared state edits (ported from src/BooruFeed.tsx so both clients write identical data)

enum SharedKeys {
    static let preferences = "booru-feed.preferences.v1", saved = "booru-feed.saved.v1", reactions = "booru-feed.reactions.v1"
    static let savedActivity = "booru-feed.saved-activity.v1", likedPosts = "booru-feed.liked-posts.v1", neverShow = "booru-feed.never-show.v1"
    static let ratings = "booru-feed.ratings.v1", mangaPreferences = "booru-feed.manga.preferences.v1"
    /// The value `setSharedItem` uses as `before` when the key was never written.
    static func empty(_ key: String) -> String { key.hasSuffix("saved.v1") ? "[]" : "{}" }
}

enum SharedEdit {
    /// web: normalTag
    static func normalTag(_ tag: String) -> String {
        tag.lowercased().replacingOccurrences(of: "[\\s_-]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    /// All stored reactions (valid entries, in order).
    static func reactions(_ text: String?) -> (liked: [(String, JSONValue)], disliked: [(String, JSONValue)]) {
        let value = JSONValue.parse(text)
        func side(_ name: String) -> [(String, JSONValue)] { (value?[name]?.entries ?? []).filter { $0.0.count <= 2200 && ($0.1.string?.count ?? 9999) <= 2000 } }
        return (side("liked"), side("disliked"))
    }
    /// The web app reads only the first 200 per side, so writes keep the newest 200: then both apps see the same set,
    /// and a new like is never the one that falls off the end.
    static let reactionCap = 200
    struct Reacted: Equatable { let reactions: String; let likedPosts: String?; let newLike: Bool }
    /// web react(post, kind): toggles one side and always clears the other; liked-posts follows likes.
    static func react(_ post: FeedPost, kind: String, reactions: String?, likedPosts: String?, fromVideos: Bool, now: Double) -> Reacted {
        var (liked, disliked) = Self.reactions(reactions)
        let key = post.id, tags = JSONValue.string(String(post.tagText.prefix(2000)))
        let wasLiked = liked.contains { $0.0 == key }
        if kind == "liked" {
            if wasLiked { liked.removeAll { $0.0 == key } } else { liked.removeAll { $0.0 == key }; liked.append((key, tags)) }
            disliked.removeAll { $0.0 == key }
        } else {
            if disliked.contains(where: { $0.0 == key }) { disliked.removeAll { $0.0 == key } } else { disliked.append((key, tags)) }
            liked.removeAll { $0.0 == key }
        }
        let out = JSONValue.object([("liked", .object(Array(liked.suffix(reactionCap)))), ("disliked", .object(Array(disliked.suffix(reactionCap))))]).text
        guard kind == "liked" || wasLiked else { return Reacted(reactions: out, likedPosts: nil, newLike: false) }
        let liking = kind == "liked" && !wasLiked
        var list = (JSONValue.parse(likedPosts)?.array ?? []).filter { item in
            guard let post = item["post"], post.entries != nil, let from = item["from"]?.string else { return false }
            return from == "feed" || from == "videos"
        }
        list.removeAll { FeedPost(raw: $0["post"] ?? .null).id == key }
        if liking { list.insert(.object([("post", post.raw), ("from", .string(fromVideos ? "videos" : "feed")), ("at", .number(now))]), at: 0) }
        return Reacted(reactions: out, likedPosts: JSONValue.array(Array(list.prefix(5000))).text, newLike: liking)
    }
    /// web hideForever: add the key once, keep the newest 20000.
    static func neverShow(_ post: FeedPost, current: String?) -> String {
        var keys = JSONValue.parse(current)?.strings ?? []
        if !keys.contains(post.id) { keys.append(post.id) }
        return JSONValue.array(keys.suffix(20000).map(JSONValue.string)).text
    }
    static func hidden(_ current: String?) -> Set<String> { Set(JSONValue.parse(current)?.strings ?? []) }
    /// web toggleBlocked (no board scope): toggle normalTag(tag) in preferences.blockedTags, keep the last 300.
    static func toggleBlocked(_ tag: String, preferences: String?) -> String {
        var prefs = JSONValue.parse(preferences) ?? .object([])
        if prefs.entries == nil { prefs = .object([]) }
        let name = normalTag(tag); guard !name.isEmpty else { return prefs.text }
        var blocked = (prefs["blockedTags"]?.strings ?? []).map(normalTag).filter { !$0.isEmpty }
        if blocked.contains(name) { blocked.removeAll { $0 == name } } else { blocked.append(name) }
        prefs["blockedTags"] = .array(Array(blocked.suffix(300)).map(JSONValue.string))
        return prefs.text
    }
    static func blocked(_ preferences: String?) -> Set<String> { Set((JSONValue.parse(preferences)?["blockedTags"]?.strings ?? []).map(normalTag)) }
    /// A post is shown unless hidden, or one of its tags (normalised) is blocked.
    static func visible(_ post: FeedPost, hidden: Set<String>, blocked: Set<String>) -> Bool {
        !hidden.contains(post.id) && !post.tags.contains { blocked.contains(normalTag($0)) }
    }
    /// web bookmark: saving puts the post first (once); removing filters it out. No cap.
    static func saved(_ post: FeedPost, removing: Bool, current: String?) -> String {
        var list = (JSONValue.parse(current)?.array ?? []).filter { FeedPost(raw: $0).id != post.id }
        if !removing { list.insert(post.raw, at: 0) }
        return JSONValue.array(list).text
    }
    static func isSaved(_ post: FeedPost, current: String?) -> Bool { (JSONValue.parse(current)?.array ?? []).contains { FeedPost(raw: $0).id == post.id } }
    /// web noteSavedActivity: per post {views, tags, likedAt?, savedAt?}, last 10000 entries.
    static func activity(_ post: FeedPost, kind: String, current: String?, now: Double) -> String {
        var entries = JSONValue.parse(current)?.entries ?? []
        var entry = entries.first { $0.0 == post.id }?.1 ?? .object([("views", .number(0)), ("tags", .string(String(post.tagText.prefix(2000))))])
        entries.removeAll { $0.0 == post.id }
        if kind == "view" { entry["views"] = .number((entry["views"]?.number ?? 0) + 1) }
        if kind == "like" { entry["likedAt"] = .number(now) }
        if kind == "save" { entry["savedAt"] = .number(now) }
        entries.append((post.id, entry))
        return JSONValue.object(Array(entries.suffix(10000))).text
    }
}

// MARK: - Search and quick filters (web filterPresets / tabFilters / togglePreset)

enum FeedFilters {
    struct Preset: Equatable { let tag: String, label: String }
    static let presets = [Preset(tag: "order:score", label: "Top scored"), Preset(tag: "order:favcount", label: "Most favourited"),
                          Preset(tag: "order:id_desc", label: "Newest first"), Preset(tag: "order:random", label: "Random"),
                          Preset(tag: "score:>100", label: "Well-loved only"), Preset(tag: "favcount:>100", label: "Popular only")]
    static let forYou = ["order:id_desc", "order:score", "order:favcount", "order:random", "score:>100", "favcount:>100"]
    static let videos = ["order:score", "order:favcount", "order:random", "score:>100"]
    static func terms(_ tags: String) -> [String] { tags.split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
    static func isOrder(_ tag: String) -> Bool { tag.hasPrefix("order:") || tag.hasPrefix("sort:") }
    /// web toggleQuickFilter: an ordering replaces any other ordering (a board honours one); count filters stack.
    static func toggle(_ preset: String, in tags: String) -> String {
        var list = terms(tags)
        if list.contains(preset) { list.removeAll { $0 == preset } }
        else {
            if isOrder(preset) { list.removeAll { isOrder($0) } }
            list.append(preset)
        }
        return list.joined(separator: ",")
    }
    /// web withoutOrders: what Random leaves of the search terms.
    static func withoutOrders(_ tags: String) -> String { terms(tags).filter { !isOrder($0) }.joined(separator: ",") }
    /// web: a quick filter (order/sort/score/favcount/window) means the paged fyp path instead of the ranked batch.
    static func isQuickFilter(_ tags: String) -> Bool { tags.range(of: "(?:^|[,\\s])(?:order|sort|score|favcount|window):", options: .regularExpression) != nil }
    /// web: Random replaces any order/sort term.
    static func withRandom(_ tags: String, random: Bool) -> String {
        guard random else { return tags }
        return (terms(tags).filter { !$0.hasPrefix("order:") && !$0.hasPrefix("sort:") } + ["order:random"]).joined(separator: ",")
    }
}

// MARK: - Manga search (web booruMangaRanking: titleMatches / rankTitleMatches)

enum MangaSearch {
    /// Words of a title or query: lower case, accents folded, punctuation dropped.
    static func words(_ text: String) -> [String] {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }
    /// Every word typed appears somewhere in the title, in any order.
    static func titleMatches(_ name: String, _ query: String) -> Bool {
        let title = words(name).joined(separator: " ")
        return words(query).allSatisfy { title.contains($0) }
    }
    /// A page of title results with full matches ahead of the provider's looser ones; order otherwise kept.
    static func fullMatchesFirst<T>(_ page: [T], query: String, name: (T) -> String) -> [T] {
        guard !words(query).isEmpty else { return page }
        return page.filter { titleMatches(name($0), query) } + page.filter { !titleMatches(name($0), query) }
    }
    /// What the search box means: "tag:x" and "artist:x" search tags, anything else searches titles.
    static func parse(_ typed: String) -> (term: String, tag: Bool) {
        let text = typed.trimmingCharacters(in: .whitespaces), lower = text.lowercased()
        if lower.hasPrefix("tag:") { return (String(text.dropFirst(4)).trimmingCharacters(in: .whitespaces), true) }
        if lower.hasPrefix("artist:") { return (lower, true) }
        return (text, false)
    }
    /// A tag in one spelling: lower case, accents folded, "-" "_" and runs of spaces as one space.
    static func tagForm(_ tag: String) -> String {
        tag.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
            .replacingOccurrences(of: "[-_\\s]+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
    /// A tag without its namespace: "female:glasses" and "glasses" are the same thing to someone searching.
    static func bareTag(_ tag: String) -> String {
        let form = tagForm(tag)
        guard let colon = form.firstIndex(of: ":"), colon != form.startIndex, form[..<colon].allSatisfy({ $0.isLetter }) else { return form }
        return String(form[form.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
    }
    /// web tagsMatch: every comma-separated tag is carried by the book, with or without a namespace on either side.
    static func tagsMatch(_ tags: [String], _ query: String) -> Bool {
        var have = Set<String>()
        for tag in tags { have.insert(tagForm(tag)); have.insert(bareTag(tag)) }
        let wanted = query.split(separator: ",").map { tagForm(String($0)) }.filter { !$0.isEmpty }
        return wanted.allSatisfy { have.contains($0) || (!$0.hasPrefix("artist:") && have.contains(bareTag($0))) }
    }
    /// A page with the titles matching most manga preference tags first; order otherwise kept.
    static func preferFirst<T>(_ page: [T], preferences: [String], tags: (T) -> [String]) -> [T] {
        let wanted = Set(preferences.map { tagForm($0) })
        guard !wanted.isEmpty else { return page }
        let rows = page.enumerated().map { (offset: $0.offset, item: $0.element, hits: Set(tags($0.element).map { tagForm($0) }).intersection(wanted).count) }
        return rows.sorted { $0.hits != $1.hits ? $0.hits > $1.hits : $0.offset < $1.offset }.map { $0.item }
    }
    /// web commonTags: too common to say much about a book, so a Similar search never starts from one.
    static let commonTags: Set<String> = ["translated", "english", "japanese", "chinese", "full color", "uncensored", "digital", "doujinshi", "manga", "rough translation", "big breasts", "sole male", "sole female", "group", "nakadashi", "blowjob", "stockings", "ahegao", "comedy", "straight", "oral"]
    /// What Similar searches for: the artist, else the first tag that says something about the book.
    static func similarTerm(_ tags: [String], common: Set<String>) -> String? {
        if let artist = tags.first(where: { $0.hasPrefix("artist:") }) { return artist }
        return (tags.first(where: { !common.contains(bareTag($0)) }) ?? tags.first).map { "tag:" + $0 }
    }
}

// MARK: - Paging

enum FeedPlanner {
    /// Ask for the next page when fewer than this many unseen posts remain below the current one.
    static let ahead = 12
    static func needsMore(count: Int, current: Int, loading: Bool, exhausted: Bool) -> Bool { !loading && !exhausted && count - current - 1 < ahead }
    /// How a post that was on screen for `ms` milliseconds is reported to the taste model.
    enum Leave: Equatable { case skip, view(ms: Int) }
    static func leave(after ms: Int) -> Leave { ms < 1500 ? .skip : .view(ms: min(ms, 120_000)) }
    /// Posts whose media is loaded around the current one (1 behind, 5 ahead).
    static func window(current: Int, count: Int) -> Range<Int> { max(0, current - 1)..<min(count, max(max(0, current - 1), current + 6)) }
}

// MARK: - Loopback stream proxy request parsing

/// The request VLC sends to the app's own 127.0.0.1 proxy: GET or HEAD /<token>/<id>, optionally with a Range.
/// Anything else (wrong token, other methods, huge or malformed heads, odd ranges) is refused.
enum LoopbackRequest {
    struct Head: Equatable { let method: String; let id: String; let range: String? }
    static let maxHead = 16384
    static func parse(_ data: Data, token: String) -> Head? {
        guard data.count <= maxHead, let text = String(data: data, encoding: .utf8), let end = text.range(of: "\r\n\r\n") else { return nil }
        let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD", parts[2].hasPrefix("HTTP/1.") else { return nil }
        let path = parts[1].split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 3, path[0].isEmpty, path[1] == token, !path[2].isEmpty, path[2].count <= 64,
              path[2].unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
        var range: String?
        for line in lines.dropFirst() where line.lowercased().hasPrefix("range:") {
            let value = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            guard value.range(of: "^bytes=(\\d+-\\d*|-\\d+)$", options: .regularExpression) != nil else { return nil }
            range = value
        }
        return Head(method: String(parts[0]), id: String(path[2]), range: range)
    }
}
