import Foundation

@main
struct PCConnectionCheck {
    static func main() {
        assert(PCConnection.url(PCConnection.defaultAddress)?.port == 8443)
        assert(PCConnection.url("  https://100.64.1.2:8443/ \n")?.host == "100.64.1.2")
        for bad in ["http://pc.ts.net/", "file:///private", "javascript:alert(1)", "https:///", "https://user:password@pc.ts.net", "https://pc.ts.net/?token=secret", "https://pc.ts.net/#code", "https://pc.ts.net:0", "https://pc.ts.net:65536"] {
            assert(PCConnection.url(bad) == nil, "Accepted invalid address: \(bad)")
        }
        print("PC connection address checks passed.")
    }
}
