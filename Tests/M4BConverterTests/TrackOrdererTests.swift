import Foundation
import Testing
@testable import M4BConverter

private func track(_ name: String, track tag: String? = nil) -> TrackInfo {
    var tags: [String: String] = [:]
    if let tag { tags["track"] = tag }
    return TrackInfo(url: URL(fileURLWithPath: "/books/\(name)"), tags: tags)
}

// Regression: a real book whose filenames put Chapter 10 before Chapter 2.
@Test func trackTagOrderBeatsFilenameOrderForChapterTen() {
    let tracks = [
        track("Gulliver's Travels - Chapter 10.mp3", track: "10"),
        track("Gulliver's Travels - Chapter 2.mp3", track: "2"),
    ]
    let ordered = TrackOrderer.order(tracks, by: .trackTag)
    #expect(ordered.map(\.filename) == [
        "Gulliver's Travels - Chapter 2.mp3",
        "Gulliver's Travels - Chapter 10.mp3",
    ])
}

@Test func filenameOrderUsesNaturalSort() {
    let tracks = [track("Part 10.mp3"), track("Part 2.mp3")]
    let ordered = TrackOrderer.order(tracks, by: .filename)
    #expect(ordered.map(\.filename) == ["Part 2.mp3", "Part 10.mp3"])
}

@Test func trackTagParsesSlashFormat() {
    let tracks = [track("b.mp3", track: "12/24"), track("a.mp3", track: "3/24")]
    let ordered = TrackOrderer.order(tracks, by: .trackTag)
    #expect(ordered.map(\.filename) == ["a.mp3", "b.mp3"])
}

@Test func tracksMissingTagsSortAfterTaggedOnesByFilename() {
    let tracks = [track("z.mp3"), track("a.mp3"), track("tagged.mp3", track: "1")]
    let ordered = TrackOrderer.order(tracks, by: .trackTag)
    #expect(ordered.map(\.filename) == ["tagged.mp3", "a.mp3", "z.mp3"])
}

@Test func orderingIsStableForEqualKeys() {
    let tracks = [track("a.mp3", track: "1"), track("b.mp3", track: "1")]
    let ordered = TrackOrderer.order(tracks, by: .trackTag)
    #expect(ordered.map(\.filename) == ["a.mp3", "b.mp3"])
}

// Files sharing a track number must come back in their original order, not
// re-sorted by filename. The names below are deliberately NOT alphabetical, so
// a tie-break that fell back to filename comparison would reorder them and fail
// here. Verified by mutation testing: replacing the offset tie-break with
// `naturalLess(a.filename, b.filename)` makes this test fail, while the
// 2-element `orderingIsStableForEqualKeys` above still passes.
//
// Note what this does NOT cover: replacing the tie-break with a bare `return
// false` keeps every test green, because Swift's `sorted(by:)` happens to be
// stable in practice (checked at n = 10…200). Stability is not part of its API
// contract, so the offset tie-break stays as insurance against a future stdlib
// change — but no test can currently force that failure.
@Test func stabilityHoldsAcrossManyTiedKeys() {
    let names = ["m.mp3", "c.mp3", "z.mp3", "a.mp3", "q.mp3",
                 "b.mp3", "y.mp3", "d.mp3", "x.mp3", "e.mp3"]
    let tracks = names.map { track($0, track: "7") }
    let ordered = TrackOrderer.order(tracks, by: .trackTag)
    #expect(ordered.map(\.filename) == names)
}

// Pins trackNumber's parsing contract. All of these are already correct —
// these tests exist so a future refactor cannot change them silently.
@Test func trackNumberParsingEdgeCases() {
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: "12/24")) == 12)
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: "0")) == 0)
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: "")) == nil)
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: "/24")) == nil)
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: "abc")) == nil)
    #expect(TrackOrderer.trackNumber(track("a.mp3")) == nil)

    // A digit run too long for Int degrades to nil (treated as untagged)
    // rather than wrapping to a negative value.
    #expect(TrackOrderer.trackNumber(track("a.mp3", track: String(repeating: "9", count: 40))) == nil)
}
