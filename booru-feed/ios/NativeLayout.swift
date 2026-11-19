import Foundation

// Foundation-only layout rules for the redesigned grids, so the cloud check can test them with plain swiftc.

extension FeedPost: Hashable {
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    /// Width ÷ height of a masonry tile.
    var tileAspect: Double { Masonry.aspect(width: width, height: height, isVideo: isVideo) }
    /// Explore grid: landscape videos and very wide pictures get a wide tile.
    var isWideTile: Bool { width > 0 && height > 0 && width / height >= (isVideo ? 1.25 : 1.7) }
    var score: Double { raw["score"]?.number ?? 0 }
    var galleryCount: Int { raw["gallery"]?.array?.count ?? 0 }
}

enum Masonry {
    /// Clamped so very tall or very wide posts are cropped in the grid; a fallback when the board gave no size.
    static func aspect(width: Double, height: Double, isVideo: Bool) -> Double {
        guard width > 0, height > 0 else { return isVideo ? 16.0 / 9.0 : 0.75 }
        return min(2.0, max(0.5, width / height))
    }
    /// Each item goes to the column that is shortest so far. Appending items never moves earlier ones.
    static func columns(heights: [Double], count: Int) -> [[Int]] {
        var columns = Array(repeating: [Int](), count: max(1, count)), totals = Array(repeating: 0.0, count: max(1, count))
        for (index, height) in heights.enumerated() {
            var target = 0
            for column in totals.indices where totals[column] < totals[target] { target = column }
            columns[target].append(index); totals[target] += height
        }
        return columns
    }
}

/// Instagram-style explore rows: three tall cells, or a wide tile (two columns) beside one cell, alternating sides;
/// a wide tile seen among the first posts leads as a full-width hero. Rows are built in arrival order and never
/// change once made, so loading more posts only adds rows below.
enum ExploreLayout {
    enum Row: Equatable { case hero(Int), wide(wide: Int, cell: Int?, wideOnLeft: Bool), cells([Int]) }
    static func rows(wide: [Bool], complete: Bool) -> [Row] {
        var rows = [Row](), wides = [Int](), normals = [Int](), wideRows = 0, lastWasWide = false
        for index in wide.indices {
            if wide[index] { wides.append(index) } else { normals.append(index) }
            if wides.count > 2 { normals.append(wides.removeFirst()) }      // too many wide posts waiting: show the oldest as a normal cell
            while true {
                if rows.isEmpty {
                    if let first = wides.first { rows.append(.hero(first)); wides.removeFirst(); lastWasWide = true; continue }
                    if normals.count < 6 { break }                         // wait a little for a wide post to lead with
                }
                if !lastWasWide, let first = wides.first, let cell = normals.first {
                    rows.append(.wide(wide: first, cell: cell, wideOnLeft: wideRows % 2 == 0))
                    wides.removeFirst(); normals.removeFirst(); wideRows += 1; lastWasWide = true; continue
                }
                if normals.count >= 3 { rows.append(.cells(Array(normals.prefix(3)))); normals.removeFirst(3); lastWasWide = false; continue }
                break
            }
        }
        guard complete else { return rows }
        while let first = wides.first {
            wides.removeFirst()
            if let cell = normals.first { normals.removeFirst(); rows.append(.wide(wide: first, cell: cell, wideOnLeft: wideRows % 2 == 0)) }
            else { rows.append(.wide(wide: first, cell: nil, wideOnLeft: wideRows % 2 == 0)) }
            wideRows += 1
        }
        while !normals.isEmpty { rows.append(.cells(Array(normals.prefix(3)))); normals.removeFirst(min(3, normals.count)) }
        return rows
    }
}

/// Saved posts grouped by the board they came from, biggest first (the Boards page).
enum SavedBoards {
    struct Board: Equatable { let source: String; let name: String; let count: Int; let covers: [Int] }
    static func group(_ posts: [FeedPost]) -> [Board] {
        var order = [String](), names = [String: String](), counts = [String: Int](), covers = [String: [Int]]()
        for (index, post) in posts.enumerated() {
            let source = post.source
            if counts[source] == nil { order.append(source); names[source] = post.boardName.isEmpty ? (URL(string: source)?.host ?? source) : post.boardName }
            counts[source, default: 0] += 1
            if !post.isVideo, covers[source, default: []].count < 3 { covers[source, default: []].append(index) }
        }
        return order.map { Board(source: $0, name: names[$0] ?? $0, count: counts[$0] ?? 0, covers: covers[$0] ?? []) }
            .sorted { $0.count > $1.count }
    }
}
