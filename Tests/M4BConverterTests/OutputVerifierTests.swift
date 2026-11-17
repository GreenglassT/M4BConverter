import Foundation
import Testing
@testable import M4BConverter

private let goodJSON = """
{"chapters":[{"start_time":"0.000","end_time":"3.000","tags":{"title":"One"}},
             {"start_time":"3.000","end_time":"6.000","tags":{"title":"Two"}}],
 "streams":[{"codec_type":"audio","codec_name":"aac"},
            {"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}],
 "format":{"duration":"6.000","tags":{"media_type":"2"}}}
"""

@Test func acceptsAWellFormedOutput() throws {
    let report = try OutputVerifier.parse(json: Data(goodJSON.utf8),
                                          expectedChapters: 2, expectedDuration: 6.0)
    #expect(report.passed)
    #expect(report.chapterCount == 2)
    #expect(report.hasCover)
    #expect(report.isAudiobook)
}

@Test func flagsChapterCountMismatch() throws {
    let report = try OutputVerifier.parse(json: Data(goodJSON.utf8),
                                          expectedChapters: 5, expectedDuration: 6.0)
    #expect(!report.passed)
    #expect(report.problems.contains { $0.contains("chapter") })
}

@Test func flagsDurationDrift() throws {
    let report = try OutputVerifier.parse(json: Data(goodJSON.utf8),
                                          expectedChapters: 2, expectedDuration: 60.0)
    #expect(!report.passed)
    #expect(report.problems.contains { $0.contains("Duration") })
}

@Test func flagsMissingCoverAndAudiobookFlag() throws {
    let json = """
    {"chapters":[{"start_time":"0.000","end_time":"6.000","tags":{"title":"One"}}],
     "streams":[{"codec_type":"audio","codec_name":"aac"}],
     "format":{"duration":"6.000","tags":{}}}
    """
    let report = try OutputVerifier.parse(json: Data(json.utf8),
                                          expectedChapters: 1, expectedDuration: 6.0)
    #expect(!report.hasCover)
    #expect(!report.isAudiobook)
}

@Test func flagsNonIncreasingChapters() throws {
    let json = """
    {"chapters":[{"start_time":"5.000","end_time":"6.000","tags":{"title":"B"}},
                 {"start_time":"1.000","end_time":"2.000","tags":{"title":"A"}}],
     "streams":[{"codec_type":"audio","codec_name":"aac"}],
     "format":{"duration":"6.000","tags":{"media_type":"2"}}}
    """
    let report = try OutputVerifier.parse(json: Data(json.utf8),
                                          expectedChapters: 2, expectedDuration: 6.0)
    #expect(!report.chaptersAscending)
    #expect(!report.passed)
}

// A video-only file with matching chapters, duration and media_type passed every
// check before this — an unplayable "audiobook" clearing the final gate.
@Test func rejectsOutputWithNoAudioStream() throws {
    let json = """
    {"chapters":[{"start_time":"0.000","end_time":"3.000","tags":{"title":"One"}},
                 {"start_time":"3.000","end_time":"6.000","tags":{"title":"Two"}}],
     "streams":[{"codec_type":"video","codec_name":"h264","disposition":{"attached_pic":0}}],
     "format":{"duration":"6.000","tags":{"media_type":"2"}}}
    """
    let report = try OutputVerifier.parse(json: Data(json.utf8),
                                          expectedChapters: 2, expectedDuration: 6.0)
    #expect(!report.passed)
    #expect(!report.hasAudio)
    #expect(report.problems.contains { $0.contains("No audio stream") })
}

// Cover art must be an attached picture, not just any video stream.
@Test func aRealVideoTrackIsNotCoverArt() throws {
    let json = """
    {"chapters":[{"start_time":"0.000","end_time":"6.000","tags":{"title":"One"}}],
     "streams":[{"codec_type":"audio","codec_name":"aac"},
                {"codec_type":"video","codec_name":"h264","disposition":{"attached_pic":0}}],
     "format":{"duration":"6.000","tags":{"media_type":"2"}}}
    """
    #expect(try !OutputVerifier.parse(json: Data(json.utf8),
                                      expectedChapters: 1, expectedDuration: 6.0).hasCover)
}

// A book with no artwork anywhere converts correctly and has nothing to report; one whose
// cover went missing gets a note about it. Neither is a failure — see the fatal/cosmetic
// split below — so the difference shows up in `cosmeticProblems`, not in `passed`.
@Test func missingCoverIsOnlyMentionedWhenACoverWasSupplied() throws {
    let json = """
    {"chapters":[{"start_time":"0.000","end_time":"6.000","tags":{"title":"One"}}],
     "streams":[{"codec_type":"audio","codec_name":"aac"}],
     "format":{"duration":"6.000","tags":{"media_type":"2"}}}
    """
    let noCoverWanted = try OutputVerifier.parse(json: Data(json.utf8), expectedChapters: 1,
                                                 expectedDuration: 6.0, expectedCover: false)
    #expect(noCoverWanted.passed)
    #expect(noCoverWanted.problems.isEmpty)

    let coverWanted = try OutputVerifier.parse(json: Data(json.utf8), expectedChapters: 1,
                                               expectedDuration: 6.0, expectedCover: true)
    #expect(coverWanted.passed)
    #expect(coverWanted.cosmeticProblems == ["No cover art embedded"])
}

// The split that stops a cosmetic complaint destroying a finished encode. `passed` was
// `problems.isEmpty`, and the queue deletes anything that fails to verify — so a missing
// cover or a missing media_type tag threw away hours of correct audio.
@Test func onlyProblemsWithTheAudioAreFatal() throws {
    let json = """
    {"chapters":[{"start_time":"0.000","end_time":"6.000","tags":{"title":"One"}}],
     "streams":[{"codec_type":"audio","codec_name":"aac"}],
     "format":{"duration":"6.000","tags":{}}}
    """
    let report = try OutputVerifier.parse(json: Data(json.utf8), expectedChapters: 1,
                                          expectedDuration: 6.0, expectedCover: true)
    #expect(report.passed)
    #expect(report.fatalProblems.isEmpty)
    #expect(report.cosmeticProblems.count == 2)
    // `problems` stays the combined list, fatal first, for anything that reports rather
    // than decides.
    #expect(report.problems == report.fatalProblems + report.cosmeticProblems)
}

// Each of the four ways the audio itself can be wrong, one at a time, with everything
// cosmetic in order — so nothing here passes by accident.
@Test func everyAudioDefectIsFatalOnItsOwn() throws {
    func report(chapters: String, streams: String, duration: String,
                expectedChapters: Int) throws -> VerificationReport {
        let json = """
        {"chapters":[\(chapters)],
         "streams":[\(streams)],
         "format":{\(duration)"tags":{"media_type":"2"}}}
        """
        return try OutputVerifier.parse(json: Data(json.utf8),
                                        expectedChapters: expectedChapters,
                                        expectedDuration: 6.0, expectedCover: true)
    }
    let art = #"{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}"#
    let audio = #"{"codec_type":"audio","codec_name":"aac"}"#
    let one = #"{"start_time":"0.000","end_time":"6.000","tags":{"title":"One"}}"#
    let backwards = """
    {"start_time":"5.000","end_time":"6.000","tags":{"title":"B"}},
    {"start_time":"1.000","end_time":"2.000","tags":{"title":"A"}}
    """

    // No audio stream.
    #expect(try !report(chapters: one, streams: art,
                        duration: #""duration":"6.000","#, expectedChapters: 1).passed)
    // Chapter count mismatch.
    #expect(try !report(chapters: one, streams: "\(audio),\(art)",
                        duration: #""duration":"6.000","#, expectedChapters: 4).passed)
    // Duration mismatch, then a duration that cannot be read at all.
    #expect(try !report(chapters: one, streams: "\(audio),\(art)",
                        duration: #""duration":"600.0","#, expectedChapters: 1).passed)
    #expect(try !report(chapters: one, streams: "\(audio),\(art)",
                        duration: "", expectedChapters: 1).passed)
    // Chapter starts that do not advance.
    #expect(try !report(chapters: backwards, streams: "\(audio),\(art)",
                        duration: #""duration":"6.000","#, expectedChapters: 2).passed)
    // And the control: all of the above put right.
    #expect(try report(chapters: one, streams: "\(audio),\(art)",
                       duration: #""duration":"6.000","#, expectedChapters: 1).passed)
}

@Test func unreadableDurationGetsItsOwnMessage() throws {
    let json = """
    {"chapters":[],"streams":[{"codec_type":"audio","codec_name":"aac"}],
     "format":{"tags":{"media_type":"2"}}}
    """
    let report = try OutputVerifier.parse(json: Data(json.utf8), expectedChapters: 0,
                                          expectedDuration: 6.0, expectedCover: false)
    #expect(report.problems.contains { $0.contains("Could not read") })
    #expect(!report.problems.contains { $0.contains("Duration off by") })
}

@Test func badJSONNamesTheActualFile() {
    #expect(throws: (any Error).self) {
        try OutputVerifier.parse(json: Data("not json".utf8), expectedChapters: 0,
                                 expectedDuration: 0,
                                 url: URL(fileURLWithPath: "/books/Real Book.m4b"))
    }
}
