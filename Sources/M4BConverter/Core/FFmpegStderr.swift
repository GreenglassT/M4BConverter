import Foundation

/// What ffmpeg's stderr says happened — which is not always what its exit code says.
///
/// `ProcessResult.succeeded` is `exitCode == 0`, and the pipeline treats that as proof of
/// success. Three separate cases have now shown it is not: ffprobe exiting 0 with
/// truncated stdout, a corrupt MP3 exiting 0 while decoding short, and — the case this
/// type exists for — a misnamed AAC file under the concat demuxer, which produced 262
/// lines of decoder errors, exited 0, and wrote an .m4b with an entire file's audio
/// missing (3.04 s where 6 s was expected).
///
/// The hard part is that the malignant case and the benign one use the SAME words. An
/// MP3's trailing ID3v1 tag is handed to the decoder as if it were a frame and produces
/// `Header missing` plus one submit error — on perfectly good books, routinely. The
/// misnamed-AAC failure produced those exact two messages 131 times each. So the
/// discriminator cannot be the message text; it has to be how much of it there is,
/// against how many files were fed in.
///
/// Everything here is measured, not assumed. Every verdict string below was found
/// verbatim in the installed ffmpeg 8.1 binaries, and the volume budget comes from
/// decoding 177 files of five real audiobooks.
public enum FFmpegStderr {
    /// One per-packet complaint, recognised by every fragment appearing on the line.
    ///
    /// Fragments rather than one substring because ffmpeg builds some of these messages
    /// with a format string: `Error submitting %s to decoder: %s` is one call site (that
    /// exact string is in the installed ffmpeg 8.1 binary) whose first `%s` is "packet"
    /// while decoding and "EOF" when the stream is flushed at the end. Matching only the
    /// "packet" expansion made the app read one condition two different wrong ways
    /// depending on the second `%s`. `Error submitting EOF to decoder: Invalid data found
    /// when processing input` — the flush of an MP3 with a trailing ID3v1 tag — was not a
    /// per-packet complaint by that spelling, so it went on to be tested against the
    /// verdict list, matched `Invalid data found when processing input` there, and failed
    /// the whole book on one benign line. With any other reason attached it matched
    /// nothing at all and a file could repeat it a thousand times unnoticed. Matching the
    /// format string instead of one of its expansions makes both behave like the "packet"
    /// spelling they are.
    struct Complaint: Sendable {
        /// What the verdict text calls this message.
        let label: String
        /// All of these must appear on a line for it to be this complaint.
        let fragments: [String]

        init(_ label: String, _ fragments: [String]? = nil) {
            self.label = label
            self.fragments = fragments ?? [label]
        }

        func matches(_ line: String) -> Bool { fragments.allSatisfy(line.contains) }
    }

    /// Complaints about ONE packet. ffmpeg prints one of these per packet it could not
    /// decode and then carries on, so a single occurrence says nothing about whether the
    /// run as a whole worked. Only the volume does.
    ///
    /// The spelling changed with the tool: `Error while decoding stream #0:0: …` up to
    /// ffmpeg 6.0 (fftools/ffmpeg.c), `Error submitting packet to decoder: …` from 6.1
    /// onwards (fftools/ffmpeg_dec.c), both at AV_LOG_ERROR for the identical condition.
    /// Nothing pins the version this app runs against — `FFmpegLocator` takes whatever is
    /// on the machine and `Preflight.validate` only asks for `aac_at` — so both spellings
    /// have to be recognised here. Miss one and a merely noisy book converted on an older
    /// ffmpeg gets failed outright, which is the expensive mistake in both directions.
    static let perPacketDecodeComplaints: [Complaint] = [
        // libavcodec/mpegaudiodec_template.c:1583, on a tag byte fed to the mp3 decoder.
        Complaint("Header missing"),
        // ffmpeg_dec.c:733, "Error submitting %s to decoder" — "packet" while decoding,
        // "EOF" when the stream is flushed at the end. Both are the same per-packet
        // condition and both must be judged the same way.
        Complaint("Error submitting … to decoder", ["Error submitting ", " to decoder"]),
        // ffmpeg.c:2656 in 6.0 and 2465 in 5.1 — the same condition, older wording.
        Complaint("Error while decoding stream"),
        // ffmpeg_dec.c:983 and :763 — the decoder thread's and receive_frame's reports
        // of the same thing, both AV_LOG_ERROR.
        Complaint("Error processing packet in decoder"),
        Complaint("Decoding error:"),
    ]

    /// Messages ffmpeg only prints once something has actually gone wrong for the run as
    /// a whole — the output is absent, empty, unfinished, or was never opened. None can
    /// be produced by a healthy conversion, so one occurrence is enough.
    ///
    /// Every entry was read out of the ffmpeg 8.1 sources (line numbers from tag n8.1)
    /// and confirmed verbatim in the installed binaries. Nothing here is a guess about
    /// what ffmpeg "probably" says.
    ///
    /// Deliberately NOT in this list: `Error submitting packet to decoder`, `Header
    /// missing` and `Error while decoding stream`. They read like failures, and good
    /// books emit them every day — they are per-packet complaints, judged by volume
    /// above.
    static let failureVerdicts = [
        // ffmpeg_mux.c:564, AV_LOG_ERROR — the muxer refused the streams, no usable file.
        "Could not write header",
        // ffmpeg_mux.c:766, AV_LOG_ERROR — "Nothing was written into output file, because
        // at least one of its streams received no packets." Exactly the shape of the bug
        // this guards against: a stream that decoded to nothing.
        "received no packets",
        // ffmpeg_mux_init.c:2102, AV_LOG_ERROR — an .m4b with nothing in it.
        "Output file does not contain any stream",
        // ffmpeg_mux.c:449, AV_LOG_ERROR — a packet that never reached the file, so the
        // audio in the output is not the audio that was planned.
        "Error muxing a packet",
        // ffmpeg_mux.c:772, AV_LOG_ERROR — for MP4 the trailer carries the moov atom, so
        // failing to write it leaves a file no player can open.
        "Error writing trailer",
        // ffmpeg_sched.c:2677, AV_LOG_ERROR — a transcode task that ended in an error.
        "Task finished with error code",
        // ffmpeg_demux.c:2017 and :763, AV_LOG_ERROR — the input was never usable.
        "Error opening input",
        "Error during demuxing",
        // ffmpeg_enc.c:346, AV_LOG_ERROR — the encoder never started.
        "Error while opening encoder",
        // libavformat/mov.c:10905, AV_LOG_ERROR — a truncated or non-MP4 file as MP4.
        "moov atom not found",
        // libavutil/error.c:43 — the text of AVERROR_INVALIDDATA, which reaches stderr as
        // the reason inside other messages. Only ever consulted on a line that is NOT a
        // per-packet complaint: the benign complaint ends "…: Invalid data found when
        // processing input", so matching it anywhere would fail every book with trailing
        // ID3v1 tags. On any other line it is something rejecting an input outright
        // ("list.txt: Invalid data found when processing input").
        "Invalid data found when processing input",
        // These last two are logged BELOW error level — ffmpeg.c:365 is AV_LOG_INFO, and
        // ffmpeg_mux.c:684 is AV_LOG_WARNING unless -abort_on is set — so `-v error`,
        // which is what this app runs, suppresses both. They are kept because they are
        // ffmpeg's plainest statements that the run failed, they cannot appear on a
        // healthy run at any verbosity, and a future caller reading stderr from a less
        // quiet invocation should not have to rediscover them.
        "Conversion failed",
        "Output file is empty",
    ]

    /// How many per-packet complaints ONE input file may legitimately produce.
    ///
    /// The cause is a trailing ID3v1 tag, and a file has at most one of those, so the
    /// honest bound is one. Measured across 177 files of five real audiobooks: never more
    /// than one of each message on any file, and four of the five books produced none at
    /// all. Two leaves room for a file that also ends on a torn frame without weakening
    /// the test.
    ///
    /// This is a per-file allowance, and `failureEvidence` multiplies it by the number of
    /// inputs — so the budget is only 2 when exactly one file was fed in. The failure this
    /// was derived from ran 131 per file, which clears a budget of 2 easily and a budget
    /// of 380 (a 190-file book) not at all: a whole-run total is at its weakest on exactly
    /// the books where a lost file is hardest to notice. `DurationMeasurer.measure` applies
    /// the same rule to ONE file's stderr before any of them are concatenated, which is
    /// where the denominator is tightest and the budget really is 2; the run-level check
    /// below stays as the backstop for what only goes wrong once the files are joined.
    static let complaintsAllowedPerFile = 2

    /// Stderr with ffmpeg's progress reporting removed, blank lines dropped.
    ///
    /// `-stats` writes its readouts carriage-return separated into a single
    /// newline-terminated run, so discarding newline-delimited lines that mention `time=`
    /// removes the whole block at once; real diagnostics arrive on their own
    /// newline-terminated lines, which is why this works at all. Runs that use `-progress`
    /// instead — the encode — put nothing on stderr to remove.
    public static func diagnosticLines(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").map(String.init).filter {
            !$0.contains("time=") && !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    static func isPerPacketComplaint(_ line: String) -> Bool {
        perPacketDecodeComplaints.contains { $0.matches(line) }
    }

    /// Evidence that this run genuinely failed, or nil when there is none.
    ///
    /// `inputFiles` is the number of files handed to ffmpeg: the budget for benign noise
    /// scales with it, because the cause of that noise is one trailing tag per file.
    ///
    /// Answering "did it fail?" from stderr rather than from the exit code is the whole
    /// point — callers apply this AFTER the exit-code check, to the runs that claimed to
    /// succeed.
    public static func failureEvidence(in stderr: String, inputFiles: Int) -> String? {
        let lines = diagnosticLines(stderr)
        guard !lines.isEmpty else { return nil }

        // A verdict, on a line that is not itself a per-packet complaint. One is enough.
        for line in lines where !isPerPacketComplaint(line) {
            guard let verdict = failureVerdicts.first(where: { line.contains($0) }) else {
                continue
            }
            return "ffmpeg reported \"\(verdict)\": \(line)"
        }

        // Or too much per-packet noise for the number of files to explain.
        let budget = max(inputFiles, 1) * complaintsAllowedPerFile
        for complaint in perPacketDecodeComplaints {
            let count = lines.count { complaint.matches($0) }
            guard count > budget else { continue }
            return "ffmpeg reported \"\(complaint.label)\" \(count) times for \(inputFiles) "
                 + "input file(s), where at most \(budget) is normal — an MP3's trailing "
                 + "ID3v1 tag accounts for one per file. That much means whole packets "
                 + "were discarded and audio is missing from the output."
        }
        return nil
    }
}
