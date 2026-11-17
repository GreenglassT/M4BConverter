import Foundation

/// The outcome of checking a finished .m4b, with the problems split by what they cost.
///
/// The split exists because the caller DELETES a file that fails to verify — the right
/// answer for audio that is wrong, and a catastrophe for metadata that is merely absent.
/// A missing cover or a missing `media_type` tag used to fail the book and destroy hours
/// of correct, complete encoding over something the user could fix in a tag editor.
///
/// Fatal means the audio is not what the app planned: no audio stream at all, the wrong
/// number of chapters, a duration that does not match or cannot be read, or chapter marks
/// that do not advance. Cosmetic means the audio is right and only its presentation is
/// imperfect. Only fatal problems fail the book.
public struct VerificationReport: Sendable, Equatable {
    public var chapterCount: Int
    public var hasAudio: Bool
    public var hasCover: Bool
    public var isAudiobook: Bool
    public var chaptersAscending: Bool
    public var fatalProblems: [String]
    public var cosmeticProblems: [String]
    /// Everything wrong with the file, fatal first — for reporting, never for deciding.
    public var problems: [String] { fatalProblems + cosmeticProblems }
    public var passed: Bool { fatalProblems.isEmpty }
}

public struct OutputVerifier: Sendable {
    /// Tolerance covers AAC frame-granularity padding; observed real drift was ≤1.11 s.
    ///
    /// Deriving this from `ConversionQueue.noisyFiles` was evaluated and rejected. The
    /// drift really is caused by the trailing-tag noise — measured against real books,
    /// one of 7 files (none noisy, 8.16 h) finished 0.005 s from its expected length,
    /// while one of 75 files (74 noisy) decodes 1.070 s longer under the concat
    /// demuxer than the sum of its files measured one at a time. But a noise-derived
    /// tolerance would have to be LARGER than 3 s for that book to keep the margin it has
    /// today, which is loosening; tightening it for clean books buys only the ability to
    /// fail an output that is 1-3 s wrong, and no known defect produces that. The ones
    /// that exist — a misnamed file dropped by the concat demuxer, a truncated MP3 —
    /// lose minutes, and are caught here with room to spare. Meanwhile the cost of being
    /// 0.5 s too strict is deleting a finished multi-hour encode. `noisyFiles` is also a
    /// loose proxy: it is counted while measuring each file alone, and the same book
    /// emits a different number of complaints once concatenated (29 files vs 16
    /// occurrences of "Header missing" for the 75-file book).
    public static let durationTolerance = 3.0

    let tools: FFmpegTools
    let runner: ProcessRunner

    public init(tools: FFmpegTools, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public func verify(_ url: URL, expectedChapters: Int,
                       expectedDuration: Double,
                       expectedCover: Bool = true) async throws -> VerificationReport {
        let result = try await runner.run(tools.ffprobe,
                                          M4BFacts.probeArguments(for: url.path))
        guard result.succeeded else {
            throw ProcessError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return try OutputVerifier.parse(json: Data(result.stdout.utf8),
                                        expectedChapters: expectedChapters,
                                        expectedDuration: expectedDuration,
                                        expectedCover: expectedCover,
                                        url: url)
    }

    public static func parse(json: Data, expectedChapters: Int,
                             expectedDuration: Double,
                             expectedCover: Bool = true,
                             url: URL? = nil) throws -> VerificationReport {
        // Reading the probe output is `M4BFacts`; everything below is the judging, which
        // is the half that needs an expectation to compare against.
        let facts = try M4BFacts.parse(json: json, url: url)

        // Fatal: the audio is not what was asked for. The caller deletes the file.
        var fatal: [String] = []
        // An audiobook with no audio stream is unplayable, and every other check can
        // still pass on such a file — verified against a real video-only .m4b.
        if !facts.hasAudio { fatal.append("No audio stream in the output") }
        if facts.chapterCount != expectedChapters {
            fatal.append("Expected \(expectedChapters) chapters, found \(facts.chapterCount)")
        }
        if let duration = facts.duration {
            if abs(duration - expectedDuration) > durationTolerance {
                fatal.append(String(format: "Duration off by %.2f s", duration - expectedDuration))
            }
        } else {
            fatal.append("Could not read the output duration")
        }
        if !facts.chaptersAscending {
            fatal.append("Chapter start times are not strictly increasing")
        }

        // Cosmetic: the audio is complete and correct, and only its presentation is off.
        // The caller keeps the file and says so in the book's notes.
        var cosmetic: [String] = []
        // Only worth mentioning when a cover was actually supplied. A book with no
        // artwork anywhere converts correctly and has nothing to report.
        if expectedCover && !facts.hasCover { cosmetic.append("No cover art embedded") }
        if !facts.isAudiobook {
            cosmetic.append("Not flagged as an audiobook (media_type != 2)")
        }

        return VerificationReport(chapterCount: facts.chapterCount,
                                  hasAudio: facts.hasAudio, hasCover: facts.hasCover,
                                  isAudiobook: facts.isAudiobook,
                                  chaptersAscending: facts.chaptersAscending,
                                  fatalProblems: fatal, cosmeticProblems: cosmetic)
    }
}
