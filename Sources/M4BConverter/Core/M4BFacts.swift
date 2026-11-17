import Foundation

/// What ffprobe says about one finished `.m4b`, with nothing expected of it.
///
/// The separation is the whole point. `OutputVerifier` asks a RELATIVE question — is this
/// the file the app just planned, with that many chapters and that much audio — and it can
/// only ask it because the source MP3s were measured first. `ExistingBookChecker` looks at
/// files this app did not create, where no such expectation exists and inventing one would
/// mean making numbers up. Both read the same ffprobe output the same way; only one of them
/// has anything to compare it against. So the reading lives here, and the judging lives in
/// each of them.
public struct M4BFacts: Sendable, Equatable {
    /// Chapter start times in file order, as reported — not sorted, because whether they
    /// ascend is one of the things being asked.
    public var chapterStarts: [Double]
    /// nil when the container reports no duration, or one that cannot be read. A different
    /// fact from a duration that merely disagrees with something, and reported as one.
    public var duration: Double?
    public var hasAudio: Bool
    public var hasCover: Bool
    public var isAudiobook: Bool

    public init(chapterStarts: [Double] = [], duration: Double? = nil,
                hasAudio: Bool = false, hasCover: Bool = false, isAudiobook: Bool = false) {
        self.chapterStarts = chapterStarts
        self.duration = duration
        self.hasAudio = hasAudio
        self.hasCover = hasCover
        self.isAudiobook = isAudiobook
    }

    public var chapterCount: Int { chapterStarts.count }

    /// Strictly ascending as the file CARRIES them, which is `ChapterEditor`'s rule rather
    /// than a comparison of Doubles: the .m4b is written on a millisecond grid, so two
    /// starts a fraction of one apart are the same number in the file. Restating that here
    /// would be a second place for it to drift away from the editor that enforces it while
    /// the user types.
    public var chaptersAscending: Bool { ChapterEditor.startsStrictlyAscend(chapterStarts) }

    /// The one ffprobe invocation both callers make, so neither can ask for less than the
    /// other reads: chapters, streams and format together, as JSON.
    public static func probeArguments(for path: String) -> [String] {
        ["-v", "error", "-show_chapters", "-show_streams", "-show_format",
         "-of", "json", path]
    }

    /// Reads one of ffprobe's time fields, in either of the two shapes it can arrive in.
    ///
    /// A JSON number OR a quoted string, for every such field, because which one appears is
    /// ffprobe's business and not this app's. `format.duration` already accepted both;
    /// `chapters[].start_time` accepted only a string and fell back to 0. The installed
    /// ffprobe (8.1) quotes both, so that was defensive code with nothing to defend against
    /// — but had a build ever emitted numbers, every chapter would have started at 0,
    /// `chaptersAscending` would have gone false for every file with more than one chapter,
    /// and `OutputVerifier` treats that as fatal: the queue would have deleted a finished
    /// multi-hour encode over a JSON type. Two fields read through one function cannot drift
    /// apart like that again.
    ///
    /// Finite only: ffprobe can emit "inf" or "nan" as text, and JSON permits both. A
    /// non-finite value reaches arithmetic that traps, and it is not a time anyway — it is
    /// the absence of one.
    static func seconds(_ value: Any?) -> Double? {
        ((value as? Double) ?? (value as? String).flatMap(Double.init))
            .flatMap { $0.isFinite ? $0 : nil }
    }

    public static func parse(json: Data, url: URL? = nil) throws -> M4BFacts {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProbeError.badJSON(url ?? URL(fileURLWithPath: "unknown file"))
        }
        let chapters = root["chapters"] as? [[String: Any]] ?? []
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]
        let tags = format["tags"] as? [String: Any] ?? [:]

        return M4BFacts(
            // A start that cannot be read at all is 0 rather than dropped: `chapterCount` is
            // this array's length and has to stay the number of chapters the file carries,
            // and `[Double]` has no way to say "unknown". Both callers then see marks that
            // do not advance, which is what an unreadable chapter table amounts to.
            chapterStarts: chapters.map { seconds($0["start_time"]) ?? 0 },
            duration: seconds(format["duration"]),
            hasAudio: streams.contains { $0["codec_type"] as? String == "audio" },
            // Require the attached-picture disposition, not merely any video stream: a
            // file carrying a real video track would otherwise satisfy the cover check.
            hasCover: streams.contains { stream in
                stream["codec_type"] as? String == "video"
                    && ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            },
            isAudiobook: String(describing: tags["media_type"] ?? "") == "2")
    }
}
