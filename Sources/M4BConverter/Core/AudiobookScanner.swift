import Foundation

public struct BookCandidate: Sendable, Equatable, Identifiable {
    public var id: URL { folder }
    public var folder: URL
    public var files: [URL]
    public var name: String { folder.lastPathComponent }
}

public struct AudiobookScanner: Sendable {
    public static let audioExtensions: Set<String> = ["mp3"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png"]

    public init() {}

    /// Every folder of MP3s under the chosen folders, one book each.
    ///
    /// The walk — the visited set that keeps a symlink cycle finite, the hidden-file skip,
    /// the natural ordering — is `FileTree`'s, shared with the existing-books check rather
    /// than written out a second time here. What is this scanner's own is the two decisions
    /// below: what counts as audio, and that a level holding any of it is a book rather than
    /// a shelf.
    public func scan(_ urls: [URL]) -> [BookCandidate] {
        var found: [BookCandidate] = []
        FileTree.walk(urls) { folder, children in
            // Already in natural order: `FileTree.walk` sorts each directory's children and
            // this only removes entries from that list, so a second sort would be work with
            // no effect on the result.
            let audio = children
                .filter { Self.audioExtensions.contains($0.pathExtension.lowercased()) }
            guard !audio.isEmpty else { return true }
            // Canonicalise: the same directory can arrive as two different URLs — the
            // one the user dropped, and the one discovered by recursion, which resolves
            // through symlinks like /var -> /private/var. Without this, dropping a
            // parent and one of its children yields the same book twice, and equality
            // -based dedup downstream cannot tell they match. iCloud-synced Desktop and
            // Documents folders are symlinks too, so this is ordinary Mac behaviour.
            let canonical = folder.resolvingSymlinksInPath()
            found.append(BookCandidate(
                folder: canonical,
                files: audio.map { canonical.appendingPathComponent($0.lastPathComponent) }))
            return false  // stop recursing: this level is the book
        }
        return found.sorted { naturalLess($0.folder.path, $1.folder.path) }
    }

    public func coverImage(in folder: URL) -> URL? {
        let children = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return children
            .filter { Self.imageExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { naturalLess($0.lastPathComponent, $1.lastPathComponent) }
            .first
    }
}
