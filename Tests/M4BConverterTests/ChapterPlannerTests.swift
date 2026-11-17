import Foundation
import Testing
@testable import M4BConverter

private func t(_ name: String, tags: [String: String] = [:]) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), tags: tags)
}

@Test func fileBoundariesUsesTitleTagsAndCumulativeOffsets() {
    let tracks = [t("1.mp3", tags: ["title": "Opening"]), t("2.mp3", tags: ["title": "Chapter 1"])]
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: [10, 20], strategy: .fileBoundaries)
    #expect(chapters.count == 2)
    #expect(chapters[0] == Chapter(start: 0, end: 10, title: "Opening"))
    #expect(chapters[1] == Chapter(start: 10, end: 30, title: "Chapter 1"))
}

@Test func fileBoundariesFallsBackToFilenameStem() {
    let chapters = ChapterPlanner.plan(tracks: [t("Prologue.mp3")], durations: [5],
                                       strategy: .fileBoundaries)
    #expect(chapters[0].title == "Prologue")
}

@Test func filenamePatternExtractsCaptureGroup() {
    let tracks = [t("Bleak House - 004 - London, 1852: Prologue.mp3")]
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: [5],
                                       strategy: .filenamePattern(ChapterStrategy.defaultFilenamePattern))
    #expect(chapters[0].title == "London, 1852: Prologue")
}

@Test func overdriveMarkersAreOffsetByPrecedingFiles() {
    let xml = "<Name>A</Name><Time>0:00.000</Time><Name>B</Name><Time>0:05.000</Time>"
    let tracks = [t("1.mp3", tags: [OverDriveMarkers.tagKey: xml]),
                  t("2.mp3", tags: [OverDriveMarkers.tagKey: "<Name>C</Name><Time>0:02.000</Time>"])]
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: [10, 10],
                                       strategy: .overdriveMarkers)
    #expect(chapters.map(\.title) == ["A", "B", "C"])
    #expect(abs(chapters[2].start - 12.0) < 0.001)
    #expect(abs(chapters[2].end - 20.0) < 0.001)
}

@Test func markersAtOrPastFileEndAreDiscarded() {
    let xml = "<Name>Good</Name><Time>0:01.000</Time><Name>Bogus</Name><Time>0:50.000</Time>"
    let chapters = ChapterPlanner.plan(tracks: [t("1.mp3", tags: [OverDriveMarkers.tagKey: xml])],
                                       durations: [10], strategy: .overdriveMarkers)
    #expect(chapters.map(\.title) == ["Good"])
}

@Test func chapterStartsAreStrictlyIncreasing() {
    let xml = "<Name>A</Name><Time>0:01.000</Time><Name>B</Name><Time>0:01.000</Time>"
    let chapters = ChapterPlanner.plan(tracks: [t("1.mp3", tags: [OverDriveMarkers.tagKey: xml])],
                                       durations: [10], strategy: .overdriveMarkers)
    #expect(chapters.count == 1)
}

/// Every START line the metadata file would carry, as `FFMetadataWriter` renders it.
private func writtenStarts(_ chapters: [Chapter]) -> [String] {
    FFMetadataWriter.render(metadata: [:], chapters: chapters)
        .split(separator: "\n").map(String.init).filter { $0.hasPrefix("START=") }
}

// Two markers a fraction of a millisecond apart are ONE time once written: the metadata
// file is `TIMEBASE=1/1000`, so both render as START=10000. Comparing the Doubles let both
// through, ffmpeg accepted them and exited 0, ffprobe reported two chapters starting at the
// same second, and `OutputVerifier` — which asks `ChapterEditor`'s millisecond question of
// the finished file — called that non-ascending and the queue deleted a completed encode.
// The rule the editor enforces while the user types has to be the rule the generator uses.
@Test func markersThatCollideOnceWrittenProduceOneChapterNotTwo() {
    let xml = "<Name>A</Name><Time>0:10.000</Time><Name>B</Name><Time>0:10.0004</Time>"
    let chapters = ChapterPlanner.plan(tracks: [t("1.mp3", tags: [OverDriveMarkers.tagKey: xml])],
                                       durations: [20], strategy: .overdriveMarkers)

    #expect(chapters.count == 1)
    #expect(ChapterEditor.startsStrictlyAscend(chapters.map(\.start)))
    let starts = writtenStarts(chapters)
    #expect(starts.count == Set(starts).count)
}

// The same collapse reached the other way: a file shorter than a millisecond leaves the
// next file starting on the same written millisecond as this one.
@Test func aSubMillisecondFileDoesNotPutTwoChaptersOnOneMillisecond() {
    let tracks = [t("A.mp3", tags: ["title": "A"]),
                  t("B.mp3", tags: ["title": "B"]),
                  t("C.mp3", tags: ["title": "C"])]
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: [10, 0.0004, 10],
                                       strategy: .fileBoundaries)

    #expect(ChapterEditor.startsStrictlyAscend(chapters.map(\.start)))
    let starts = writtenStarts(chapters)
    #expect(starts.count == Set(starts).count)
    #expect(chapters.allSatisfy { $0.start < $0.end })
}

// OverDriveMarkers.parse returns markers in document order with no sorting or
// deduplication. A marker that would move a chapter backwards is dropped rather
// than reordered, keeping chapter starts strictly increasing.
@Test func outOfOrderMarkersAreDropped() {
    let xml = "<Name>Later</Name><Time>0:05.000</Time><Name>Earlier</Name><Time>0:02.000</Time>"
    let chapters = ChapterPlanner.plan(tracks: [t("1.mp3", tags: [OverDriveMarkers.tagKey: xml])],
                                       durations: [10], strategy: .overdriveMarkers)
    #expect(chapters.map(\.title) == ["Later"])
    #expect(abs(chapters[0].start - 5.0) < 0.001)
    #expect(abs(chapters[0].end - 10.0) < 0.001)
}

// A zero-length file must not emit a chapter: its entry would tie with the next
// file's offset and the strictly-increasing filter would drop the NEXT file.
@Test func zeroDurationFileDoesNotDisplaceItsNeighbour() {
    let tracks = [t("A.mp3", tags: ["title": "A"]),
                  t("B.mp3", tags: ["title": "B"]),
                  t("C.mp3", tags: ["title": "C"])]
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: [10, 0, 10],
                                       strategy: .fileBoundaries)
    #expect(chapters.map(\.title) == ["A", "C"])
    #expect(chapters.allSatisfy { $0.start < $0.end })
}

@Test func trailingZeroDurationFileProducesNoZeroLengthChapter() {
    let chapters = ChapterPlanner.plan(
        tracks: [t("A.mp3", tags: ["title": "A"]), t("B.mp3", tags: ["title": "B"])],
        durations: [10, 0], strategy: .fileBoundaries)
    #expect(chapters.allSatisfy { $0.start < $0.end })
    #expect(chapters.map(\.title) == ["A"])
}

@Test func emptyAndAllZeroInputsYieldNoChapters() {
    #expect(ChapterPlanner.plan(tracks: [], durations: [], strategy: .fileBoundaries).isEmpty)
    #expect(ChapterPlanner.plan(tracks: [t("A.mp3"), t("B.mp3")], durations: [0, 0],
                                strategy: .fileBoundaries).isEmpty)
}

// A non-participating capture group has range {NSNotFound, 0}; substringing it
// throws NSInvalidArgumentException and aborts the process.
@Test func nonParticipatingCaptureGroupFallsBackInsteadOfCrashing() {
    let pattern = #"(?:(a+)|b+)\.mp3$"#
    #expect(ChapterPlanner.patternMatchesAll([t("bbb.mp3")], pattern: pattern) == false)
    let chapters = ChapterPlanner.plan(tracks: [t("bbb.mp3")], durations: [5],
                                       strategy: .filenamePattern(pattern))
    #expect(chapters.map(\.title) == ["bbb"])
}

@Test func patternCapturingNothingIsRejected() {
    #expect(ChapterPlanner.patternMatchesAll([t("Something.mp3"), t(".mp3")],
                                             pattern: #"^(.*)\.mp3$"#) == false)
}
