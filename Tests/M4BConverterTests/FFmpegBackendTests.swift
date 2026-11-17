import Foundation
import Testing
@testable import M4BConverter

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func backendProducesChapteredM4B() async throws {
    let tools = Fixtures.tools!
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 3, tags: ["title": "One"])
    try await Fixtures.makeMP3(in: folder, named: "02.mp3", seconds: 3, tags: ["title": "Two"])
    let cover = try await Fixtures.makeCover(in: folder)

    let tracks = try await Fixtures.probeTracks(in: folder, named: ["01.mp3", "02.mp3"])
    let durations = tracks.map(\.estimatedDuration)
    let chapters = ChapterPlanner.plan(tracks: tracks, durations: durations, strategy: .fileBoundaries)

    let output = folder.appendingPathComponent("Book.m4b")
    let job = ConversionJob(tracks: tracks, chapters: chapters,
                            metadata: ["title": "Book", "artist": "Tester", "media_type": "2"],
                            coverImage: cover, outputURL: output,
                            bitRate: 64000, sampleRate: 44100, channels: 2,
                            totalDuration: durations.reduce(0, +))

    _ = try await FFmpegBackend(tools: tools).convert(job) { _ in }

    #expect(FileManager.default.fileExists(atPath: output.path))

    let json = try await ProcessRunner().run(tools.ffprobe, [
        "-v", "error", "-show_chapters", "-show_format", "-of", "json", output.path,
    ])
    #expect(json.stdout.contains("\"title\": \"One\"") || json.stdout.contains("\"title\":\"One\""))
    #expect(json.stdout.contains("Two"))
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func backendReportsProgress() async throws {
    let tools = Fixtures.tools!
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 4)
    let track = try await MediaProbe(tools: tools).probe(folder.appendingPathComponent("01.mp3"))

    let output = folder.appendingPathComponent("P.m4b")
    let job = ConversionJob(tracks: [track],
                            chapters: [Chapter(start: 0, end: track.estimatedDuration, title: "A")],
                            metadata: ["title": "P"], coverImage: nil, outputURL: output,
                            bitRate: 64000, sampleRate: 44100, channels: 2,
                            totalDuration: track.estimatedDuration)

    let seen = ProgressCollector()
    _ = try await FFmpegBackend(tools: tools).convert(job) { seen.add($0) }
    #expect(seen.values.contains { $0 > 0 })
    #expect(seen.values.allSatisfy { $0 >= 0 && $0 <= 1.0001 })
}

// ffmpeg's FINAL -progress block reports the attached picture's timestamp (~0.04s),
// not the audio's — verified against a 40-minute encode where readings climbed to
// 2282s of 2400s and then the last block reported 0.04s. Without clamping, the bar
// would run to ~95%, snap back to 0%, then jump to 100%.
@Test func progressOnlyEverMovesForward() {
    let tracker = MonotonicProgress()
    #expect(tracker.advance(to: 0.5) == 0.5)
    #expect(tracker.advance(to: 0.9) == 0.9)
    #expect(tracker.advance(to: 0.01) == nil)
    #expect(tracker.advance(to: 0.95) == 0.95)
    #expect(tracker.advance(to: 0.95) == nil)
}

@Test(.enabled(if: Fixtures.ffmpegAvailable))
func reportedProgressIsNonDecreasing() async throws {
    let tools = Fixtures.tools!
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 3)
    let cover = try await Fixtures.makeCover(in: folder)
    let track = try await MediaProbe(tools: tools).probe(folder.appendingPathComponent("01.mp3"))

    let output = folder.appendingPathComponent("Mono.m4b")
    let job = ConversionJob(tracks: [track],
                            chapters: [Chapter(start: 0, end: track.estimatedDuration, title: "A")],
                            metadata: ["title": "Mono"], coverImage: cover, outputURL: output,
                            bitRate: 64000, sampleRate: 44100, channels: 2,
                            totalDuration: track.estimatedDuration)

    let seen = ProgressCollector()
    _ = try await FFmpegBackend(tools: tools).convert(job) { seen.add($0) }
    let values = seen.values
    #expect(zip(values, values.dropFirst()).allSatisfy { $0 <= $1 })
}

// Some books have no cover image file — the art lives inside the MP3s. Without
// extraction the book converts with no cover, and Task 15's verifier fails a book
// for exactly that.
@Test(.enabled(if: Fixtures.ffmpegAvailable))
func backendExtractsEmbeddedArtWhenNoCoverFileExists() async throws {
    let tools = Fixtures.tools!
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try await Fixtures.makeMP3WithEmbeddedArt(in: folder, named: "01.mp3", seconds: 3)
    let track = try await MediaProbe(tools: tools).probe(folder.appendingPathComponent("01.mp3"))
    #expect(track.embeddedArtCodec != nil)

    let output = folder.appendingPathComponent("Embedded.m4b")
    let job = ConversionJob(tracks: [track],
                            chapters: [Chapter(start: 0, end: track.estimatedDuration, title: "A")],
                            metadata: ["title": "Embedded"],
                            coverImage: nil,              // no cover file on disk
                            outputURL: output,
                            bitRate: 64000, sampleRate: 44100, channels: 2,
                            totalDuration: track.estimatedDuration)

    _ = try await FFmpegBackend(tools: tools).convert(job) { _ in }

    let streams = try await ProcessRunner().run(tools.ffprobe, [
        "-v", "error", "-select_streams", "v", "-show_entries", "stream=codec_type",
        "-of", "csv=p=0", output.path,
    ])
    #expect(streams.stdout.contains("video"))
}

// The real bug, end to end with the real ffmpeg. A misnamed AAC file under the concat
// demuxer — which forces the FIRST input's format onto every input — decodes to nothing:
// ffmpeg prints 262 lines of decoder errors, EXITS 0, and writes an .m4b holding 3.04 s
// of the 6 s asked for. The exit-code guard passes it, so before the stderr check this
// returned the truncated file as a success and left it on disk for OutputVerifier to
// discover after however long the encode took.
@Test(.enabled(if: Fixtures.ffmpegAvailable))
func anEncodeThatExitsZeroWithADecodeFailureIsStillAFailure() async throws {
    let tools = Fixtures.tools!
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }

    try await Fixtures.makeMP3(in: folder, named: "01.mp3", seconds: 3)
    try await Fixtures.makeAACNamedMP3(in: folder, named: "02.mp3", seconds: 3)
    let tracks = try await Fixtures.probeTracks(in: folder, named: ["01.mp3", "02.mp3"])
    let durations = tracks.map(\.estimatedDuration)

    let output = folder.appendingPathComponent("Broken.m4b")
    let job = ConversionJob(
        tracks: tracks,
        chapters: ChapterPlanner.plan(tracks: tracks, durations: durations,
                                      strategy: .fileBoundaries),
        metadata: ["title": "Broken"], coverImage: nil, outputURL: output,
        bitRate: 64000, sampleRate: 44100, channels: 2,
        totalDuration: durations.reduce(0, +))

    var thrown: Error?
    do {
        _ = try await FFmpegBackend(tools: tools).convert(job) { _ in }
    } catch {
        thrown = error
    }

    let error = try #require(thrown, "ffmpeg exited 0, but the audio is not what was asked for")
    guard case ProcessError.failed(_, let stderr) = error else {
        Issue.record("expected ProcessError.failed, got \(error)")
        return
    }
    // ffmpeg's own output reaches the book's log, with the verdict last so the one-line
    // summary leads with it rather than with the last of hundreds of identical lines.
    #expect(stderr.contains("Header missing"))
    #expect(stderr.contains("Stopped because the decode failed"))
    #expect(failureSummary(for: error).contains("Stopped because the decode failed"))
    // And the file that is missing half its audio is gone, not left looking finished.
    #expect(!FileManager.default.fileExists(atPath: output.path))
}

final class ProgressCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Double] = []
    func add(_ value: Double) { lock.lock(); storage.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return storage }
}
