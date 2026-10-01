import Foundation

struct MediaFile: Identifiable, Sendable {
    enum Kind: String, Sendable { case folder, image, video, file }
    let url: URL
    let kind: Kind
    var id: String { url.path }
    var name: String { url.lastPathComponent }
    var playable: Bool { kind == .image || kind == .video }
}

enum MediaFiles {
    static let images = Set("jpg jpeg png gif webp avif bmp heic heif tiff tif".split(separator: " ").map(String.init))
    static let videos = Set("mp4 webm mkv mk3d avi mov m4v wmv asf flv f4v mpg mpeg mpe m2v mts m2ts ts vob ogv ogg 3gp 3g2 rm rmvb divx mxf nut dv hevc h264 h265".split(separator: " ").map(String.init))
    static let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    static func contains(_ url: URL, in root: URL) -> Bool {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let path = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        return url.isFileURL && path.starts(with: base)
    }

    static func entry(_ url: URL, root: URL) throws -> MediaFile? {
        guard contains(url, in: root) else { return nil }
        let values = try url.resourceValues(forKeys: keys)
        guard values.isSymbolicLink != true else { return nil }
        if values.isDirectory == true { return MediaFile(url: url, kind: .folder) }
        guard values.isRegularFile == true else { return nil }
        let ext = url.pathExtension.lowercased()
        return MediaFile(url: url, kind: images.contains(ext) ? .image : videos.contains(ext) ? .video : .file)
    }

    static func list(_ folder: URL, root: URL) throws -> [MediaFile] {
        guard contains(folder, in: root) else { throw CocoaError(.fileReadNoPermission) }
        let urls = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var rows = [MediaFile]()
        for url in urls {
            try Task.checkCancellation()
            if let row = try? entry(url, root: root) { rows.append(row) }
        }
        return rows.sorted {
            if ($0.kind == .folder) != ($1.kind == .folder) { return $0.kind == .folder }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    struct Sample: Sendable { let rows: [MediaFile]; let total: Int; let skipped: Int }
    static func shuffle(_ folder: URL, root: URL, recursive: Bool) throws -> Sample {
        guard contains(folder, in: root) else { throw CocoaError(.fileReadNoPermission) }
        // Verify a disconnected or inaccessible root rather than reporting an empty shuffle.
        _ = try folder.resourceValues(forKeys: [.isDirectoryKey])
        var rows = [MediaFile](), total = 0, skipped = 0
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in skipped += 1; return true }) else { throw CocoaError(.fileReadUnknown) }
        for case let url as URL in walker {
            try Task.checkCancellation()
            guard let row = try? entry(url, root: root) else { walker.skipDescendants(); continue }
            if row.kind == .folder {
                if !recursive || walker.level >= 64 { walker.skipDescendants() }
                continue
            }
            guard row.playable else { continue }
            total += 1
            // ponytail: cap shuffle at 1,000 sampled files; browse folders to reach every file.
            let slot = total <= 1000 ? total - 1 : Int.random(in: 0..<total)
            if slot < rows.count { rows[slot] = row } else if slot < 1000 { rows.append(row) }
        }
        return Sample(rows: rows.shuffled(), total: total, skipped: skipped)
    }
}
