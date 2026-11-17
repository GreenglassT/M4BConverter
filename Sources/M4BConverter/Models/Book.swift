import Foundation
import Observation

public enum BookStatus: Sendable, Equatable {
    case ready
    case warning
    case converting
    case verified
    /// Converted, verified, and its source MP3s sent to the Trash by the user.
    ///
    /// A state of its own rather than a flag beside `.verified`, because everything the app
    /// offers a book is decided from the status: this one has no audio on disk any more, so
    /// it must never be picked up by a run, offered a Retry, or given settings that describe
    /// a conversion that can no longer happen. Terminal for exactly that reason.
    case reclaimed
    case failed(String)

    public var isTerminal: Bool {
        switch self {
        case .verified, .reclaimed, .failed: return true
        default: return false
        }
    }
}

/// What a successful run actually wrote: the file, the number of chapters it put in it, and
/// the length it measured by decoding the sources.
///
/// The three are recorded together because all three are evidence, and the reclaim re-checks
/// the .m4b against them hours or days later. Two of them used to be read off the live `Book`
/// instead — `chapters.count` and a duration derived from the same list — and both of those
/// move after a conversion: a chapter source can be assigned, and until the guard in
/// `acceptsEdits` was widened the list could be merged, split or retitled as well. That made
/// the re-check blame the file for a list the app itself had changed ("…no longer matches
/// this book: Expected 2 chapters, found 3", about a file carrying exactly what it was
/// given), and it let the reverse through unnoticed. The evidence for sending someone's MP3s
/// to the Trash has to be what the run did, not what the window says now.
public struct WrittenOutput: Sendable, Equatable {
    /// The file this run wrote. `Book.outputURL` is only the name the book would LIKE to
    /// have — a `.keepBoth` run writes "Title 2.m4b", a `.replace` run swaps onto the
    /// original — so this is the path to go looking for and the path to re-check.
    public var url: URL
    /// How many chapters were written into it.
    public var chapterCount: Int
    /// The total the run MEASURED by decoding every source file — the same number
    /// `OutputVerifier` checked the finished file against when the run ended, and therefore
    /// the only one the same check can be repeated with.
    public var duration: Double

    public init(url: URL, chapterCount: Int, duration: Double) {
        self.url = url
        self.chapterCount = chapterCount
        self.duration = duration
    }
}

@Observable
@MainActor
public final class Book: Identifiable {
    public let id = UUID()
    public let folder: URL
    /// The three inputs `recompute()` derives everything from. Each rebuilds the derived
    /// state on assignment, so the cache below cannot go stale: the invariant used to be
    /// a doc comment asking callers to remember, and forgetting silently produced a book
    /// converted in one order and chaptered in another. `didSet` does not fire for the
    /// assignments in `init`, which ends with its own `recompute()`.
    public var tracks: [TrackInfo] { didSet { recompute() } }
    public var order: OrderStrategy { didSet { recompute() } }
    public var chapterStrategy: ChapterStrategy { didSet { recompute() } }
    public var title: String
    public var author: String
    public var year: String
    public var coverImage: URL?
    public private(set) var warnings: [String]
    public var notes: [String] = []
    /// What the last successful run wrote, and what it wrote into it. Nil until a run
    /// succeeds; cleared by everything that invalidates it — the start of the next run, and
    /// `retry()`.
    ///
    /// One property rather than three, so the file and the evidence about it cannot be
    /// cleared separately or fall out of step: `SourceReclaimer` re-checks the .m4b against
    /// the count and the duration recorded here, and a stale one of those is exactly how a
    /// reclaim ends up asking the wrong question of the right file.
    public var written: WrittenOutput?

    /// The file the last successful run actually wrote. `outputURL` is only the name
    /// this book would like to have — a `.keepBoth` run writes "Title 2.m4b" instead —
    /// so the inspector must report this one when it is set.
    public var writtenURL: URL? { written?.url }
    /// The app-wide save location, pushed down by `AppModel` — every book carries its own
    /// copy so `outputURL` stays a pure computed property with nothing to look up.
    /// `AppModel` re-pushes it to every book when the setting changes.
    public var defaultDestination: OutputDestination
    /// This book's own save location. `nil` — the normal case — means "inherit
    /// `defaultDestination`", so changing the app-wide setting moves this book too.
    public var destinationOverride: OutputDestination?
    public var collisionPolicy: CollisionPolicy = .keepBoth
    /// The chapter list the book converts with — `manualChapters` when there are any,
    /// otherwise the one `chapterStrategy` produces.
    ///
    /// Read-only from outside, and written in exactly two places in here: `recompute()`,
    /// which picks between the two sources, and `showMeasuredChapters`, which is how the
    /// conversion replaces the scan-time estimates with what it measured. Anywhere else
    /// assigning it could put a list on screen that neither source agrees with, and the
    /// next `recompute()` — one keystroke away — would silently swap it back.
    public private(set) var chapters: [Chapter] = []
    /// The user's own chapter list, or nil — the normal case — when the chapters are
    /// derived from `chapterStrategy`.
    ///
    /// This is the one piece of a book's state that cannot be recomputed from anything,
    /// which is exactly why `recompute()` must leave it alone. The three inputs above
    /// rebuild the derived state on every assignment, and until this existed that meant
    /// touching the Order or Chapters picker silently destroyed however many chapter
    /// titles the user had just typed. The only routes that clear it are the ones where
    /// the user said so: `adoptChapterStrategy`, `adoptOrder` and
    /// `revertToAutomaticChapters`, each of which the inspector puts behind a
    /// confirmation naming what is about to be regenerated.
    ///
    /// Never empty when non-nil: every edit below goes through `applyManualChapters`,
    /// and none of them can empty the list — there is no delete, and merge needs two
    /// chapters to make one.
    ///
    /// **This assumes `tracks` is never reassigned after `init`, and today nothing in the
    /// app reassigns it.** A book's files are fixed when the folder is scanned, and a
    /// folder whose contents changed is re-dropped, which builds a whole new `Book`. That
    /// assumption is what makes it safe for `recompute()` to leave this alone: the audio a
    /// hand-placed boundary was set against is still the audio at that offset.
    ///
    /// `tracks` is nevertheless a public `var`, and its `didSet` deliberately does NOT
    /// rebuild this — that is the point of it. So an edit that starts reassigning tracks —
    /// a rescan in place, a repair for files that moved, a drag to reorder — would leave a
    /// manual chapter list describing audio that is no longer there: the same times over
    /// different files, with nothing recomputing it and nothing on screen to say it had
    /// stopped meaning anything. `adoptOrder` already treats a mere reordering as enough to
    /// throw this away, behind a confirmation; anything that replaces the tracks themselves
    /// has at least that much to decide, in the same move.
    public private(set) var manualChapters: [Chapter]?
    public var status: BookStatus = .ready
    public var progress: Double = 0
    public var log: String = ""

    /// Warnings produced at scan time. Kept separately so `recompute` can rebuild the
    /// full list without losing them when the user changes a strategy.
    private let inferredWarnings: [String]

    public init(folder: URL, tracks: [TrackInfo], coverImage: URL? = nil,
                defaultDestination: OutputDestination = .besideSource) {
        let inference = Inference.infer(tracks)
        self.folder = folder
        self.defaultDestination = defaultDestination
        self.tracks = tracks
        self.order = inference.order
        self.chapterStrategy = inference.chapterStrategy
        self.title = inference.title
        self.author = inference.author
        self.year = inference.year
        self.inferredWarnings = inference.warnings
        self.warnings = inference.warnings
        self.coverImage = coverImage
        self.status = inference.warnings.isEmpty ? .ready : .warning
        recompute()
    }

    /// `.failed` carries an associated value, so the status enum cannot be compared
    /// with `==` here. A running book must not be removable from the queue: the
    /// conversion holds its own reference and would keep writing regardless.
    public var isConverting: Bool {
        if case .converting = status { return true }
        return false
    }

    /// Whether this book's source MP3s have been sent to the Trash.
    public var isReclaimed: Bool { status == .reclaimed }

    /// Whether reclaiming this book's source MP3s is something to offer at all.
    ///
    /// Only `.verified`. The whole justification for removing the originals is that a
    /// finished, checked copy exists — so a book that has not converted and verified has
    /// nothing to keep in their place, and one already reclaimed has nothing left to take.
    /// This decides only what is OFFERED; `SourceReclaimer` checks the file itself, at the
    /// moment of removal, rather than trusting a flag set hours earlier.
    public var isReclaimable: Bool { status == .verified }

    /// Whether this book's settings still decide anything, and therefore whether the
    /// inspector should let them be touched.
    ///
    /// False while a run is in flight — it read them at the start — and false once the run
    /// is over, whatever it ended as. The order, the chapter source, the destination and the
    /// chapter list describe a conversion, and a terminal book's conversion has already
    /// happened: a `.verified` book's chapter list is a record of the .m4b that was written,
    /// a `.reclaimed` book's audio is in the Trash, and a `.failed` book's settings decide
    /// nothing until Retry puts it back in the queue — which `retry()` does, returning it to
    /// `idleStatus` and to editing in the same move.
    ///
    /// `.verified` was the one this used to miss, and it was not cosmetic: the chapter table
    /// stayed live after a conversion, so a merge or a split moved the list the reclaim
    /// re-checked the finished file against, and a retitle left `book.chapters` permanently
    /// describing a list the .m4b does not carry. The pickers and the table are disabled for
    /// every one of these states, and the guards below are the rule behind that, because a
    /// disabled control is not a rule.
    public var acceptsEdits: Bool { !isConverting && !status.isTerminal }

    /// Cached by `recompute()`, not derived on every read. `TrackOrderer.order` tokenizes
    /// filenames inside its comparator, so this is a real sort per access — and the
    /// sidebar reads `totalDuration` for every row while the inspector reads it again,
    /// on every progress-driven frame. A large library re-sorted every book many times a
    /// second. The `didSet` observers on `tracks`, `order` and `chapterStrategy` keep
    /// this in step with them.
    public private(set) var orderedTracks: [TrackInfo] = []
    public private(set) var totalDuration: Double = 0

    /// Rebuilds the ordering, the chapter list AND the warnings for the current settings.
    /// All must refresh together: a user who picks a different strategy in the inspector
    /// needs to see the consequences of that choice, not the ones inferred at scan time.
    ///
    /// Everything here is DERIVED — recomputable from the three inputs at any time, which
    /// is what makes it safe to rebuild on every assignment to them. `manualChapters` is
    /// not derived and is not rebuilt: it is the user's own work, and this method fires
    /// from a `didSet` on three properties, so overwriting it here would mean a picker
    /// destroying an afternoon of chapter titles with no click, no confirmation and
    /// nothing on screen to say it had happened.
    public func recompute() {
        let ordered = TrackOrderer.order(tracks, by: order)
        orderedTracks = ordered
        totalDuration = ordered.reduce(0) { $0 + $1.estimatedDuration }
        chapters = manualChapters
            ?? ChapterPlanner.plan(tracks: ordered,
                                   durations: ordered.map(\.estimatedDuration),
                                   strategy: chapterStrategy)

        var current = inferredWarnings
        // Inference never picks track-tag order unless every file has a distinct number,
        // but the user can choose it by hand — and then untagged files sort to the end.
        if order == .trackTag {
            let untagged = tracks.filter { TrackOrderer.trackNumber($0) == nil }.count
            if untagged > 0 {
                current.append("\(untagged) file(s) have no track number and will be placed last.")
            }
        }
        // Deliberately about the SETTING, and only asked when the setting is what the book
        // converts with. A hand-edited list cannot be empty, so this could have been left
        // as a bare `chapters.isEmpty` — but the sentence is the point: telling a user
        // looking at twelve chapters they typed that "this setting produces no chapters"
        // would be both untrue and unactionable. The warning comes straight back if they
        // revert to automatic, which is when it is true again and there is something to do
        // about it.
        if manualChapters == nil, chapters.isEmpty {
            current.append("This setting produces no chapters.")
        }
        warnings = current

        if !status.isTerminal && status != .converting {
            status = idleStatus
        }
    }

    /// The status a book that is neither running nor finished should be wearing: the one
    /// place `.ready` and `.warning` are told apart.
    ///
    /// Every route back to a convertible state goes through this — `recompute()` above,
    /// `retry()` below, and both of `ConversionQueue`'s cancel paths. Each of those used
    /// to be free to assign `.ready` directly, and a book with warnings that was cancelled
    /// came back with its warning badge silently traded for a plain circle: the warnings
    /// were still listed in the inspector, but the sidebar no longer said so.
    public var idleStatus: BookStatus { warnings.isEmpty ? .ready : .warning }

    /// Returns a failed book to the queue, reporting whether it took.
    ///
    /// `ConversionQueue.convertAll` skips every terminal status, so a book that failed for
    /// a transient reason — a full disk, a save location that was briefly unavailable, an
    /// ffmpeg hiccup — was stuck for the life of the queue. The only escape was Remove
    /// followed by re-dropping the folder, which is not discoverable and throws away every
    /// per-book setting the user had adjusted: the title, the strategies, the destination
    /// override, the collision policy.
    ///
    /// Only `.failed`. Re-running a `.verified` book is a different intent — it would
    /// silently redo hours of work on a file that is already good — and `.converting` is
    /// owned by a run in flight.
    ///
    /// Everything the failed run left behind goes with it. The log and the notes describe
    /// that run, the progress bar is stale, and `written` would leave the inspector
    /// reporting "Written to:" a path the failed run deleted on its way out — and would
    /// leave a reclaim re-checking a file this book no longer has anything to do with.
    @discardableResult
    public func retry() -> Bool {
        guard case .failed = status else { return false }
        log = ""
        notes = []
        progress = 0
        written = nil
        status = idleStatus
        return true
    }

    // MARK: - Chapter editing

    /// Whether this book's chapters are the user's own rather than the strategy's. Drives
    /// the inspector's badge, its Revert control, and the confirmations on both pickers.
    public var hasManualChapters: Bool { manualChapters != nil }

    /// Renames chapter `index`, refusing an empty title and flattening a pasted one.
    public func setChapterTitle(_ title: String, at index: Int) throws {
        try requireEditable()
        applyManualChapters(try ChapterEditor.retitled(chapters, at: index, to: title))
    }

    /// Moves the boundary between chapter `index` and the next one, setting both sides.
    public func moveChapterBoundary(after index: Int, to time: Double) throws {
        try requireEditable()
        applyManualChapters(try ChapterEditor.boundaryMoved(chapters, after: index, to: time))
    }

    /// Chapter `index` absorbs the one after it.
    public func mergeChapter(at index: Int) throws {
        try requireEditable()
        applyManualChapters(try ChapterEditor.merged(chapters, at: index))
    }

    /// Splits chapter `index` in two at `time`.
    public func splitChapter(at index: Int, at time: Double) throws {
        try requireEditable()
        applyManualChapters(try ChapterEditor.split(chapters, at: index, atTime: time))
    }

    /// The rule behind the table's `.disabled(book.isConverting)`, because a disabled
    /// control is not a rule.
    ///
    /// A run reads the chapter list once, at step 2, and writes it to the metadata file
    /// ffmpeg is already muxing from. An edit accepted now would change the table and the
    /// book's own list without changing a byte of the file being produced — and the
    /// finished .m4b would then disagree with the app that made it, with nothing anywhere
    /// saying which of the two was right.
    private func requireEditable() throws {
        guard !isConverting else { throw ChapterEditError.bookIsConverting }
        // And the same for a book whose audio is in the Trash: its chapter list describes
        // a finished file that is not going to be written again, so an edit accepted here
        // would change the table and nothing else, for ever. Asked before the general
        // question below, which a reclaimed book also answers, because this one can say
        // where the audio went and how to get it back.
        guard !isReclaimed else { throw ChapterEditError.sourceReclaimed }
        // Every other finished state, for the same reason. A `.verified` book's list is
        // already written into the .m4b: an edit here would leave the app describing a
        // file that does not carry it, with the table disabled and no way to write it.
        guard !status.isTerminal else { throw ChapterEditError.bookIsFinished }
    }

    /// Through `recompute()` rather than assigning `chapters` directly, so that list has
    /// exactly one writer and cannot drift from `manualChapters` — and so the warnings and
    /// the status refresh with it, as they do for every other change to a book.
    private func applyManualChapters(_ edited: [Chapter]) {
        manualChapters = edited
        recompute()
    }

    /// Gives the strategy back the job of producing the chapters, discarding the edits.
    ///
    /// Deliberate and named, because it is the only way back: once a list is manual, no
    /// picker regenerates it by itself. The inspector confirms this the same way it
    /// confirms a picker change — the edits are gone either way, and which button was
    /// pressed is no reason to be quieter about it.
    public func revertToAutomaticChapters() {
        // Same rule as `requireEditable`, and the same reason: mid-run this would leave the
        // table showing a list the file being written knows nothing about. Refusing changes
        // nothing and loses nothing — the edits are still there when the run finishes.
        guard acceptsEdits, manualChapters != nil else { return }
        manualChapters = nil
        recompute()
    }

    /// Adopts a chapter source, regenerating the list from it.
    ///
    /// The confirmed half of the inspector's guard: assigning `chapterStrategy` directly
    /// KEEPS any manual edits, so this is the only route that throws them away, and the UI
    /// only reaches it once the user has said yes. Both are needed — a guard that lived
    /// only in the picker's binding would be bypassed by every other caller, and one that
    /// lived only here would make the plain assignment lossy again.
    public func adoptChapterStrategy(_ strategy: ChapterStrategy) {
        guard acceptsEdits else { return }
        manualChapters = nil
        chapterStrategy = strategy
    }

    /// The same for the file ordering, which manual chapters outlive just as readily —
    /// and which invalidates them more thoroughly, since a boundary the user placed by ear
    /// points at whatever audio is now at that offset.
    public func adoptOrder(_ order: OrderStrategy) {
        guard acceptsEdits else { return }
        manualChapters = nil
        self.order = order
    }

    /// The chapters this run will actually write, from the durations it measured.
    ///
    /// Manual edits win over the re-plan. Step 2 of a conversion re-plans the chapters
    /// from the exact decoded durations — the whole reason for measuring them — and that
    /// is right for a derived list and wrong for an edited one: the user's list is not an
    /// estimate to be improved on. It is only fitted to the measured length, which moves
    /// the final `end` and nothing else.
    ///
    /// Throws when the measured audio stops at or before one of the user's boundaries —
    /// `ChapterEditor.fitted` refuses rather than writing a chapter that points past the end
    /// of the book. The run fails there and then, before anything is encoded.
    public func conversionChapters(tracks ordered: [TrackInfo],
                                   durations: [Double]) throws -> [Chapter] {
        guard let manual = manualChapters else {
            return ChapterPlanner.plan(tracks: ordered, durations: durations,
                                       strategy: chapterStrategy)
        }
        return try ChapterEditor.fitted(manual, toTotal: durations.reduce(0, +))
    }

    /// Puts the conversion's exact chapters on screen in place of the scan-time estimates.
    ///
    /// Ignored for an edited list, and deliberately ignored HERE rather than at the call
    /// site: what the table shows there is not an estimate to be improved on, it is what
    /// the user typed and what this very run is writing. Assigning over it would replace
    /// their times with a fit of them, and the next `recompute()` would silently put
    /// theirs back — a list that flickers between two versions of itself.
    public func showMeasuredChapters(_ measured: [Chapter]) {
        guard manualChapters == nil else { return }
        chapters = measured
    }

    // `expectedOutputDuration` lived here: the chapter list's own span, offered as "how long
    // the finished .m4b should be" for a check made after the run. It had one caller, the
    // reclaim's re-verify, and it was wrong for it twice over. It moved whenever the list
    // moved, which is the whole of finding 2; and for a MANUAL list it was never the
    // measured length at all — `showMeasuredChapters` deliberately leaves an edited list
    // alone — so it was the sum of the scan-time estimates, which on a 190-file book sat
    // 4.75 s from what actually decoded against a 3.0 s tolerance. Its doc comment claimed
    // that difference was "milliseconds". `WrittenOutput.duration` is what the run measured,
    // and it is what the re-check uses now.

    /// The override if there is one, the app-wide default otherwise.
    public var destination: OutputDestination { destinationOverride ?? defaultDestination }

    /// Deliberately still a pure computed property, and deliberately NOT part of the
    /// `recompute()` cache: `makeJob`, `ConversionQueue`, `Preflight` and the inspector all
    /// read it whenever they need it, so nothing has to be invalidated when the title or
    /// either destination changes.
    public var outputURL: URL {
        destination.directory(forSource: folder).appendingPathComponent(outputFilename)
    }

    /// The book's title as a filename, which is not the same string.
    ///
    /// The cleaning is not cosmetic. `/` in an album tag ("AC/DC Live") would make the
    /// title a path separator, and a colon ("Rob Roy: The Waverley Novels, Book 4") reads as
    /// one in the Finder — so the file would land somewhere other than the folder that was
    /// chosen, or fail to be written at all. That mattered when the destination was always
    /// the source's parent; it matters more now that the user names the folder.
    private var outputFilename: String {
        let name = title.isEmpty ? folder.lastPathComponent : title
        return name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-") + ".m4b"
    }

    /// Takes the ordered tracks rather than re-deriving them from `order`. The caller
    /// measures durations and plans chapters from one snapshot of the ordering, and
    /// those steps await; re-reading `orderedTracks` here would attach chapters computed
    /// for one order to audio concatenated in another if the user touched the Order
    /// picker in between. Chapter count and total duration still match, so the verifier
    /// passes and the wrong file is marked verified.
    public func makeJob(tracks ordered: [TrackInfo],
                        chapters: [Chapter], totalDuration: Double) -> ConversionJob {
        let first = ordered.first
        var metadata: [String: String] = [
            "title": title, "album": title, "artist": author, "album_artist": author,
            "genre": "Audiobook", "media_type": "2",
        ]
        if !year.isEmpty { metadata["date"] = year }
        return ConversionJob(
            tracks: ordered, chapters: chapters, metadata: metadata,
            coverImage: coverImage, outputURL: outputURL,
            bitRate: first?.bitRate ?? 64000,
            sampleRate: first?.sampleRate ?? 44100,
            channels: first?.channels ?? 2,
            totalDuration: totalDuration)
    }
}
