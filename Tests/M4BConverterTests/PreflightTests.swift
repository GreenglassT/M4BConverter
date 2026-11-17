import Foundation
import Testing
@testable import M4BConverter

@Test func estimatesOutputSizeFromBitrateAndDuration() {
    // 64 kbit/s for 3600 s ≈ 28.8 MB
    let bytes = Preflight.estimatedBytes(bitRate: 64000, duration: 3600)
    #expect(bytes > 28_000_000 && bytes < 30_000_000)
}

@Test func uniqueURLAppendsACounterWhenTheNameIsTaken() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pre-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let taken = folder.appendingPathComponent("Book.m4b")
    try Data().write(to: taken)
    #expect(Preflight.uniqueURL(for: taken).lastPathComponent == "Book 2.m4b")

    try Data().write(to: folder.appendingPathComponent("Book 2.m4b"))
    #expect(Preflight.uniqueURL(for: taken).lastPathComponent == "Book 3.m4b")
}

@Test func uniqueURLLeavesFreeNamesAlone() {
    let free = URL(fileURLWithPath: "/tmp/definitely-not-there-\(UUID().uuidString).m4b")
    #expect(Preflight.uniqueURL(for: free) == free)
}

// Existence on disk is not the whole answer while other conversions are in flight: a
// run that has resolved a path but not yet created the file must still make that path
// unavailable, or two books sharing an output name both pick it and encode into one file.
@Test func uniqueURLAvoidsPathsClaimedByARunInFlight() {
    let folder = URL(fileURLWithPath: "/tmp/claim-\(UUID().uuidString)")
    let wanted = folder.appendingPathComponent("Ivanhoe.m4b")
    let second = folder.appendingPathComponent("Ivanhoe 2.m4b")
    // Nothing exists on disk at any of these names.
    #expect(Preflight.uniqueURL(for: wanted) == wanted)
    #expect(Preflight.uniqueURL(for: wanted, avoiding: []) == wanted)
    #expect(Preflight.uniqueURL(for: wanted, avoiding: [wanted]) == second)
    #expect(Preflight.uniqueURL(for: wanted, avoiding: [wanted, second])
            == folder.appendingPathComponent("Ivanhoe 3.m4b"))
}

@Test func reportsInsufficientSpace() {
    let report = PreflightReport(estimatedBytes: 10_000_000_000,
                                 freeBytes: 1_000_000, outputExists: false)
    #expect(!report.hasEnoughSpace)
}

@Test func freeSpaceOnTempIsPositive() {
    #expect(Preflight.freeBytes(at: URL(fileURLWithPath: NSTemporaryDirectory())) > 0)
}

// The installed ffmpeg must pass validation, or nothing else in this app works.
@Test(.enabled(if: FFmpegLocator.locate(override: nil) != nil))
func theInstalledFFmpegValidates() async {
    let tools = FFmpegLocator.locate(override: nil)!
    #expect(await Preflight.validate(tools) == nil)
}

// A build without AudioToolbox AAC fails every conversion on the first file with raw
// ffmpeg text ("Unknown encoder"), which reads like a problem with the user's audio.
// Catch it at launch instead.
@Test func anFFmpegWithoutAudioToolboxAACIsRejected() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("fake-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let fake = try Fixtures.fakeTools("""
    if [ "$2" = "-encoders" ]; then echo ' A..... aac  AAC (native)'
    else echo 'ffmpeg version 8.1'; fi
    exit 0
    """, in: folder)

    let message = await Preflight.validate(fake)
    #expect(message?.contains("aac_at") == true)
}

@Test func anFFmpegThatWillNotRunIsRejected() async throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("broken-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }

    let broken = try Fixtures.fakeTools("exit 1", in: folder)

    let message = await Preflight.validate(broken)
    #expect(message?.contains("would not run") == true)
}

/// The 8 bytes these tests write to stand for "the file that was already there". Named
/// because the Trash cleanup below refuses to delete anything that is not exactly this.
private let originalMarker = Data("ORIGINAL".utf8)

/// Where a file called `name` lands when it is trashed with no name already taken.
///
/// By name rather than by searching: `~/.Trash` cannot be ENUMERATED without Full Disk
/// Access — `contentsOfDirectory` there fails with "Operation not permitted" from a test
/// binary — while stat, read and unlink of a known path inside it all work. Only ever used
/// on a UUID-bearing name, so nothing can already be there under it.
private func trashedFile(named name: String) -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".Trash").appendingPathComponent(name)
}

/// A title nothing else on the machine could produce, so what a test throws away lands in
/// the Trash under exactly that name and macOS has no reason to rename it. The same device
/// `ReclaimTests` uses, for the same reason.
private func probeTitle() -> String { "M4BTrashProbe-\(UUID().uuidString)" }

/// Watches where the `.replace` swap actually put the file it replaced, and takes it back
/// out afterwards.
///
/// The old helper guessed. It assumed macOS renames a colliding name by appending " 2",
/// and macOS actually appends a TIMESTAMP — `Book.m4b 16-54-32-261.m4b` — so on every run
/// where the fixed names `Book.m4b`, `Swapped.m4b` or `Ivanhoe.m4b` were already in the
/// Trash from the run before, the cleanup looked in five places that never exist and left
/// the marker behind. Two runs in a row was all it took, and the developer's Trash filled
/// up one 8-byte file at a time.
///
/// Guessing is unnecessary: `trashItem(at:resultingItemURL:)` reports the final URL, and
/// `ConversionQueue` takes its `TrashOperation` — so a test can hand it one that records
/// the answer. `reclaim()` then removes exactly what was trashed, whatever it was named,
/// and fails the test if anything is left, so this cannot silently rot again.
@MainActor
private final class TrashWatcher {
    private(set) var trashed: [URL] = []

    /// Passed to `ConversionQueue` in place of the default. Really does trash the file —
    /// the point of these tests is that the swap does not delete — and remembers where.
    var operation: TrashOperation {
        { [self] url in
            let result = try SourceReclaimer.systemTrash(url)
            // The queue calls this on the main actor, which is where this object lives.
            MainActor.assumeIsolated { if let result { trashed.append(result) } }
            return result
        }
    }

    /// Takes back everything this run put in the Trash, and only that: a file is removed
    /// only once its contents have been confirmed to be the suite's own 8-byte marker.
    func reclaim(_ sourceLocation: SourceLocation = #_sourceLocation) {
        for url in trashed {
            guard (try? Data(contentsOf: url)) == originalMarker else {
                Issue.record("\(url.path) is in the Trash and is not this suite's marker",
                             sourceLocation: sourceLocation)
                continue
            }
            try? FileManager.default.removeItem(at: url)
            #expect(!FileManager.default.fileExists(atPath: url.path),
                    "left \(url.lastPathComponent) in the Trash",
                    sourceLocation: sourceLocation)
        }
    }
}

// `.replace` called `replaceItemAt(_:withItemAt:)` with no `backupItemName`, which DELETES
// the item it replaces. That was survivable while the policy could only reach the source
// folder's parent, where the file in the way was almost certainly this app's own earlier
// output; with a chosen save location it can reach anything in the library that shares a
// title. The user picked "Replace", not "destroy whatever is in the way".
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func replaceSendsTheFileItReplacedToTheTrash() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // A title nothing else on the machine could produce, so the Trash cannot already
    // hold that name and macOS has no reason to rename what it puts there.
    let album = probeTitle()
    let book = try await Fixtures.makeBook(named: "Replaced", in: root, album: album)
    book.collisionPolicy = .replace
    try originalMarker.write(to: book.outputURL)
    let watcher = TrashWatcher()
    defer { watcher.reclaim() }

    await ConversionQueue(tools: Fixtures.tools!,
                          trashing: watcher.operation).convertAll([book])

    #expect(book.status == .verified)
    // The conversion is at the original's name, as it has always been.
    #expect(book.writtenURL == book.outputURL)
    #expect(try Data(contentsOf: book.outputURL) != originalMarker)
    // And the file that used to be there still exists, byte for byte, in the Trash.
    let recovered = trashedFile(named: "\(album).m4b")
    #expect(FileManager.default.fileExists(atPath: recovered.path))
    #expect(try Data(contentsOf: recovered) == originalMarker)
    // The user is told, or "Replace" looks exactly like a delete from the outside.
    #expect(book.notes.contains { $0.contains("Trash") })
}

// `Book.outputURL` is derived from the title, but a `.keepBoth` run writes elsewhere.
// The inspector showed "Output: …/Book.m4b" above a note saying "Saved as Book 2.m4b":
// two filenames, one of them wrong. Record the path this run actually wrote.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func keepBothRecordsThePathItActuallyWrote() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    let book = try await Fixtures.makeBook(named: "Kept", in: root)
    book.collisionPolicy = .keepBoth
    try Data("ORIGINAL".utf8).write(to: book.outputURL)

    await ConversionQueue(tools: Fixtures.tools!).convertAll([book])

    #expect(book.status == .verified)
    #expect(book.writtenURL?.lastPathComponent == "Kept 2.m4b")
    #expect(try Data(contentsOf: book.outputURL) == Data("ORIGINAL".utf8))
}

// `.replace` encodes to "<stem> (converting).m4b" and swaps it onto the original name,
// so the path worth telling the user about is the original, not the temporary one.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func replaceRecordsTheOriginalPathNotTheTemporaryOne() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }

    // A UUID title, so what the swap trashes cannot collide with anything already in
    // there and cannot be renamed on the way in.
    let album = probeTitle()
    let book = try await Fixtures.makeBook(named: "Swapped", in: root, album: album)
    book.collisionPolicy = .replace
    try originalMarker.write(to: book.outputURL)
    // The swap trashes the file it replaces; don't leave it on the machine.
    let watcher = TrashWatcher()
    defer { watcher.reclaim() }

    await ConversionQueue(tools: Fixtures.tools!,
                          trashing: watcher.operation).convertAll([book])

    #expect(book.status == .verified)
    #expect(book.writtenURL == book.outputURL)
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent("\(album) (converting).m4b").path))
    #expect(try Data(contentsOf: book.outputURL) != originalMarker)
}

// Two DISTINCT books can resolve to one output path: `Book.outputURL` is the source
// folder's PARENT plus the album title, so an ordinary multi-disc rip (Ivanhoe/Disc 1,
// Ivanhoe/Disc 2) puts both discs on the same name. Dedup by `Book.ID` does not see it,
// and `queueDeduplicatesTheSameBook` passes the same instance twice so the concurrent
// path was never executed at all. With maxConcurrent = 3 both preflights ran before
// either file existed, both encodes used `-y`, and whichever verify finished last
// reported the interleaved result as good.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func twoBooksSharingAnOutputPathNeverWriteTheSameFile() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Ivanhoe")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    let disc1 = try await Fixtures.makeBook(named: "Disc 1", in: set, album: "Ivanhoe")
    let disc2 = try await Fixtures.makeBook(named: "Disc 2", in: set, album: "Ivanhoe")
    // The precondition that makes this bite: two books, one output path.
    #expect(disc1.outputURL == disc2.outputURL)
    #expect(disc1.id != disc2.id)

    await ConversionQueue(tools: Fixtures.tools!).convertAll([disc1, disc2])

    #expect(disc1.status == .verified)
    #expect(disc2.status == .verified)
    let written = [disc1.writtenURL, disc2.writtenURL].compactMap(\.self)
    #expect(written.count == 2)
    #expect(Set(written).count == 2)
    for url in written { #expect(FileManager.default.fileExists(atPath: url.path)) }
    // One of them had to move aside, and the user is told which.
    #expect(written.contains { $0.lastPathComponent == "Ivanhoe 2.m4b" })
    #expect((disc1.notes + disc2.notes).contains { $0.contains("Ivanhoe 2.m4b") })
}

// The swap at the end of `.replace` can fail — a read-only parent, a locked original,
// a full disk. The old fallback then ran `removeItem` on the original followed by
// `moveItem` of the new file, both `try?`, and set `.verified` regardless: with a
// read-only parent every call failed and the book reported success while pointing at the
// old unconverted file, and when `replaceItemAt` had already consumed its source (which
// Apple documents it may do before throwing) the remove succeeded, the move did not, and
// the folder was left empty. Delete nothing; keep both files; say so.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aFailedSwapKeepsTheOriginalAndReportsFailure() async throws {
    let root = try Fixtures.temporaryDirectory()
    let book = try await Fixtures.makeBook(named: "Locked", in: root)
    book.collisionPolicy = .replace
    try Data("ORIGINAL".utf8).write(to: book.outputURL)
    // Fail the swap without disturbing the encode: the conversion still writes
    // "Locked (converting).m4b" into a writable folder, and only the rename onto the
    // immutable original is refused.
    try FileManager.default.setAttributes([.immutable: true],
                                          ofItemAtPath: book.outputURL.path)
    defer {
        try? FileManager.default.setAttributes([.immutable: false],
                                               ofItemAtPath: book.outputURL.path)
        try? FileManager.default.removeItem(at: root)
    }

    await ConversionQueue(tools: Fixtures.tools!).convertAll([book])

    // The original: still there, still itself.
    #expect(FileManager.default.fileExists(atPath: book.outputURL.path))
    #expect(try Data(contentsOf: book.outputURL) == Data("ORIGINAL".utf8))
    // The conversion: still there too, for the user to move into place by hand.
    let converted = root.appendingPathComponent("Locked (converting).m4b")
    #expect(FileManager.default.fileExists(atPath: converted.path))
    // And emphatically not a success.
    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains(converted.path))
    #expect(message.contains(book.outputURL.path))
    #expect(book.log == message)
    #expect(book.writtenURL == nil)
}

// A re-run that fails must not leave the previous run's path on screen.
@Test @MainActor func aFailedRunClearsThePreviouslyWrittenPath() async throws {
    let (tools, dir) = try Fixtures.fakeTools("exit 1")
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                          estimatedDuration: 10, tags: ["album": "Book"])
    let book = Book(folder: folder, tracks: [track])
    book.written = WrittenOutput(url: folder.appendingPathComponent("stale.m4b"),
                                 chapterCount: 1, duration: 10)

    await ConversionQueue(tools: tools).convertAll([book])
    #expect(book.writtenURL == nil)
    #expect(book.written == nil)
}

// The catch collapsed every error through `localizedDescription`, and `ProcessError.failed`
// folds ffmpeg's entire stderr into that one string — so the red label carried the whole
// dump and the log below it repeated it verbatim, showing the user nothing new. ffmpeg's
// own output is the first thing worth having when a conversion fails: keep it in the log,
// where it can be read, and leave the label one line.
@Test @MainActor func aFailedEncodePutsFFmpegsStderrInTheLog() async throws {
    // The shape of a real failure: hundreds of repeats of one decoder complaint, and a
    // final line that says what actually went wrong. 400 lines is over the 200-line cap.
    let (tools, dir) = try Fixtures.fakeTools("""
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*)
        i=1
        while [ $i -le 400 ]; do echo "[mp3 @ 0x7f] Header missing $i" >&2; i=$((i+1)); done
        echo 'Conversion failed!' >&2
        exit 1 ;;
    esac
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: dir) }

    let book = try fakeBook(in: dir)
    await ConversionQueue(tools: tools).convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(book.log.contains("ffmpeg exited 1"))
    // The tail survives: the last line, and the ones just before it.
    #expect(book.log.contains("Conversion failed!"))
    #expect(book.log.contains("Header missing 400"))
    // The head is what goes, and the loss is stated rather than silent.
    #expect(!book.log.contains("Header missing 1\n"))
    #expect(book.log.contains("omitted"))
    // The point of the change: the log is no longer a copy of the label above it.
    #expect(book.log != message)
    #expect(!message.contains("Header missing"))
    #expect(message.contains("Conversion failed!"))
}

// Every other error keeps the behaviour it had: the log is the message.
@Test @MainActor func aNonProcessFailureStillLogsItsOwnDescription() async throws {
    // ffmpeg cannot be launched at all, so the throw is `ProcessError.launchFailed`.
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let missing = dir.appendingPathComponent("not-there")

    let book = try fakeBook(in: dir)
    await ConversionQueue(tools: FFmpegTools(ffmpeg: missing, ffprobe: missing))
        .convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains("Could not start process"))
    #expect(book.log == message)
}

// A run that fails after the collision step must never destroy a pre-existing file.
// `.replace` used to delete it up front; `.keepBoth`'s cleanup used to delete the
// canonical path rather than the one this run actually wrote.
@Test @MainActor func aFailedRunNeverDestroysAnExistingFile() async throws {
    for policy in [CollisionPolicy.replace, .keepBoth] {
        // measurement succeeds (one time= line), then the encode fails
        let (tools, dir) = try Fixtures.fakeTools(
            "if [ \"$NM_FAIL\" = \"\" ]; then echo 'time=00:00:10.00' >&2; fi; exit 1")
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                              estimatedDuration: 10, tags: ["album": "Book"])
        let book = Book(folder: folder, tracks: [track])
        book.collisionPolicy = policy

        try Data("ORIGINAL".utf8).write(to: book.outputURL)
        await ConversionQueue(tools: tools).convertAll([book])

        #expect(FileManager.default.fileExists(atPath: book.outputURL.path))
        #expect(try Data(contentsOf: book.outputURL) == Data("ORIGINAL".utf8))
    }
}

// `claimedOutputs` stops two books writing one file, but it cannot make `.replace`
// correct: both books set `replacing` to the same original — under that policy there is
// no alternative target — each encodes its own "(converting)" file, and both swap onto
// the original in turn. Nothing is lost from disk, but the loser's conversion is thrown
// away while its `writtenURL` names a file now holding the other book's audio. The
// second book has to be refused outright instead.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func twoBooksReplacingOneOriginalRefuseToBothRun() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let set = root.appendingPathComponent("Ivanhoe")
    try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)

    let album = probeTitle()
    let disc1 = try await Fixtures.makeBook(named: "Disc 1", in: set, album: album)
    let disc2 = try await Fixtures.makeBook(named: "Disc 2", in: set, album: album)
    // Two distinct books, one output path — the multi-disc rip again.
    #expect(disc1.outputURL == disc2.outputURL)
    disc1.collisionPolicy = .replace
    disc2.collisionPolicy = .replace
    let original = disc1.outputURL
    try originalMarker.write(to: original)
    let watcher = TrashWatcher()
    defer { watcher.reclaim() }

    await ConversionQueue(tools: Fixtures.tools!,
                          trashing: watcher.operation).convertAll([disc1, disc2])

    // Whichever claims the original first wins; the other must not have encoded a file
    // only to have it discarded.
    #expect([disc1.status, disc2.status].filter { $0 == .verified }.count == 1)
    let refused = try #require([disc1, disc2].first { $0.status != .verified })
    guard case let .failed(message) = refused.status else {
        Issue.record("expected .failed, got \(refused.status)")
        return
    }
    #expect(message.contains("already replacing"))
    #expect(message.contains("\(album).m4b"))
    // Nothing written, so nothing to point at.
    #expect(refused.writtenURL == nil)

    // The winner's audio is at the original name, and no "(converting)" file survives.
    #expect(try Data(contentsOf: original) != originalMarker)
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: set.path)
        .filter { $0.hasSuffix(".m4b") }
    #expect(leftovers == ["\(album).m4b"])
}

/// Fake tools whose measure step reports 10 s and whose encode writes its output file.
/// `verify` is left to the caller: the two failures worth separating are a verifier that
/// runs and condemns the file, and a verifier that will not run at all.
private func fakeToolsThatEncode(thenVerify verify: String) throws -> (FFmpegTools, URL) {
    try Fixtures.fakeTools("""
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*) for last; do :; done; echo CONVERTED > "$last"; exit 0 ;;
      *-show_chapters*) \(verify) ;;
    esac
    exit 0
    """)
}

// A file that fails verification used to be left exactly where it was written, for every
// policy. That turns a loud failure into a quiet one: a complete-looking .m4b sits in the
// library beside the good copy, and the next run under `.skip` skips the book on the
// strength of a file the app never certified.
@Test @MainActor func aFileThatFailsVerificationIsNotLeftBehind() async throws {
    // The third case has no pre-existing file, so this run's output is the only .m4b
    // there is — and it must still go.
    for (policy, hasOriginal) in [(CollisionPolicy.keepBoth, true),
                                  (.replace, true),
                                  (.keepBoth, false)] {
        // Empty JSON: no audio stream, no chapters, no readable duration.
        let (tools, dir) = try fakeToolsThatEncode(thenVerify: "echo '{}'; exit 0")
        defer { try? FileManager.default.removeItem(at: dir) }

        let folder = dir.appendingPathComponent("Book")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                              estimatedDuration: 10, tags: ["album": "Book"])
        let book = Book(folder: folder, tracks: [track])
        book.collisionPolicy = policy
        if hasOriginal { try Data("ORIGINAL".utf8).write(to: book.outputURL) }

        await ConversionQueue(tools: tools).convertAll([book])

        guard case .failed = book.status else {
            Issue.record("expected .failed for \(policy), got \(book.status)")
            return
        }
        #expect(book.writtenURL == nil)
        // Whatever was there before is untouched, and nothing new survives.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".m4b") }.sorted()
        #expect(remaining == (hasOriginal ? ["Book.m4b"] : []))
        if hasOriginal {
            #expect(try Data(contentsOf: book.outputURL) == Data("ORIGINAL".utf8))
        }
    }
}

/// Fake tools as above, but the verifier prints whatever JSON the test has left in
/// `verify.json` beside the script — so the report can be built to match the book.
private func fakeToolsVerifyingFromFile() throws -> (FFmpegTools, URL) {
    try fakeToolsThatEncode(thenVerify: #"cat "$(dirname "$0")/verify.json"; exit 0"#)
}

/// A one-track book in `dir/Book`, with a cover file so a cover is expected of the output.
///
/// `album` decides the output filename. A test whose output really is trashed passes a
/// UUID-bearing one, so nothing already in the Trash can share the name and macOS has no
/// reason to rename what it puts there.
@MainActor
private func fakeBook(in dir: URL, withCover: Bool = true,
                      album: String = "Book") throws -> Book {
    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let cover = folder.appendingPathComponent("cover.jpg")
    if withCover { try Data("JPEG".utf8).write(to: cover) }
    let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                          estimatedDuration: 10, tags: ["album": album])
    return Book(folder: folder, tracks: [track],
                coverImage: withCover ? cover : nil)
}

// `VerificationReport.passed` was `problems.isEmpty`, so ANY problem failed the book —
// and the failure branch deletes the output. "No cover art embedded" or "media_type != 2"
// therefore destroyed hours of finished, correct audio over metadata. The audio is what
// the delete-on-failure rule exists to protect; cosmetic defects must keep the file.
@Test @MainActor func aCosmeticVerificationProblemKeepsTheFileAndVerifiesTheBook() async throws {
    let (tools, dir) = try fakeToolsVerifyingFromFile()
    defer { try? FileManager.default.removeItem(at: dir) }

    let book = try fakeBook(in: dir)
    // Complete, correct audio: right chapter count, right duration, ascending starts.
    // No cover art, and not flagged as an audiobook.
    try Fixtures.verifierJSON(chapterCount: book.chapters.count, duration: 10,
                     cover: false, audiobook: false)
        .write(to: dir.appendingPathComponent("verify.json"), atomically: true, encoding: .utf8)

    await ConversionQueue(tools: tools).convertAll([book])

    #expect(book.status == .verified)
    #expect(book.writtenURL == book.outputURL)
    // The whole point: the encode survives.
    #expect(FileManager.default.fileExists(atPath: book.outputURL.path))
    #expect(try Data(contentsOf: book.outputURL) == Data("CONVERTED\n".utf8))
    // And the user is told what is imperfect about it.
    #expect(book.notes.contains { $0.contains("cover") })
    #expect(book.notes.contains { $0.contains("media_type") })
}

// The other half of the split: a chapter count that does not match means the audio is
// not what the app planned, so the file is still deleted and the book still fails.
@Test @MainActor func aFatalVerificationProblemStillDeletesTheOutput() async throws {
    let (tools, dir) = try fakeToolsVerifyingFromFile()
    defer { try? FileManager.default.removeItem(at: dir) }

    let book = try fakeBook(in: dir)
    // Everything cosmetic is perfect; only the chapter count is wrong.
    try Fixtures.verifierJSON(chapterCount: book.chapters.count + 3, duration: 10,
                     cover: true, audiobook: true)
        .write(to: dir.appendingPathComponent("verify.json"), atomically: true, encoding: .utf8)

    await ConversionQueue(tools: tools).convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains("chapters"))
    #expect(book.writtenURL == nil)
    #expect(!FileManager.default.fileExists(atPath: book.outputURL.path))
}

// Under `.replace` a cosmetic-only result must still swap: the audio is good, and
// leaving the original in place would silently discard a successful conversion.
@Test @MainActor func replaceStillSwapsWhenTheOnlyProblemsAreCosmetic() async throws {
    let (tools, dir) = try fakeToolsVerifyingFromFile()
    defer { try? FileManager.default.removeItem(at: dir) }

    let album = probeTitle()
    let book = try fakeBook(in: dir, album: album)
    book.collisionPolicy = .replace
    try originalMarker.write(to: book.outputURL)
    let watcher = TrashWatcher()
    defer { watcher.reclaim() }
    try Fixtures.verifierJSON(chapterCount: book.chapters.count, duration: 10,
                     cover: false, audiobook: false)
        .write(to: dir.appendingPathComponent("verify.json"), atomically: true, encoding: .utf8)

    await ConversionQueue(tools: tools, trashing: watcher.operation).convertAll([book])

    #expect(book.status == .verified)
    #expect(book.writtenURL == book.outputURL)
    #expect(try Data(contentsOf: book.outputURL) == Data("CONVERTED\n".utf8))
    #expect(!FileManager.default.fileExists(
        atPath: dir.appendingPathComponent("\(album) (converting).m4b").path))
}

// Preflight checked free space and existence but never writability, so a read-only
// destination was discovered only after a multi-hour encode. `Book.outputURL` writes to
// the PARENT of the book folder, so a book on a read-only volume aims at that volume's
// root — a very ordinary way to hit this.
@Test @MainActor func aReadOnlyDestinationFailsBeforeAnythingIsEncoded() async throws {
    let (tools, dir) = try fakeToolsVerifyingFromFile()
    let destination = dir.appendingPathComponent("ReadOnly")
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: destination.path)
        try? FileManager.default.removeItem(at: dir)
    }

    let book = try fakeBook(in: destination)
    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: destination.path)

    await ConversionQueue(tools: tools).convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains("read-only"))
    #expect(message.contains(destination.path))
    #expect(book.writtenURL == nil)
    #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path)
        .filter { $0.hasSuffix(".m4b") }.isEmpty)
}

// `isWritableFile(atPath:)` is `access(W_OK)`, which consults POSIX permissions and knows
// nothing about macOS privacy protection — so Desktop, Documents and Downloads all pass it
// and are then refused at encode time with raw ffmpeg "Permission denied". Writing a file
// is the only check that sees what actually stops the write. TCC cannot be simulated in a
// unit test, so what is asserted here is the mechanism: it really does write, it agrees
// with the permission bits where those are the answer, and it leaves nothing behind.
@Test func writabilityIsProvedByWritingAndLeavesNothingBehind() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("probe-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }

    #expect(Preflight.canWrite(to: folder))
    // Not one trace of the probe, under any name — least of all something ending .m4b.
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).isEmpty)

    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: folder.path)
    #expect(!Preflight.canWrite(to: folder))

    // A folder that is not there cannot be written to either, and saying so must not
    // create it.
    let missing = folder.appendingPathComponent("not-there")
    #expect(!Preflight.canWrite(to: missing))
    #expect(!FileManager.default.fileExists(atPath: missing.path))
}

@Test func reportFlagsAReadOnlyDestination() throws {
    let folder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ro-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: folder.path)
        try? FileManager.default.removeItem(at: folder)
    }
    let output = folder.appendingPathComponent("Book.m4b")
    #expect(Preflight.report(for: output, bitRate: 64000, duration: 60).isWritable)

    try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                          ofItemAtPath: folder.path)
    #expect(!Preflight.report(for: output, bitRate: 64000, duration: 60).isWritable)
}

// The `catch` cleanup was gated on `replacing != nil`, so a `.keepBoth` run that failed
// AFTER the encode — a verifier that will not run, say — kept its finished but
// uncertified file. `writing` is only ever a path this run created, so the guard was
// never protecting anything.
@Test @MainActor func aFailureAfterTheEncodeDoesNotLeakTheFileItWrote() async throws {
    let (tools, dir) = try fakeToolsThatEncode(
        thenVerify: "echo 'ffprobe fell over' >&2; exit 3")
    defer { try? FileManager.default.removeItem(at: dir) }

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let track = TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                          estimatedDuration: 10, tags: ["album": "Book"])
    let book = Book(folder: folder, tracks: [track])
    book.collisionPolicy = .keepBoth
    try Data("ORIGINAL".utf8).write(to: book.outputURL)

    await ConversionQueue(tools: tools).convertAll([book])

    guard case .failed = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    // "Book 2.m4b" is the path a `.keepBoth` run picks around the original.
    let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasSuffix(".m4b") }
    #expect(remaining == ["Book.m4b"])
    #expect(try Data(contentsOf: book.outputURL) == Data("ORIGINAL".utf8))
}
