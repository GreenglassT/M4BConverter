import Foundation
import Testing
@testable import M4BConverter

@Test func readsFinalTimestampFromFFmpegStderr() {
    let stderr = """
    size=N/A time=00:16:32.78 bitrate=N/A speed=1.97e+03x
    size=N/A time=01:13:07.81 bitrate=N/A speed=2.01e+03x
    """
    let seconds = DurationMeasurer.parseFinalTime(stderr)
    #expect(seconds != nil)
    #expect(abs(seconds! - 4387.81) < 0.01)
}

@Test func ignoresTrailingSummaryLineWithZeroTime() {
    // ffmpeg's final "Lsize=" line reports time=00:00:00.04 and must not win
    let stderr = "time=00:10:00.00 speed=1x\nLsize=234426KiB time=00:00:00.04 bitrate=48010406.6kbits/s"
    #expect(abs(DurationMeasurer.parseFinalTime(stderr)! - 600.0) < 0.01)
}

@Test func returnsNilWhenNoTimestampPresent() {
    #expect(DurationMeasurer.parseFinalTime("no timing here") == nil)
}

@Test func recognisesBenignID3v1DecodeNoise() {
    let stderr = "[mp3float @ 0x1] Header missing\n[aist#0:0/mp3 @ 0x2] Error submitting packet to decoder: Invalid data found when processing input"
    #expect(DurationMeasurer.isBenignTrailingTagNoise(stderr))
}

@Test func realDecodeErrorsAreNotTreatedAsBenign() {
    #expect(!DurationMeasurer.isBenignTrailingTagNoise("Invalid data found when processing input\nmoov atom not found"))
}

/// The duration `measure` settles on, or nil when it refused the file.
private func measureOrNil(reporting time: String, container: Double) async throws -> Double? {
    let (tools, directory) = try Fixtures.fakeTools(
        "echo 'size=N/A time=\(time) bitrate=N/A' >&2; exit 0")
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = TrackInfo(url: URL(fileURLWithPath: "/b/a.mp3"), estimatedDuration: container)
    return try? await DurationMeasurer(tools: tools).measure(track).duration
}

// A file that decodes a little short of what its container claims still reports the
// DECODED value: that is the truth, because the encode decodes the same bytes with the
// same decoder and produces exactly that much audio. Chapters must be based on it.
//
// The numbers used to be 600 s claimed against 149.97 s decoded, which is not "a little"
// — it is three quarters of the file gone, silently, and this test asserted that the app
// accepted it. That is the defect in finding 1, not a property worth keeping; the
// property worth keeping is that the decoded value wins, which is what it does here.
@Test func measurePrefersDecodedDurationOverTheContainerEstimate() async throws {
    let measured = try await measureOrNil(reporting: "00:02:29.97", container: 150.5)
    #expect(measured != nil)
    #expect(abs((measured ?? 0) - 149.97) < 0.01)
}

// The threshold, against the distribution it was derived from.
//
// Measured read-only across the nine real books — 448 files, 261.5 hours: every file
// decoded SHORTER than its container claimed, by at most 0.025 s; the largest relative
// gap was 0.285% on the shortest file in the library (3.0 s), and among the 395 files
// over 200 s the largest was 0.009%. So the allowance is
// `min(max(1 s, 0.5% of the claim), 10 s)` — a floor because short files make small
// absolute gaps look enormous in percentage terms, a fraction so longer files get
// proportional room, and a cap because 0.5% of an 8-hour file is 2.4 minutes.
@Test func theShortfallAllowanceAcceptsTheRealLibraryAndCatchesRealLoss() async throws {
    // Accepted: the worst RELATIVE gap in the library. 0.285% of a 3 s file — a
    // relative-only rule tuned to catch a 10% loss would still fail this.
    #expect(try await measureOrNil(reporting: "00:00:02.991", container: 3.0) != nil)
    // Accepted: the worst ABSOLUTE gap in the library, on its longest file (2.99 h).
    #expect(try await measureOrNil(reporting: "02:59:25.975", container: 10766.0) != nil)
    // Accepted: the floor doing its job. 0.8 s is 4% of a 20 s file, and 4% sounds
    // alarming, but 0.8 s is a third of the worst gap this app has ever seen scaled up.
    #expect(try await measureOrNil(reporting: "00:00:19.20", container: 20.0) != nil)

    // Refused: the case from the report — a CBR MP3 with 10% of its bytes overwritten,
    // 2.01 s of narration gone, ffmpeg exit 0, two lines on stderr.
    #expect(try await measureOrNil(reporting: "00:00:18.024", container: 20.036) == nil)
    // Refused: 30 s missing from an 8-hour file. That is 0.10% — comfortably inside any
    // purely relative rule, which is why the cap exists.
    #expect(try await measureOrNil(reporting: "07:59:30.00", container: 28800.0) == nil)
}

// The whole of finding 1 in one file: a quietly-lossy MP3 that every other defence in
// the app waves through. It is a real MP3 (`isMP3` passes), ffmpeg exits 0, its stderr
// is inside the volume budget, and the short measurement it produces then becomes the
// expected length that `OutputVerifier` checks the output against — so the .m4b is
// declared `.verified` two seconds short of the book the user has on disk.
@Test(.enabled(if: Fixtures.ffmpegAvailable))
func aQuietlyLossyMP3IsRefusedRatherThanMeasuredShort() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let tools = Fixtures.tools!
    let url = try await Fixtures.makeLossyMP3(in: folder, named: "01.mp3", seconds: 20)
    let track = try await MediaProbe(tools: tools).probe(url)

    // Re-establish the premise on this machine rather than trusting the report.
    #expect(track.isMP3)
    #expect(abs(track.estimatedDuration - 20) < 0.5)

    let raw = try await ProcessRunner().run(tools.ffmpeg, [
        "-hide_banner", "-v", "error", "-stats",
        "-i", url.path, "-map", "0:a:0", "-f", "null", "-",
    ])
    #expect(raw.exitCode == 0)
    // Not enough stderr for the volume check to have an opinion — this is the gap the
    // duration comparison closes, and if it ever stops being true this test is no
    // longer testing what it claims to.
    #expect(FFmpegStderr.failureEvidence(in: raw.stderr, inputFiles: 1) == nil)
    let decoded = try #require(DurationMeasurer.parseFinalTime(raw.stderr))
    #expect(track.estimatedDuration - decoded > 1.0,
            "the fixture is meant to lose about 2 s")

    var thrown: Error?
    do {
        _ = try await DurationMeasurer(tools: tools).measure(track)
    } catch {
        thrown = error
    }
    let error = try #require(thrown, "a file that decodes seconds short must not measure clean")
    // And it says which file, so the user can go and replace it.
    #expect(failureSummary(for: error).contains("01.mp3"))
}

// End to end, because the point is not that a helper throws — it is that the book does
// not come out `.verified`.
@Test(.enabled(if: Fixtures.ffmpegAvailable)) @MainActor
func aBookWithAQuietlyLossyFileIsNotVerified() async throws {
    let root = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = root.appendingPathComponent("Book")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tools = Fixtures.tools!

    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 5, tags: ["album": "Book"])
    try await Fixtures.makeLossyMP3(in: folder, named: "02.mp3", seconds: 20,
                                    tags: ["album": "Book"])
    let tracks = try await Fixtures.probeTracks(in: folder, named: ["01.mp3", "02.mp3"])
    let book = Book(folder: folder, tracks: tracks)

    await ConversionQueue(tools: tools).convertAll([book])

    guard case let .failed(message) = book.status else {
        Issue.record("expected .failed, got \(book.status)")
        return
    }
    #expect(message.contains("02.mp3"))
    #expect(book.writtenURL == nil)
    // And nothing short was left in the library for a later `.skip` run to trust.
    #expect(try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.hasSuffix(".m4b") }.isEmpty)
}

// Finding 2: the volume budget is a whole-RUN total, so it is weakest on the books
// where a missing file is hardest to spot. 200 complaints is loud enough to mean
// several seconds of dropped audio, and a 190-file book's budget of 380 shrugs at it.
// Measuring happens one file at a time, which is where the denominator is 1 and the
// budget really is 2 — so that is where this has to be caught.
@Test func oneFileComplainingInBulkIsRefusedEvenWhereTheRunLevelBudgetWouldNot() async throws {
    let noise = "[mp3float @ 0x1] Header missing"
    let bulk = Array(repeating: noise, count: 200).joined(separator: "\n")
    // The backstop, on the book this file belongs to: no opinion at all.
    #expect(FFmpegStderr.failureEvidence(in: bulk, inputFiles: 190) == nil)
    // The same stderr, judged against the one file that produced it.
    #expect(FFmpegStderr.failureEvidence(in: bulk, inputFiles: 1) != nil)

    // And `measure` applies it. The duration agrees exactly, so nothing but the stderr
    // volume can fail this file.
    let (tools, directory) = try Fixtures.fakeTools("""
    i=0
    while [ $i -lt 200 ]; do echo '\(noise)' >&2; i=$((i+1)); done
    echo 'size=N/A time=00:16:40.00 bitrate=N/A' >&2
    exit 0
    """)
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = TrackInfo(url: URL(fileURLWithPath: "/b/loud.mp3"), estimatedDuration: 1000)
    var thrown: Error?
    do {
        _ = try await DurationMeasurer(tools: tools).measure(track)
    } catch {
        thrown = error
    }
    let error = try #require(thrown)
    #expect(failureLog(for: error).contains("loud.mp3"))
    #expect(failureLog(for: error).contains("200 times"))
}

// Nothing decoded AND ffmpeg failed: missing, empty, or non-audio. Fail loudly
// rather than silently feeding a stale estimate into cumulative chapter offsets.
@Test func measureThrowsWhenNothingDecodedAndFFmpegFailed() async throws {
    let (tools, directory) = try Fixtures.fakeTools(
        "echo 'No such file or directory' >&2; exit 254")
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = TrackInfo(url: URL(fileURLWithPath: "/b/missing.mp3"), estimatedDuration: 600)
    await #expect(throws: (any Error).self) {
        _ = try await DurationMeasurer(tools: tools).measure(track)
    }
}

// Nothing decoded and ffmpeg exited 0. This used to fall back to the container's own
// claimed duration — the very number Task 13 stopped trusting, because a VBR header can
// be wrong by minutes. That is not a measurement, and it does not stay local: it feeds
// `totalDuration`, which is what OutputVerifier checks the finished .m4b against, so a
// wrong value here makes the verifier agree with a wrong output. "Could not measure" has
// to be a failure whatever the exit code says.
@Test func measureThrowsWhenNothingDecodedEvenThoughFFmpegSucceeded() async throws {
    let (tools, directory) = try Fixtures.fakeTools("exit 0")
    defer { try? FileManager.default.removeItem(at: directory) }
    let track = TrackInfo(url: URL(fileURLWithPath: "/b/a.mp3"), estimatedDuration: 42)
    var thrown: Error?
    do {
        _ = try await DurationMeasurer(tools: tools).measure(track)
    } catch {
        thrown = error
    }
    let error = try #require(thrown)
    // And it says which file and why, rather than "ffmpeg exited 0, writing nothing".
    #expect(failureLog(for: error).contains("a.mp3"))
    #expect(failureLog(for: error).contains("Nothing decoded"))
}

// Raw stderr from a real `-stats` run interleaves progress lines with any errors,
// and those progress lines are not benign patterns — so filtering is required.
@Test func benignNoiseDetectionRequiresFilteredStderr() {
    let raw = """
    size=N/A time=00:01:00.00 bitrate=N/A speed=2e+03x
    [mp3float @ 0x1] Header missing
    size=N/A time=00:02:00.00 bitrate=N/A speed=2e+03x
    """
    #expect(!DurationMeasurer.isBenignTrailingTagNoise(raw))

    let filtered = raw.split(separator: "\n")
        .filter { !$0.contains("time=") }
        .joined(separator: "\n")
    #expect(DurationMeasurer.isBenignTrailingTagNoise(filtered))
}
