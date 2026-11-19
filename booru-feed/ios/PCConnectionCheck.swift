import Foundation

@main
struct PCConnectionCheck {
    static func main() {
        assert(PCConnection.url(PCConnection.defaultAddress)?.port == 8443)
        assert(PCConnection.url("  https://100.64.1.2:8443/ \n")?.host == "100.64.1.2")
        for bad in ["http://pc.ts.net/", "file:///private", "javascript:alert(1)", "https:///", "https://user:password@pc.ts.net", "https://pc.ts.net/?token=secret", "https://pc.ts.net/#code", "https://pc.ts.net:0", "https://pc.ts.net:65536"] {
            assert(PCConnection.url(bad) == nil, "Accepted invalid address: \(bad)")
        }
        assert(PCConnection.safeName("e621-123.mp4") == "e621-123.mp4")
        assert(PCConnection.safeName("../../etc/passwd") == "passwd")
        assert(PCConnection.safeName("..hidden.jpg") == "hidden.jpg")
        assert(PCConnection.safeName("a b/c:d?.png") == "c_d_.png")
        assert(PCConnection.safeName("") == "booru-media" && PCConnection.safeName("...") == "booru-media")
        assert(PCConnection.safeName(String(repeating: "x", count: 300) + ".mp4").count == 120)
        let folder = URL(fileURLWithPath: "/tmp/feed"), taken: Set<String> = ["/tmp/feed/a.mp4", "/tmp/feed/a (2).mp4"]
        assert(PCConnection.unique("a.mp4", in: folder, exists: { taken.contains($0.path) }).lastPathComponent == "a (3).mp4")
        assert(PCConnection.unique("b", in: folder, exists: { _ in false }).lastPathComponent == "b")
        print("PC connection address checks passed.")
    }
}
