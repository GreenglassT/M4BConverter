import Foundation
import Testing
@testable import M4BConverter

/// ffprobe-shaped output for a file with no expectation attached — the shapes
/// `Fixtures.verifierJSON` cannot make, because the checker has to survive files that
/// `OutputVerifier` would never be handed: no audio at all, chapters that do not advance.
private func probeJSON(chapterStarts: [Double], duration: String?,
                       audio: Bool = true, cover: Bool = false,
                       audiobook: Bool = false) -> String {
    let chapters = chapterStarts.map {
        #"{"start_time":"\#($0)","end_time":"\#($0 + 1)","tags":{"title":"C"}}"#
    }
    var streams: [String] = []
    if audio { streams.append(#"{"codec_type":"audio","codec_name":"aac"}"#) }
    if cover {
        streams.append(
            #"{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}"#)
    }
    let format = [duration.map { #""duration":"\#($0)""# },
                  audiobook ? #""tags":{"media_type":"2"}"# : #""tags":{}"#]
        .compactMap(\.self).joined(separator: ",")
    return """
    {"chapters":[\(chapters.joined(separator: ","))],
     "streams":[\(streams.joined(separator: ","))],
     "format":{\(format)}}
    """
}

/// Fake tools whose ffprobe prints `probe.json` and whose decode prints `decode.err` on
/// stderr after `delay` seconds and exits `decodeExit` — the four things the checker reads,
/// all of them controllable from a test, so the rules can be pinned without encoding real
/// audio.
private func fakeCheckerTools(in directory: URL, probe: String,
                              decodeStderr: String, delay: String = "0",
                              decodeExit: String = "0") throws -> FFmpegTools {
    try probe.write(to: directory.appendingPathComponent("probe.json"),
                    atomically: true, encoding: .utf8)
    try decodeStderr.write(to: directory.appendingPathComponent("decode.err"),
                           atomically: true, encoding: .utf8)
    try delay.write(to: directory.appendingPathComponent("delay"),
                    atomically: true, encoding: .utf8)
    try decodeExit.write(to: directory.appendingPathComponent("decode.exit"),
                         atomically: true, encoding: .utf8)
    return try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*)
        sleep "$(cat "$D/delay")"; cat "$D/decode.err" >&2
        exit "$(cat "$D/decode.exit")" ;;
      *-show_chapters*) cat "$D/probe.json"; exit 0 ;;
    esac
    exit 0
    """, in: directory)
}

/// A path that need not exist: with fake tools nothing opens the file.
private func namedFiles(_ count: Int, in directory: URL) -> [URL] {
    (1...count).map { directory.appendingPathComponent("Book \($0).m4b") }
}

/// The same paths, actually on disk — for the routes through `AppModel`, where
/// `ExistingBookChecker.collect` walks the filesystem before anything is decoded.
private func realFiles(_ count: Int, in directory: URL) throws -> [URL] {
    try namedFiles(count, in: directory).map {
        try Data().write(to: $0)
        return $0
    }
}

/// An `AppModel` on its own defaults suite, as `AppModel.init` documents: `.standard`
/// reads the save location the person running the suite has chosen in the app.
@MainActor
private func scratchModel() -> (model: AppModel, cleanup: () -> Void) {
    let suite = "m4b-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    return (AppModel(defaults: defaults),
            { defaults.removePersistentDomain(forName: suite) })
}

// MARK: - the absolute checks, against real files

// The check that needs no expectation at all, and the one the whole mode exists for: a
// container claiming more audio than actually decodes. Nothing else in this app can ask
// that question of a file it did not create — `OutputVerifier` compares against the source
// MP3s, and there are none here.
@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aHealthyExistingBookPassesWithNothingToReport() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try await Fixtures.makeM4B(in: root, named: "Healthy.m4b", seconds: 6)

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    #expect(report.passed)
    #expect(report.problems.isEmpty)
    #expect(report.chapterCount == 2)
    #expect(report.hasAudio && report.hasCover && report.isAudiobook)
    // Both numbers are reported, because the point of the check is their difference.
    #expect(report.containerDuration ?? 0 > 5.5)
    #expect(report.decodedDuration ?? 0 > 5.5)
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aBookThatDecodesShortOfItsContainerIsDamaged() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    // `+faststart` puts the moov atom at the FRONT, so chopping the tail off leaves the
    // container still claiming the full length while a fifth of the audio is simply gone.
    let url = try await Fixtures.makeM4B(in: root, named: "Short.m4b", seconds: 20)
    try Fixtures.truncate(url, toFraction: 0.8)

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    #expect(!report.passed)
    #expect(report.fatalProblems.count == 1)
    #expect(report.fatalProblems.first?.contains("did not decode") == true)
    let decoded = try #require(report.decodedDuration)
    let claimed = try #require(report.containerDuration)
    #expect(claimed - decoded > 2)
}

// The other half of "real damage": a file whose length is right and whose middle is not.
// The duration check cannot see this one — every packet still carries its timestamp, so
// the decode runs to the very end — and the volume of complaints is the only evidence.
@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aBookWhoseDecodeComplainsFarBeyondOneFilesBudgetIsDamaged() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try await Fixtures.makeM4B(in: root, named: "Rotten.m4b", seconds: 20)
    try Fixtures.zeroBytes(in: url, fraction: 0.10, startingAtFraction: 0.45)

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    #expect(!report.passed)
    #expect(report.fatalProblems.contains { $0.contains("Error submitting") })
    // And it is caught DESPITE the length being right, which is what makes it worth a
    // separate check.
    #expect(abs((report.decodedDuration ?? 0) - (report.containerDuration ?? 0)) < 1)
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func missingChaptersCoverAndTheAudiobookFlagAreFindingsNotDamage() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try await Fixtures.makeM4B(in: root, named: "Bare.m4b", seconds: 4,
                                         chapters: 0, cover: false, audiobook: false)

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    // The audio is complete and correct, so the file is sound. Everything absent from it
    // is something the user can fix in a tag editor, which is exactly the cosmetic side of
    // the split `OutputVerifier` already draws.
    #expect(report.passed)
    #expect(report.fatalProblems.isEmpty)
    #expect(report.cosmeticProblems.count == 3)
    #expect(report.cosmeticProblems.contains { $0.contains("chapters") })
    #expect(report.cosmeticProblems.contains { $0.contains("cover") })
    #expect(report.cosmeticProblems.contains { $0.contains("media_type") })
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aFileWithNoAudioStreamIsRejected() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try await Fixtures.makeVideoOnlyMP4(in: root, named: "NotABook.m4b")

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    #expect(!report.passed)
    #expect(!report.hasAudio)
    #expect(report.fatalProblems.contains { $0.contains("No audio stream") })
    // Nothing was decoded, and the report must not pretend a length was measured.
    #expect(report.decodedDuration == nil)
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aFileThatIsNotMediaAtAllIsRejected() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let url = root.appendingPathComponent("Junk.m4b")
    try Data("not an audiobook".utf8).write(to: url)

    let report = try await ExistingBookChecker(tools: Fixtures.tools!).check(url)

    #expect(!report.passed)
    #expect(report.fatalProblems.contains { $0.contains("could not be read") })
}

// MARK: - the rules, pinned exactly

// The allowance is `DurationMeasurer`'s, not a second one invented here: the same floor,
// fraction and cap that were measured against 448 real files. 20.0 s claimed against 18.0 s
// decoded is the defect this mode exists to find; 19.5 s is metadata drift.
@Test func theShortfallAllowanceIsTheOneDurationMeasurerAlreadyUses() async throws {
    for (decoded, isDamaged) in [("00:00:18.00", true), ("00:00:19.50", false),
                                 ("00:00:20.01", false)] {
        let root = try Fixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let tools = try fakeCheckerTools(
            in: root,
            probe: probeJSON(chapterStarts: [0], duration: "20.0",
                             cover: true, audiobook: true),
            decodeStderr: "size=N/A time=\(decoded) bitrate=N/A speed=200x")

        let report = try await ExistingBookChecker(tools: tools)
            .check(root.appendingPathComponent("Book.m4b"))

        #expect(report.passed != isDamaged, "decoded \(decoded)")
    }
    // And the boundary really is the shared one.
    #expect(DurationMeasurer.allowedShortfall(containerDuration: 20) == 1.0)
}

// `ChapterEditor` already owns this rule, because the .m4b carries whole milliseconds and
// two starts a fraction of one apart become the same number once written. Restating it
// here would be a second place for it to drift.
@Test func chapterStartsThatDoNotAdvanceOnTheMillisecondGridAreDamage() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0, 0.0004, 5], duration: "20.0",
                         cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")

    let report = try await ExistingBookChecker(tools: tools)
        .check(root.appendingPathComponent("Book.m4b"))

    #expect(!report.passed)
    #expect(report.fatalProblems.contains { $0.contains("start times") })
    #expect(!ChapterEditor.startsStrictlyAscend([0, 0.0004, 5]))
}

// Nothing decoded at all is not a length of zero: it is a file whose real length is
// unknown, and calling it 0 s would report a shortfall it has not been shown to have.
@Test func aFileThatDecodesNoTimestampsAtAllIsDamagedRatherThanZeroLength() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0",
                         cover: true, audiobook: true),
        decodeStderr: "")

    let report = try await ExistingBookChecker(tools: tools)
        .check(root.appendingPathComponent("Book.m4b"))

    #expect(!report.passed)
    #expect(report.decodedDuration == nil)
    #expect(report.fatalProblems.contains { $0.contains("Nothing decoded") })
}

// A container with no duration to claim cannot be compared against anything, and the mode
// must not invent one. Say what is missing instead — as a FINDING: the audio decoded from
// end to end, and what is absent is a number in the container's metadata. Fatal here means
// the audio is wrong, and this file's audio has not been shown to be.
@Test func aContainerWithNoDurationIsAFindingNotDamage() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: nil, cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")

    let report = try await ExistingBookChecker(tools: tools)
        .check(root.appendingPathComponent("Book.m4b"))

    #expect(report.passed)
    #expect(report.fatalProblems.isEmpty)
    #expect(report.containerDuration == nil)
    #expect(report.decodedDuration != nil)
    #expect(report.cosmeticProblems.contains { $0.contains("duration") })
}

// A decode that did not finish is not a measurement of anything. ffmpeg killed partway —
// memory pressure, Activity Monitor, a cancel — still prints the `time=` lines it got
// through, and reading those as the file's length turned a machine event into "3.2 h (40%)
// of this file did not decode … Re-download or re-rip this book" about a file nothing had
// been shown to be wrong with. No verdict is the honest answer, which is what this type
// already has `wasChecked` for.
@Test @MainActor func aDecodeThatExitsNonZeroIsNotReportedAsAShortBook() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        // 8 of the 20 seconds, and then killed.
        decodeStderr: "size=N/A time=00:00:08.00 bitrate=N/A speed=200x",
        decodeExit: "137")

    await #expect(throws: ProcessError.self) {
        try await ExistingBookChecker(tools: tools)
            .check(root.appendingPathComponent("Book.m4b"))
    }

    // And through the run the user actually sees: not sound, not damaged, not checked.
    let check = LibraryCheck()
    await check.run(namedFiles(1, in: root), tools: tools)
    let report = try #require(check.reports.first)
    #expect(!report.wasChecked)
    #expect(report.verdict == "Not checked")
    #expect(report.problems.isEmpty)
    #expect(check.damagedCount == 0)
}

// The same asymmetry, from the other end: the ffprobe above uses plain `try` and correctly
// reports "Not checked" when the binary is missing, while the decode's `try?` turned the
// identical failure into "Damaged". A missing binary is not a defect in someone's book.
@Test @MainActor func aDecodeThatCannotBeLaunchedIsNotCheckedRatherThanDamaged() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let probing = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")
    // The probe works; the decode's binary is not there at all.
    let tools = FFmpegTools(ffmpeg: root.appendingPathComponent("no-such-ffmpeg"),
                            ffprobe: probing.ffprobe)

    await #expect(throws: ProcessError.self) {
        try await ExistingBookChecker(tools: tools)
            .check(root.appendingPathComponent("Book.m4b"))
    }

    let check = LibraryCheck()
    await check.run(namedFiles(1, in: root), tools: tools)
    let report = try #require(check.reports.first)
    #expect(!report.wasChecked)
    #expect(report.verdict == "Not checked")
    #expect(check.damagedCount == 0)
}

// The per-file denominator is 1: this is one file handed to one ffmpeg, which is the
// tightest the budget ever is, and the same reading `DurationMeasurer` makes.
@Test func benignTrailingTagNoiseOnOneFileIsNotDamage() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0",
                         cover: true, audiobook: true),
        decodeStderr: """
        [mp3 @ 0x1] Header missing
        [aist#0:0/mp3 @ 0x1] Error submitting EOF to decoder: Invalid data found when processing input
        size=N/A time=00:00:20.00 bitrate=N/A
        """)

    let report = try await ExistingBookChecker(tools: tools)
        .check(root.appendingPathComponent("Book.m4b"))

    #expect(report.passed)
    #expect(report.problems.isEmpty)
}

// Both of ffprobe's time fields, in both of the shapes JSON allows. `format.duration` was
// read as a number OR a string while `chapters[].start_time` was read only as a string and
// fell back to 0 — defensive code only, since the installed ffprobe (8.1) quotes both, but
// had a build ever emitted bare numbers every chapter would have started at 0, the marks
// would not have advanced, and `OutputVerifier` calls that fatal: the queue deletes a
// finished multi-hour encode over a JSON type. One reader for both fields.
@Test func aChapterStartIsReadWhetherFFprobeQuotesItOrNot() throws {
    let quoted = """
    {"chapters":[{"start_time":"0"},{"start_time":"10.5"}],
     "streams":[{"codec_type":"audio"}],"format":{"duration":"20.0"}}
    """
    let bare = """
    {"chapters":[{"start_time":0},{"start_time":10.5}],
     "streams":[{"codec_type":"audio"}],"format":{"duration":20.0}}
    """
    for json in [quoted, bare] {
        let facts = try M4BFacts.parse(json: Data(json.utf8))
        #expect(facts.chapterStarts == [0, 10.5])
        #expect(facts.duration == 20.0)
        #expect(facts.chaptersAscending)
        #expect(facts.chapterCount == 2)
    }

    // And neither field accepts something that is not a finite number: "inf" and "nan" are
    // both text ffprobe can emit and both parse as Doubles that trap in arithmetic.
    let nonsense = """
    {"chapters":[{"start_time":"nan"},{"start_time":"5"}],
     "streams":[],"format":{"duration":"inf"}}
    """
    let facts = try M4BFacts.parse(json: Data(nonsense.utf8))
    #expect(facts.duration == nil)
    // A start that cannot be read is 0, not a missing chapter: the count has to stay the
    // number of marks the file carries, and marks that do not advance are the honest
    // reading of a chapter table that cannot be read.
    #expect(facts.chapterStarts == [0, 5])
}

// MARK: - collecting what to check

@Test func collectingTakesFilesAndFoldersAndFindsOnlyM4Bs() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let nested = root.appendingPathComponent("Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    for name in ["A.m4b", "B.mp3", "C.M4B"] {
        try Data().write(to: root.appendingPathComponent(name))
    }
    try Data().write(to: nested.appendingPathComponent("D.m4b"))
    let loose = root.appendingPathComponent("A.m4b")

    // A folder is walked, including into its children.
    let fromFolder = ExistingBookChecker.collect([root])
    #expect(fromFolder.map(\.lastPathComponent) == ["A.m4b", "C.M4B", "D.m4b"])
    // A file chosen directly is taken as it is.
    #expect(ExistingBookChecker.collect([loose]) == [loose])
    // And the same file reached twice is checked once.
    #expect(ExistingBookChecker.collect([root, loose]).count == 3)
}

// The order the user picked their folders in is information, and a global sort over the
// result threw it away — check the new shelf first and then the archive, and the archive
// came back first. It also made the per-directory sorting dead work.
@Test func collectingKeepsTheOrderTheFoldersWereChosenIn() throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    for folder in ["Zebra", "Archive"] {
        let url = root.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        // Two files each, so the ordering WITHIN a folder is still natural order.
        for name in ["10 Ten.m4b", "9 Nine.m4b"] {
            try Data().write(to: url.appendingPathComponent(name))
        }
    }

    let picked = ["Zebra", "Archive"].map { root.appendingPathComponent($0) }
    #expect(ExistingBookChecker.collect(picked).map(\.lastPathComponent)
            == ["9 Nine.m4b", "10 Ten.m4b", "9 Nine.m4b", "10 Ten.m4b"])
    #expect(ExistingBookChecker.collect(picked).map { $0.deletingLastPathComponent().lastPathComponent }
            == ["Zebra", "Zebra", "Archive", "Archive"])
}

// MARK: - the run

@Test @MainActor func theRunKeepsTheOrderItWasGivenAndCountsAsItGoes() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")
    let files = namedFiles(12, in: root)

    let check = LibraryCheck()
    await check.run(files, tools: tools)

    #expect(!check.isRunning)
    #expect(check.total == 12)
    #expect(check.completed == 12)
    // Results arrive in whatever order twelve concurrent processes finish in; the list the
    // user reads must be the list they chose.
    #expect(check.reports.map(\.url) == files)
    #expect(check.reports.allSatisfy { $0.passed })
    #expect(check.damagedCount == 0)
    #expect(check.summary == "12 sound, 0 damaged")
}

// A sound book with something to fix is neither of the other two states, and burying it in
// the "sound" count would hide every cover and media_type finding on the shelf.
@Test @MainActor func theSummarySeparatesSoundBooksThatStillHaveFindings() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        // Right length, chapters present — but no cover and not flagged as an audiobook.
        probe: probeJSON(chapterStarts: [0, 5], duration: "20.0"),
        decodeStderr: "time=00:00:20.00")

    let check = LibraryCheck()
    await check.run(namedFiles(3, in: root), tools: tools)

    #expect(check.reports.allSatisfy { $0.passed })
    #expect(check.findingCount == 3)
    #expect(check.summary == "3 sound (3 with findings), 0 damaged")
}

@Test @MainActor func cancellingStopsTheRunAndClaimsNoVerdictForWhatItDidNotFinish() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00", delay: "5")
    let files = namedFiles(12, in: root)

    let check = LibraryCheck()
    let running = Task { await check.run(files, tools: tools) }
    // Long enough for the first batch — `FFmpegBudget.concurrentDecodes` of them — to be in
    // flight in their five-second sleep, with more files behind them than that.
    try await Task.sleep(for: .milliseconds(400))
    check.cancelAll()
    _ = await running.value

    #expect(!check.isRunning)
    #expect(check.isCancelled)
    #expect(check.reports.count == 12)
    #expect(check.reports.map(\.url) == files)
    // Nothing that was not finished is reported as sound OR as damaged.
    #expect(check.reports.contains { !$0.wasChecked })
    #expect(check.reports.allSatisfy { $0.wasChecked || $0.problems.isEmpty })
    #expect(check.reports.filter { $0.wasChecked }.count == check.checkedCount)
}

// A folder that holds no .m4b files looks exactly like one that could not be read, and an
// empty results window explains neither. Say something, as every other refusal in the app
// does.
@Test @MainActor func checkingSomethingWithNoBooksInItSaysSoRatherThanShowingNothing() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data().write(to: root.appendingPathComponent("notes.txt"))

    // Its own defaults suite, which is what `AppModel.init` takes one for: with `.standard`
    // this reads the save location the person running the suite has chosen in the app, and
    // `relocateTools` launches a real `Preflight.validate` against whatever ffmpeg is
    // installed — a subprocess racing the fake tools installed on the next line.
    let suite = "m4b-test-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(defaults: defaults)
    model.tools = try Fixtures.fakeTools("exit 0", in: root)
    await model.checkExistingBooks([root])

    #expect(model.libraryCheck.reports.isEmpty)
    #expect(model.libraryCheckMessage?.contains("No .m4b files") == true)
}

// MARK: - checking more, without losing what was found

// "Check More…" said more and did less: `run` started with an empty result list, so a second
// choice threw the first away. Someone who checks sixty books, reads two damage findings and
// then adds another folder lost the findings they had not written down yet.
@Test @MainActor func checkingMoreBooksAddsToTheResultsAlreadyThere() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")
    let first = namedFiles(2, in: root)
    let more = (1...3).map { root.appendingPathComponent("Later \($0).m4b") }

    let check = LibraryCheck()
    await check.run(first, tools: tools)
    #expect(check.reports.count == 2)

    await check.run(more, tools: tools)

    // Both choices, in the order they were made, every one of them still carrying a verdict.
    #expect(check.reports.map(\.url) == first + more)
    #expect(check.reports.allSatisfy { $0.wasChecked })
    #expect(check.checkedCount == 5)
    #expect(check.summary == "5 sound, 0 damaged")
    // The progress figures describe the run that just happened, which is what the header's
    // bar is about — not the accumulated shelf.
    #expect(check.total == 3)
    #expect(check.completed == 3)
}

// Appending must not mean appending the same file twice: two rows for one book puts two
// identical `id`s into the window's `ForEach`, and the second check's answer is the one
// worth keeping anyway.
@Test @MainActor func aFileCheckedAgainKeepsOneRowAndTakesTheNewerVerdict() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")
    let files = namedFiles(2, in: root)

    let check = LibraryCheck()
    await check.run(files, tools: tools)
    #expect(check.damagedCount == 0)

    // The same file again, with the decode now stopping 8 s short of what the container
    // claims — the file went bad between the two checks, which is the case for re-checking.
    try "time=00:00:12.00".write(to: root.appendingPathComponent("decode.err"),
                                 atomically: true, encoding: .utf8)
    await check.run([files[0]], tools: tools)

    #expect(check.reports.count == 2)
    #expect(check.reports.map(\.url) == files)
    #expect(check.damagedCount == 1)
    #expect(check.reports[0].passed == false)
    #expect(check.reports[1].passed == true)
}

// The check window used to lose a whole choice silently: `run` bails when one is already
// going, and `checkExistingBooks` said nothing at all — the user picked thirty files, the
// panel closed, and nothing happened. `setDefaultDestination` and `relocateTools` both
// report their refusals; so does this now.
@Test @MainActor func aSecondCheckWhileOneIsRunningIsRefusedOutLoud() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00", delay: "5")
    let files = try realFiles(3, in: root)

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    model.tools = tools

    let running = Task { await model.checkExistingBooks(Array(files.prefix(2))) }
    var attempts = 0
    while !model.libraryCheck.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }
    #expect(model.libraryCheck.isRunning)

    await model.checkExistingBooks([files[2]])

    #expect(model.libraryCheckMessage?.contains("already running") == true)
    // The refusal the message is reporting: `run` itself says no, rather than the model
    // guessing at whether it would have.
    #expect(await model.libraryCheck.run([files[2]], tools: tools) == false)
    // And the refused files were not quietly added to the run in flight.
    #expect(model.libraryCheck.reports.count == 2)
    #expect(model.libraryCheck.total == 2)

    model.libraryCheck.cancelAll()
    await running.value
}

// The empty state was keyed on the results alone, but `run` sets `total` and `isRunning`
// immediately while the first decode can take minutes — so the window said "No books checked
// yet", with a disabled Choose button, directly under a header reading "0 of 8" beside a
// Cancel button. Every chosen file now has a row from the moment the run starts, and the
// view gates on `!isRunning && reports.isEmpty` as well.
@Test @MainActor func everyChosenFileHasARowFromTheMomentTheRunStarts() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00", delay: "5")
    let files = namedFiles(8, in: root)

    let check = LibraryCheck()
    let running = Task { await check.run(files, tools: tools) }
    var attempts = 0
    while !check.isRunning, attempts < 300 {
        try await Task.sleep(for: .milliseconds(10)); attempts += 1
    }

    #expect(check.reports.count == 8)
    #expect(check.reports.map(\.url) == files)
    // No verdict yet, and none claimed: a file being decoded right now is not sound and not
    // damaged.
    #expect(check.reports.allSatisfy { !$0.wasChecked })
    #expect(check.summary == "0 sound, 0 damaged, 8 not checked")

    // And a report copied or saved at this moment says what it is. It used to read
    // "checked 8 file(s)" with a summary of eight, while the rest of the shelf — possibly
    // including damaged books — was simply absent from the page.
    let partial = check.plainText
    #expect(partial.contains("still going"))
    #expect(partial.contains("0 of 8"))
    #expect(partial.contains("NOT CHECKED"))
    #expect(partial.contains("8 file(s)"))

    check.cancelAll()
    _ = await running.value
    // Finished, the same report no longer claims to be in progress.
    #expect(!check.plainText.contains("still going"))
}

// The two ways of choosing nothing checkable have to agree. The "no .m4b files there" path
// returns before `run`, so it always left earlier results alone; `run` itself used to clear
// them, so the same window forgot or remembered depending on which choice was made.
@Test @MainActor func aChoiceWithNoBooksInItLeavesTheEarlierResultsAlone() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0", cover: true, audiobook: true),
        decodeStderr: "time=00:00:20.00")
    let files = try realFiles(2, in: root)
    let empty = root.appendingPathComponent("Nothing Here")
    try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)

    let (model, cleanup) = scratchModel()
    defer { cleanup() }
    model.tools = tools

    await model.checkExistingBooks([files[0]])
    #expect(model.libraryCheck.reports.count == 1)

    await model.checkExistingBooks([files[1]])
    #expect(model.libraryCheck.reports.count == 2)

    await model.checkExistingBooks([empty])
    #expect(model.libraryCheckMessage?.contains("No .m4b files") == true)
    #expect(model.libraryCheck.reports.count == 2)
    #expect(model.libraryCheck.checkedCount == 2)
}

@Test @MainActor func theResultsAreExportableAsPlainText() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tools = try fakeCheckerTools(
        in: root,
        probe: probeJSON(chapterStarts: [0], duration: "20.0"),
        decodeStderr: "time=00:00:18.00")
    let files = namedFiles(2, in: root)

    let check = LibraryCheck()
    await check.run(files, tools: tools)

    let text = check.plainText
    // Every file, its verdict and its problems — enough to act on outside the app.
    #expect(text.contains("Book 1.m4b"))
    #expect(text.contains("Book 2.m4b"))
    #expect(text.contains("did not decode"))
    #expect(text.contains("cover"))
    #expect(check.damagedCount == 2)
    // The header on screen and the first lines of the export are the same sentence.
    #expect(text.contains("0 sound, 2 damaged"))
    #expect(check.summary == "0 sound, 2 damaged")
}
