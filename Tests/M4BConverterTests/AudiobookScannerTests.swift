import Foundation
import Testing
@testable import M4BConverter

private func makeTree(_ layout: [String]) throws -> URL {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("scan-\(UUID().uuidString)")
    for relative in layout {
        let file = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data().write(to: file)
    }
    return root
}

@Test func flatFolderOfMP3sIsOneBook() throws {
    let root = try makeTree(["Frankenstein/Part01.mp3", "Frankenstein/Part02.mp3",
                             "Frankenstein/cover.jpg"])
    defer { try? FileManager.default.removeItem(at: root) }

    let books = AudiobookScanner().scan([root.appendingPathComponent("Frankenstein")])
    #expect(books.count == 1)
    #expect(books[0].files.count == 2)
    #expect(books[0].name == "Frankenstein")
}

@Test func nestedSagaYieldsOneBookPerSubfolder() throws {
    let root = try makeTree([
        "Saga/0 Ivanhoe/a.mp3", "Saga/0 Ivanhoe/b.mp3",
        "Saga/1 Moby-Dick/a.mp3",
    ])
    defer { try? FileManager.default.removeItem(at: root) }

    let books = AudiobookScanner().scan([root.appendingPathComponent("Saga")])
    #expect(books.count == 2)
    #expect(books.map(\.name).sorted() == ["0 Ivanhoe", "1 Moby-Dick"])
}

@Test func recursionStopsAtTheFirstLevelHoldingMP3s() throws {
    let root = try makeTree(["Book/a.mp3", "Book/extras/bonus.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }

    let books = AudiobookScanner().scan([root.appendingPathComponent("Book")])
    #expect(books.count == 1)
    #expect(books[0].files.count == 1)
}

@Test func filesWithinABookAreNaturallySorted() throws {
    let root = try makeTree(["B/Chapter 10.mp3", "B/Chapter 2.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }

    let books = AudiobookScanner().scan([root.appendingPathComponent("B")])
    #expect(books[0].files.map(\.lastPathComponent) == ["Chapter 2.mp3", "Chapter 10.mp3"])
}

@Test func foldersWithoutAudioAreIgnored() throws {
    let root = try makeTree(["Empty/readme.txt"])
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(AudiobookScanner().scan([root.appendingPathComponent("Empty")]).isEmpty)
}

// `fileExists(atPath:isDirectory:)` follows symlinks, and `collect` recursed with no
// record of where it had already been. A folder holding a link back to itself or to an
// ancestor therefore recursed until the stack overflowed — a crash, or a UI wedged with
// `isScanning` stuck true. iCloud-synced Desktop and Documents folders are symlinks, so
// links inside a dropped tree are ordinary Mac behaviour.
@Test func aSymlinkCycleDoesNotRecurseForever() throws {
    let root = try makeTree(["Series/Book/a.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }
    let series = root.appendingPathComponent("Series")
    let manager = FileManager.default
    // A link back to the folder that contains it, and one pointing at itself.
    try manager.createSymbolicLink(at: series.appendingPathComponent("loop"),
                                   withDestinationURL: series)
    try manager.createSymbolicLink(at: series.appendingPathComponent("self"),
                                   withDestinationURL: series.appendingPathComponent("self"))

    let books = AudiobookScanner().scan([series])
    #expect(books.count == 1)
    #expect(books[0].name == "Book")
}

// A link to an ancestor several levels up is the same cycle wearing a hat.
@Test func aSymlinkToAnAncestorDoesNotRecurseForever() throws {
    let root = try makeTree(["Library/Series/Book/a.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }
    // Beside the book rather than inside it: recursion stops at the first level holding
    // MP3s, so a link within the book folder would never be followed.
    try FileManager.default.createSymbolicLink(
        at: root.appendingPathComponent("Library/Series/up"), withDestinationURL: root)

    let books = AudiobookScanner().scan([root])
    #expect(books.count == 1)
    #expect(books[0].name == "Book")
}

// The same directory can arrive as two different URLs: the one the user dropped,
// and the one recursion discovers with symlinks resolved (/var -> /private/var).
// Downstream dedup compares URLs for equality, so the scanner must canonicalise.
@Test func droppingAParentAndItsChildYieldsOneCanonicalFolder() throws {
    let root = try makeTree(["Frankenstein/Part01.mp3", "Frankenstein/Part02.mp3"])
    defer { try? FileManager.default.removeItem(at: root) }

    let books = AudiobookScanner().scan([root, root.appendingPathComponent("Frankenstein")])
    // One folder, scanned once: the visited set that keeps a symlink cycle finite also
    // stops the same directory being probed and queued twice when it is reached twice.
    #expect(books.count == 1)
    #expect(Set(books.map(\.folder.path)).count == 1)
    #expect(books.allSatisfy { book in
        book.files.allSatisfy { $0.path.hasPrefix(book.folder.path) }
    })
    #expect(books.allSatisfy { book in
        book.files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) }
    })
}
