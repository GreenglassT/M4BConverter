import Foundation

public struct InferenceResult: Sendable, Equatable {
    public var order: OrderStrategy
    /// How to produce chapters, not the chapters themselves. `Book.chapters` and
    /// `ConversionJob.chapters` are `[Chapter]`; this used to share their name.
    public var chapterStrategy: ChapterStrategy
    public var title: String
    public var author: String
    public var year: String
    public var warnings: [String]
}

public enum Inference {
    public static func infer(_ tracks: [TrackInfo]) -> InferenceResult {
        var warnings: [String] = []

        let byName = TrackOrderer.order(tracks, by: .filename)
        // Track tags are only usable as an ordering when every file has one AND the
        // numbers are distinct. A rip tagged `track=1` on every file satisfies
        // "everything is tagged" while carrying no ordering information at all, and
        // would otherwise fall through to directory-scan order while claiming the
        // tags disagreed with the filenames.
        let numbers = tracks.compactMap { TrackOrderer.trackNumber($0) }
        let tagsUsable = numbers.count == tracks.count && Set(numbers).count == tracks.count
        var order: OrderStrategy = .filename

        if tagsUsable {
            let byTag = TrackOrderer.order(tracks, by: .trackTag)
            if byTag.map(\.filename) != byName.map(\.filename) {
                order = .trackTag
                warnings.append("Filename order and track-tag order disagree; using track tags.")
            }
        }

        let ordered = TrackOrderer.order(tracks, by: order)
        let chapterStrategy: ChapterStrategy
        if ordered.contains(where: { ($0.tags[OverDriveMarkers.tagKey]?.isEmpty == false) }) {
            chapterStrategy = .overdriveMarkers
        } else if ChapterPlanner.patternMatchesAll(ordered,
                                                   pattern: ChapterStrategy.defaultFilenamePattern) {
            chapterStrategy = .filenamePattern(ChapterStrategy.defaultFilenamePattern)
        } else {
            chapterStrategy = .fileBoundaries
        }

        let first = ordered.first
        let rates = Set(ordered.map(\.sampleRate))
        if rates.count > 1 {
            warnings.append("Files have mixed sample rates (\(rates.sorted().map(String.init).joined(separator: ", "))).")
        }

        return InferenceResult(
            order: order,
            chapterStrategy: chapterStrategy,
            title: nonEmpty(first?.tags["album"])
                ?? nonEmpty(first?.url.deletingLastPathComponent().lastPathComponent)
                ?? "Untitled",
            author: nonEmpty(first?.tags["artist"]) ?? nonEmpty(first?.tags["album_artist"]) ?? "",
            year: String((nonEmpty(first?.tags["date"]) ?? "").prefix(4)),
            warnings: warnings
        )
    }
}

/// Trimmed, or nil when the value is missing or blank — so a fallback chain still runs
/// past a present-but-empty tag, which ID3 writers commonly emit rather than omitting
/// the frame. At module scope because `ChapterPlanner` needs the same rule for its
/// chapter titles, and it should not have to depend on `Inference` to get it.
func nonEmpty(_ value: String?) -> String? {
    guard let trimmed = value?.trimmingCharacters(in: .whitespaces),
          !trimmed.isEmpty else { return nil }
    return trimmed
}
