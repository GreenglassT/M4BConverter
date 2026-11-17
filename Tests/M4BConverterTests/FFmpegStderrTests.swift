import Foundation
import Testing
@testable import M4BConverter

/// The two messages a trailing ID3v1 tag produces, exactly as ffmpeg 8.1 writes them.
private func trailingTagNoise(files: Int) -> String {
    (0..<files).flatMap { index in
        ["[mp3float @ 0x12\(index)] Header missing",
         "[aist#0:0/mp3 @ 0x34\(index)] [dec:mp3float @ 0x56\(index)] "
         + "Error submitting packet to decoder: Invalid data found when processing input"]
    }.joined(separator: "\n")
}

// The failure that motivated all of this. A misnamed AAC file under the concat demuxer:
// 131 of each message for two input files, exit code 0, and an .m4b missing an entire
// file's audio — 3.04 s where 6 s was expected. Counts and wording are the real ones,
// captured from ffmpeg 8.1.
@Test func bulkDecodeErrorsAreAFailureNoMatterWhatTheExitCodeSays() {
    let stderr = (0..<131).map { _ in trailingTagNoise(files: 1) }.joined(separator: "\n")
    let evidence = FFmpegStderr.failureEvidence(in: stderr, inputFiles: 2)
    #expect(evidence != nil)
    #expect(evidence?.contains("131") == true)
    #expect(evidence?.contains("Header missing") == true)
}

// The same words, in the quantity a healthy book produces. A real 75-file book does emit
// one of these per file across 75 files; failing it would destroy hours of correct work.
@Test func oneTrailingTagComplaintPerFileIsNotAFailure() {
    for files in [1, 7, 75, 190] {
        #expect(FFmpegStderr.failureEvidence(in: trailingTagNoise(files: files),
                                             inputFiles: files) == nil)
    }
}

// Measured from a real book: concatenating its 75 files produced 16
// "Header missing" and 74 "Error submitting packet to decoder", and that book is fine.
@Test func theNoisiestRealBookInTheLibraryIsNotFlagged() {
    let lines = Array(repeating: "[mp3float @ 0x1] Header missing", count: 16)
        + Array(repeating: "[aist#0:0/mp3 @ 0x2] [dec:mp3float @ 0x3] Error submitting "
                + "packet to decoder: Invalid data found when processing input", count: 74)
    #expect(FFmpegStderr.failureEvidence(in: lines.joined(separator: "\n"),
                                         inputFiles: 75) == nil)
}

// A clean real book: 7 files, 190 chapters, and not one byte on stderr. The overwhelmingly
// common case must cost nothing and decide nothing.
@Test func silenceIsNotEvidenceOfFailure() {
    #expect(FFmpegStderr.failureEvidence(in: "", inputFiles: 7) == nil)
    #expect(FFmpegStderr.failureEvidence(in: "\n   \n", inputFiles: 7) == nil)
}

// `-stats` writes its readouts carriage-return separated inside one newline-terminated
// run. Those are progress, not diagnostics, and must never be counted as either.
@Test func progressOutputIsNotADiagnostic() {
    let stats = "size=N/A time=00:17:08.51 bitrate=N/A speed=2.06e+03x\r"
              + "size=N/A time=00:34:24.06 bitrate=N/A speed=2.05e+03x"
    #expect(FFmpegStderr.diagnosticLines(stats).isEmpty)
    #expect(FFmpegStderr.failureEvidence(in: stats, inputFiles: 1) == nil)
}

// ffmpeg's own statements that the run failed. One is enough — no book produces these.
@Test func aSingleFailureVerdictIsEnough() {
    let verdicts = [
        "[mp4 @ 0x1] Could not write header (incorrect codec parameters ?): Invalid argument",
        "[out#0/mp4 @ 0x1] Nothing was written into output file, because at least one of "
            + "its streams received no packets.",
        "[out#0/mp4 @ 0x1] Error muxing a packet",
        "[out#0/mp4 @ 0x1] Error writing trailer: Input/output error",
        "[in#0 @ 0x1] Error opening input: Invalid data found when processing input",
        "[mov,mp4,m4a @ 0x1] moov atom not found",
        "/tmp/list.txt: Invalid data found when processing input",
        "Conversion failed!",
    ]
    for verdict in verdicts {
        #expect(FFmpegStderr.failureEvidence(in: verdict, inputFiles: 7) != nil,
                "expected \(verdict) to be treated as a failure")
    }
}

// The benign complaint ENDS with "Invalid data found when processing input", which is
// also a failure verdict on any other line. Matching it blindly would fail every book in
// the library that carries trailing ID3v1 tags.
@Test func theReasonInsideABenignComplaintIsNotAVerdict() {
    let benign = "[aist#0:0/mp3 @ 0x1] [dec:mp3float @ 0x2] Error submitting packet to "
               + "decoder: Invalid data found when processing input"
    #expect(FFmpegStderr.failureEvidence(in: benign, inputFiles: 1) == nil)
    // Still a verdict when it is the demuxer's own, on a line of its own.
    #expect(FFmpegStderr.failureEvidence(in: benign + "\n/tmp/list.txt: Invalid data found "
                                         + "when processing input", inputFiles: 1) != nil)
}

// The message is built from `Error submitting %s to decoder: %s`, one format string whose
// first `%s` is "packet" while decoding and "EOF" when the stream is flushed at the end.
// Only the "packet" expansion was listed, so the EOF one was judged by whatever its reason
// text happened to be: with "Invalid data found when processing input" — which is exactly
// what a trailing ID3v1 tag produces — it fell through to the verdict list and failed the
// whole book on one benign line, and with any other reason it matched nothing at all and a
// file could repeat it hundreds of times unnoticed.
@Test func theEOFSpellingOfTheSubmitErrorIsJudgedLikeThePacketSpelling() {
    let eof = "[aist#0:0/mp3 @ 0x1] [dec:mp3float @ 0x2] Error submitting EOF to decoder: "
            + "Invalid data found when processing input"
    // Benign in ones, exactly like the packet spelling — this is what an ID3v1 tag on the
    // last frame of a file looks like when the decoder is flushed.
    #expect(FFmpegStderr.failureEvidence(in: eof, inputFiles: 1) == nil)
    #expect(DurationMeasurer.isBenignTrailingTagNoise(eof))
    // And damning in bulk, which it could not be while it matched nothing at all.
    let bulk = Array(repeating: eof, count: 131).joined(separator: "\n")
    let evidence = FFmpegStderr.failureEvidence(in: bulk, inputFiles: 2)
    #expect(evidence != nil)
    #expect(evidence?.contains("131") == true)

    // The packet spelling still works, and the two are counted as the one message they
    // are: 2 of each is 4 for one file, over a budget of 2.
    let packet = "[aist#0:0/mp3 @ 0x1] Error submitting packet to decoder: "
               + "Invalid data found when processing input"
    #expect(FFmpegStderr.failureEvidence(
        in: [eof, packet, eof, packet].joined(separator: "\n"), inputFiles: 1) != nil)

    // Not so loose that it matches ffmpeg's other "Error submitting …" messages, which
    // are about the filter graph, the encoder and the muxer rather than a decoded packet.
    for other in ["[fc#0 @ 0x1] Error submitting a packet for filtering: Invalid argument",
                  "[out#0/mp4 @ 0x1] Error submitting a packet to the muxer: I/O error"] {
        #expect(!DurationMeasurer.isBenignTrailingTagNoise(other),
                "expected \(other) not to be read as a per-packet decode complaint")
    }
}

// ffmpeg <= 6.0 words the identical per-packet failure differently (fftools/ffmpeg.c
// "Error while decoding stream #%d:%d"; 6.1 moved to "Error submitting %s to decoder").
// Nothing pins the version the app runs against, so both spellings must be benign in
// ones and damning in bulk — otherwise an older ffmpeg either fails good books or hides
// broken ones.
@Test func theOlderFFmpegWordingIsJudgedTheSameWay() {
    let line = "Error while decoding stream #0:0: Invalid data found when processing input"
    let onePerFile = Array(repeating: line, count: 7).joined(separator: "\n")
    #expect(FFmpegStderr.failureEvidence(in: onePerFile, inputFiles: 7) == nil)

    let bulk = Array(repeating: line, count: 131).joined(separator: "\n")
    #expect(FFmpegStderr.failureEvidence(in: bulk, inputFiles: 2) != nil)
    #expect(DurationMeasurer.isBenignTrailingTagNoise(line))
}
