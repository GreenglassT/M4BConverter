import Foundation

/// What could be established about one `.m4b` the app did not make.
///
/// The split into fatal and cosmetic is `OutputVerifier`'s, deliberately — the same two
/// words, meaning the same two things — because the user is being asked the same question
/// in both places: is the AUDIO wrong, or is only its presentation imperfect? There it
/// decides whether a finished file is deleted; here nothing is deleted at all, and the
/// split decides which line of a report deserves someone's afternoon.
///
/// What is NOT here is any expected value. `OutputVerifier` knows how many chapters and how
/// many seconds the book should have, because the source MP3s were probed and decoded
/// first. For a file that arrived from somewhere else there is no such number, and the
/// honest thing is to ask only the questions a file can answer about itself.
public struct ExistingBookReport: Sendable, Equatable, Identifiable {
    public var url: URL
    public var id: URL { url }

    /// False when no verdict was reached: the run was cancelled before this file finished,
    /// or the tools could not be run at all, or the decode started and did not finish. Such
    /// a report carries no verdict — not "sound", not "damaged" — because there is none. A
    /// machine that ran out of memory says nothing about a book.
    public var wasChecked: Bool
    /// What the container claims, and what actually decoded. Both optional and both
    /// reported, because the check that matters most is the difference between them.
    public var containerDuration: Double?
    public var decodedDuration: Double?
    public var chapterCount: Int
    public var hasAudio: Bool
    public var hasCover: Bool
    public var isAudiobook: Bool
    public var chaptersAscending: Bool
    public var fatalProblems: [String]
    public var cosmeticProblems: [String]

    public init(url: URL, wasChecked: Bool = true,
                containerDuration: Double? = nil, decodedDuration: Double? = nil,
                chapterCount: Int = 0, hasAudio: Bool = false, hasCover: Bool = false,
                isAudiobook: Bool = false, chaptersAscending: Bool = true,
                fatalProblems: [String] = [], cosmeticProblems: [String] = []) {
        self.url = url
        self.wasChecked = wasChecked
        self.containerDuration = containerDuration
        self.decodedDuration = decodedDuration
        self.chapterCount = chapterCount
        self.hasAudio = hasAudio
        self.hasCover = hasCover
        self.isAudiobook = isAudiobook
        self.chaptersAscending = chaptersAscending
        self.fatalProblems = fatalProblems
        self.cosmeticProblems = cosmeticProblems
    }

    /// A file the run never got to. Deliberately not "passed" and not "damaged".
    public static func notChecked(_ url: URL) -> ExistingBookReport {
        ExistingBookReport(url: url, wasChecked: false)
    }

    /// Everything found, damage first — for reporting, never for deciding.
    public var problems: [String] { fatalProblems + cosmeticProblems }

    public var passed: Bool { wasChecked && fatalProblems.isEmpty }

    public var verdict: String {
        guard wasChecked else { return "Not checked" }
        guard fatalProblems.isEmpty else { return "Damaged" }
        guard !cosmeticProblems.isEmpty else { return "Sound" }
        return cosmeticProblems.count == 1 ? "Sound, 1 finding"
                                           : "Sound, \(cosmeticProblems.count) findings"
    }
}

/// Checks a `.m4b` this app did not create, using only what the file can be asked about
/// itself.
///
/// `OutputVerifier` cannot do this job. Its every check is relative — this many chapters,
/// this many seconds, both taken from the source MP3s measured minutes earlier — and for a
/// book that arrived from a shop, a rip or another tool there is nothing on the other side
/// of the comparison. Inventing one (guessing a chapter count from the title, say) would
/// produce confident wrong answers, which is worse than no answer.
///
/// So this asks the absolute questions, in descending order of what they cost the listener:
///
/// 1. **Does it decode to the length it claims?** The one check that needs no expectation
///    whatsoever, and the one that catches the defect this whole mode exists for: a
///    container reporting 20.0 s over 18.0 s of actual audio, ffmpeg exiting 0, and nothing
///    anywhere saying the last two seconds of the book are gone. The allowance for normal
///    metadata drift is `DurationMeasurer.allowedShortfall` — the one measured against 448
///    real files, not a second rule invented here.
/// 2. **Did the decode complain more than one file can explain?** `FFmpegStderr` with
///    `inputFiles: 1`, which is the tightest denominator the app ever has: one file in, one
///    stderr out, a budget of two. This catches the damage the length check cannot see — a
///    corrupt middle, where every packet still carries its timestamp so the file decodes to
///    exactly the right length while the audio inside it is rubbish.
/// 3. Audio at all, and chapter marks that advance — unplayable and unnavigable
///    respectively, and both fatal in `OutputVerifier` for the same reasons.
/// 4. Chapters, cover art, `media_type`, and a container that states no duration at all —
///    all present-or-absent facts about metadata, all fixable in a tag editor, none of them
///    a reason to call a book damaged. The last of those used to be fatal, which labelled a
///    file whose audio had just decoded from end to end as damage.
public struct ExistingBookChecker: Sendable {
    public static let fileExtension = "m4b"

    let tools: FFmpegTools
    let runner: ProcessRunner

    public init(tools: FFmpegTools, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    /// Every `.m4b` under the chosen files and folders, in the order a person would read
    /// them, each one once.
    ///
    /// Accepts files as well as folders, unlike `AudiobookScanner`: the user is picking
    /// finished books, not folders of tracks, and picking one book to check is the obvious
    /// thing to want.
    ///
    /// The walk itself is `FileTree`'s, shared with the scanner rather than written out
    /// again here — including the reason a walk needs remembering at all: a symlink to an
    /// ancestor makes a tree infinitely deep, and a folder chosen alongside one of its own
    /// children would otherwise be walked twice. All this adds is which extension it wants.
    ///
    /// The order is the walk's: the roots in the order the user picked them, and within each
    /// one, every directory's contents in natural order. There used to be a global
    /// `sorted(by: naturalLess)` over the result, which made the per-directory sorting dead
    /// work and threw away the order someone chose their folders in — check the new shelf
    /// first, then the archive, and the archive came back first.
    public static func collect(_ urls: [URL]) -> [URL] {
        var found: [URL] = []
        FileTree.walk(urls) { file in
            if file.pathExtension.lowercased() == fileExtension { found.append(file) }
        } visitDirectory: { _, _ in
            true  // every level: a shelf is folders of books, not one flat pile
        }
        return found
    }

    /// Throws only when no verdict could be reached — a cancelled runner, a missing binary,
    /// a decode that did not finish. Everything a FILE can be wrong about comes back as a
    /// report, because a damaged book is a result, not an error.
    ///
    /// The two halves have to answer that the same way, and did not: the ffprobe below used
    /// `try` and correctly produced "Not checked", while the decode's `try?` turned the same
    /// missing binary into "Damaged". A verdict about someone's irreplaceable media must not
    /// depend on which of two identical failures happened to occur.
    public func check(_ url: URL) async throws -> ExistingBookReport {
        let probe = try await runner.run(tools.ffprobe, M4BFacts.probeArguments(for: url.path))
        guard probe.succeeded, let facts = try? M4BFacts.parse(json: Data(probe.stdout.utf8),
                                                              url: url) else {
            let said = FFmpegStderr.diagnosticLines(probe.stderr).last
            return ExistingBookReport(
                url: url,
                fatalProblems: ["This could not be read as a media file"
                                + (said.map { ": \($0)" } ?? ".")])
        }

        var fatal: [String] = []
        var cosmetic: [String] = []
        var decoded: Double?

        // Unplayable, and every other check can still pass on such a file — the same
        // reasoning, and the same wording, as `OutputVerifier`.
        if !facts.hasAudio {
            fatal.append("No audio stream in this file, so nothing can play it.")
        } else {
            let outcome = try await decode(url, claiming: facts.duration)
            decoded = outcome.decoded
            fatal += outcome.fatal
            cosmetic += outcome.cosmetic
        }

        if !facts.chaptersAscending {
            fatal.append("Chapter start times do not strictly increase. Two marks land on "
                         + "the same millisecond or run backwards, and a player has no way "
                         + "to order them.")
        }
        if facts.chapterCount == 0 {
            cosmetic.append("No chapters at all — the book is one unmarked run of audio, "
                            + "so a player cannot skip through it or remember a place by "
                            + "chapter.")
        }
        if !facts.hasCover { cosmetic.append("No cover art embedded.") }
        if !facts.isAudiobook {
            cosmetic.append("Not flagged as an audiobook (media_type != 2), so players "
                            + "shelve it with music and may not remember its position.")
        }

        return ExistingBookReport(url: url, containerDuration: facts.duration,
                                  decodedDuration: decoded,
                                  chapterCount: facts.chapterCount,
                                  hasAudio: facts.hasAudio, hasCover: facts.hasCover,
                                  isAudiobook: facts.isAudiobook,
                                  chaptersAscending: facts.chaptersAscending,
                                  fatalProblems: fatal, cosmeticProblems: cosmetic)
    }

    /// Decodes the file and compares what came out against what the container promised.
    ///
    /// Everything about how this is judged is `DurationMeasurer`'s and `FFmpegStderr`'s: the
    /// same ffmpeg arguments, the same shortfall allowance, the same per-file complaint
    /// budget with the same denominator of one. The only thing that differs is the wording,
    /// because there the answer is "refuse to convert this MP3" and here it is "this book
    /// on your shelf is short".
    ///
    /// Throws rather than reporting when the decode could not be run OR did not finish.
    /// Neither is a fact about the file, and both used to be turned into one.
    private func decode(_ url: URL, claiming claimed: Double?) async throws
        -> (decoded: Double?, fatal: [String], cosmetic: [String]) {
        // `try`, not `try?`. A binary that is not there is the same failure the ffprobe
        // above reports as "Not checked"; swallowing it here made it "Damaged", which is a
        // verdict about a book, delivered because of something wrong with this machine.
        let result = try await runner.run(
            tools.ffmpeg, DurationMeasurer.decodeArguments(for: url.path))

        // And the same for a decode that started and did not finish. ffmpeg killed partway
        // — memory pressure, Activity Monitor, a cancel — still prints every `time=` line it
        // got through, so `parseFinalTime` happily recovers a number: a floor on how far the
        // decode got, not a measurement of the file. Comparing that against the container
        // produced "3.2 h (40%) of this file did not decode … Re-download or re-rip this
        // book" about a file nothing had been shown to be wrong with. No verdict is the
        // honest answer, and `LibraryCheck` already has one: "Not checked". ffmpeg's exit
        // code and its stderr travel with the error, as they do in `DurationMeasurer`.
        guard result.succeeded else {
            throw ProcessError.failed(
                code: result.exitCode,
                stderr: result.stderr + "\n\nThe decode of \(url.lastPathComponent) did not "
                      + "finish — ffmpeg exited \(result.exitCode) — so nothing was "
                      + "established about this file either way.")
        }

        var fatal: [String] = []
        if let evidence = FFmpegStderr.failureEvidence(in: result.stderr, inputFiles: 1) {
            fatal.append("The decode failed. " + evidence)
        }
        guard let measured = DurationMeasurer.parseFinalTime(result.stderr) else {
            fatal.append("Nothing decoded: ffmpeg reported no timestamps at all, so "
                         + "this file's real length is unknown and its container's "
                         + "claim is not a safe substitute.")
            return (nil, fatal, [])
        }

        // A container with no duration in it is a metadata absence, and belongs with the
        // other metadata absences below. The audio decoded from end to end; there is simply
        // nothing to check its length against. Fatal here means the AUDIO is wrong — the
        // type's own doc says so — and calling this file damaged said the opposite of what
        // the decode had just shown.
        guard let claimed, claimed > 0 else {
            return (measured, fatal,
                    [String(format: "The container reports no duration, so the %.2f s that "
                          + "decoded could not be checked against anything. The audio is "
                          + "there; the number that would describe it is not.", measured)])
        }

        let shortfall = claimed - measured
        let allowed = DurationMeasurer.allowedShortfall(containerDuration: claimed)
        if shortfall > allowed {
            fatal.append(String(
                format: "Decodes to only %.2f s, but its container reports %.2f s — "
                      + "%.2f s (%.1f%%) of this file did not decode. That much audio is "
                      + "missing from the book, and ffmpeg exits 0 without saying so. At "
                      + "most %.2f s of disagreement is normal here. Re-download or "
                      + "re-rip this book.",
                measured, claimed, shortfall, shortfall / claimed * 100, allowed))
        }
        return (measured, fatal, [])
    }
}
