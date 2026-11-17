import Foundation
import Testing
@testable import M4BConverter

private func track(_ name: String, tags: [String: String] = [:]) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), estimatedDuration: 10, tags: tags)
}

@MainActor
private func book(in folder: String, titled title: String,
                  destination: OutputDestination = .besideSource) -> Book {
    let book = Book(folder: URL(fileURLWithPath: folder),
                    tracks: [track("a.mp3", tags: ["album": title])],
                    defaultDestination: destination)
    return book
}

/// A `UserDefaults` of its own, so a test can neither read nor overwrite the setting the
/// person running the suite has chosen in the app.
private func scratchDefaults() -> (UserDefaults, () -> Void) {
    let name = "m4b-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    return (defaults, { defaults.removePersistentDomain(forName: name) })
}

// MARK: - Resolution

// The bug this feature exists for: a nested book writes into its parent. Dropping
// `Audiobooks/Waverley Novels by Walter Scott` put all six .m4b files inside the saga folder
// instead of in the library root.
@Test @MainActor func outputURLHonoursAFixedDestination() {
    let library = URL(fileURLWithPath: "/Audiobooks")
    let nested = book(in: "/Audiobooks/Waverley Novels by Walter Scott/Ivanhoe",
                      titled: "Ivanhoe", destination: .fixed(library))
    #expect(nested.outputURL.path == "/Audiobooks/Ivanhoe.m4b")

    // And the old behaviour is still the old behaviour.
    let beside = book(in: "/Audiobooks/Waverley Novels by Walter Scott/Ivanhoe", titled: "Ivanhoe")
    #expect(beside.outputURL.path == "/Audiobooks/Waverley Novels by Walter Scott/Ivanhoe.m4b")
}

// A fixed destination must not weaken the title cleaning: `Rob Roy: The Waverley Novels,
// Book 4` carries a colon, and an album tag can carry a slash. Either one reaching the
// path unchanged would put the file somewhere other than the folder the user picked —
// a slash makes it a subdirectory that does not exist, so the write fails outright.
@Test @MainActor func aFixedDestinationStillCleansTheTitle() {
    let library = URL(fileURLWithPath: "/Audiobooks")
    let colon = book(in: "/src/Rob Roy", titled: "Rob Roy: The Waverley Novels, Book 4",
                     destination: .fixed(library))
    #expect(colon.outputURL.path == "/Audiobooks/Rob Roy- The Waverley Novels, Book 4.m4b")
    #expect(colon.outputURL.deletingLastPathComponent().path == "/Audiobooks")

    let slash = book(in: "/src/X", titled: "AC/DC Live", destination: .fixed(library))
    #expect(slash.outputURL.path == "/Audiobooks/AC-DC Live.m4b")

    // The empty-title fallback survives too: the folder name, not an unnamed ".m4b".
    let untitled = book(in: "/src/Nameless", titled: "", destination: .fixed(library))
    untitled.title = ""
    #expect(untitled.outputURL.path == "/Audiobooks/Nameless.m4b")
}

@Test @MainActor func aPerBookOverrideBeatsTheAppWideDefault() {
    let book = book(in: "/Audiobooks/Saga/Ivanhoe", titled: "Ivanhoe",
                    destination: .fixed(URL(fileURLWithPath: "/Audiobooks")))
    #expect(book.outputURL.path == "/Audiobooks/Ivanhoe.m4b")

    book.destinationOverride = .fixed(URL(fileURLWithPath: "/Volumes/Media/Audiobooks"))
    #expect(book.outputURL.path == "/Volumes/Media/Audiobooks/Ivanhoe.m4b")

    // "Beside source folder" is a real choice, not just the absence of one: it has to be
    // selectable per book even when the app-wide setting is a fixed folder.
    book.destinationOverride = .besideSource
    #expect(book.outputURL.path == "/Audiobooks/Saga/Ivanhoe.m4b")

    // And clearing the override returns the book to the app-wide setting.
    book.destinationOverride = nil
    #expect(book.outputURL.path == "/Audiobooks/Ivanhoe.m4b")
}

// MARK: - Push-down

// Changing the app-wide setting has to move the books already in the queue, or the user
// changes it, looks at the inspector and sees the old path — while a book that was
// deliberately pointed somewhere else must stay where it was put.
@Test @MainActor func changingTheDefaultMovesInheritingBooksAndLeavesOverridesAlone() {
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    let library = URL(fileURLWithPath: NSTemporaryDirectory())

    let model = AppModel(defaults: defaults)
    let inheriting = book(in: "/Audiobooks/Saga/Ivanhoe", titled: "Ivanhoe")
    let overridden = book(in: "/Audiobooks/Saga/Moby-Dick", titled: "Moby-Dick")
    overridden.destinationOverride = .fixed(URL(fileURLWithPath: "/Volumes/Elsewhere"))
    model.books = [inheriting, overridden]

    #expect(model.setDefaultDestination(.fixed(library)) == nil)

    #expect(model.defaultDestination == .fixed(library))
    #expect(inheriting.defaultDestination == .fixed(library))
    #expect(inheriting.outputURL == library.appendingPathComponent("Ivanhoe.m4b"))
    // The override still wins, and is untouched.
    #expect(overridden.destinationOverride == .fixed(URL(fileURLWithPath: "/Volumes/Elsewhere")))
    #expect(overridden.outputURL.path == "/Volumes/Elsewhere/Moby-Dick.m4b")

    // Books added afterwards inherit it as well, without a second push.
    let later = Book(folder: URL(fileURLWithPath: "/Audiobooks/Saga/Bleak House"),
                     tracks: [track("a.mp3", tags: ["album": "Bleak House"])],
                     defaultDestination: model.defaultDestination)
    #expect(later.outputURL == library.appendingPathComponent("Bleak House.m4b"))
}

// MARK: - Persistence

@Test func theDestinationSettingRoundTripsThroughUserDefaults() {
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }

    // Unset means the behaviour the app has always had.
    #expect(OutputDestination.fromDefaults(defaults) == .besideSource)

    let library = URL(fileURLWithPath: "/Users/someone/Audiobooks", isDirectory: true)
    OutputDestination.fixed(library).writeToDefaults(defaults)
    #expect(defaults.string(forKey: OutputDestination.defaultsKey) == "/Users/someone/Audiobooks")
    #expect(OutputDestination.fromDefaults(defaults) == .fixed(library))
    // The stored spelling has no trailing slash and the read-back one does; they must
    // still be the same destination, or the settings picker shows nothing selected.
    #expect(OutputDestination.fromDefaults(defaults)
            == .fixed(URL(fileURLWithPath: "/Users/someone/Audiobooks")))

    OutputDestination.besideSource.writeToDefaults(defaults)
    #expect(defaults.string(forKey: OutputDestination.defaultsKey) == nil)
    #expect(OutputDestination.fromDefaults(defaults) == .besideSource)
}

@Test @MainActor func aNewModelAdoptsTheStoredDestination() {
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    let library = URL(fileURLWithPath: NSTemporaryDirectory())
    OutputDestination.fixed(library).writeToDefaults(defaults)

    let model = AppModel(defaults: defaults)
    #expect(model.defaultDestination == .fixed(library))
    #expect(model.destinationMessage == nil)
}

// MARK: - Bad destinations

@Test func aMissingOrUnwritableDestinationIsReported() throws {
    #expect(OutputDestination.besideSource.problem() == nil)

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("dest-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }
    #expect(OutputDestination.fixed(root).problem() == nil)

    // Gone: an unmounted volume or a folder the user moved between launches.
    let missing = root.appendingPathComponent("not-there")
    let goneMessage = try #require(OutputDestination.fixed(missing).problem())
    #expect(goneMessage.contains(missing.path))
    #expect(goneMessage.contains("not there"))

    // A file where a folder should be.
    let file = root.appendingPathComponent("a-file")
    try Data("x".utf8).write(to: file)
    #expect(OutputDestination.fixed(file).problem()?.contains("not a folder") == true)

    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: root.path)
    let readOnly = try #require(OutputDestination.fixed(root).problem())
    #expect(readOnly.contains("read-only"))
    #expect(readOnly.contains(root.path))
}

// Picking a folder that cannot be written to must say so there and then, rather than
// leaving the user to discover it when a book fails hours later — and the setting that
// was working must stay in force rather than being replaced by a broken one.
@Test @MainActor func pickingAnUnusableFolderIsRefusedAndTheOldSettingStands() throws {
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    let good = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("good-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: good) }

    let model = AppModel(defaults: defaults)
    #expect(model.setDefaultDestination(.fixed(good)) == nil)

    let missing = good.appendingPathComponent("gone")
    let message = try #require(model.setDefaultDestination(.fixed(missing)))
    #expect(message.contains(missing.path))
    #expect(model.destinationMessage == message)
    // Unchanged, in the model and on disk.
    #expect(model.defaultDestination == .fixed(good))
    #expect(OutputDestination.fromDefaults(defaults) == .fixed(good))
}

// A stored path can go stale between launches. The app keeps it — and says so — rather
// than quietly reverting to "beside each source folder", which would scatter files back
// into the library's subfolders without the user asking for that.
@Test @MainActor func aStoredDestinationThatWentStaleIsKeptAndReported() throws {
    let (defaults, cleanUp) = scratchDefaults()
    defer { cleanUp() }
    let missing = URL(fileURLWithPath: "/Volumes/NotMounted-\(UUID().uuidString)/Audiobooks")
    OutputDestination.fixed(missing).writeToDefaults(defaults)

    let model = AppModel(defaults: defaults)
    #expect(model.defaultDestination == .fixed(missing))
    let message = try #require(model.destinationMessage)
    #expect(message.contains(missing.path))

    // A book added now aims at the missing folder, not at its own parent: nothing is
    // written to a place the user did not choose.
    let book = Book(folder: URL(fileURLWithPath: "/Audiobooks/Saga/Ivanhoe"),
                    tracks: [track("a.mp3", tags: ["album": "Ivanhoe"])],
                    defaultDestination: model.defaultDestination)
    #expect(book.outputURL.path == missing.appendingPathComponent("Ivanhoe.m4b").path)
}

// The whole point of failing early: the conversion stops at preflight, names the folder,
// and puts nothing beside the source folder as a consolation prize.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aBookAimedAtAMissingFolderFailsWithoutWritingAnywhereElse() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 1, tags: ["album": "Book"])
    let tracks = try await Fixtures.probeTracks(in: folder, named: ["01.mp3"])

    let missing = root.appendingPathComponent("no-such-folder")
    let book = Book(folder: folder, tracks: tracks, defaultDestination: .fixed(missing))

    await ConversionQueue(tools: Fixtures.tools!).convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains(missing.path))
    #expect(message.contains("missing"))
    #expect(book.writtenURL == nil)
    // Nothing landed beside the source folder, which is where it would have gone before
    // the setting existed, and nothing inside the book's own folder either.
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasSuffix(".m4b") }.isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path)
        .filter { $0.hasSuffix(".m4b") }.isEmpty)
}

// MARK: - Collisions

// A fixed destination creates collisions that could not happen before: two books in
// different source folders may share a title, and their outputs used to differ only
// because their parents did. Pointing both at one folder makes them the same path —
// so `claimedOutputs` and the collision policy have to carry a case that, until now,
// only arose for sibling disc folders of one set.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func twoSameTitledBooksIntoOneFixedDestinationNeverWriteTheSameFile() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = root.appendingPathComponent("Library")
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

    // Different source folders, under different parents, sharing one album title.
    var books: [Book] = []
    for parent in ["Author A", "Author B"] {
        books.append(try await Fixtures.makeBook(
            named: "Ivanhoe", in: root.appendingPathComponent(parent),
            destination: .fixed(library)))
    }

    // Beside their sources these two would not have collided at all.
    #expect(books[0].folder.deletingLastPathComponent()
            != books[1].folder.deletingLastPathComponent())
    // Pointed at one folder, they do.
    #expect(books[0].outputURL == books[1].outputURL)
    #expect(books[0].id != books[1].id)

    await ConversionQueue(tools: Fixtures.tools!).convertAll(books)

    #expect(books[0].status == .verified)
    #expect(books[1].status == .verified)
    let written = books.compactMap(\.writtenURL)
    #expect(written.count == 2)
    #expect(Set(written).count == 2)
    for url in written {
        // By path: `deletingLastPathComponent()` leaves a trailing slash that `URL`'s own
        // equality treats as a different location.
        #expect(url.deletingLastPathComponent().standardizedFileURL.path
                == library.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
    // Two real files, both non-empty: neither run overwrote the other's output.
    let sizes = try written.map {
        try FileManager.default.attributesOfItem(atPath: $0.path)[.size] as? Int ?? 0
    }
    #expect(sizes.allSatisfy { $0 > 0 })
    #expect(written.contains { $0.lastPathComponent == "Ivanhoe 2.m4b" })
    #expect((books[0].notes + books[1].notes).contains { $0.contains("Ivanhoe 2.m4b") })
}
