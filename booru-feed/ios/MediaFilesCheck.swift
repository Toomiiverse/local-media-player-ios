import Foundation

@main
struct MediaFilesCheck {
    static func main() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = base.appendingPathComponent("media")
        let outside = base.appendingPathComponent("media-other")
        try fm.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }
        for name in ["video10.MP4", "video2.mp4", "picture.png", "notes.txt", "nested/child.mov"] { try Data().write(to: root.appendingPathComponent(name)) }
        try Data().write(to: outside.appendingPathComponent("private.mp4"))
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        assert(!MediaFiles.contains(outside, in: root))
        assert(!MediaFiles.contains(root.appendingPathComponent("escape/private.mp4"), in: root))
        let rows = try MediaFiles.list(root, root: root)
        assert(rows.first?.kind == .folder)
        assert(rows.filter { $0.kind == .video }.map(\.name) == ["video2.mp4", "video10.MP4"])
        assert(rows.contains { $0.name == "notes.txt" && !$0.playable })
        assert(!rows.contains { $0.name == "escape" })
        let flat = try MediaFiles.shuffle(root, root: root, recursive: false)
        let recursive = try MediaFiles.shuffle(root, root: root, recursive: true)
        print("Flat: \(flat.total) \(flat.rows.map(\.name)); recursive: \(recursive.total) \(recursive.rows.map(\.name))")
        fflush(stdout)
        assert(flat.total == 3 && recursive.total == 4)
        for number in 0..<1100 { try Data().write(to: root.appendingPathComponent("item\(number).mp4")) }
        let large = try MediaFiles.shuffle(root, root: root, recursive: true)
        assert(large.total == 1104 && large.rows.count == 1000)
        assert(Set(large.rows.map(\.id)).count == 1000)
        do { _ = try MediaFiles.list(outside, root: root); assertionFailure("Escaped root") } catch {}
        let cancelled = Task { () throws -> MediaFiles.Sample in
            try await Task.sleep(nanoseconds: 10_000_000)
            return try MediaFiles.shuffle(root, root: root, recursive: true)
        }
        cancelled.cancel()
        do { _ = try await cancelled.value; assertionFailure("Ignored cancellation") } catch is CancellationError {} 
        try fm.removeItem(at: root)
        do { _ = try MediaFiles.shuffle(root, root: root, recursive: true); assertionFailure("Missing drive") } catch {}
        print("PASS: folder browsing, natural ordering, scope boundaries, recursive shuffle, bounded sample, cancellation and missing drive")
    }
}
