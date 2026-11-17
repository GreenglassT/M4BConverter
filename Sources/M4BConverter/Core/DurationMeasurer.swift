import Foundation

public struct DurationMeasurer: Sendable {
    let tools: FFmpegTools
    let runner: ProcessRunner

    public init(tools: FFmpegTools, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public struct Measurement: Sendable {
        public var duration: Double
        public var hadBenignTagNoise: Bool
    }

    /// Decode the first audio stream and discard it, with `-stats` so ffmpeg reports how
    /// far it got — the only way to learn how much audio a file really contains.
    ///
    /// Shared with `ExistingBookChecker`, which asks the same question of a finished .m4b
    /// that this asks of a source MP3. One argument list, so the two cannot end up decoding
    /// differently and disagreeing about what "the file's real length" means.
    public static func decodeArguments(for path: String) -> [String] {
        ["-hide_banner", "-v", "error", "-stats",
         "-i", path, "-map", "0:a:0", "-f", "null", "-"]
    }

    /// Exact duration by decoding.
    ///
    /// A partially decodable file legitimately reports less than its container claims,
    /// and ffmpeg still exits 0 — that shorter value is the truth, because the encode
    /// decodes the same bytes with the same decoder and produces exactly that much
    /// audio. Chapters must be based on it, not on the metadata.
    ///
    /// But "the truth" and "acceptable" are different questions, and only the first one
    /// used to be asked. A CBR MP3 with 10% of its bytes overwritten mid-file decodes
    /// 2.01 s short of its container's 20.04 s, exits 0, and says exactly two things on
    /// stderr — inside every budget the app had. The shorter number then became the
    /// expected length, `OutputVerifier` compared the .m4b against it and agreed, and the
    /// book was marked `.verified` two seconds short with nothing on screen to say so.
    /// The container's claim was sitting unused on `TrackInfo` the whole time. Compare
    /// against it, and refuse the file when the decode falls materially short.
    ///
    /// No timestamps at all means nothing decoded: a missing, empty, or non-audio file.
    /// That is a failure whatever ffmpeg exits with.
    ///
    /// It used to be a failure only when ffmpeg also exited non-zero, and otherwise fell
    /// back to `track.estimatedDuration` — the container's own claim, which is precisely
    /// the number Task 13 stopped trusting because VBR headers lie about it. That turned
    /// "this file could not be measured" into "a number known to be wrong was used
    /// quietly", and the damage compounds: the value feeds `totalDuration`, which is what
    /// `OutputVerifier` checks the finished .m4b against, so a wrong length here makes the
    /// verifier agree with a wrong output. Nothing real depends on the fallback either —
    /// `-stats` prints a final `time=` readout even for a 0.05 s file (verified), so any
    /// file with decodable audio in it reaches the branch above. Using it as a CEILING to
    /// check the measurement against is a different use, and a safe one: a header that
    /// lies makes this check fire on a good file, which costs a loud, named, retryable
    /// failure — not a quietly incomplete audiobook.
    public func measure(_ track: TrackInfo) async throws -> Measurement {
        let result = try await runner.run(
            tools.ffmpeg, DurationMeasurer.decodeArguments(for: track.url.path))

        // One file in, one stderr out: this is the tightest denominator the app ever has,
        // and the only place the "at most two complaints per file" budget is applied at
        // its real strength. The encode's check divides the same allowance across every
        // file of the book, so a 190-file book can absorb 380 complaints — enough to hide
        // seconds of dropped audio — while the run still looks clean.
        if let evidence = FFmpegStderr.failureEvidence(in: result.stderr, inputFiles: 1) {
            throw ProcessError.failed(
                code: result.exitCode,
                stderr: describe(track, note: "\(track.filename) could not be measured. "
                                            + evidence, stderr: result.stderr))
        }

        // isBenignTrailingTagNoise requires progress lines stripped first, which is
        // exactly what `diagnosticLines` does for the classifier above.
        let noiseOnly = DurationMeasurer.isBenignTrailingTagNoise(
            FFmpegStderr.diagnosticLines(result.stderr).joined(separator: "\n"))

        if let measured = DurationMeasurer.parseFinalTime(result.stderr) {
            let shortfall = track.estimatedDuration - measured
            let allowed = DurationMeasurer.allowedShortfall(
                containerDuration: track.estimatedDuration)
            // Only when the container claims a duration at all: 0 means ffprobe reported
            // none, and there is nothing to compare against.
            if track.estimatedDuration > 0, shortfall > allowed {
                let percent = shortfall / track.estimatedDuration * 100
                let note = String(
                    format: "%@ decodes to only %.2f s, but its container reports %.2f s "
                          + "— %.2f s (%.1f%%) of this file did not decode, and ffmpeg "
                          + "exited %d without saying so. That audio would be missing "
                          + "from the .m4b, and because the chapter plan and the finished "
                          + "file would both be built from the short measurement, nothing "
                          + "later would notice. At most %.2f s of disagreement is normal "
                          + "here. Re-download or re-rip this file.",
                    track.filename, measured, track.estimatedDuration, shortfall, percent,
                    result.exitCode, allowed)
                throw ProcessError.failed(
                    code: result.exitCode,
                    stderr: describe(track, note: note, stderr: result.stderr))
            }
            return Measurement(duration: measured, hadBenignTagNoise: noiseOnly)
        }
        let note = "Nothing decoded from \(track.filename): ffmpeg reported no timestamps "
                 + "at all, so the file's real length is unknown. The container's own "
                 + "claim is not a safe substitute — a VBR header can be wrong by minutes, "
                 + "and it would be used to place every later chapter and to decide "
                 + "whether the finished file is the right length."
        throw ProcessError.failed(
            code: result.exitCode,
            stderr: describe(track, note: note, stderr: result.stderr))
    }

    /// ffmpeg's own output first, this app's explanation last.
    ///
    /// `failureSummary` puts the LAST non-empty line on the red label, so the sentence
    /// that names the file has to come after ffmpeg's, and has to be one line.
    private func describe(_ track: TrackInfo, note: String, stderr: String) -> String {
        stderr.isEmpty ? note : stderr + "\n\n" + note
    }

    /// How far short of its container's claim one file may decode before the difference
    /// is treated as lost audio rather than as metadata drift.
    ///
    /// Measured, not guessed: 448 files and 261.5 hours of real audiobooks — nine
    /// books from several sources — decoded one at a time and
    /// compared against ffprobe's `format.duration` for the same file. Every single one
    /// decoded SHORTER than its container claimed, by at most **0.025 s**; the largest
    /// relative gap was 0.285%, on the shortest file in the library (3.0 s), and among the
    /// 395 files over 200 s the largest relative gap was 0.009%. Nothing decoded long.
    ///
    /// Hence three terms, because no single one of them is safe on its own:
    ///
    /// - A floor of 1 s, since a purely relative rule punishes short files: 9 ms on a 3 s
    ///   file is 0.28%, and `-stats` only prints hundredths anyway, so the resolution of
    ///   the measurement is itself 0.01 s. 40× the worst absolute gap observed.
    /// - 0.5% of the claimed duration, so a longer file gets proportionally more room for
    ///   a header that rounds or estimates. 55× the worst relative gap observed on the
    ///   files where this term is the one in force.
    /// - A cap of 10 s, because the relative term alone is dangerous exactly where it
    ///   matters most: 0.5% of an 8-hour file is 2.4 minutes, and a single contiguous
    ///   corrupt span produces ONE pair of stderr complaints however much audio it eats,
    ///   so volume-based checks cannot backstop it. 400× the worst gap observed on the
    ///   224 files over 2000 s.
    ///
    /// The library's worst file uses 1.9% of its allowance. The 20 s / 2.01 s corruption
    /// this exists to catch uses 201% of it.
    public static let shortfallFloor = 1.0
    public static let shortfallFraction = 0.005
    public static let shortfallCap = 10.0

    public static func allowedShortfall(containerDuration: Double) -> Double {
        min(max(shortfallFloor, containerDuration * shortfallFraction), shortfallCap)
    }

    private static let timePattern = try! NSRegularExpression(
        pattern: #"time=(\d+):(\d\d):(\d\d\.\d+)"#)

    /// Returns the largest timestamp seen. ffmpeg's closing summary line reports a
    /// near-zero time, so taking the last match would be wrong.
    public static func parseFinalTime(_ stderr: String) -> Double? {
        let ns = stderr as NSString
        let matches = timePattern.matches(in: stderr,
                                          range: NSRange(location: 0, length: ns.length))
        let values: [Double] = matches.compactMap { match in
            guard let h = Double(ns.substring(with: match.range(at: 1))),
                  let m = Double(ns.substring(with: match.range(at: 2))),
                  let s = Double(ns.substring(with: match.range(at: 3))) else { return nil }
            return h * 3600 + m * 60 + s
        }
        return values.max()
    }

    /// MP3s with a trailing ID3v1 tag hand the decoder 128 bytes of tag text as if it
    /// were a frame. One "Header missing" per file, at the very end of the file, and
    /// treating it as a failure would make perfectly good books look broken.
    ///
    /// How much audio that costs is NOT known here, and nothing in this app has ever
    /// measured it — the "about 17 ms" the user used to be shown was a frame-size
    /// calculation presented as an observation. The question is answered instead by
    /// `measure`, which compares what actually decoded against the container's own
    /// duration and refuses the file when it falls materially short. A book that reaches
    /// the note has passed that check on every one of its files.
    ///
    /// Requires stderr with progress lines already removed — `measure` runs with
    /// `-stats`, and those `time=` lines do not match the benign patterns, so passing
    /// raw stderr here always returns false. Callers must filter first.
    ///
    /// This recognises the *message text*, not the number of occurrences, so a genuinely
    /// broken file producing many of the same messages would be classified benign here.
    /// That is fine for what this drives — an informational note — because `measure` now
    /// runs `FFmpegStderr.failureEvidence` over the same stderr first, with a budget of
    /// two for the one file it just decoded. The patterns are shared with that classifier
    /// so the two cannot drift apart.
    public static func isBenignTrailingTagNoise(_ stderr: String) -> Bool {
        let lines = stderr.split(separator: "\n").map(String.init)
        guard !lines.isEmpty else { return false }
        return lines.allSatisfy(FFmpegStderr.isPerPacketComplaint)
    }
}
