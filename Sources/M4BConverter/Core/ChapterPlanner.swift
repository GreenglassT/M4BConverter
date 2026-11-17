import Foundation

public enum ChapterPlanner {
    public static func plan(tracks: [TrackInfo],
                            durations: [Double],
                            strategy: ChapterStrategy) -> [Chapter] {
        precondition(tracks.count == durations.count, "durations must parallel tracks")
        let total = durations.reduce(0, +)
        // Compiled once, not once per track: `plan` runs on every `recompute()`.
        let patternRegex: NSRegularExpression? = {
            guard case .filenamePattern(let pattern) = strategy else { return nil }
            return try? NSRegularExpression(pattern: pattern)
        }()

        var starts: [(Double, String)] = []
        var offset = 0.0
        for (track, duration) in zip(tracks, durations) {
            switch strategy {
            case .overdriveMarkers:
                let raw = track.tags[OverDriveMarkers.tagKey] ?? ""
                for marker in OverDriveMarkers.parse(raw) where marker.seconds < duration {
                    starts.append((offset + marker.seconds, marker.title))
                }
            case .fileBoundaries:
                // A zero-length file contributes no chapter. Emitting one would tie
                // with the following file's offset and, via the strictly-increasing
                // filter below, silently drop that file's chapter instead.
                if duration > 0 {
                    starts.append((offset, nonEmpty(track.tags["title"])
                                        ?? track.url.deletingPathExtension().lastPathComponent))
                }
            case .filenamePattern:
                if duration > 0 {
                    starts.append((offset, patternRegex.flatMap { capturedTitle(track, regex: $0) }
                                        ?? track.url.deletingPathExtension().lastPathComponent))
                }
            }
            offset += duration
        }

        // Strictly increasing ON THE MILLISECOND GRID the file is written on, which is
        // `ChapterEditor`'s rule rather than a comparison of Doubles.
        //
        // `FFMetadataWriter` renders `TIMEBASE=1/1000`, so two starts a fraction of a
        // millisecond apart are ONE number once written. Comparing the Doubles let both
        // through — two OverDrive markers at 10.0000 and 10.0004, or a file shorter than a
        // millisecond — ffmpeg wrote START=10000 twice and exited 0, and `OutputVerifier`
        // asks this same millisecond question of the finished file: it called that pair
        // non-ascending, which is fatal, and the queue deleted hours of finished encoding.
        // The editor refuses such a boundary while the user is still typing; the generator
        // that produces most lists has to refuse it too, by the same rule and not a second
        // copy of it.
        var cleaned: [(Double, String)] = []
        for entry in starts {
            if let last = cleaned.last,
               !ChapterEditor.startsStrictlyAscend([last.0, entry.0]) { continue }
            cleaned.append(entry)
        }

        return cleaned.enumerated().map { index, entry in
            Chapter(start: entry.0,
                    end: index + 1 < cleaned.count ? cleaned[index + 1].0 : total,
                    title: entry.1)
        }
    }

    /// Capture group 1 of `regex` against the track's filename, trimmed — or nil when the
    /// pattern does not match, when group 1 did not participate, or when what it captured
    /// is blank. Both callers need exactly this answer: one to title a chapter, the other
    /// to decide whether the pattern would title all of them.
    ///
    /// An alternation like `(?:(a+)|b+)` can match without group 1 participating; its
    /// range is then {NSNotFound, 0} and `substring(with:)` would throw.
    static func capturedTitle(_ track: TrackInfo, regex: NSRegularExpression) -> String? {
        let name = track.filename
        let ns = name as NSString
        guard let match = regex.firstMatch(in: name,
                                           range: NSRange(location: 0, length: ns.length)),
              match.numberOfRanges > 1 else { return nil }
        let range = match.range(at: 1)
        guard range.location != NSNotFound else { return nil }
        let captured = ns.substring(with: range).trimmingCharacters(in: .whitespaces)
        return captured.isEmpty ? nil : captured
    }

    /// True when every track's filename yields a non-empty capture group 1, so a pattern
    /// that matches while capturing nothing is rejected rather than producing blank
    /// chapter titles.
    public static func patternMatchesAll(_ tracks: [TrackInfo], pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern), !tracks.isEmpty else {
            return false
        }
        return tracks.allSatisfy { capturedTitle($0, regex: regex) != nil }
    }
}
