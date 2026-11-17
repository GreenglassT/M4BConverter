import Foundation
import Testing
@testable import M4BConverter

private func track(_ name: String, titled title: String, seconds: Double = 600) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), estimatedDuration: seconds,
              tags: ["title": title])
}

private let files = [("01.mp3", "One"), ("02.mp3", "Two"), ("03.mp3", "Three")]

/// Three ten-minute files whose filename order is their reading order, so the inferred
/// strategy is `.fileBoundaries` and the derived chapters are `0…600`, `600…1200`,
/// `1200…1800`, titled from the tags.
@MainActor private func book() -> Book {
    Book(folder: URL(fileURLWithPath: "/b"),
         tracks: files.map { track($0.0, titled: $0.1) })
}

/// The two invariants everything downstream depends on: the list covers the book with no
/// gap and no overlap, and the starts strictly ascend. `OutputVerifier` rejects a finished
/// file whose chapter starts do not increase — after the encode — so an edit that could
/// produce one would cost the user hours.
private func isContiguousAndAscending(_ chapters: [Chapter]) -> Bool {
    guard !chapters.isEmpty else { return true }
    for (a, b) in zip(chapters, chapters.dropFirst()) {
        guard a.end == b.start, a.start < b.start else { return false }
    }
    return chapters.allSatisfy { $0.start < $0.end }
}

// MARK: - Times

@Test func timecodesRoundTripThroughTheFieldTheUserSees() {
    for seconds in [0.0, 12.5, 90, 3661, 3661.5, 29_400.125] {
        #expect(Timecode.parse(Timecode.format(seconds)) == seconds)
    }
    #expect(Timecode.format(3661) == "1:01:01")
    #expect(Timecode.format(3661.5) == "1:01:01.500")
    #expect(Timecode.format(0) == "0:00:00")
}

// Forgiving about what it accepts, strict about what it stores: a user typing a boundary
// should not have to count the colons, but the value kept is rounded to the millisecond
// the .m4b metadata can actually express.
@Test func timecodeParsingAcceptsWhatAPersonWouldType() {
    #expect(Timecode.parse("1:01:01") == 3661)
    #expect(Timecode.parse(" 1:01:01.5 ") == 3661.5)
    #expect(Timecode.parse("1:01:01,5") == 3661.5)
    #expect(Timecode.parse("2:03") == 123)
    #expect(Timecode.parse("83") == 83)
    #expect(Timecode.parse("0:00") == 0)
    // Rounded to the millisecond, so what is displayed and what is stored agree.
    #expect(Timecode.parse("0:00:01.00049") == 1.0)

    for rubbish in ["", "   ", "abc", "1:2:3:4", "-5", "1:", ":30", "1:2.5:3", "12e3"] {
        #expect(Timecode.parse(rubbish) == nil, "\(rubbish) should not parse")
    }
}

// MARK: - Manual edits vs. the derived list

// The central rule. `recompute()` rebuilds the ordering, the total and the warnings from
// the strategies — and it used to rebuild the chapter list along with them, which since
// the last refactor fires from `didSet` on three properties. Any hand edit would have
// been destroyed by the next touch of a picker with nothing on screen to say so.
@Test @MainActor func anEditSurvivesARecompute() throws {
    let b = book()
    #expect(!b.hasManualChapters)
    try b.setChapterTitle("Prologue", at: 0)
    #expect(b.hasManualChapters)

    b.recompute()
    #expect(b.chapters.map(\.title) == ["Prologue", "Two", "Three"])
    #expect(b.manualChapters?.map(\.title) == ["Prologue", "Two", "Three"])

    // And through the `didSet` route, which is how the app actually gets here.
    b.tracks = files.map { track($0.0, titled: $0.1) }
    #expect(b.chapters.map(\.title) == ["Prologue", "Two", "Three"])
}

// Assigning a strategy is not consent to throw the edits away. The inspector asks first
// and only then calls `adoptChapterStrategy`; the plain assignment must keep them, or the
// confirmation could be bypassed by any other route to the same property.
@Test @MainActor func changingAStrategyDoesNotSilentlyDiscardEdits() throws {
    let b = book()
    try b.setChapterTitle("Prologue", at: 0)

    b.chapterStrategy = .overdriveMarkers
    #expect(b.chapters.map(\.title) == ["Prologue", "Two", "Three"])
    b.order = .trackTag
    #expect(b.chapters.map(\.title) == ["Prologue", "Two", "Three"])
    #expect(b.hasManualChapters)
}

// The confirmed half of the same guard: the user was asked, and said yes.
@Test @MainActor func adoptingAStrategyDeliberatelyRegeneratesTheList() throws {
    let b = book()
    try b.setChapterTitle("Prologue", at: 0)

    b.adoptChapterStrategy(.fileBoundaries)
    #expect(!b.hasManualChapters)
    #expect(b.chapters.map(\.title) == ["One", "Two", "Three"])

    try b.setChapterTitle("Prologue", at: 0)
    b.adoptOrder(.trackTag)
    #expect(!b.hasManualChapters)
    #expect(b.chapters.map(\.title) == ["One", "Two", "Three"])
}

// The explicit way back, for a user who wants the strategy's list after all.
@Test @MainActor func revertingReturnsToTheStrategyDerivedList() throws {
    let b = book()
    try b.mergeChapter(at: 0)
    try b.setChapterTitle("Everything", at: 0)
    #expect(b.chapters.count == 2)

    b.revertToAutomaticChapters()
    #expect(!b.hasManualChapters)
    #expect(b.chapters.map(\.title) == ["One", "Two", "Three"])
    #expect(b.chapters.count == 3)
}

// "This setting produces no chapters." is about the SETTING. While a hand-edited list is
// in effect the setting is not what the book converts with, so the warning would be both
// untrue and unactionable — and it must come back the moment the user reverts.
@Test @MainActor func theNoChaptersWarningDescribesTheStrategyNotTheEditedList() throws {
    let b = book()
    try b.setChapterTitle("Prologue", at: 0)

    // A strategy these files cannot satisfy. The derived list would be empty; the book's
    // is not, because the user's list is what it converts with.
    b.chapterStrategy = .overdriveMarkers
    #expect(!b.chapters.isEmpty)
    #expect(!b.warnings.contains { $0.contains("no chapters") })
    #expect(b.status == .ready)

    b.revertToAutomaticChapters()
    #expect(b.chapters.isEmpty)
    #expect(b.warnings.contains { $0.contains("no chapters") })
    #expect(b.status == .warning)
}

// MARK: - Boundaries

// One time, two chapters. Editing `start` and `end` independently is what produces the
// gaps and overlaps `OutputVerifier` rejects after the encode.
@Test @MainActor func movingABoundaryMovesBothSidesOfIt() throws {
    let b = book()
    try b.moveChapterBoundary(after: 0, to: 500)

    #expect(b.chapters[0].end == 500)
    #expect(b.chapters[1].start == 500)
    #expect(b.chapters[0].start == 0)
    #expect(b.chapters[1].end == 1200)
    #expect(isContiguousAndAscending(b.chapters))
}

@Test @MainActor func aBoundaryOutsideItsNeighboursIsRejected() throws {
    let b = book()
    let original = b.chapters

    // At or before the chapter it would end, and at or after the one it would begin.
    for time in [-1.0, 0, 1200, 1500] {
        #expect(throws: ChapterEditError.self) {
            try b.moveChapterBoundary(after: 0, to: time)
        }
    }
    #expect(b.chapters == original)
    #expect(!b.hasManualChapters)
}

// Two times a fraction of a millisecond apart are one time once written: FFMetadataWriter
// rounds to `TIMEBASE=1/1000`. Accepting this would produce a file whose chapter starts do
// not strictly increase — which `OutputVerifier` only finds out after the encode, and then
// deletes the finished book over.
@Test @MainActor func aBoundaryThatCollidesOnceWrittenIsRejected() throws {
    let b = Book(folder: URL(fileURLWithPath: "/b"),
                 tracks: [track("01.mp3", titled: "One", seconds: 600.4408),
                          track("02.mp3", titled: "Two", seconds: 600)])
    #expect(b.chapters[1].start == 600.4408)

    // Distinct as a Double, identical as milliseconds: both render as START=600441.
    #expect(throws: ChapterEditError.self) {
        try b.splitChapter(at: 1, at: 600.4412)
    }
    try b.splitChapter(at: 1, at: 600.442)
    let written = FFMetadataWriter.render(metadata: [:], chapters: b.chapters)
    let starts = written.split(separator: "\n").filter { $0.hasPrefix("START=") }
    #expect(starts.count == Set(starts).count)
}

// The first chapter starts where the audio does and the last ends where it stops. Neither
// is a boundary between two chapters, so neither can be moved.
@Test @MainActor func theOuterEdgesOfTheBookAreNotBoundaries() throws {
    let b = book()
    #expect(throws: ChapterEditError.self) { try b.moveChapterBoundary(after: -1, to: 10) }
    #expect(throws: ChapterEditError.self) { try b.moveChapterBoundary(after: 2, to: 1700) }
    #expect(b.chapters.first?.start == 0)
    #expect(b.chapters.last?.end == 1800)
}

// MARK: - Merge and split

@Test @MainActor func mergingAbsorbsTheNextChapterAndKeepsTheListContiguous() throws {
    let b = book()
    try b.mergeChapter(at: 0)

    #expect(b.chapters.count == 2)
    #expect(b.chapters[0].start == 0)
    #expect(b.chapters[0].end == 1200)
    #expect(b.chapters[0].title == "One")
    #expect(b.chapters[1] == Chapter(start: 1200, end: 1800, title: "Three"))
    #expect(isContiguousAndAscending(b.chapters))
}

@Test @MainActor func theLastChapterHasNothingToMergeWith() throws {
    let b = book()
    #expect(throws: ChapterEditError.self) { try b.mergeChapter(at: 2) }
    #expect(throws: ChapterEditError.self) { try b.mergeChapter(at: 7) }
    #expect(b.chapters.count == 3)
}

@Test @MainActor func splittingProducesTwoContiguousChapters() throws {
    let b = book()
    try b.splitChapter(at: 1, at: 900)

    #expect(b.chapters.count == 4)
    #expect(b.chapters[1].start == 600)
    #expect(b.chapters[1].end == 900)
    #expect(b.chapters[2].start == 900)
    #expect(b.chapters[2].end == 1200)
    #expect(b.chapters[1].title == "Two")
    #expect(!b.chapters[2].title.isEmpty)
    #expect(isContiguousAndAscending(b.chapters))
}

@Test @MainActor func aSplitAtOrOutsideTheChaptersOwnBoundsIsRejected() throws {
    let b = book()
    let original = b.chapters
    for time in [600.0, 1200, 0, 1799] {
        #expect(throws: ChapterEditError.self) { try b.splitChapter(at: 1, at: time) }
    }
    #expect(b.chapters == original)
}

// A run of edits, checked as a whole: whatever the user does, what reaches the encoder
// still covers the book exactly once and still ascends.
@Test @MainActor func aSequenceOfEditsStaysContiguousAndAscending() throws {
    let b = book()
    try b.splitChapter(at: 0, at: 100)
    try b.splitChapter(at: 3, at: 1500)
    try b.moveChapterBoundary(after: 1, to: 550)
    try b.mergeChapter(at: 2)
    try b.setChapterTitle("Finale", at: b.chapters.count - 1)

    #expect(isContiguousAndAscending(b.chapters))
    #expect(b.chapters.first?.start == 0)
    #expect(b.chapters.last?.end == 1800)
}

// MARK: - Titles

@Test @MainActor func anEmptyTitleIsRejected() throws {
    let b = book()
    for title in ["", "   ", "\n", "\r\n  \n"] {
        #expect(throws: ChapterEditError.self) { try b.setChapterTitle(title, at: 0) }
    }
    #expect(b.chapters[0].title == "One")
    #expect(!b.hasManualChapters)
}

// FFMetadataWriter escapes newlines correctly, so this is not a corruption risk — but a
// chapter title spanning two lines is not something anyone means to create, and it is
// what a paste from a web page produces.
@Test @MainActor func typedTitlesAreFlattenedToOneLine() throws {
    let b = book()
    try b.setChapterTitle("  Chapter 1\r\nThe Beginning \n", at: 0)
    #expect(b.chapters[0].title == "Chapter 1 The Beginning")
}

// The rule behind the table's `.disabled(book.isConverting)`. A run reads the chapter list
// once and writes it into the metadata file ffmpeg is muxing from, so an edit accepted now
// would change the table without changing the file — and the finished .m4b would disagree
// with the app that made it.
@Test @MainActor func chaptersCannotBeEditedWhileTheBookIsConverting() throws {
    let b = book()
    try b.setChapterTitle("Prologue", at: 0)
    b.status = .converting

    #expect(throws: ChapterEditError.bookIsConverting) { try b.setChapterTitle("No", at: 1) }
    #expect(throws: ChapterEditError.bookIsConverting) { try b.mergeChapter(at: 0) }
    #expect(throws: ChapterEditError.bookIsConverting) { try b.splitChapter(at: 0, at: 300) }
    #expect(throws: ChapterEditError.bookIsConverting) {
        try b.moveChapterBoundary(after: 0, to: 300)
    }
    b.revertToAutomaticChapters()
    b.adoptChapterStrategy(.overdriveMarkers)

    // Refused, not lost: everything is still there when the run ends.
    #expect(b.chapters.map(\.title) == ["Prologue", "Two", "Three"])
    #expect(b.hasManualChapters)
    b.status = .ready
    try b.setChapterTitle("Prologue Two", at: 1)
    #expect(b.chapters.map(\.title) == ["Prologue", "Prologue Two", "Three"])
}

// The same rule for a book whose run is over. A verified book's chapter list is a record of
// the .m4b that was written rather than a plan for one: the file already carries the list
// the run wrote, nothing will write it again, and an edit accepted here would leave the
// table describing a file that does not carry it — on controls the inspector disables, with
// no rule behind them.
@Test @MainActor func chaptersCannotBeEditedOnceTheRunIsOver() throws {
    for status in [BookStatus.verified, .failed("disk full")] {
        let b = book()
        b.status = status
        #expect(!b.acceptsEdits)
        #expect(throws: ChapterEditError.bookIsFinished) { try b.setChapterTitle("No", at: 0) }
        #expect(throws: ChapterEditError.bookIsFinished) { try b.mergeChapter(at: 0) }
        #expect(throws: ChapterEditError.bookIsFinished) { try b.splitChapter(at: 0, at: 300) }
        #expect(throws: ChapterEditError.bookIsFinished) {
            try b.moveChapterBoundary(after: 0, to: 300)
        }
        // The other two routes into the list are guarded by the same rule.
        b.revertToAutomaticChapters()
        b.adoptChapterStrategy(.overdriveMarkers)
        b.adoptOrder(.trackTag)
        #expect(b.chapters.map(\.title) == ["One", "Two", "Three"])
        #expect(!b.hasManualChapters)
    }

    // Refused, not lost: a failed book is editable again the moment Retry puts it back in
    // the queue, which is the only state in which its chapters decide anything.
    let b = book()
    b.status = .failed("disk full")
    #expect(b.retry())
    try b.setChapterTitle("Prologue", at: 0)
    #expect(b.chapters.first?.title == "Prologue")
}

// MARK: - Reaching the encoder

@Test @MainActor func manualChaptersReachTheJobAndTheMetadataFile() throws {
    let b = book()
    try b.mergeChapter(at: 1)
    try b.setChapterTitle("Part Two", at: 1)

    let chapters = try b.conversionChapters(
        tracks: b.orderedTracks, durations: b.orderedTracks.map(\.estimatedDuration))
    #expect(chapters.map(\.title) == ["One", "Part Two"])

    let job = b.makeJob(tracks: b.orderedTracks, chapters: chapters, totalDuration: 1800)
    #expect(job.chapters.map(\.title) == ["One", "Part Two"])
    let rendered = FFMetadataWriter.render(metadata: job.metadata, chapters: job.chapters)
    #expect(rendered.contains("title=Part Two"))
    #expect(rendered.components(separatedBy: "[CHAPTER]").count == 3)
}

// The exact durations measured at conversion time differ from the container's estimates by
// milliseconds, and the last chapter has to reach the end of the audio: a chapter claiming
// audio that is not there, or stopping short of it, is what the user's player shows.
// Nothing else the user typed is touched.
@Test @MainActor func aManualListIsFittedToTheMeasuredLengthWithoutMovingWhatTheUserSet() throws {
    let b = book()
    try b.moveChapterBoundary(after: 0, to: 500)

    let fitted = try b.conversionChapters(tracks: b.orderedTracks,
                                          durations: [600, 600, 599.5])
    #expect(fitted.map(\.start) == [0, 500, 1200])
    #expect(fitted.last?.end == 1799.5)
    #expect(isContiguousAndAscending(fitted))
}

// The other side of the same rule, and the one that used to be silent. `fitted` only ever
// moves the final `end`, so when the measured audio stops at or before the last chapter's
// start there is nothing it can honestly do — and it returned the list UNCHANGED, which is
// exactly the "claims audio that is not there" its own comment forbids. The starts still
// ascend and the count still matches, so `OutputVerifier` (which compares the file against
// the measured total, not against the chapter span) passes it and the user gets an .m4b
// whose last chapters point past the end of the audio.
@Test @MainActor func aListRunningPastTheMeasuredAudioIsRefusedRatherThanWrittenAsIs() throws {
    let b = book()
    try b.setChapterTitle("Prologue", at: 0)
    let ordered = b.orderedTracks

    // The last chapter starts at 1200; this book decodes to 1150.
    #expect(throws: ChapterEditError.chapterStartsPastTheAudio(start: 1200, total: 1150)) {
        _ = try b.conversionChapters(tracks: ordered, durations: [600, 500, 50])
    }
    // An INTERIOR boundary past the end is the same lie, and used to reach the file
    // untouched: the total lands between two of the user's boundaries, and the first one
    // the audio does not reach is the one named.
    #expect(throws: ChapterEditError.chapterStartsPastTheAudio(start: 1200, total: 700)) {
        _ = try b.conversionChapters(tracks: ordered, durations: [400, 300, 0])
    }
    // Nothing was changed on the way to refusing.
    #expect(b.chapters.map(\.start) == [0, 600, 1200])
}

// And on the millisecond grid, like everything else in `ChapterEditor`: a total 0.4 ms past
// the last chapter's start is the same millisecond once written, so fitting to it would
// render START == END for the final chapter.
@Test @MainActor func fittingComparesOnTheMillisecondGrid() throws {
    let chapters = [Chapter(start: 0, end: 600, title: "One"),
                    Chapter(start: 600, end: 1200, title: "Two")]

    #expect(throws: ChapterEditError.chapterStartsPastTheAudio(start: 600,
                                                              total: 600.0004)) {
        _ = try ChapterEditor.fitted(chapters, toTotal: 600.0004)
    }
    // As is a total that lands exactly on it: that chapter would be zero seconds long.
    #expect(throws: ChapterEditError.chapterStartsPastTheAudio(start: 600, total: 600)) {
        _ = try ChapterEditor.fitted(chapters, toTotal: 600)
    }
    // A millisecond further on is a real millisecond of audio, and fits.
    let fitted = try ChapterEditor.fitted(chapters, toTotal: 600.001)
    #expect(fitted.last?.end == 600.001)
}

// End to end: the refusal reaches the user as a named failure BEFORE a single frame is
// encoded, rather than as a finished file describing audio that is not there.
@Test @MainActor func aBookWhoseChaptersOutrunItsAudioFailsBeforeEncoding() async throws {
    let (tools, dir) = try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*) echo 'time=00:00:09.20' >&2; exit 0 ;;
      *-progress*) touch "$D/encoded"; for last; do :; done; echo X > "$last"; exit 0 ;;
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
    // The user's own list, typed against the scan-time estimates: 0…10, 10…19 and 19…20.
    // Each file decodes 0.8 s short of what its container claims — inside the allowance, so
    // the measurement stands — which leaves the book 18.4 s long and the last chapter
    // starting 0.6 s after the audio stops.
    try b.splitChapter(at: 1, at: 19)

    await ConversionQueue(tools: tools).convertAll([b])

    #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("encoded").path))
    #expect(b.writtenURL == nil)
    guard case let .failed(message) = b.status else {
        Issue.record("expected a failure, got \(b.status)")
        return
    }
    // Readable, and about the chapter that outruns the audio — not "error 4".
    #expect(message.contains("0:00:19"))
    #expect(!message.lowercased().contains("error 4"))
}

// Without a manual list the conversion still re-plans from the exact durations, which is
// the whole point of measuring them.
@Test @MainActor func aDerivedListIsStillPlannedFromTheMeasuredDurations() throws {
    let b = book()
    let planned = try b.conversionChapters(tracks: b.orderedTracks, durations: [1, 2, 3])
    #expect(planned.map(\.start) == [0, 1, 3])
    #expect(planned.last?.end == 6)
}

// End to end through the queue, which is where the edits could still have been lost: step
// 2 of `convert` re-plans the chapters from the exact durations and used to assign that
// list over the book's. What ffmpeg is handed is what the user typed.
@Test @MainActor func theEncoderIsGivenTheEditedChaptersNotTheReplannedOnes() async throws {
    let (tools, dir) = try Fixtures.fakeTools("""
    D="$(dirname "$0")"
    case "$*" in
      *"-f null"*) echo 'time=00:00:10.00' >&2; exit 0 ;;
      *-progress*)
        for a in "$@"; do case "$a" in *meta.txt) cp "$a" "$D/meta-seen.txt" ;; esac; done
        for last; do :; done; echo CONVERTED > "$last"; exit 0 ;;
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
    #expect(b.chapters.count == 2)
    try b.mergeChapter(at: 0)
    try b.setChapterTitle("The Whole Thing", at: 0)

    try Fixtures.verifierJSON(chapterCount: 1, duration: 20, cover: false, audiobook: true)
        .write(to: dir.appendingPathComponent("verify.json"),
               atomically: true, encoding: .utf8)

    await ConversionQueue(tools: tools).convertAll([b])
    #expect(b.status == .verified)

    let metadata = try String(contentsOf: dir.appendingPathComponent("meta-seen.txt"),
                              encoding: .utf8)
    #expect(metadata.contains("title=The Whole Thing"))
    #expect(metadata.components(separatedBy: "[CHAPTER]").count == 2)
    // And the table still shows the user's list afterwards, not a re-planned one.
    #expect(b.chapters.map(\.title) == ["The Whole Thing"])
}
