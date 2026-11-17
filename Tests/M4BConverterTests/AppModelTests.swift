import Foundation
import Testing
@testable import M4BConverter

private func track(_ name: String) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), estimatedDuration: 10)
}

// `relocateTools` used to clear `setupMessage` synchronously and let the async
// validation put it back ~10-50 ms later, so "Check again" dismissed the sheet and
// then reopened it. The sheet must stay up continuously across a re-check.
@Test @MainActor func recheckingToolsNeverDropsTheSetupSheet() {
    let model = AppModel()
    model.setupMessage = "an earlier failure"
    model.relocateTools()
    // No suspension point above, so the validation task cannot have run yet: this is
    // exactly the instant at which the sheet used to blink out.
    #expect(model.needsSetup)
    #expect(model.setupMessage != nil)
    if model.tools != nil { #expect(model.isValidating) }
}

// `relocateTools` rebuilt the queue unconditionally, so "Check again" or "Locate
// manually…" during a conversion orphaned the running one: it kept its ffmpeg processes
// while becoming unreachable, the footer's Cancel disappeared with it, and
// `applicationShouldTerminate` then inspected the NEW idle queue, returned `.terminateNow`
// and let the app quit while ffmpeg was still writing — producing exactly the
// never-verified leftover file that handler exists to prevent.
@Test @MainActor func relocatingToolsIsRefusedWhileAConversionRuns() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Slow enough that the conversion is genuinely in flight when the user clicks.
    let tools = try Fixtures.fakeTools("sleep 30", in: dir)

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let book = Book(folder: folder,
                    tracks: [TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                                       estimatedDuration: 10, tags: ["album": "Book"])])

    let queue = ConversionQueue(tools: tools)
    let model = AppModel()
    model.queue = queue

    let running = Task { await queue.convertAll([book]) }
    var attempts = 0
    while !queue.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(queue.isRunning)

    model.relocateTools()

    // Same queue, still cancellable, still visible to the termination handler.
    #expect(model.queue === queue)
    #expect(model.scanMessage?.contains("conversion is running") == true)

    queue.cancelAll()
    await running.value
    #expect(!queue.isRunning)
}

// The Settings window (⌘,) reaches app-level state that a running queue owns, and unlike
// `relocateTools` and `SetupSheet` it had no guard at all. `defaultDestination.didSet`
// pushes down to EVERY book including the converting ones, whose output path was resolved
// and claimed at preflight and cannot move — so the inspector would name a folder the file
// is not being written to, which is precisely what its own `.disabled(book.isConverting)`
// guard exists to prevent. Books still queued behind the running ones resolve `outputURL`
// afterwards, so one click of Convert All would split its output across two folders while
// the footer still read "3 of 9".
@Test @MainActor func theSaveLocationCannotBeChangedWhileAConversionRuns() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    // Slow enough that the conversion is genuinely in flight when ⌘, is pressed.
    let tools = try Fixtures.fakeTools("sleep 30", in: dir)

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let book = Book(folder: folder,
                    tracks: [TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                                       estimatedDuration: 10, tags: ["album": "Book"])])
    // A real, usable folder, so nothing but the running conversion can refuse it.
    let elsewhere = dir.appendingPathComponent("Elsewhere")
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

    let queue = ConversionQueue(tools: tools)
    // Its own defaults, so the suite neither reads nor overwrites the save location the
    // person running it has chosen in the app.
    let suite = "m4b-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.books = [book]
    model.queue = queue

    let running = Task { await queue.convertAll([book]) }
    var attempts = 0
    while !queue.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(queue.isRunning)

    let message = model.setDefaultDestination(.fixed(elsewhere))

    #expect(message?.contains("conversion is running") == true)
    #expect(model.destinationMessage == message)
    // Unchanged: in the model, on the books it would have pushed to, and on disk.
    #expect(model.defaultDestination == .besideSource)
    #expect(book.defaultDestination == .besideSource)
    #expect(book.outputURL == dir.appendingPathComponent("Book.m4b"))
    #expect(OutputDestination.fromDefaults(defaults) == .besideSource)

    queue.cancelAll()
    await running.value
    // And once it is over the setting takes, so this is a refusal and not a lock-out.
    #expect(model.setDefaultDestination(.fixed(elsewhere)) == nil)
    #expect(book.outputURL == elsewhere.appendingPathComponent("Book.m4b"))
}

// AudiobookScanner only ever yields folders, so a dropped file produced the message
// about unreadable folders — pointing the user at entirely the wrong hypothesis.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func droppingALooseFileAsksForAFolder() async throws {
    let model = AppModel()
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let loose = folder.appendingPathComponent("loose.mp3")
    try Data("not really an mp3".utf8).write(to: loose)

    await model.add([loose])
    #expect(model.books.isEmpty)
    #expect(model.scanMessage?.contains("Drop a folder") == true)
}

// A folder that is empty (or unreadable) still gets the original message.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func droppingAnEmptyFolderStillReportsNoMP3s() async throws {
    let model = AppModel()
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A drop delivers directories flagged as such, the way Finder hands them over.
    let dropped = URL(fileURLWithPath: folder.path, isDirectory: true)

    await model.add([dropped])
    #expect(model.scanMessage?.contains("No MP3s found") == true)
}

// Probing concurrently must not disturb the order of the tracks array. TrackOrderer
// breaks ties on each track's `.enumerated()` offset, so appending in completion
// order would silently scramble files that share a track number.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func concurrentScanPreservesFileOrder() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Ordered")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

    // More files than the concurrency limit, of differing lengths so probes finish
    // out of order rather than in lockstep.
    let names = (1...12).map { String(format: "%02d.mp3", $0) }
    for (index, name) in names.enumerated() {
        try await Fixtures.makeMP3(in: folder, named: name,
                                   seconds: 0.4 + Double(index) * 0.1,
                                   // Same number on every file: ordering information
                                   // has to come from the array, not the tag.
                                   tags: ["album": "Ordered", "track": "1"])
    }

    let model = AppModel()
    await model.add([folder])

    let book = try #require(model.books.first)
    #expect(book.tracks.map(\.filename) == names)

    // The tie-break path: every track number is 1, so this order is the array order.
    book.order = .trackTag
    book.recompute()
    #expect(book.orderedTracks.map(\.filename) == names)
}

// A file that will not probe used to be dropped on the floor: `probeConcurrently` turned
// the throw into nil and `compactMap` removed it. The book was then built, planned and
// verified against the surviving tracks, so a short audiobook came out marked verified
// with nothing on screen to suggest a track was missing. Refuse the folder instead, and
// name the file.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aFolderWithAnUnprobeableFileAddsNoBookAndSaysWhich() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Half Readable")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 0.4,
                               tags: ["album": "Half Readable"])
    // Right extension, no audio in it: ffprobe exits non-zero, exactly as it would on a
    // truncated download or a file the disk has gone bad under.
    try Data("not really an mp3".utf8)
        .write(to: folder.appendingPathComponent("02.mp3"))
    try await Fixtures.makeMP3(in: folder, named: "03.mp3", seconds: 0.4,
                               tags: ["album": "Half Readable"])

    let model = AppModel()
    await model.add([folder])

    #expect(model.books.isEmpty)
    let message = try #require(model.scanMessage)
    #expect(message.contains("02.mp3"))
    #expect(message.contains("Drop the folder again"))
    // Not the "already in the queue" note, which would read as nothing being wrong.
    #expect(!message.contains("already in the queue"))
}

// AudiobookScanner selects by extension, so a file that is really AAC/ALAC/FLAC under a
// `.mp3` name was accepted. It probes fine and measures a correct duration on its own, so
// nothing before the encode noticed — but under the concat demuxer the FIRST input's
// format is forced onto every input, so the misnamed file decodes to nothing, ffmpeg
// exits 0, and that audio is silently missing. OutputVerifier does catch it, as a
// duration mismatch, after the entire encode; and its 3 s tolerance would let a file
// shorter than that through with a matching chapter count and no complaint at all.
// Refuse the folder in about a second at scan time instead.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aFolderWithAMisnamedNonMP3AddsNoBookAndNamesTheCodec() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Mislabelled")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 0.4,
                               tags: ["album": "Mislabelled"])
    try await Fixtures.makeAACNamedMP3(in: folder, named: "02.mp3", seconds: 0.4)
    try await Fixtures.makeAACNamedMP3(in: folder, named: "03.mp3", seconds: 0.4)

    let model = AppModel()
    await model.add([folder])

    #expect(model.books.isEmpty)
    let message = try #require(model.scanMessage)
    // The count, the first offender, and what it actually is.
    #expect(message.contains("2 files"))
    #expect(message.contains("02.mp3"))
    #expect(message.contains("aac"))
    #expect(message.contains("No book was added"))
    #expect(!message.contains("already in the queue"))
}

// A folder of genuine MP3s is unaffected: the codec check must not become a second way
// for an ordinary book to be refused.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aFolderOfRealMP3sIsStillAccepted() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Genuine")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["01.mp3", "02.mp3"] {
        try await Fixtures.makeMP3(in: folder, named: name, seconds: 0.4,
                                   tags: ["album": "Genuine"])
    }

    let model = AppModel()
    await model.add([folder])

    #expect(model.books.count == 1)
    #expect(model.books.first?.tracks.allSatisfy(\.isMP3) == true)
}

// ffprobe reports "mp3" here (ffmpeg 8.1), but the decoder name "mp3float" reaches
// `codec_name` on some builds, and tags are not reliably lower-cased.
@Test func mp3IsRecognisedByCodecNameNotByExtension() {
    let url = URL(fileURLWithPath: "/b/a.mp3")
    for name in ["mp3", "MP3", "mp3float", "MP3Float"] {
        #expect(TrackInfo(url: url, codecName: name).isMP3)
    }
    for name in ["aac", "alac", "flac", "opus", "unknown", ""] {
        #expect(!TrackInfo(url: url, codecName: name).isMP3)
    }
}

// The refusal is per folder: a good folder dropped alongside a bad one still becomes a
// book, so one corrupt file cannot block an entire library import.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func oneUnreadableFolderDoesNotBlockAGoodOneDroppedWithIt() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let bad = root.appendingPathComponent("Bad")
    let good = root.appendingPathComponent("Good")
    for folder in [bad, good] {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 0.4)
    }
    try Data("not really an mp3".utf8).write(to: bad.appendingPathComponent("02.mp3"))

    let model = AppModel()
    await model.add([bad, good])

    #expect(model.books.count == 1)
    #expect(model.books.first?.folder.lastPathComponent == "Good")
    #expect(model.scanMessage?.contains("02.mp3") == true)
}

// `add` has no reentrancy guard and its dedup check was separated from the append by the
// probing `await`, so two overlapping drops of one folder both cleared the check and both
// appended. Two books for one folder means two books with one output path — exactly the
// concurrent collision the queue then has to defend against.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func twoOverlappingAddsOfOneFolderProduceOneBook() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Twice")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for name in ["01.mp3", "02.mp3"] {
        try await Fixtures.makeMP3(in: folder, named: name, seconds: 0.4,
                                   tags: ["album": "Twice"])
    }

    let model = AppModel()
    // Both calls are in flight at once: the second reaches the dedup check while the
    // first is still awaiting its probes.
    async let first: Void = model.add([folder])
    async let second: Void = model.add([folder])
    _ = await (first, second)

    #expect(model.books.count == 1)
    #expect(model.books.first?.folder == folder)
}

// Removing a book mid-conversion left ConversionQueue holding it: the run kept going,
// writing a file the user could no longer see or cancel individually.
@Test @MainActor func aBookBeingConvertedCannotBeRemoved() {
    let model = AppModel()
    let book = Book(folder: URL(fileURLWithPath: "/b"), tracks: [track("a.mp3")])
    model.books = [book]
    model.selection = book.id

    book.status = .converting
    #expect(book.isConverting)
    model.remove(book)
    #expect(model.books.count == 1)

    book.status = .verified
    #expect(!book.isConverting)
    model.remove(book)
    #expect(model.books.isEmpty)
}

// `.failed` carries an associated value, so a plain `==` on the status enum is not
// enough to answer "is this one running".
@Test @MainActor func isConvertingIsFalseForEveryOtherStatus() {
    let book = Book(folder: URL(fileURLWithPath: "/b"), tracks: [track("a.mp3")])
    for status in [BookStatus.ready, .warning, .verified, .failed("nope")] {
        book.status = status
        #expect(!book.isConverting)
    }
    book.status = .converting
    #expect(book.isConverting)
}

// MARK: - stopping everything before the app goes away

// What `applicationShouldTerminate` asks. Foundation `Process` children outlive their
// parent, and the existing-books check grows two of them per file in flight — a decode and
// its ffprobe — up to `FFmpegBudget.concurrentDecodes` files at a time. The quit handler
// guarded on the conversion queue alone, because the check was added afterwards and the
// guard was never widened: quitting during a check returned `.terminateNow` and left every
// one of those processes running after the app had gone.
@Test @MainActor func aLibraryCheckIsSomethingRunningAndIsStoppedWithEverythingElse() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // Slow enough that the check is genuinely in flight when the user presses ⌘Q.
    let tools = try Fixtures.fakeTools("sleep 30", in: root)

    let model = AppModel()
    model.tools = tools
    #expect(!model.isBusy)

    let files = (1...8).map { root.appendingPathComponent("Book \($0).m4b") }
    let running = Task { await model.libraryCheck.run(files, tools: tools) }
    var attempts = 0
    while !model.libraryCheck.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }

    // No conversion at all: the queue is idle, and this is exactly the state that used to
    // read as "nothing is running".
    #expect(!model.isConverting)
    #expect(model.isBusy)
    // And the wait really does wait: it reports failure rather than pretending.
    let gaveUp = await model.waitUntilIdle(within: 0.05)
    #expect(!gaveUp)

    model.cancelEverything()
    _ = await running.value

    #expect(await model.waitUntilIdle(within: 5))
    #expect(!model.isBusy)
    #expect(model.libraryCheck.isCancelled)
    // A killed decode is not a verdict about anyone's book.
    #expect(model.libraryCheck.reports.allSatisfy { !$0.wasChecked })
}

// The half that already worked, kept working — and asked through the same one question, so
// neither source of child processes is a special case beside the other.
@Test @MainActor func aRunningConversionIsSomethingRunningToo() async throws {
    let dir = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let tools = try Fixtures.fakeTools("sleep 30", in: dir)

    let folder = dir.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let book = Book(folder: folder,
                    tracks: [TrackInfo(url: folder.appendingPathComponent("a.mp3"),
                                       estimatedDuration: 10, tags: ["album": "Book"])])
    let queue = ConversionQueue(tools: tools)
    let model = AppModel()
    model.tools = tools
    model.queue = queue

    let running = Task { await queue.convertAll([book]) }
    var attempts = 0
    while !queue.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(model.isBusy)
    #expect(!model.libraryCheck.isRunning)

    model.cancelEverything()
    await running.value

    #expect(await model.waitUntilIdle(within: 5))
    #expect(!model.isBusy)
    #expect(book.status == .ready)
}
