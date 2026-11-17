import Foundation

/// ffmpeg's final `-progress` block reports the attached picture's timestamp (~0.04s)
/// rather than the audio's, so a raw reading would snap the bar back to zero at the end
/// of every book that has a cover — which is all of them. Only report forward movement.
final class MonotonicProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var highest = 0.0

    /// Returns the value to report, or nil if this reading would move backwards.
    func advance(to value: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        guard value > highest else { return nil }
        highest = value
        return value
    }
}

public struct FFmpegBackend: Sendable {
    let tools: FFmpegTools
    let runner: ProcessRunner

    public init(tools: FFmpegTools, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public func convert(_ job: ConversionJob,
                        progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let work = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m4b-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let listURL = work.appendingPathComponent("list.txt")
        let metaURL = work.appendingPathComponent("meta.txt")
        try ConcatListWriter.render(job.tracks.map(\.url))
            .write(to: listURL, atomically: true, encoding: .utf8)
        try FFMetadataWriter.render(metadata: job.metadata, chapters: job.chapters)
            .write(to: metaURL, atomically: true, encoding: .utf8)

        // Some books ship no cover file — the art lives only inside the MP3s.
        // Extract it so the output still gets a cover; the verifier fails a book
        // that has none.
        var cover = job.coverImage
        if cover == nil, let first = job.tracks.first {
            cover = await extractEmbeddedArt(from: first, into: work)
        }

        var arguments = [
            "-hide_banner", "-v", "error", "-progress", "pipe:1", "-nostats", "-y",
            "-f", "concat", "-safe", "0", "-i", listURL.path,
            "-i", metaURL.path,
        ]
        if let cover {
            arguments += ["-i", cover.path]
        }
        arguments += ["-map", "0:a:0", "-map_metadata", "1", "-map_chapters", "1"]
        if cover != nil {
            arguments += ["-map", "2:v:0", "-c:v", "mjpeg", "-disposition:v:0", "attached_pic"]
        }
        arguments += [
            "-c:a", "aac_at", "-b:a", "\(job.bitRate)",
            "-ar", "\(max(job.sampleRate, 22050))", "-ac", "\(job.channels)",
            "-movflags", "+faststart", "-f", "mp4", job.outputURL.path,
        ]

        let total = max(job.totalDuration, 0.001)
        let tracker = MonotonicProgress()
        let result = try await runner.run(tools.ffmpeg, arguments) { line in
            // ffmpeg -progress emits "out_time_us=12345678"
            guard line.hasPrefix("out_time_us=") else { return }
            let value = line.dropFirst("out_time_us=".count)
            guard let micros = Double(value), micros >= 0 else { return }
            if let fraction = tracker.advance(to: min(micros / 1_000_000 / total, 1.0)) {
                progress(fraction)
            }
        }

        guard result.succeeded else {
            try? FileManager.default.removeItem(at: job.outputURL)
            throw ProcessError.failed(code: result.exitCode, stderr: result.stderr)
        }
        // A zero exit code is not proof the encode worked. Verified: a misnamed AAC file
        // under the concat demuxer — which forces the first input's format onto every
        // input — printed 262 lines of decoder errors, exited 0, and wrote an .m4b with
        // an entire file's audio missing, 3.04 s where 6 s was expected. Believing the
        // exit code there means writing a file that is wrong and calling it done.
        //
        // So ask stderr as well, and let a genuine failure take the failure path: the
        // half-right output is deleted, and `failureLog` puts ffmpeg's own words in the
        // book's log where the user can read them.
        if let evidence = FFmpegStderr.failureEvidence(in: result.stderr,
                                                       inputFiles: job.tracks.count) {
            try? FileManager.default.removeItem(at: job.outputURL)
            // One trailing line, so `failureSummary` — which takes the last non-empty
            // line — leads with the verdict rather than with the last of hundreds of
            // identical decoder complaints.
            throw ProcessError.failed(
                code: result.exitCode,
                stderr: result.stderr + "\n\nStopped because the decode failed: " + evidence)
        }
        progress(1.0)
        return job.outputURL
    }

    /// Pulls the attached picture out of an MP3 into `folder`, returning nil when the
    /// file carries none. The codec varies by source — some books embed png, most
    /// embed mjpeg — so the extension follows `embeddedArtCodec`.
    func extractEmbeddedArt(from track: TrackInfo, into folder: URL) async -> URL? {
        guard let codec = track.embeddedArtCodec else { return nil }
        let ext = (codec == "png") ? "png" : "jpg"
        let output = folder.appendingPathComponent("embedded-cover.\(ext)")
        let result = try? await runner.run(tools.ffmpeg, [
            "-hide_banner", "-v", "error", "-y",
            "-i", track.url.path, "-map", "0:v:0", "-c", "copy", output.path,
        ])
        guard result?.succeeded == true,
              FileManager.default.fileExists(atPath: output.path) else { return nil }
        return output
    }
}
