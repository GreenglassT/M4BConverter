import Foundation
import Testing
@testable import M4BConverter

/// A one-track book in `dir/Book`, tagged so its output is `dir/Book.m4b`. No cover file,
/// so the verifier is not asked for one.
@MainActor
private func retryableBook(in dir: URL) throws -> Book {
    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                          estimatedDuration: 10, tags: ["album": "Book"])
    return Book(folder: folder, tracks: [track])
}

/// Fake tools whose FIRST encode fails and whose second succeeds — a transient failure of
/// exactly the kind Retry exists for. The marker beside the script is what remembers,
/// since each invocation is a fresh process.
private func fakeToolsFailingOnlyTheFirstEncode() throws -> (FFmpegTools, URL) {
    try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*)
        if [ ! -f "$D/attempted" ]; then
          : > "$D/attempted"
          echo 'Conversion failed!' >&2
          exit 1
        fi
        for last; do :; done; echo CONVERTED > "$last"; exit 0 ;;
      *-show_chapters*) cat "$D/verify.json"; exit 0 ;;
    esac
    exit 0
    """)
}

// The gap Retry closes. `convertAll` skips every terminal status, so a book that failed
// for a transient reason — a full disk, a save location that was briefly unavailable, an
// ffmpeg hiccup — was stuck for good: the only escape was Remove followed by re-dropping
// the folder, which is undiscoverable and throws away every per-book setting.
//
// Asserted through the queue rather than on the status alone: the point is not that the
// flag flipped, it is that the next run actually converts the book.
@Test @MainActor func aRetriedBookIsPickedUpByTheNextRunAndConverts() async throws {
    let (tools, dir) = try fakeToolsFailingOnlyTheFirstEncode()
    defer { try? FileManager.default.removeItem(at: dir) }

    let book = try retryableBook(in: dir)
    try Fixtures.verifierJSON(chapterCount: book.chapters.count, duration: 10,
                              cover: false, audiobook: true)
        .write(to: dir.appendingPathComponent("verify.json"),
               atomically: true, encoding: .utf8)

    let queue = ConversionQueue(tools: tools)
    await queue.convertAll([book])
    guard case .failed = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }

    // Left alone, it is invisible to the queue for ever — including to a brand new one.
    let skipping = ConversionQueue(tools: tools)
    await skipping.convertAll([book])
    #expect(skipping.total == 0)

    #expect(book.retry())
    #expect(book.status == .ready)

    // The same queue that ran the failure, so a claim leaked from that run would show up
    // here: `claimedOutputs` still holding `Book.m4b` sends this `.keepBoth` book to
    // `Book 2.m4b` instead of the name it is entitled to.
    await queue.convertAll([book])
    #expect(queue.total == 1)
    #expect(book.status == .verified)
    #expect(book.writtenURL == book.outputURL)
    #expect(try Data(contentsOf: book.outputURL) == Data("CONVERTED\n".utf8))
}

// `Book` decides `.ready` vs `.warning` from whether there is anything to warn about, and
// retry has to ask rather than assume: a book with warnings that came back as `.ready`
// would keep listing its warnings in the inspector while the sidebar showed a plain circle.
@Test @MainActor func aRetriedBookWithWarningsComesBackAsWarningNotReady() async throws {
    let book = try retryableBook(in: Fixtures.temporaryDirectory())
    // A strategy these filenames cannot satisfy: "This setting produces no chapters."
    book.chapterStrategy = .overdriveMarkers
    #expect(!book.warnings.isEmpty)

    book.status = .failed("disk full")
    #expect(book.retry())

    #expect(book.status == .warning)
    #expect(!book.warnings.isEmpty)
}

// Everything the failed run left behind describes that run. What it wrote is the part that
// actively lies: the inspector prefers `writtenURL` over `outputURL`, so it would go on
// reporting "Written to:" a path the failed run deleted on its way out — and the chapter
// count and length recorded beside it are what a reclaim would re-check that file against.
@Test @MainActor func retryClearsWhatTheFailedRunLeftBehind() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let book = try retryableBook(in: dir)

    book.status = .failed("ffmpeg exited 1")
    book.log = "ffmpeg exited 1\n\nHeader missing"
    book.notes = ["Saved as Book 2.m4b to avoid overwriting an existing file."]
    book.progress = 0.62
    book.written = WrittenOutput(url: dir.appendingPathComponent("Book 2.m4b"),
                                 chapterCount: 2, duration: 20)

    #expect(book.retry())

    #expect(book.status == .ready)
    #expect(book.log.isEmpty)
    #expect(book.notes.isEmpty)
    #expect(book.progress == 0)
    #expect(book.written == nil)
    #expect(book.writtenURL == nil)
}

// Only `.failed`. Re-running a `.verified` book is a different intent — it would silently
// redo hours of work on a file that is already good — and `.converting` belongs to a run
// in flight, which would keep writing regardless.
@Test @MainActor func retryOnlyEverAppliesToAFailedBook() async throws {
    let book = try retryableBook(in: Fixtures.temporaryDirectory())
    for status in [BookStatus.ready, .warning, .converting, .verified] {
        book.status = status
        #expect(!book.retry())
        #expect(book.status == status)
    }
}

// Both of `ConversionQueue`'s cancel paths used to assign `.ready` directly, which is the
// same defect as hardcoding it in retry: a cancelled book with warnings lost its badge
// while the inspector went on listing the warnings underneath. This is the catch path —
// the terminated tool throws, and the run unwinds into `catch`.
@Test @MainActor func cancellingABookWithWarningsKeepsItsWarningBadge() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Slow enough that the cancel lands while the run is genuinely in flight.
    let tools = try Fixtures.fakeTools("sleep 30", in: dir)

    let book = try retryableBook(in: dir)
    book.chapterStrategy = .overdriveMarkers
    #expect(book.status == .warning)

    let queue = ConversionQueue(tools: tools)
    let running = Task { await queue.convertAll([book]) }
    var attempts = 0
    while !book.isConverting, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(book.isConverting)

    queue.cancelAll()
    await running.value

    #expect(book.status == .warning)
    #expect(!book.warnings.isEmpty)
}

// The other cancel path: the encode itself finishes, and the `guard !isCancelled` after it
// is what stops the run. Reached deterministically by an encode that ignores SIGTERM and
// waits for the test to release it, so the cancel is known to have landed first.
@Test @MainActor func aCancelLandingAfterTheEncodeAlsoKeepsTheWarningBadge() async throws {
    let (tools, dir) = try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*)
        trap '' TERM
        : > "$D/encoding"
        while [ ! -f "$D/go" ]; do sleep 0.05; done
        for last; do :; done; echo CONVERTED > "$last"; exit 0 ;;
    esac
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: dir) }

    let book = try retryableBook(in: dir)
    book.chapterStrategy = .overdriveMarkers
    #expect(book.status == .warning)

    let queue = ConversionQueue(tools: tools)
    let running = Task { await queue.convertAll([book]) }
    let encoding = dir.appendingPathComponent("encoding")
    var attempts = 0
    while !FileManager.default.fileExists(atPath: encoding.path), attempts < 600 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(FileManager.default.fileExists(atPath: encoding.path))

    queue.cancelAll()
    // Only now let the encode finish, so it returns success to a run already cancelled.
    try Data().write(to: dir.appendingPathComponent("go"))
    await running.value

    #expect(book.status == .warning)
    #expect(!book.warnings.isEmpty)
    // And the half-written file that run produced is not left in the library.
    #expect(!FileManager.default.fileExists(atPath: book.outputURL.path))
}

// The sidebar and the inspector both offer Retry through `AppModel`, which is where the
// mid-run refusal lives: `convertAll` snapshots its pending list at the start, so a book
// returned to `.ready` now would not join the run in progress — it would simply sit there
// looking queued while the footer counted down to a total that never included it.
@Test @MainActor func retryIsRefusedWhileAConversionIsRunning() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tools = try Fixtures.fakeTools("sleep 30", in: dir)

    let running = try retryableBook(in: dir)
    let failed = Book(folder: dir.appendingPathComponent("Other"),
                      tracks: [TrackInfo(url: dir.appendingPathComponent("Other/b.mp3"),
                                         estimatedDuration: 10, tags: ["album": "Other"])])
    failed.status = .failed("disk full")

    let queue = ConversionQueue(tools: tools)
    let model = AppModel()
    model.queue = queue
    model.books = [running, failed]

    let task = Task { await queue.convertAll([running]) }
    var attempts = 0
    while !queue.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(queue.isRunning)

    #expect(!model.retry(failed))
    #expect(model.retryAllFailed() == 0)
    #expect(failed.status == .failed("disk full"))
    #expect(model.scanMessage?.contains("conversion is running") == true)

    queue.cancelAll()
    await task.value

    // A refusal, not a lock-out: once the run is over the same click works.
    #expect(model.retry(failed))
    #expect(failed.status == .ready)
}

// One click for a batch that failed together — a save location that had gone away takes
// every book in the queue down with it, and retrying them one at a time is busywork.
@Test @MainActor func retryAllPutsBackEveryFailedBookAndNothingElse() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }

    let model = AppModel()
    var books: [Book] = []
    for (index, status) in [BookStatus.failed("disk full"), .verified,
                            .failed("no such folder"), .ready].enumerated() {
        let folder = dir.appendingPathComponent("Book \(index)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let book = Book(folder: folder,
                        tracks: [TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                                           estimatedDuration: 10,
                                           tags: ["album": "Book \(index)"])])
        book.status = status
        books.append(book)
    }
    model.books = books

    #expect(model.failedBooks.count == 2)
    #expect(model.retryAllFailed() == 2)
    #expect(model.failedBooks.isEmpty)

    #expect(books[0].status == .ready)
    // Untouched: a finished book is not re-run, and a waiting one has nothing to retry.
    #expect(books[1].status == .verified)
    #expect(books[2].status == .ready)
    #expect(books[3].status == .ready)
}
