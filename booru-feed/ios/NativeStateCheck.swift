import Foundation

// Byte-level compatibility with the web feed's shared state. Run: swiftc NativeState.swift NativeStateCheck.swift
@main
struct NativeStateCheck {
    static func post(_ id: Int, tags: String = "a b", video: Bool = false) -> FeedPost {
        FeedPost(raw: JSONValue.parse(#"{"id":\#(id),"source":"https://b.org","tags":"\#(tags)","mediaType":"\#(video ? "video" : "image")","url":"https://b.org/p/\#(id)","mediaUrl":"https://b.org/\#(id).jpg","previewUrl":"","width":1,"height":2,"rating":"g","artist":"x","score":3,"createdAt":"2026-01-01"}"#)!)
    }
    static func main() {
        // JSON round trip keeps key order, escapes like JSON.stringify, and survives unknown fields.
        let sample = #"{"z":1,"a":{"y":[1,2.5,"é\"\n",null,true]},"u":"\u0001","big":12345678901234,"neg":-0}"#
        assert(JSONValue.parse(sample)!.text == #"{"z":1,"a":{"y":[1,2.5,"é\"\n",null,true]},"u":"\u0001","big":12345678901234,"neg":0}"#)
        assert(JSONValue.parse(#"{"a":1,"b":2,"a":3}"#)!.text == #"{"a":3,"b":2}"#)       // JS: first position, last value
        assert(JSONValue.parse("[1,") == nil && JSONValue.parse("{} x") == nil)
        assert(JSONValue.parse(#""\ud83d\ude00""#)!.string == "😀")

        // Like: adds at the end, clears dislike, and the liked list gets the post first.
        let p = post(7)
        var r = SharedEdit.react(p, kind: "liked", reactions: #"{"liked":{"x:1":"t"},"disliked":{"https://b.org:7":"a b"}}"#, likedPosts: nil, fromVideos: false, now: 5)
        assert(r.reactions == #"{"liked":{"x:1":"t","https://b.org:7":"a b"},"disliked":{}}"#, r.reactions)
        assert(r.newLike && JSONValue.parse(r.likedPosts)!.array!.first!["at"]!.number == 5)
        assert(JSONValue.parse(r.likedPosts)!.array!.first!["from"]!.string == "feed")
        // Unlike removes from both.
        r = SharedEdit.react(p, kind: "liked", reactions: r.reactions, likedPosts: r.likedPosts, fromVideos: false, now: 6)
        assert(r.reactions == #"{"liked":{"x:1":"t"},"disliked":{}}"# && r.likedPosts == "[]" && !r.newLike)
        // Dislike on a liked post: removes the like and its liked-post entry; dislike toggles off again.
        let liked = SharedEdit.react(p, kind: "liked", reactions: nil, likedPosts: nil, fromVideos: true, now: 1)
        r = SharedEdit.react(p, kind: "disliked", reactions: liked.reactions, likedPosts: liked.likedPosts, fromVideos: true, now: 2)
        assert(r.reactions == #"{"liked":{},"disliked":{"https://b.org:7":"a b"}}"# && r.likedPosts == "[]")
        r = SharedEdit.react(p, kind: "disliked", reactions: r.reactions, likedPosts: nil, fromVideos: false, now: 3)
        assert(r.reactions == #"{"liked":{},"disliked":{}}"# && r.likedPosts == nil)
        // Over the web app's 200 cap: a new like is kept (newest 200 written), so the heart fills and the web sees it too.
        let many = "{\"liked\":{" + (0..<250).map { "\"k:\($0)\":\"t\"" }.joined(separator: ",") + "},\"disliked\":{}}"
        assert(SharedEdit.reactions(many).liked.count == 250)
        let capped = SharedEdit.react(p, kind: "liked", reactions: many, likedPosts: nil, fromVideos: false, now: 9)
        let kept = SharedEdit.reactions(capped.reactions).liked
        assert(kept.count == 200 && kept.last!.0 == "https://b.org:7" && kept.first!.0 == "k:51")

        // Hide forever: once, newest kept.
        assert(SharedEdit.neverShow(p, current: #"["a"]"#) == #"["a","https://b.org:7"]"#)
        assert(SharedEdit.neverShow(p, current: #"["https://b.org:7"]"#) == #"["https://b.org:7"]"#)

        // Block tag toggles the normalised name and keeps every other preference untouched, in order.
        let prefs = #"{"sources":["s"],"blockedTags":["foo bar"],"tags":"","layout":"focus"}"#
        let blocked = SharedEdit.toggleBlocked("Big_Cat", preferences: prefs)
        assert(blocked == #"{"sources":["s"],"blockedTags":["foo bar","big cat"],"tags":"","layout":"focus"}"#, blocked)
        assert(SharedEdit.toggleBlocked("FOO-bar", preferences: prefs) == #"{"sources":["s"],"blockedTags":[],"tags":"","layout":"focus"}"#)
        assert(!SharedEdit.visible(post(1, tags: "big_cat x"), hidden: [], blocked: SharedEdit.blocked(blocked)))
        assert(SharedEdit.visible(post(1, tags: "dog"), hidden: [], blocked: SharedEdit.blocked(blocked)))
        assert(!SharedEdit.visible(p, hidden: ["https://b.org:7"], blocked: []))

        // Save puts the post first once; remove filters it out.
        let saved = SharedEdit.saved(p, removing: false, current: SharedEdit.saved(post(1), removing: false, current: nil))
        assert(JSONValue.parse(saved)!.array!.map { FeedPost(raw: $0).postId } == [7, 1] && SharedEdit.isSaved(p, current: saved))
        assert(JSONValue.parse(SharedEdit.saved(p, removing: true, current: saved))!.array!.count == 1)

        // Quick filters and paging.
        assert(FeedFilters.toggle("order:score", in: "cat, dog") == "cat,dog,order:score")
        assert(FeedFilters.toggle("order:score", in: "cat,order:score") == "cat")
        assert(FeedFilters.toggle("order:favcount", in: "cat,order:score") == "cat,order:favcount")   // one ordering replaces another
        assert(FeedFilters.toggle("score:>100", in: "order:score") == "order:score,score:>100")        // count filters stack
        assert(FeedFilters.withoutOrders("cat,order:score,score:>100,sort:id") == "cat,score:>100")
        assert(MangaSearch.titleMatches("Summer of Blue: Vol. 2", "blue summer") && MangaSearch.titleMatches("Café Élan", "cafe elan"))
        assert(!MangaSearch.titleMatches("Summer of Blue", "blue winter") && MangaSearch.titleMatches("Anything", "  "))
        assert(MangaSearch.fullMatchesFirst(["Blue Sky", "Summer of Blue", "Red"], query: "blue summer") { $0 } == ["Summer of Blue", "Blue Sky", "Red"])
        assert(MangaSearch.tagsMatch(["artist:quiet_ink", "female:glasses", "school-uniform"], "glasses") && MangaSearch.tagsMatch(["female:glasses", "school-uniform"], "Female:Glasses, school uniform"))
        assert(!MangaSearch.tagsMatch(["female:glasses"], "artist:glasses") && !MangaSearch.tagsMatch(["glasses"], "glasses, swimsuit") && MangaSearch.tagsMatch(["artist:quiet_ink"], "artist:quiet ink"))
        assert(MangaSearch.preferFirst(["a", "b", "c"], preferences: ["Storm"], tags: { $0 == "c" ? ["storm"] : [] }) == ["c", "a", "b"])
        assert(MangaSearch.similarTerm(["translated", "artist:quiet ink", "storm"], common: MangaSearch.commonTags) == "artist:quiet ink")
        assert(MangaSearch.similarTerm(["translated", "storm"], common: MangaSearch.commonTags) == "tag:storm" && MangaSearch.similarTerm([], common: MangaSearch.commonTags) == nil)
        assert(MangaSearch.parse(" tag: Glasses ") == ("Glasses", true) && MangaSearch.parse("Artist:Quiet Ink") == ("artist:quiet ink", true) && MangaSearch.parse("blue") == ("blue", false))
        assert(FeedFilters.isQuickFilter("cat,score:>100") && !FeedFilters.isQuickFilter("cat"))
        assert(FeedFilters.withRandom("cat,order:score", random: true) == "cat,order:random")
        assert(FeedPlanner.needsMore(count: 10, current: 0, loading: false, exhausted: false))
        assert(!FeedPlanner.needsMore(count: 30, current: 5, loading: false, exhausted: false))
        assert(FeedPlanner.leave(after: 900) == .skip && FeedPlanner.leave(after: 4000) == .view(ms: 4000))
        assert(FeedPlanner.window(current: 0, count: 3) == 0..<3 && FeedPlanner.window(current: 5, count: 100) == 4..<11)
        // Loopback proxy: only the right token, GET/HEAD, sane ranges. ("|" stands for CRLF.)
        func head(_ text: String) -> Data { Data(text.replacingOccurrences(of: "|", with: "\r\n").utf8) }
        let token = "abc123"
        assert(LoopbackRequest.parse(head("GET /abc123/f00d HTTP/1.1|Host: 127.0.0.1|Range: bytes=100-||"), token: token) == LoopbackRequest.Head(method: "GET", id: "f00d", range: "bytes=100-"))
        assert(LoopbackRequest.parse(head("HEAD /abc123/f00d HTTP/1.1||"), token: token)?.range == nil)
        assert(LoopbackRequest.parse(head("HEAD /abc123/f00d HTTP/1.1||"), token: token) != nil)
        assert(LoopbackRequest.parse(head("GET /wrong/f00d HTTP/1.1||"), token: token) == nil)
        assert(LoopbackRequest.parse(head("POST /abc123/f00d HTTP/1.1||"), token: token) == nil)
        assert(LoopbackRequest.parse(head("GET /abc123/../x HTTP/1.1||"), token: token) == nil)
        assert(LoopbackRequest.parse(head("GET /abc123/f00d HTTP/1.1|Range: bytes=1-2,5-6||"), token: token) == nil)
        assert(LoopbackRequest.parse(head("GET /abc123/f00d HTTP/1.1|"), token: token) == nil)   // head not finished
        assert(LoopbackRequest.parse(head("GET /abc123/f00d HTTP/1.1|X: " + String(repeating: "a", count: 17000) + "||"), token: token) == nil)
        // Masonry: shortest column wins, and appending never moves earlier items.
        assert(Masonry.columns(heights: [3, 1, 1, 1], count: 2) == [[0], [1, 2, 3]])
        assert(Masonry.columns(heights: [3, 1, 1], count: 2) == [[0], [1, 2]])
        assert(Masonry.aspect(width: 0, height: 0, isVideo: false) == 0.75 && Masonry.aspect(width: 100, height: 1000, isVideo: false) == 0.5)
        // Explore rows: a wide post among the first leads as the hero; rows already made never change.
        let mixed = [false, false, true, false, false, false, false]
        assert(ExploreLayout.rows(wide: mixed, complete: false) == [.hero(2), .cells([0, 1, 3]), .cells([4, 5, 6])])
        assert(ExploreLayout.rows(wide: Array(mixed.prefix(4)), complete: false) == [.hero(2), .cells([0, 1, 3])])
        assert(ExploreLayout.rows(wide: [false, false, false, false, false, false, true, false], complete: false) == [.cells([0, 1, 2]), .cells([3, 4, 5]), .wide(wide: 6, cell: 7, wideOnLeft: true)])
        assert(ExploreLayout.rows(wide: [true, true], complete: true) == [.hero(0), .wide(wide: 1, cell: nil, wideOnLeft: true)])
        assert(ExploreLayout.rows(wide: [false, false], complete: false).isEmpty && ExploreLayout.rows(wide: [false, false], complete: true) == [.cells([0, 1])])
        // Boards: saved posts grouped by where they came from.
        let boards = SavedBoards.group([post(1), post(2, video: true)])
        assert(boards.count == 1 && boards[0].count == 2 && boards[0].name == "b.org" && boards[0].covers == [0])
        print("Native feed state checks passed.")
    }
}
