import Foundation

public enum ProbeError: Error, LocalizedError {
    case noAudioStream(URL)
    case badJSON(URL)

    public var errorDescription: String? {
        switch self {
        case .noAudioStream(let url): return "No audio stream in \(url.lastPathComponent)"
        case .badJSON(let url): return "Could not read media info for \(url.lastPathComponent)"
        }
    }
}

public struct MediaProbe: Sendable {
    let tools: FFmpegTools
    let runner: ProcessRunner

    public init(tools: FFmpegTools, runner: ProcessRunner = ProcessRunner()) {
        self.tools = tools
        self.runner = runner
    }

    public func probe(_ url: URL) async throws -> TrackInfo {
        let result = try await runner.run(tools.ffprobe, [
            "-v", "error", "-show_format", "-show_streams", "-of", "json", url.path,
        ])
        guard result.succeeded else {
            throw ProcessError.failed(code: result.exitCode, stderr: result.stderr)
        }
        return try MediaProbe.parse(json: Data(result.stdout.utf8), url: url)
    }

    public static func parse(json: Data, url: URL) throws -> TrackInfo {
        guard let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw ProbeError.badJSON(url)
        }
        let streams = root["streams"] as? [[String: Any]] ?? []
        let format = root["format"] as? [String: Any] ?? [:]

        guard let audio = streams.first(where: { $0["codec_type"] as? String == "audio" }) else {
            throw ProbeError.noAudioStream(url)
        }

        func int(_ any: Any?) -> Int? {
            if let n = any as? Int { return n }
            if let s = any as? String { return Int(s) }
            // Int(d) traps on NaN, infinity, or anything beyond Int's range, and
            // JSON permits all three (1e20 parses fine; -1e400 becomes -inf).
            if let d = any as? Double, d.isFinite { return Int(exactly: d.rounded()) }
            return nil
        }
        func double(_ any: Any?) -> Double? {
            // Same finiteness rule as `int()` above, and for the same reason: JSON permits
            // infinity ("-1e400" parses straight to -inf) and ffprobe can emit "inf" or
            // "nan" as text. A non-finite duration reaches `Int(seconds)` in formatHours,
            // `Int64(...)` in Preflight and `Int(...)` in FFMetadataWriter, every one of
            // which traps — so the app dies on a file that merely probed strangely.
            if let d = any as? Double { return d.isFinite ? d : nil }
            if let s = any as? String { return Double(s).flatMap { $0.isFinite ? $0 : nil } }
            if let n = any as? Int { return Double(n) }
            return nil
        }

        // ffprobe can emit two keys that collide once lowercased — a standard frame
        // (reported lowercase, e.g. "title") alongside a custom TXXX frame whose
        // description is "TITLE". Iterating the dictionary directly would let Swift's
        // randomized ordering decide the winner, so the same file could yield a
        // different title on different runs. Sort for determinism, and let the
        // canonical already-lowercase key win.
        var tags: [String: String] = [:]
        let rawTags = format["tags"] as? [String: Any] ?? [:]
        for key in rawTags.keys.sorted() {
            let lowered = key.lowercased()
            let isCanonical = (key == lowered)
            guard isCanonical || tags[lowered] == nil else { continue }
            tags[lowered] = String(describing: rawTags[key]!)
        }

        let art = streams.first { $0["codec_type"] as? String == "video" }

        return TrackInfo(
            url: url,
            estimatedDuration: double(format["duration"]) ?? 0,
            codecName: audio["codec_name"] as? String ?? "unknown",
            sampleRate: int(audio["sample_rate"]) ?? 44100,
            channels: int(audio["channels"]) ?? 2,
            bitRate: int(audio["bit_rate"]) ?? int(format["bit_rate"]) ?? 64000,
            tags: tags,
            embeddedArtCodec: art?["codec_name"] as? String
        )
    }
}
