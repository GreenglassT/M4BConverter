import Foundation

/// Why an edit was refused, in the words the inspector shows.
///
/// Every one of these is a state the encoder must never be handed rather than a matter of
/// taste: `OutputVerifier` fails a finished .m4b whose chapter starts do not strictly
/// ascend, and it does so AFTER the encode — so a gap or an overlap accepted here costs
/// the user the whole conversion. The refusal happens while they are still typing instead.
public enum ChapterEditError: Error, Equatable, LocalizedError {
    case noSuchChapter
    case emptyTitle
    case unreadableTime(String)
    case boundaryOutsideNeighbours(after: Double, before: Double)
    case splitOutsideChapter(after: Double, before: Double)
    case nothingToMergeWith
    case bookIsConverting
    case sourceReclaimed
    case bookIsFinished
    case chapterStartsPastTheAudio(start: Double, total: Double)

    /// The same sentence wherever the error is rendered. `fitted` throws one of these from
    /// inside a conversion, where `ConversionQueue` reports `localizedDescription` — without
    /// this the user would get "The operation couldn't be completed. (error 9.)" for a
    /// refusal that has a perfectly good explanation.
    public var errorDescription: String? { message }

    public var message: String {
        switch self {
        case .noSuchChapter:
            return "That chapter is not there any more."
        case .emptyTitle:
            return "A chapter needs a title."
        case .unreadableTime(let text):
            return "\"\(text)\" is not a time. Write it as h:mm:ss — 1:04:30, "
                 + "or 1:04:30.500 for part of a second."
        case .boundaryOutsideNeighbours(let after, let before):
            return "A chapter boundary has to fall between \(Timecode.format(after)) "
                 + "and \(Timecode.format(before)), which is where the chapters on "
                 + "either side of it begin and end."
        case .splitOutsideChapter(let after, let before):
            return "A split has to fall inside the chapter, between "
                 + "\(Timecode.format(after)) and \(Timecode.format(before))."
        case .nothingToMergeWith:
            return "The last chapter has nothing after it to merge with."
        case .bookIsConverting:
            return "This book is being converted right now. Its chapters were read at the "
                 + "start of the run and are already written into the file being made, so "
                 + "they cannot be changed until it finishes."
        case .sourceReclaimed:
            return "This book's source MP3s are in the Trash, so it will not be converted "
                 + "again and its chapters are only a record of the file that was made. "
                 + "Put the folder back and drop it on the window to work on it again."
        case .bookIsFinished:
            return "This book's run is over, so its chapters no longer decide anything. A "
                 + "verified book's list is a record of the .m4b that was written rather "
                 + "than a plan for one, and a failed book's is the list that run used — "
                 + "Retry puts it back in the queue, and then it can be edited again."
        case .chapterStartsPastTheAudio(let start, let total):
            return "A chapter starts at \(Timecode.format(start)), but this book decodes "
                 + "to \(Timecode.format(total)) — so that chapter would describe audio "
                 + "that is not there. The times were typed against the lengths the files "
                 + "claim; the conversion measures them by decoding. Move that boundary "
                 + "earlier, or revert to automatic chapters, and convert again."
        }
    }
}

/// Edits to a chapter list, as pure functions over the list.
///
/// The list is a chain, not a set of independent rows: chapter N's `end` IS chapter N+1's
/// `start`, the first chapter starts where the audio does and the last ends where it stops.
/// Every function here either returns a list that still satisfies all of that — contiguous,
/// strictly ascending, covering the same span — or throws and changes nothing. That is why
/// the UI edits *boundaries* rather than the two times either side of one: a table that let
/// `start` and `end` be typed independently could produce a gap or an overlap, and there is
/// no honest thing for the encoder to do with either.
public enum ChapterEditor {
    /// A title as it will be stored: one line, trimmed, and not empty.
    ///
    /// `FFMetadataWriter` escapes newlines and carriage returns correctly, so a multi-line
    /// title is not a corruption risk — it is simply not something anyone means to create,
    /// and it is exactly what pasting from a web page or a PDF produces. Flattened to one
    /// line with the words kept apart rather than run together.
    public static func cleanedTitle(_ raw: String) throws -> String {
        let title = raw.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !title.isEmpty else { throw ChapterEditError.emptyTitle }
        return title
    }

    public static func retitled(_ chapters: [Chapter], at index: Int,
                                to raw: String) throws -> [Chapter] {
        guard chapters.indices.contains(index) else { throw ChapterEditError.noSuchChapter }
        var edited = chapters
        edited[index].title = try cleanedTitle(raw)
        return edited
    }

    /// Moves the boundary between chapter `index` and chapter `index + 1` to `time`,
    /// setting both sides of it at once.
    ///
    /// Only a boundary BETWEEN two chapters can move. The first chapter's start and the
    /// last chapter's end are the ends of the audio itself; moving either would describe
    /// a book of a different length from the one being encoded.
    public static func boundaryMoved(_ chapters: [Chapter], after index: Int,
                                     to time: Double) throws -> [Chapter] {
        guard chapters.indices.contains(index), chapters.indices.contains(index + 1) else {
            throw ChapterEditError.noSuchChapter
        }
        let lower = chapters[index].start
        let upper = chapters[index + 1].end
        guard isStrictlyBetween(time, lower, upper) else {
            throw ChapterEditError.boundaryOutsideNeighbours(after: lower, before: upper)
        }
        var edited = chapters
        edited[index].end = time
        edited[index + 1].start = time
        return edited
    }

    /// Chapter `index` absorbs the one after it, keeping its own title.
    ///
    /// Keeping the first title is not arbitrary: merging is how a user folds "Chapter 12"
    /// and "Chapter 12 (continued)" back into one, and the name they want is the one at
    /// the top of the pair.
    public static func merged(_ chapters: [Chapter], at index: Int) throws -> [Chapter] {
        guard chapters.indices.contains(index) else { throw ChapterEditError.noSuchChapter }
        guard chapters.indices.contains(index + 1) else {
            throw ChapterEditError.nothingToMergeWith
        }
        var edited = chapters
        edited[index].end = edited[index + 1].end
        edited.remove(at: index + 1)
        return edited
    }

    /// Splits chapter `index` at `time`, into `start…time` and `time…end`.
    ///
    /// The second half needs a name — an empty title is refused everywhere else, so it
    /// cannot be left blank here — and is given the first's with a "(2)" so the two are
    /// tellable apart in a 190-row table. Renaming it is one field away.
    public static func split(_ chapters: [Chapter], at index: Int,
                             atTime time: Double) throws -> [Chapter] {
        guard chapters.indices.contains(index) else { throw ChapterEditError.noSuchChapter }
        let chapter = chapters[index]
        guard isStrictlyBetween(time, chapter.start, chapter.end) else {
            throw ChapterEditError.splitOutsideChapter(after: chapter.start,
                                                       before: chapter.end)
        }
        var edited = chapters
        edited[index].end = time
        edited.insert(Chapter(start: time, end: chapter.end,
                              title: "\(chapter.title) (2)"), at: index + 1)
        return edited
    }

    /// Strictly between, measured on the grid the .m4b is written on.
    ///
    /// `FFMetadataWriter` renders `TIMEBASE=1/1000` and rounds every time to a whole
    /// millisecond, so two times a fraction of one apart become the SAME number in the
    /// file. A boundary typed 0.4 ms after a chapter that starts at 600.4408 s is
    /// genuinely between its neighbours as a `Double` and lands on top of one of them as
    /// written — and `OutputVerifier` fails a finished file whose chapter starts do not
    /// strictly increase, which it can only discover after the encode. Comparing on the
    /// doubles would leave that door open; comparing here closes it while the user is
    /// still typing.
    private static func isStrictlyBetween(_ time: Double,
                                          _ lower: Double, _ upper: Double) -> Bool {
        let written = writtenMilliseconds(time)
        return writtenMilliseconds(lower) < written && written < writtenMilliseconds(upper)
    }

    /// Whether a list of chapter starts strictly ascends *as written*, by the same rule.
    ///
    /// This is what a finished file has to satisfy, and it is asked in two places: of the
    /// .m4b this app just made (`OutputVerifier`) and of one it did not (`M4BFacts`, for
    /// the existing-books check). Both ask it of the millisecond grid rather than of the
    /// Doubles, because that is the grid the file carries — two starts 0.4 ms apart are one
    /// number once written, and a player given two chapters at the same mark has no way to
    /// order them. Comparing Doubles would call that pair ascending and let it through.
    public static func startsStrictlyAscend(_ starts: [Double]) -> Bool {
        zip(starts, starts.dropFirst()).allSatisfy {
            writtenMilliseconds($0) < writtenMilliseconds($1)
        }
    }

    private static func writtenMilliseconds(_ seconds: Double) -> Int64 {
        guard seconds.isFinite else { return 0 }
        return Int64((seconds * 1000).rounded())
    }

    /// The user's list against the length the conversion actually measured, or a refusal.
    ///
    /// The times were typed against the durations ffprobe read from the containers at scan
    /// time; the encode uses the durations ffmpeg measured by decoding, which differ. Only
    /// the final `end` is adjusted, and only to the end of the audio: a last chapter
    /// stopping short leaves the tail of the book outside every chapter, and one running
    /// past the end claims audio that is not there. Nothing the user set — no start, no
    /// boundary, no title — is touched.
    ///
    /// And when the measured audio stops at or before a boundary the user set, there is no
    /// honest fit to make, so this THROWS. It used to return the list unchanged, which is
    /// precisely the "claims audio that is not there" case above: only the final `end` is
    /// ever adjusted, so every boundary past the measured total was written exactly as
    /// typed. Nothing downstream catches that — the starts still ascend, the count still
    /// matches, and `OutputVerifier` compares the file's duration against the same measured
    /// total rather than against the chapter span — so the book verified clean while its
    /// last chapters pointed past the end of its audio. Refusing costs a named failure
    /// before a frame is encoded.
    ///
    /// Compared on the millisecond grid, like everything else here: a total 0.4 ms past the
    /// last chapter's start is the same millisecond once written, and fitting to it would
    /// render `START == END` for the final chapter.
    public static func fitted(_ chapters: [Chapter], toTotal total: Double) throws -> [Chapter] {
        guard !chapters.isEmpty else { return chapters }
        // Every start, not just the last one: a list is only ever handed here contiguous
        // and ascending, but this asks the question the file will be asked rather than
        // trusting that, and it names the first boundary the audio does not reach.
        if let past = chapters.first(where: { !startsStrictlyAscend([$0.start, total]) }) {
            throw ChapterEditError.chapterStartsPastTheAudio(start: past.start, total: total)
        }
        var edited = chapters
        edited[edited.count - 1].end = total
        return edited
    }
}
