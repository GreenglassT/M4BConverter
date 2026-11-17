import Foundation
@testable import M4BConverter

enum Fixtures {
    static var tools: FFmpegTools? { FFmpegLocator.locate(override: nil) }
    static var ffmpegAvailable: Bool { tools != nil }

    static func temporaryDirectory() throws -> URL {
        sweepStaleDirectories()
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("m4b-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Cleanup is each test's own business, and several of the cancellation tests return
    /// early without doing it — 132 empty `m4b-test-*` directories had piled up in a single
    /// day of runs. Rather than add a `defer` to every call site and depend on the next one
    /// remembering, each new directory takes the stale ones with it.
    ///
    /// An hour old, so a directory belonging to a suite running right now is never pulled
    /// out from under it: tests run concurrently and the slowest of them waits on a
    /// `sleep 30` fake tool.
    private static func sweepStaleDirectories() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let cutoff = Date().addingTimeInterval(-3600)
        let contents = try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.contentModificationDateKey])
        for url in contents ?? [] where url.lastPathComponent.hasPrefix("m4b-test-") {
            let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            if let modified, modified < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Runs the located ffmpeg to produce `output`, which every builder below passes as
    /// the last argument, and throws ffmpeg's own stderr when it will not.
    ///
    /// The shared shape of all of them: no ffmpeg means no fixture, and a non-zero exit
    /// means the file a test is about to assert on is not there — so failing here, with
    /// what ffmpeg said, beats failing later on a missing file.
    @discardableResult
    private static func produce(_ output: URL, _ arguments: [String]) async throws -> URL {
        guard let tools else { throw ProbeError.badJSON(output.deletingLastPathComponent()) }
        let result = try await ProcessRunner().run(tools.ffmpeg, arguments + [output.path])
        guard result.succeeded else {
            throw ProcessError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return output
    }

    /// Writes a real MP3 of `seconds` length carrying the given ID3 tags.
    @discardableResult
    static func makeMP3(in folder: URL, named name: String, seconds: Double,
                        tags: [String: String] = [:]) async throws -> URL {
        var arguments = [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:a", "libmp3lame", "-b:a", "64k", "-ar", "44100", "-ac", "2",
        ]
        for (key, value) in tags.sorted(by: { $0.key < $1.key }) {
            arguments += ["-metadata", "\(key)=\(value)"]
        }
        return try await produce(folder.appendingPathComponent(name), arguments)
    }

    /// A CBR MP3 with a span of its bytes in the middle overwritten with zeroes — a bad
    /// download, a failing disk, an interrupted copy.
    ///
    /// The point of this fixture is how QUIET the result is. The container header is
    /// untouched, so ffprobe still reports the full length; ffmpeg resynchronises after
    /// the dead span, decodes the rest, exits 0, and says exactly two things on stderr —
    /// the same two things a perfectly good MP3 with a trailing ID3v1 tag says. Only the
    /// decoded length gives it away.
    @discardableResult
    static func makeLossyMP3(in folder: URL, named name: String, seconds: Double,
                             zeroedFraction: Double = 0.10,
                             tags: [String: String] = [:]) async throws -> URL {
        let url = try await makeMP3(in: folder, named: name, seconds: seconds, tags: tags)
        // Well past the Xing/LAME header at the front, so the container's claim survives.
        try zeroBytes(in: url, fraction: zeroedFraction, startingAtFraction: 0.45)
        return url
    }

    /// Overwrites a span in the middle of a file with zeroes, leaving its length and its
    /// header alone — a bad download, a failing disk, an interrupted copy.
    static func zeroBytes(in url: URL, fraction: Double,
                          startingAtFraction: Double) throws {
        let size = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(Double(size) * startingAtFraction))
        try handle.write(contentsOf: Data(repeating: 0,
                                          count: Int(Double(size) * fraction)))
        try handle.synchronize()
    }

    /// Chops the tail off a file.
    ///
    /// For an `.m4b` written with `+faststart` this is the quietly-lossy case in its purest
    /// form: the moov atom sits at the FRONT and still claims the original duration, while
    /// the audio it describes is simply not there any more. ffprobe reports the full
    /// length; only decoding shows what is missing.
    static func truncate(_ url: URL, toFraction fraction: Double) throws {
        let size = (try FileManager.default
            .attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(Double(size) * fraction))
        try handle.synchronize()
    }

    /// A real `.m4b`: `seconds` of audio, `chapters` evenly spaced chapters, and the cover
    /// and `media_type` tag optional — the file the app itself writes, minus the
    /// AudioToolbox encoder, which is not needed to make one that ffprobe reads the same
    /// way. `+faststart` matches `FFmpegBackend` and is what lets `truncate` above produce
    /// a container that outlives its audio.
    @discardableResult
    static func makeM4B(in folder: URL, named name: String, seconds: Double,
                        chapters: Int = 2, cover: Bool = true,
                        audiobook: Bool = true) async throws -> URL {
        var arguments = [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
        ]
        var maps = ["-map", "0:a:0"]
        var inputIndex = 1
        // Removed after ffmpeg has read them, not at the end of the branch that made them.
        var scratch: [URL] = []
        defer { for url in scratch { try? FileManager.default.removeItem(at: url) } }

        if chapters > 0 || audiobook {
            let step = seconds / Double(max(chapters, 1))
            let list = (0..<chapters).map {
                Chapter(start: Double($0) * step, end: Double($0 + 1) * step,
                        title: "Chapter \($0 + 1)")
            }
            let metadata = folder.appendingPathComponent("meta-\(UUID().uuidString).txt")
            scratch.append(metadata)
            try FFMetadataWriter
                .render(metadata: audiobook ? ["media_type": "2"] : [:], chapters: list)
                .write(to: metadata, atomically: true, encoding: .utf8)
            arguments += ["-i", metadata.path]
            maps += ["-map_metadata", "\(inputIndex)", "-map_chapters", "\(inputIndex)"]
            inputIndex += 1
        }
        if cover {
            let art = try await makeCover(in: folder, named: "art-\(UUID().uuidString).jpg")
            scratch.append(art)
            arguments += ["-i", art.path]
            maps += ["-map", "\(inputIndex):v:0", "-c:v", "mjpeg",
                     "-disposition:v:0", "attached_pic"]
        }

        return try await produce(folder.appendingPathComponent(name), arguments + maps + [
            "-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "2",
            "-movflags", "+faststart", "-f", "mp4",
        ])
    }

    /// An `.m4b` with no audio in it at all — a video file under an audiobook's name, which
    /// is the shape of the mistake this catches: a download that fetched the wrong thing.
    @discardableResult
    static func makeVideoOnlyMP4(in folder: URL, named name: String) async throws -> URL {
        try await produce(folder.appendingPathComponent(name), [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=blue:s=64x64:d=2:r=10",
            "-c:v", "mpeg4", "-movflags", "+faststart", "-f", "mp4",
        ])
    }

    /// An MP3 carrying embedded cover art, like real books that have
    /// no separate cover image on disk.
    @discardableResult
    static func makeMP3WithEmbeddedArt(in folder: URL, named name: String,
                                       seconds: Double) async throws -> URL {
        let source = try await makeCover(in: folder, named: "art-source-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: source) }
        return try await produce(folder.appendingPathComponent(name), [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-i", source.path,
            "-map", "0:a", "-map", "1:v",
            "-c:a", "libmp3lame", "-b:a", "64k", "-ar", "44100", "-ac", "2",
            "-c:v", "mjpeg", "-id3v2_version", "3",
            "-metadata:s:v", "title=Album cover", "-disposition:v", "attached_pic",
        ])
    }

    /// A real AAC file under a `.mp3` name — how the case actually arises, from a rip or
    /// a batch conversion that renamed rather than re-encoded. ffprobe reports its
    /// `codec_name` as "aac" (verified against ffmpeg 8.1), and the file decodes
    /// perfectly well on its own, which is exactly why nothing downstream noticed.
    @discardableResult
    static func makeAACNamedMP3(in folder: URL, named name: String,
                                seconds: Double) async throws -> URL {
        // Encode into a correctly named container first: `-c:a aac` into a `.mp3` path
        // would leave ffmpeg to pick a muxer from the extension and fail.
        let source = folder.appendingPathComponent("aac-source-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: source) }
        try await produce(source, [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(seconds)",
            "-c:a", "aac", "-b:a", "64k", "-ar", "44100", "-ac", "2",
        ])
        let output = folder.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.copyItem(at: source, to: output)
        return output
    }

    /// A small JPEG usable as cover art.
    @discardableResult
    static func makeCover(in folder: URL, named name: String = "cover.jpg") async throws -> URL {
        try await produce(folder.appendingPathComponent(name), [
            "-hide_banner", "-v", "error", "-y",
            "-f", "lavfi", "-i", "color=c=red:s=64x64:d=1", "-frames:v", "1",
        ])
    }

    /// The tracks for `names` in `folder`, probed one at a time and returned in that
    /// order — the array order is what `TrackOrderer` breaks ties on, so a test that
    /// wants a book in a known order has to build it in one.
    static func probeTracks(in folder: URL, named names: [String]) async throws -> [TrackInfo] {
        guard let tools else { throw ProbeError.badJSON(folder) }
        let probe = MediaProbe(tools: tools)
        var tracks: [TrackInfo] = []
        for name in names {
            tracks.append(try await probe.probe(folder.appendingPathComponent(name)))
        }
        return tracks
    }

    /// A book of two real one-second MP3s in `root/name`, tagged with `album` (the folder
    /// name unless given), so its canonical output is `<destination>/<album>.m4b`.
    ///
    /// Two files rather than one because that is what makes a conversion realistic: the
    /// concat list, the chapter plan and the duration sum all have something to get wrong.
    @MainActor
    static func makeBook(named name: String, in root: URL, album: String? = nil,
                         destination: OutputDestination = .besideSource) async throws -> Book {
        let album = album ?? name
        let folder = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let names = ["01.mp3", "02.mp3"]
        for file in names {
            try await makeMP3(in: folder, named: file, seconds: 1, tags: ["album": album])
        }
        return Book(folder: folder,
                    tracks: try await probeTracks(in: folder, named: names),
                    defaultDestination: destination)
    }

    /// ffprobe-shaped output for a file that really is `duration` long and really does
    /// carry `chapterCount` evenly spaced chapters — with the cover and the audiobook flag
    /// optional, since `OutputVerifier` treats those two as cosmetic and the rest as fatal.
    ///
    /// Shared rather than private to one test file: every test that drives the queue
    /// through fake tools to a `.verified` book needs a verifier that agrees with the book
    /// it was given, and a second copy of this would be a second place for the JSON shape
    /// to drift away from what `OutputVerifier.parse` actually reads.
    static func verifierJSON(chapterCount: Int, duration: Double,
                             cover: Bool, audiobook: Bool) -> String {
        let step = duration / Double(max(chapterCount, 1))
        let chapters = (0..<chapterCount).map { index in
            """
            {"start_time":"\(Double(index) * step)","end_time":"\(Double(index + 1) * step)",\
            "tags":{"title":"Chapter \(index + 1)"}}
            """
        }
        var streams = [#"{"codec_type":"audio","codec_name":"aac"}"#]
        if cover {
            streams.append(
                #"{"codec_type":"video","codec_name":"mjpeg","disposition":{"attached_pic":1}}"#)
        }
        return """
        {"chapters":[\(chapters.joined(separator: ","))],
         "streams":[\(streams.joined(separator: ","))],
         "format":{"duration":"\(duration)",
                   "tags":\(audiobook ? #"{"media_type":"2"}"# : "{}")}}
        """
    }

    /// A shell script standing in for ffmpeg AND ffprobe, so a test can drive the whole
    /// pipeline without the real tools and can make one step fail on demand.
    ///
    /// One script in both slots: every caller tells the steps apart by the arguments they
    /// were given (`-f null` to measure, `-progress` to encode, `-show_chapters` to
    /// verify), which is also the only thing the pipeline itself guarantees about them.
    @discardableResult
    static func fakeTools(_ script: String, in directory: URL) throws -> FFmpegTools {
        let exe = directory.appendingPathComponent("ffmpeg")
        try ("#!/bin/sh\n" + script).write(to: exe, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: exe.path)
        return FFmpegTools(ffmpeg: exe, ffprobe: exe)
    }

    /// The same, in a temporary directory of its own — handed back so the caller can
    /// delete it, and because these tests put their books and outputs beside the script.
    static func fakeTools(_ script: String) throws -> (tools: FFmpegTools, directory: URL) {
        let directory = try temporaryDirectory()
        return (try fakeTools(script, in: directory), directory)
    }
}
