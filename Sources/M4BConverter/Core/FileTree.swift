import Foundation

/// One walk of the files and folders the user chose, shared by everything that has to find
/// things in them.
///
/// There were two copies of this: `AudiobookScanner.collect` looking for folders of MP3s and
/// `ExistingBookChecker.collect` looking for `.m4b` files, each with its own visited set, its
/// own symlink canonicalisation, its own `.skipsHiddenFiles` and its own natural ordering.
/// The second one's comment even said "the visited set is the scanner's". Two copies means
/// the next traversal fix — and every one of these clauses IS a fix, made once because a
/// real tree broke something — has to be made twice.
public enum FileTree {
    /// Visits `roots` in the order given, and everything beneath them, once each.
    ///
    /// `visitDirectory` is handed each directory and the entries directly inside it, already
    /// sorted naturally, and answers whether to descend into it. `visitFile` is handed each
    /// plain file, including a file chosen directly as a root — which is why the checker can
    /// accept "this one book" as readily as a shelf.
    ///
    /// **Nothing is visited twice.** `fileExists(atPath:isDirectory:)` follows symlinks, so
    /// without the visited set a tree containing a link to itself or to an ancestor is
    /// infinitely deep — a crash, or a UI wedged with `isScanning` stuck true. The same set
    /// stops a folder dropped alongside one of its own children being walked twice, and the
    /// file set stops a book chosen alongside the folder that holds it being checked twice.
    /// Paths are canonicalised through `resolvingSymlinksInPath` so the two spellings of one
    /// directory compare equal; iCloud-synced Desktop and Documents folders are symlinks, so
    /// links inside a dropped tree are ordinary Mac behaviour.
    ///
    /// **Order is the order a person would read.** Each directory's children come back in
    /// natural order, so "Chapter 2" precedes "Chapter 10", and the roots keep the order they
    /// were given — which for a multi-folder drop is the order the user picked them in.
    public static func walk(_ roots: [URL],
                            visitFile: (URL) -> Void = { _ in },
                            visitDirectory: (URL, [URL]) -> Bool) {
        let manager = FileManager.default
        var visitedFolders: Set<String> = []
        var seenFiles: Set<String> = []

        func canonicalPath(_ url: URL) -> String {
            url.resolvingSymlinksInPath().standardized.path
        }

        func walk(_ url: URL) {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
            guard isDirectory.boolValue else {
                guard seenFiles.insert(canonicalPath(url)).inserted else { return }
                visitFile(url)
                return
            }
            guard visitedFolders.insert(canonicalPath(url)).inserted else { return }
            let children = ((try? manager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? [])
                .sorted { naturalLess($0.path, $1.path) }
            guard visitDirectory(url, children) else { return }
            for child in children { walk(child) }
        }

        for root in roots { walk(root) }
    }
}
