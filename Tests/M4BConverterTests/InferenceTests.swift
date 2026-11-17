import Foundation
import Testing
@testable import M4BConverter

private func t(_ name: String, tags: [String: String] = [:]) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), tags: tags)
}

@Test func agreeingOrdersPickFilenameWithNoWarning() {
    let tracks = [t("01.mp3", tags: ["track": "1"]), t("02.mp3", tags: ["track": "2"])]
    let result = Inference.infer(tracks)
    #expect(result.order == .filename)
    #expect(result.warnings.isEmpty)
}

// Natural sort already places "Chapter 2" before "Chapter 10", so filenames of that
// shape do NOT disagree with track tags. A genuine disagreement needs filenames whose
// natural order differs from the numbering — a rip where names and tags don't correspond.
@Test func disagreeingOrdersPickTrackTagAndWarn() {
    let tracks = [t("beta.mp3", tags: ["track": "1"]),
                  t("alpha.mp3", tags: ["track": "2"])]
    let result = Inference.infer(tracks)
    #expect(result.order == .trackTag)
    #expect(result.warnings.count == 1)
}

// Verified against a real book: natural filename order and track-tag order
// agree for this layout, so it is NOT flagged. The ordering rule exists for
// genuinely mismatched rips, not for this one.
@Test func agreeingOrdersNeedNoTrackTagOverride() {
    var tracks = [t("Gulliver's Travels - 001.mp3", tags: ["track": "1"])]
    for n in [2, 3, 9, 10, 11, 25, 74, 75] {
        tracks.append(t("Gulliver's Travels - Chapter \(n).mp3", tags: ["track": "\(n)"]))
    }
    let result = Inference.infer(tracks)
    #expect(result.order == .filename)
    #expect(result.warnings.isEmpty)
}

@Test func missingTrackTagsFallBackToFilename() {
    let tracks = [t("b.mp3"), t("a.mp3")]
    #expect(Inference.infer(tracks).order == .filename)
}

@Test func overdriveMarkersWinWhenPresent() {
    let tracks = [t("a.mp3", tags: [OverDriveMarkers.tagKey: "<Name>X</Name><Time>0:00.000</Time>"])]
    #expect(Inference.infer(tracks).chapterStrategy == .overdriveMarkers)
}

@Test func filenamePatternChosenOnlyWhenEveryFileMatches() {
    let all = [t("Book - 01 - Opening.mp3"), t("Book - 02 - Chapter 1.mp3")]
    #expect(Inference.infer(all).chapterStrategy == .filenamePattern(ChapterStrategy.defaultFilenamePattern))

    let partial = [t("Book - 01 - Opening.mp3"), t("stray.mp3")]
    #expect(Inference.infer(partial).chapterStrategy == .fileBoundaries)
}

@Test func metadataComesFromTagsUntrimmed() {
    let tracks = [t("a.mp3", tags: ["album": "Rob Roy: The Waverley Novels, Book 4",
                                    "artist": "Walter Scott", "date": "2015-07-16"])]
    let result = Inference.infer(tracks)
    #expect(result.title == "Rob Roy: The Waverley Novels, Book 4")
    #expect(result.author == "Walter Scott")
    #expect(result.year == "2015")
}

// Tags that all say the same thing carry no ordering information. Trusting them
// would order by directory-scan order while claiming the filenames disagreed.
@Test func identicalTrackTagsDoNotCountAsDisagreement() {
    let tracks = [t("b.mp3", tags: ["track": "1"]), t("a.mp3", tags: ["track": "1"])]
    let result = Inference.infer(tracks)
    #expect(result.order == .filename)
    #expect(result.warnings.isEmpty)
}

// ID3 writers often emit empty frames rather than omitting them; `??` alone
// would let a blank tag short-circuit the fallback chain.
@Test func emptyTagsFallThroughToTheNextSource() {
    let tracks = [t("a.mp3", tags: ["album": "", "artist": "", "album_artist": "Real Author"])]
    let result = Inference.infer(tracks)
    #expect(result.title == "b")              // parent directory name (t() builds /b/\(name))
    #expect(result.author == "Real Author")   // album_artist, not discarded
}

@Test func emptyAndSingleFileInputsAreClean() {
    let empty = Inference.infer([])
    #expect(empty.title == "Untitled")
    #expect(empty.warnings.isEmpty)

    let single = Inference.infer([t("only.mp3", tags: ["track": "1"])])
    #expect(single.order == .filename)
    #expect(single.warnings.isEmpty)
}

// When a genuine disagreement flips the order, metadata must follow the track
// that sorts first under the CHOSEN order, not the original array order.
@Test func metadataFollowsTheChosenOrder() {
    let tracks = [t("beta.mp3", tags: ["track": "1", "album": "FromBeta"]),
                  t("alpha.mp3", tags: ["track": "2", "album": "FromAlpha"])]
    #expect(Inference.infer(tracks).title == "FromBeta")
}
