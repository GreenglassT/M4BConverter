import Foundation
import Testing
@testable import M4BConverter

/// A folder name nothing else on the machine could produce, so what these tests throw away
/// lands in the Trash under exactly this name — macOS appends a counter only on a collision
/// — and the cleanup below can take it back by path.
private func probeFolderName() -> String { "M4BReclaimProbe-\(UUID().uuidString)" }

/// Where a folder called `name` lands when it is trashed.
///
/// By name rather than by searching, for the same reason as the `.replace` tests in
/// `PreflightTests`: `~/.Trash` cannot be ENUMERATED without Full Disk Access, while stat,
/// read and unlink of a known path inside it all work from a test binary.
private func trashedItem(named name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash").appendingPathComponent(name)
}

/// Reclaiming really does move a folder to the Trash, so any test that exercises a
/// successful one leaves it on the machine running the suite. Take it back out — but only
/// a folder that is unmistakably this suite's own: the UUID name AND the tracks it wrote.
private func reclaimTrashedFolder(named name: String) {
    guard name.hasPrefix("M4BReclaimProbe-") else { return }
    let url = trashedItem(named: name)
    guard FileManager.default.fileExists(atPath: url.appendingPathComponent("01.mp3").path)
    else { return }
    try? FileManager.default.removeItem(at: url)
}

/// A verified book whose source folder is real and whose finished .m4b is real, with fake
/// tools whose ffprobe answers the re-check from `verify.json` beside them.
///
/// The tracks are bytes rather than encoded audio: nothing here decodes them, and what the
/// tests are about is which files still exist afterwards.
@MainActor
private func verifiedFixture(
    in root: URL,
    outputInsideTheFolder: Bool = false,
    extras: [String] = [],
    reportedChapters: Int? = nil,
    reportedDuration: Double? = nil
) throws -> (book: Book, tools: FFmpegTools) {
    let folder = root.appendingPathComponent(probeFolderName())
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let names = ["01.mp3", "02.mp3"]
    for name in names {
        try Data(repeating: 0x41, count: 4096).write(to: folder.appendingPathComponent(name))
    }
    try Data(repeating: 0x42, count: 512).write(to: folder.appendingPathComponent("cover.jpg"))
    for extra in extras {
        try Data("extra".utf8).write(to: folder.appendingPathComponent(extra))
    }

    let tracks = names.map {
        TrackInfo(url: folder.appendingPathComponent($0), estimatedDuration: 10,
                  tags: ["album": "Book"])
    }
    let book = Book(folder: folder, tracks: tracks,
                    coverImage: folder.appendingPathComponent("cover.jpg"))
    // Deterministic: two files, one chapter each, twenty seconds altogether.
    book.chapterStrategy = .fileBoundaries

    let output = (outputInsideTheFolder ? folder : root).appendingPathComponent("Book.m4b")
    try Data(repeating: 0x4D, count: 1024).write(to: output)
    // What the run wrote, as the run would have recorded it: two chapters, twenty seconds.
    // The re-check is made against THIS, not against whatever the book's list says later.
    let written = WrittenOutput(url: output, chapterCount: book.chapters.count,
                                duration: book.chapters.last?.end ?? 0)
    book.written = written
    book.status = .verified

    try Fixtures.verifierJSON(chapterCount: reportedChapters ?? written.chapterCount,
                              duration: reportedDuration ?? written.duration,
                              cover: true, audiobook: true)
        .write(to: root.appendingPathComponent("verify.json"), atomically: true, encoding: .utf8)
    let tools = try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *-show_chapters*) cat "$D/verify.json"; exit 0 ;;
    esac
    exit 0
    """, in: root)
    return (book, tools)
}

/// A second book for the queue, standing at `folder` and having written `output`.
///
/// No files behind either path unless the caller writes them: what the survey decides from
/// is the QUEUE, so these tests put the book where the finding puts it and let the disk
/// agree or not as each test needs.
@MainActor private func queuedBook(titled title: String, folder: URL,
                                   output: URL? = nil) -> Book {
    let book = Book(folder: folder, tracks: [
        TrackInfo(url: folder.appendingPathComponent("01.mp3"), estimatedDuration: 10,
                  tags: ["album": title])
    ])
    book.title = title
    if let output {
        book.written = WrittenOutput(url: output, chapterCount: 1, duration: 10)
        book.status = .verified
    }
    return book
}

/// A counter the main actor can bump, for the test that asks whether it was free.
@MainActor private final class MainActorTicks { var count = 0 }

@MainActor private func model(with tools: FFmpegTools) -> AppModel {
    let model = AppModel()
    model.tools = tools
    return model
}

/// Whether the source MP3s are still where they were.
@MainActor private func sourcesSurvive(_ book: Book) -> Bool {
    book.tracks.allSatisfy { FileManager.default.fileExists(atPath: $0.url.path) }
}

// The feature itself: nine converted books here were ~8 GB of MP3s whose .m4b files are
// another 8.5 GB, and removing the sources by hand is exactly when someone deletes the
// wrong folder. The folder goes to the TRASH — recoverable — and the finished book, which
// is the whole justification for removing them, is untouched.
@Test @MainActor func reclaimingSendsTheSourceFolderToTheTrashAndKeepsTheOutput() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let name = book.folder.lastPathComponent
    defer { reclaimTrashedFolder(named: name) }

    let app = model(with: tools)
    let reclaimed = await app.reclaimSource(of: book)
    #expect(reclaimed)

    #expect(!FileManager.default.fileExists(atPath: book.folder.path))
    // Recoverable, not gone: the tracks are in the Trash, byte for byte.
    let recovered = trashedItem(named: name)
    #expect(FileManager.default.fileExists(atPath: recovered.appendingPathComponent("01.mp3").path))
    #expect(try Data(contentsOf: recovered.appendingPathComponent("01.mp3")).count == 4096)
    // The reason the folder could go: a checked copy that is still there.
    #expect(FileManager.default.fileExists(atPath: book.writtenURL!.path))

    #expect(book.status == .reclaimed)
    #expect(book.notes.contains { $0.contains("Trash") })
    // And how much came back, where the app's other messages appear.
    #expect(app.scanMessage?.contains("Trash") == true)
    #expect(app.scanMessage?.contains("KB") == true)
}

// The justification for removing the source is that a good copy exists, so that is checked
// at the moment of removal rather than taken from a status flag set hours ago. A file that
// has been moved away since leaves the MP3s as the only copy there is.
@Test @MainActor func reclaimingIsRefusedWhenTheFinishedBookIsNotThere() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let app = model(with: tools)

    try FileManager.default.removeItem(at: book.writtenURL!)
    var reclaimed = await app.reclaimSource(of: book)
    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(book.status == .verified)
    #expect(app.scanMessage?.contains(book.writtenURL!.path) == true)

    // And the book that never recorded one at all.
    book.written = nil
    reclaimed = await app.reclaimSource(of: book)
    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(FileManager.default.fileExists(atPath: book.folder.path))
}

// A status flag is not a file. The .m4b is re-probed and re-verified against this book's
// own chapter count and duration, and anything that does not match keeps the MP3s.
@Test @MainActor func reclaimingIsRefusedWhenTheOutputNoLongerVerifies() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // The file on disk has five chapters; this book wrote two.
    let (book, tools) = try verifiedFixture(in: root, reportedChapters: 5)
    let app = model(with: tools)

    let reclaimed = await app.reclaimSource(of: book)
    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(book.status == .verified)
    #expect(app.scanMessage?.contains("chapters") == true)
}

// The same for a file that is the right shape and the wrong length — a truncated copy, or
// a different book that happens to share the name.
@Test @MainActor func reclaimingIsRefusedWhenTheOutputIsTheWrongLength() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root, reportedDuration: 300)
    let app = model(with: tools)

    let reclaimed = await app.reclaimSource(of: book)
    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(app.scanMessage?.contains("Duration") == true)
}

// The evidence itself, recorded by the run that produced it: the file, the number of
// chapters actually written into it, and the length the conversion measured by decoding.
// All three are what `SourceReclaimer` re-checks, and all three have to come from the run.
@Test @MainActor func aSuccessfulRunRecordsWhatItWroteBesideThePath() async throws {
    let (tools, dir) = try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*) for last; do :; done; echo CONVERTED > "$last"; exit 0 ;;
      *-show_chapters*) cat "$D/verify.json"; exit 0 ;;
    esac
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tracks = ["a.mp3", "b.mp3"].map {
        TrackInfo(url: folder.appendingPathComponent($0),
                  estimatedDuration: 10, tags: ["album": "Book"])
    }
    let b = Book(folder: folder, tracks: tracks)
    try Fixtures.verifierJSON(chapterCount: 2, duration: 20, cover: false, audiobook: true)
        .write(to: dir.appendingPathComponent("verify.json"),
               atomically: true, encoding: .utf8)

    await ConversionQueue(tools: tools).convertAll([b])

    #expect(b.status == .verified)
    let written = try #require(b.written)
    #expect(written.url == b.outputURL)
    #expect(written.url == b.writtenURL)
    // The two numbers the verify that just passed was given: the chapters this run wrote,
    // and the length it measured by decoding every source file.
    #expect(written.chapterCount == 2)
    #expect(written.duration == 20)
}

// The evidence for removing the MP3s is what the RUN wrote, and that is not something the
// window can move. `book.chapters` and the length derived from it are both still reachable
// after a conversion — assigning a chapter source re-plans the whole list — so re-checking
// the finished file against them made the app blame the file for a list the app itself had
// changed: "…no longer matches this book: Expected 2 chapters, found 3." The .m4b is fine;
// only the app's copy of the list moved.
@Test @MainActor func theRecheckUsesWhatTheRunWroteNotTheBooksCurrentList() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let name = book.folder.lastPathComponent
    defer { reclaimTrashedFolder(named: name) }

    // A chapter source these tracks cannot satisfy: the book's list is empty now, and its
    // span is nothing like the finished file's. Not one byte of the .m4b has changed.
    book.chapterStrategy = .overdriveMarkers
    #expect(book.chapters.isEmpty)

    let app = model(with: tools)
    let reclaimed = await app.reclaimSource(of: book)

    #expect(reclaimed)
    #expect(book.status == .reclaimed)
    #expect(!FileManager.default.fileExists(atPath: book.folder.path))
}

// The save location can be set to the source folder itself — Settings allows it, and the
// inspector's "Save to" row allows it per book. Trashing the folder would take the .m4b
// with it, leaving nothing at all.
@Test @MainActor func reclaimingIsRefusedWhenTheOutputLivesInsideTheFolder() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root, outputInsideTheFolder: true)
    let app = model(with: tools)

    let reclaimed = await app.reclaimSource(of: book)
    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(FileManager.default.fileExists(atPath: book.writtenURL!.path))
    #expect(app.scanMessage?.contains(book.folder.path) == true)
}

// Reclaiming is never part of converting: only a book the app has converted AND verified
// has anything to keep in place of its MP3s.
@Test @MainActor func reclaimingIsRefusedForABookThatIsNotVerified() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let app = model(with: tools)

    for status in [BookStatus.ready, .warning, .converting, .failed("disk full")] {
        book.status = status
        let reclaimed = await app.reclaimSource(of: book)
        #expect(!reclaimed)
        #expect(sourcesSurvive(book))
        #expect(book.status == status)
    }
    #expect(app.scanMessage?.contains("verified") == true)
}

// Refused mid-run for the same reason as Retry and the save location: the app's own state
// must not move under a conversion in flight. The UI disables the control and this is the
// guard behind it, because a disabled control is not a rule.
@Test @MainActor func reclaimingIsRefusedWhileAConversionIsRunning() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let name = book.folder.lastPathComponent
    defer { reclaimTrashedFolder(named: name) }

    let sleeper = root.appendingPathComponent("sleeper")
    try FileManager.default.createDirectory(at: sleeper, withIntermediateDirectories: true)
    let slow = try Fixtures.fakeTools("sleep 30", in: sleeper)
    let running = Book(folder: sleeper,
                       tracks: [TrackInfo(url: sleeper.appendingPathComponent("a.mp3"),
                                          estimatedDuration: 10, tags: ["album": "Other"])])

    let app = model(with: tools)
    let queue = ConversionQueue(tools: slow)
    app.queue = queue
    app.books = [book, running]

    let task = Task { await queue.convertAll([running]) }
    var attempts = 0
    while !queue.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(queue.isRunning)

    let refused = await app.reclaimSource(of: book)
    #expect(!refused)
    #expect(sourcesSurvive(book))
    #expect(app.scanMessage?.contains("conversion is running") == true)

    queue.cancelAll()
    await task.value

    // A refusal, not a lock-out: once the run is over the same request works.
    let reclaimed = await app.reclaimSource(of: book)
    #expect(reclaimed)
    #expect(book.status == .reclaimed)
}

// Trash, never delete. A volume with no Trash — a network share, some external formats —
// must leave every file exactly where it is and say so, not fall back to removing them.
@Test @MainActor func aVolumeWithNoTrashReportsRatherThanDeleting() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let app = model(with: tools)

    let noTrash = NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError,
                          userInfo: [NSLocalizedDescriptionKey:
                                        "The volume doesn’t have a Trash."])
    let reclaimed = await app.reclaimSource(of: book, trashing: { _ in throw noTrash })

    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(FileManager.default.fileExists(atPath: book.folder.path))
    #expect(book.status == .verified)
    #expect(app.scanMessage?.contains("Nothing was deleted") == true)
}

// The same through the real `FileManager.trashItem`, with the folder's parent made
// read-only so the move genuinely fails: no code path in this feature falls back to
// deleting, so the MP3s are all still there.
@Test @MainActor func aTrashThatRefusesTheFolderLeavesEveryFileWhereItWas() async throws {
    let root = try Fixtures.temporaryDirectory()
    let (book, tools) = try verifiedFixture(in: root)
    let app = model(with: tools)
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                               ofItemAtPath: root.path)
        try? FileManager.default.removeItem(at: root)
    }

    let reclaimed = await app.reclaimSource(of: book)

    #expect(!reclaimed)
    #expect(sourcesSurvive(book))
    #expect(book.status == .verified)
    #expect(app.scanMessage?.contains("Nothing was deleted") == true)
}

// The folder goes as a whole, so anything in it that is not this book's own tracks or its
// cover goes too — a PDF, a second cover, a nested folder of extras. Say so before the
// user agrees rather than after.
@Test @MainActor func theConfirmationCountsTheFolderAndNamesWhatElseIsInIt() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, _) = try verifiedFixture(in: root, extras: ["liner-notes.pdf", "bonus.txt"])

    let survey = await SourceReclaimer.survey(book)
    #expect(survey.folder == book.folder)
    // Two tracks, the cover, and the two strangers.
    #expect(survey.fileCount == 5)
    #expect(survey.byteCount == 4096 + 4096 + 512 + 5 + 5)
    #expect(survey.strangers == ["bonus.txt", "liner-notes.pdf"])

    let message = survey.confirmation(for: book)
    #expect(message.contains(book.folder.path))
    #expect(message.contains("5 files"))
    #expect(message.contains("Trash"))
    #expect(message.contains("liner-notes.pdf"))
    #expect(message.contains("bonus.txt"))
    // The finished book is named too: it is the thing being kept.
    #expect(message.contains(book.writtenURL!.path))

    // One stranger reads as one, not as "1 item that are not".
    let (single, _) = try verifiedFixture(in: root, extras: ["only-one.pdf"])
    let alone = await SourceReclaimer.survey(single).confirmation(for: single)
    #expect(alone.contains("1 item that is not"))
    #expect(alone.contains("only-one.pdf"))
    #expect(!alone.contains("items"))
}

// The folder about to go can hold ANOTHER book in the queue. It takes only a parent folder
// and one of its children dropped in two separate operations — `AudiobookScanner` stops
// recursing at the first level holding MP3s, so that is the only way both become books —
// and then reclaiming the parent moves the child's MP3s to the Trash as a side effect. The
// survey already listed the child, as an anonymous "item that is not one of this book's
// MP3s": true, useless, and not the sentence that would stop anybody.
@Test @MainActor func theConfirmationNamesAnotherQueuedBookInsideTheFolder() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (parent, _) = try verifiedFixture(in: root, extras: ["liner-notes.pdf"])

    let childFolder = parent.folder.appendingPathComponent("Book Two")
    try FileManager.default.createDirectory(at: childFolder,
                                            withIntermediateDirectories: true)
    try Data(repeating: 0x43, count: 2048)
        .write(to: childFolder.appendingPathComponent("01.mp3"))
    // Its own .m4b is safely outside, so only its MP3s are at stake.
    let child = queuedBook(titled: "Book Two", folder: childFolder,
                           output: root.appendingPathComponent("Book Two.m4b"))

    let survey = await SourceReclaimer.survey(parent, queue: [parent, child])
    #expect(survey.queued == [QueuedBookInside(title: "Book Two", sourceGoes: true,
                                               outputGoes: false)])
    // Named once, as a book. The folder is no longer repeated in the anonymous list.
    #expect(survey.strangers == ["liner-notes.pdf"])
    // And it is still counted: the child's MP3 is going too.
    #expect(survey.fileCount == 5)

    let message = survey.confirmation(for: parent)
    #expect(message.contains("Another book in this queue"))
    #expect(message.contains("Book Two (its MP3s)"))
    // Distinct from the generic list, which still does its own job.
    #expect(message.contains("liner-notes.pdf"))
    #expect(message.contains("1 item that is not"))
    // And it says what nothing else will say afterwards: that book keeps its status.
    #expect(message.contains("without any check of its own"))
    #expect(message.contains("show it exactly as it is now"))
    // The book being reclaimed is never one of its own warnings.
    #expect(!survey.queued.contains { $0.title == parent.title })
}

// The serious half: another book's FINISHED .m4b inside the folder. This is the same loss
// `outputInsideTheFolder` refuses outright for the book being reclaimed — a save location
// pointing into someone else's source folder — one book over.
@Test @MainActor func theConfirmationNamesAQueuedBooksFinishedFileInsideTheFolder() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (parent, _) = try verifiedFixture(in: root)

    // One that only SAVED in here; its MP3s are somewhere else entirely.
    let elsewhere = root.appendingPathComponent("Elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let saved = parent.folder.appendingPathComponent("Moby-Dick.m4b")
    try Data(repeating: 0x4D, count: 64).write(to: saved)
    let neighbour = queuedBook(titled: "Moby-Dick", folder: elsewhere, output: saved)

    // And one nested in here that also saved in here: both halves at once.
    let nested = parent.folder.appendingPathComponent("Bleak House")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let nestedOutput = nested.appendingPathComponent("Bleak House.m4b")
    try Data(repeating: 0x4D, count: 64).write(to: nestedOutput)
    let child = queuedBook(titled: "Bleak House", folder: nested, output: nestedOutput)

    let survey = await SourceReclaimer.survey(parent, queue: [parent, neighbour, child])
    #expect(survey.queued == [
        QueuedBookInside(title: "Moby-Dick", sourceGoes: false, outputGoes: true),
        QueuedBookInside(title: "Bleak House", sourceGoes: true, outputGoes: true),
    ])
    // Both are described as books; neither is left in the anonymous list.
    #expect(survey.strangers.isEmpty)

    let message = survey.confirmation(for: parent)
    #expect(message.contains("2 other books in this queue"))
    #expect(message.contains("Moby-Dick (its finished .m4b)"))
    #expect(message.contains("Bleak House (its MP3s and its finished .m4b)"))
    // Plural throughout, not "It goes … as it is now" about two books.
    #expect(message.contains("without any check of their own"))
    #expect(message.contains("show them exactly as they are now"))
}

// A book whose MP3s are in the Trash already cannot have them taken again, and saying so
// would be the one thing worse than saying nothing. Its finished .m4b, if it was saved in
// here, is still very much present and is still named.
@Test @MainActor func aReclaimedNeighboursMP3sAreNotNamedAsGoingAgain() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (parent, _) = try verifiedFixture(in: root)

    let goneFolder = parent.folder.appendingPathComponent("Already Gone")
    let gone = queuedBook(titled: "Already Gone", folder: goneFolder,
                          output: root.appendingPathComponent("Already Gone.m4b"))
    gone.status = .reclaimed

    // Nothing of this one's is in the folder any more, so it is not named at all.
    #expect(await SourceReclaimer.survey(parent, queue: [parent, gone]).queued.isEmpty)

    // Its .m4b, though, was saved inside — and that has not moved.
    gone.written = WrittenOutput(url: parent.folder.appendingPathComponent("Gone.m4b"),
                                 chapterCount: 1, duration: 10)
    let survey = await SourceReclaimer.survey(parent, queue: [parent, gone])
    #expect(survey.queued == [QueuedBookInside(title: "Already Gone", sourceGoes: false,
                                               outputGoes: true)])
}

// An ordinary queue — nothing nested in anything — says nothing about any of this. The
// warning has to be absent when there is nothing to warn about, or it is noise and gets
// read past on the day it matters.
@Test @MainActor func anOrdinaryQueueAddsNothingToTheConfirmation() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, _) = try verifiedFixture(in: root)
    let (sibling, _) = try verifiedFixture(in: root)

    let survey = await SourceReclaimer.survey(book, queue: [book, sibling])
    #expect(survey.queued.isEmpty)
    let message = survey.confirmation(for: book)
    #expect(!message.contains("in this queue"))
    #expect(message.hasPrefix(book.folder.path))
}

// The inspector shows one book at a time, and `ContentView` gives it no `.id` — so
// selecting another book re-renders the same view, and the same `ReclaimRequest`, around a
// different one. Counting the folder asynchronously opened a window in which that can
// happen mid-walk, and the confirmation would then arrive about the previous book while the
// pane behind it showed this one.
@Test @MainActor func aRequestGivenUpOnRaisesNoConfirmationAfterwards() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (first, _) = try verifiedFixture(in: root)
    let (second, _) = try verifiedFixture(in: root)

    let request = ReclaimRequest()
    request.ask(about: first, in: [first, second])
    #expect(request.isSurveying)
    // The selection moved while the folder was still being counted.
    request.abandon()
    #expect(!request.isSurveying)

    // Long enough to have walked that folder many times over. No dialog ever appears.
    try await Task.sleep(for: .milliseconds(400))
    #expect(request.pending == nil)

    // Given up on, not broken: asking about the book now on screen still works.
    request.ask(about: second, in: [first, second])
    var attempts = 0
    while request.pending == nil, attempts < 500 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    let pending = try #require(request.pending)
    #expect(pending.book === second)
    #expect(pending.message.contains(second.folder.path))
}

// Item 2: the dialog is not raised until the folder has actually been counted. A
// confirmation carrying "0 files, Zero KB" that changes under the user is a confirmation of
// nothing — and it is exactly what raising the dialog first would produce.
@Test @MainActor func noConfirmationIsRaisedUntilTheFolderHasBeenCounted() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, _) = try verifiedFixture(in: root, extras: ["liner-notes.pdf"])

    let request = ReclaimRequest()
    request.ask(about: book, in: [book])
    #expect(request.pending == nil)
    #expect(request.isSurveying)
    // A second press while the first is still counting starts nothing: two walks would
    // raise two dialogs, of which SwiftUI shows one, and not necessarily this one.
    request.ask(about: book, in: [book])

    var attempts = 0
    while request.pending == nil, attempts < 500 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    let pending = try #require(request.pending)
    #expect(!request.isSurveying)
    #expect(pending.book === book)
    // Two tracks, the cover and the PDF — the real count, not a placeholder.
    #expect(pending.message.contains("4 files"))
    #expect(pending.message.contains("liner-notes.pdf"))
}

// And the reason it is asynchronous at all: on a network share or a large tree the walk
// takes long enough to hitch the window. Nothing here measures a clock — the ticker below
// runs only when the main actor is free, and if the walk happened there it would get no
// turns at all. Against the synchronous version this recorded exactly 0.
@Test @MainActor func countingTheFolderDoesNotBlockTheMainActor() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, _) = try verifiedFixture(in: root)
    for index in 0..<3000 {
        FileManager.default.createFile(
            atPath: book.folder.appendingPathComponent("extra-\(index).bin").path,
            contents: Data("x".utf8))
    }

    let ticks = MainActorTicks()
    let ticker = Task { @MainActor in
        while !Task.isCancelled { ticks.count += 1; await Task.yield() }
    }
    defer { ticker.cancel() }
    await Task.yield()
    let before = ticks.count

    let survey = await SourceReclaimer.survey(book)
    let during = ticks.count - before
    ticker.cancel()

    // The two tracks, the cover, and the three thousand.
    #expect(survey.fileCount == 3003)
    #expect(during > 10, "the main actor got \(during) turns while the folder was counted")
}

// A book whose tracks are in the Trash cannot convert and must not look as if it could.
// Nothing that would now fail is offered: the queue skips it, Retry refuses it, and the
// settings that describe a conversion are closed.
@Test @MainActor func aReclaimedBookIsNotConvertibleRetryableOrEditable() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let (book, tools) = try verifiedFixture(in: root)
    let name = book.folder.lastPathComponent
    defer { reclaimTrashedFolder(named: name) }

    let app = model(with: tools)
    let reclaimed = await app.reclaimSource(of: book)
    #expect(reclaimed)

    #expect(book.status.isTerminal)
    #expect(!book.acceptsEdits)
    #expect(!book.isReclaimable)
    // Retry is for a failed book; a reclaimed one has no audio left to re-run.
    #expect(!book.retry())
    #expect(book.status == .reclaimed)
    // The queue skips it, and says so by never counting it.
    let queue = ConversionQueue(tools: tools)
    await queue.convertAll([book])
    #expect(queue.total == 0)
    #expect(book.status == .reclaimed)
    // And the chapter table's guard, which is a rule and not just a disabled control.
    #expect(throws: ChapterEditError.sourceReclaimed) {
        try book.setChapterTitle("Anything", at: 0)
    }
    book.adoptOrder(.filename)
    book.revertToAutomaticChapters()
    #expect(book.status == .reclaimed)
}

// `add` dedups by folder, so a reclaimed book would swallow the re-drop of a folder the
// user had put back from the Trash — matched against an entry that can never convert
// anything, with "Those books are already in the queue" as the only feedback.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aRestoredFolderCanBeDroppedOverTheReclaimedBook() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let app = AppModel()
    let stale = try await Fixtures.makeBook(named: "Restored", in: root)
    stale.status = .reclaimed
    app.books = [stale]
    app.selection = stale.id

    // The folder is on disk again because the user put it there.
    await app.add([stale.folder])

    #expect(app.books.count == 1)
    let fresh = try #require(app.books.first)
    #expect(fresh !== stale)
    #expect(fresh.folder == stale.folder)
    #expect(fresh.status == .ready)
    #expect(app.selection == fresh.id)
    #expect(app.scanMessage == nil)
}
