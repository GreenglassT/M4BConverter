import Foundation
import Testing
@testable import M4BConverter

private func track(_ name: String, tags: [String: String] = [:]) -> TrackInfo {
    TrackInfo(url: URL(fileURLWithPath: "/b/\(name)"), estimatedDuration: 10, tags: tags)
}

// Note the fixture: filenames whose natural order differs from their track numbers.
// "Chapter 10" vs "Chapter 2" would NOT disagree — natural sort already orders those
// correctly — so it would never trigger the track-tag override.
@Test @MainActor func bookAdoptsInferredDefaults() {
    let book = Book(folder: URL(fileURLWithPath: "/b"),
                    tracks: [track("beta.mp3", tags: ["track": "1", "album": "B"]),
                             track("alpha.mp3", tags: ["track": "2", "album": "B"])])
    #expect(book.order == .trackTag)
    #expect(book.title == "B")
    #expect(!book.warnings.isEmpty)
    #expect(book.status == .warning)
}

@Test @MainActor func changingStrategyRecomputesChapters() {
    let book = Book(folder: URL(fileURLWithPath: "/b"),
                    tracks: [track("B - 01 - Opening.mp3"), track("B - 02 - Chapter 1.mp3")])
    #expect(book.chapters.map(\.title) == ["Opening", "Chapter 1"])

    book.chapterStrategy = .fileBoundaries
    book.recompute()
    #expect(book.chapters.map(\.title) == ["B - 01 - Opening", "B - 02 - Chapter 1"])
}

@Test @MainActor func outputURLUsesTitleNextToTheSourceFolderParent() {
    let book = Book(folder: URL(fileURLWithPath: "/Audiobooks/Frankenstein"),
                    tracks: [track("a.mp3", tags: ["album": "Frankenstein"])])
    #expect(book.outputURL.path == "/Audiobooks/Frankenstein.m4b")
}

@Test @MainActor func outputURLSanitisesSlashesInTitles() {
    let book = Book(folder: URL(fileURLWithPath: "/Audiobooks/X"),
                    tracks: [track("a.mp3", tags: ["album": "AC/DC Live"])])
    #expect(book.outputURL.lastPathComponent == "AC-DC Live.m4b")
}

// Inference never picks .trackTag for a partially-tagged folder, but the user can
// select it by hand in the inspector — and then the untagged files silently sort to
// the end. Warnings must refresh when a strategy changes, not only at scan time.
@Test @MainActor func manualTrackTagOverrideWarnsAboutUntaggedFiles() {
    let book = Book(folder: URL(fileURLWithPath: "/b"),
                    tracks: [track("a.mp3", tags: ["track": "1"]), track("b.mp3")])
    #expect(book.order == .filename)
    #expect(book.warnings.isEmpty)

    book.order = .trackTag
    book.recompute()
    #expect(book.warnings.contains { $0.contains("no track number") })
    #expect(book.status == .warning)
}

// Choosing a chapter source the files do not support yields zero chapters. Silently
// producing a chapterless audiobook would be a poor outcome; say so up front.
@Test @MainActor func aStrategyThatProducesNoChaptersIsFlagged() {
    let book = Book(folder: URL(fileURLWithPath: "/b"), tracks: [track("a.mp3")])
    book.chapterStrategy = .overdriveMarkers
    book.recompute()
    #expect(book.chapters.isEmpty)
    #expect(book.warnings.contains { $0.contains("no chapters") })
}

// The same Book twice in one array would start two pipelines writing the same
// output path. A status filter alone does not catch it: both entries are still
// `.ready` when the filter runs, so dedup must be by identity.
@Test @MainActor func queueDeduplicatesTheSameBook() async {
    let tools = FFmpegTools(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"),
                            ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
    let book = Book(folder: URL(fileURLWithPath: "/b"), tracks: [track("a.mp3")])
    let queue = ConversionQueue(tools: tools)
    await queue.convertAll([book, book])
    #expect(queue.total == 1)
}

// The queue snapshots the ordering once, measures durations from that snapshot and
// plans chapters from those durations — all of which awaits. `makeJob` used to re-read
// `orderedTracks`, so flipping the Order picker mid-measurement attached chapters
// computed for one ordering to audio concatenated in another. Chapter count and total
// duration both still match, so the verifier passes and the wrong file is marked
// verified. The job must be built from the tracks it is handed.
@Test @MainActor func makeJobUsesTheTracksItIsGivenNotTheCurrentOrder() {
    let book = Book(folder: URL(fileURLWithPath: "/b"),
                    tracks: [track("beta.mp3", tags: ["track": "1", "album": "B"]),
                             track("alpha.mp3", tags: ["track": "2", "album": "B"])])
    let ordered = book.orderedTracks
    #expect(ordered.map(\.filename) == ["beta.mp3", "alpha.mp3"])

    // The user changes Order while the conversion is between its awaits.
    book.order = .filename
    book.recompute()
    #expect(book.orderedTracks.map(\.filename) == ["alpha.mp3", "beta.mp3"])

    let job = book.makeJob(tracks: ordered, chapters: book.chapters, totalDuration: 20)
    #expect(job.tracks.map(\.filename) == ["beta.mp3", "alpha.mp3"])
}

// The cached ordering used to be kept in step by convention — a doc comment asking every
// caller to remember `recompute()`. The inspector's pickers now simply assign, so the
// derived state has to rebuild itself or a book gets converted in one order and chaptered
// in another: the class of bug this project has already fixed twice.
@Test @MainActor func assigningAnInputRebuildsTheDerivedStateWithoutRecompute() {
    let book = Book(folder: URL(fileURLWithPath: "/b"),
                    tracks: [track("beta.mp3", tags: ["track": "1"]),
                             track("alpha.mp3", tags: ["track": "2"])])
    #expect(book.order == .trackTag)

    book.order = .filename
    #expect(book.orderedTracks.map(\.filename) == ["alpha.mp3", "beta.mp3"])

    book.chapterStrategy = .overdriveMarkers
    #expect(book.chapters.isEmpty)
    #expect(book.warnings.contains { $0.contains("no chapters") })

    book.tracks = [track("solo.mp3")]
    #expect(book.orderedTracks.map(\.filename) == ["solo.mp3"])
    #expect(book.totalDuration == 10)
}

@Test @MainActor func queueSkipsBooksThatAlreadyFinished() async {
    let tools = FFmpegTools(ffmpeg: URL(fileURLWithPath: "/usr/bin/false"),
                            ffprobe: URL(fileURLWithPath: "/usr/bin/false"))
    let book = Book(folder: URL(fileURLWithPath: "/b"), tracks: [track("a.mp3")])
    book.status = .verified
    let queue = ConversionQueue(tools: tools)
    await queue.convertAll([book])
    #expect(queue.total == 0)
}
