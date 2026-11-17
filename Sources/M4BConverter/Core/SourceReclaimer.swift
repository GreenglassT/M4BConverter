import Foundation

/// Why a request to reclaim a book's source MP3s was refused, in the words the app shows.
///
/// Every one of these is a reason the app cannot yet promise that a good copy of the audio
/// exists somewhere else, and each of them ends the same way: nothing was moved and nothing
/// was deleted. That is the point of the type — the refusals are the feature. Sending eight
/// gigabytes of someone's audiobooks to the Trash is only defensible when the app has just
/// re-checked the file that replaces them.
public enum ReclaimRefusal: Error, Equatable, Sendable {
    case notVerified
    case conversionRunning
    case toolsMissing
    case noOutputRecorded
    case outputMissing(URL)
    case outputInsideTheFolder(output: URL, folder: URL)
    case couldNotCheckOutput(String)
    case outputNoLongerVerifies(problems: [String], output: URL)
    case folderMissing(URL)
    case couldNotTrash(folder: URL, reason: String)

    public var message: String {
        switch self {
        case .notVerified:
            return "Only a verified book's source MP3s can be reclaimed. The reason for "
                 + "removing them is that a finished, checked copy exists in their place, "
                 + "and this book has not converted and verified."
        case .conversionRunning:
            return "A conversion is running, so nothing can be reclaimed yet. Cancel it "
                 + "first, or wait for it to finish."
        case .toolsMissing:
            return "ffmpeg is not available, so the finished book cannot be checked again "
                 + "— and nothing goes to the Trash without checking it first."
        case .noOutputRecorded:
            return "This book has no finished file recorded, so there is nothing to keep "
                 + "in place of its MP3s. Nothing was moved."
        case .outputMissing(let output):
            return "The finished book is not at \(output.path) any more — moved, renamed "
                 + "or deleted. These MP3s are the only copy left, so nothing was moved."
        case .outputInsideTheFolder(let output, let folder):
            return "The finished book is at \(output.path), inside \(folder.path) — the "
                 + "very folder that would go to the Trash, which would take the .m4b with "
                 + "it. Save the book outside its source folder first. Nothing was moved."
        case .couldNotCheckOutput(let reason):
            return "The finished book could not be checked: \(reason) Nothing was moved."
        case .outputNoLongerVerifies(let problems, let output):
            return "\(output.path) no longer matches this book: "
                 + "\(problems.joined(separator: "; ")). The MP3s are still there."
        case .folderMissing(let folder):
            return "\(folder.path) is not there any more — moved, renamed, or already in "
                 + "the Trash. Nothing was moved."
        case .couldNotTrash(let folder, let reason):
            return "\(folder.path) could not be moved to the Trash: \(reason) Nothing was "
                 + "deleted — every file is exactly where it was. A volume with no Trash "
                 + "cannot be reclaimed from here; move the folder yourself if you mean to."
        }
    }
}

/// Another book in the queue that lives inside the folder about to go to the Trash.
///
/// Named separately from the `strangers` list because a stranger is a file the user can
/// look at and judge, and this is a book the app itself is holding — one whose MP3s, whose
/// finished .m4b, or both, this reclaim would take away as a side effect of removing
/// someone else's. "A folder called Ivanhoe goes too" is not the same sentence as "the book
/// Ivanhoe goes too", and only the second one stops anybody.
public struct QueuedBookInside: Sendable, Equatable {
    /// The book's title, which is what the queue shows and therefore what the user knows
    /// it by. Not the folder name: those differ as soon as a title is edited or inferred.
    public var title: String
    /// Whether its source folder is one of the things going to the Trash.
    ///
    /// False for an already-reclaimed book — its MP3s are in the Trash already, so saying
    /// they go again would be untrue — and false for a book that merely SAVED into this
    /// folder from somewhere else.
    public var sourceGoes: Bool
    /// Whether the .m4b a run wrote for it is going too, because the save location put it
    /// in here. This is the serious half: it is the same loss `outputInsideTheFolder`
    /// refuses outright for the book being reclaimed, one book over.
    public var outputGoes: Bool

    /// "Ivanhoe (its MP3s and its finished .m4b)"
    public var described: String {
        switch (sourceGoes, outputGoes) {
        case (true, true): return "\(title) (its MP3s and its finished .m4b)"
        case (true, false): return "\(title) (its MP3s)"
        default: return "\(title) (its finished .m4b)"
        }
    }
}

/// What is about to go, counted before the user is asked.
public struct ReclaimSurvey: Sendable, Equatable {
    public var folder: URL
    /// Every regular file inside the folder, at any depth — not just the book's tracks.
    /// The folder goes as a whole, so this is what the user is actually agreeing to.
    public var fileCount: Int
    public var byteCount: Int64
    /// Anything in the folder that is not one of this book's own tracks or its cover image,
    /// by name. A PDF, a second cover, a nested folder of extras: all of it goes too, and
    /// the user should hear that from the confirmation rather than discover it afterwards.
    ///
    /// Never repeats anything already named in `queued` below: an entry that IS one of
    /// those books is dropped from here, so each thing going to the Trash is described
    /// once, by whichever of the two lists knows the most about it.
    public var strangers: [String]
    /// The other books in the queue this folder holds. Empty in the ordinary case, and
    /// empty for a survey taken without a queue to compare against — `reclaim` takes one
    /// of those purely to count what it just moved.
    public var queued: [QueuedBookInside] = []

    public var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }

    /// "32 files, 1.2 GB"
    public var summary: String {
        "\(fileCount) file\(fileCount == 1 ? "" : "s"), \(formattedSize)"
    }
}

@MainActor
extension ReclaimSurvey {
    /// The sentence the confirmation dialog puts under its title.
    ///
    /// It has to say four things, because each of them is something the user would
    /// otherwise have to take on trust: which folder, how much of it, that it goes to the
    /// TRASH rather than being deleted, and which finished file is being kept in its place.
    ///
    /// And a fifth, when there is one to say: that another book in the queue is in there
    /// too. That sentence comes FIRST, ahead of the file count and everything else, because
    /// it is the only one that would change a reasonable person's mind — and it is a
    /// warning rather than a refusal, for the reasons on `queuedBooksInside`.
    public func confirmation(for book: Book) -> String {
        var text = ""
        if !queued.isEmpty {
            let named = queued.prefix(5).map(\.described).joined(separator: ", ")
            let rest = queued.count > 5 ? ", and \(queued.count - 5) more" : ""
            let one = queued.count == 1
            text += one
                ? "Another book in this queue is inside \(folder.path): \(named). "
                : "\(queued.count) other books in this queue are inside \(folder.path): "
                + "\(named)\(rest). "
            // The second half said outright, because nothing afterwards will say it: those
            // books keep whatever status they had, so a verified one still offers its own
            // Reclaim and would then refuse with "…is not there any more".
            text += one
                ? "It goes to the Trash with the folder, without any check of its own, and "
                + "the queue will still show it exactly as it is now. "
                : "They go to the Trash with the folder, without any check of their own, "
                + "and the queue will still show them exactly as they are now. "
        }
        text += "\(folder.path) holds \(summary). "
        if !strangers.isEmpty {
            let named = strangers.prefix(5).joined(separator: ", ")
            let rest = strangers.count > 5 ? ", and \(strangers.count - 5) more" : ""
            let subject = strangers.count == 1
                ? "1 item that is not one of this book's MP3s or its cover"
                : "\(strangers.count) items that are not this book's MP3s or its cover"
            text += "It also holds \(subject) (\(named)\(rest)), which "
                  + "\(strangers.count == 1 ? "goes" : "go") with it. "
        }
        text += "All of it goes to the Trash — not deleted — so you can put it back from "
              + "there. "
        if let written = book.writtenURL {
            text += "\(written.path) is checked once more first, and is not touched."
        }
        return text
    }
}

/// What a completed reclaim did, for the message the user gets afterwards.
public struct ReclaimReceipt: Sendable, Equatable {
    public var survey: ReclaimSurvey
    /// Where the folder landed in the Trash, when the system said.
    public var trashedURL: URL?
}

/// How an item is sent to the Trash, answering where it ended up.
///
/// Injected so the "this volume has no Trash" path can be exercised without a disk image —
/// and so that there is exactly one function in this feature that moves anything, and it
/// can be read in full in the four lines of `systemTrash` below.
public typealias TrashOperation = @Sendable (URL) throws -> URL?

/// Moves a converted book's source MP3s to the Trash, once and only once it has confirmed
/// that the finished .m4b is still there and still good.
///
/// Two rules hold this together, and neither is negotiable:
///
/// **Trash, never delete.** There is no `removeItem` anywhere in this file. A volume with
/// no Trash means the reclaim FAILS and says so; it never falls back to deleting. This is
/// the same choice `ConversionQueue` makes for the `.replace` swap, and for the same
/// reason: losing the ability to reclaim is an inconvenience, and losing someone's only
/// copy of an audiobook is not.
///
/// **Check the file, not the flag.** `.verified` was set when the run finished, which may
/// have been days ago; files move, volumes are unmounted, and a save location can even be
/// the source folder itself. Everything below is re-checked at the moment of removal, and
/// the .m4b is re-probed and re-verified against `Book.written` — the chapter count and the
/// measured length THE RUN recorded, not the book's live chapter list. The live list is
/// still assignable after a conversion, and re-checking against it meant the app could
/// refuse a perfectly good file for a change the app itself had made ("Expected 2 chapters,
/// found 3") or, the other way round, trash the MP3s while `book.chapters` no longer
/// described the .m4b at all. Evidence a window can move is not evidence.
@MainActor
public enum SourceReclaimer {
    /// `nonisolated` because it is one Sendable closure over `FileManager` that touches no
    /// state of this type. Both callers that send something to the Trash — the reclaim
    /// here and the `.replace` swap in `ConversionQueue` — should be able to name it from
    /// wherever they run, rather than one of them keeping a second hand-rolled copy of
    /// `trashItem(at:resultingItemURL:)` to avoid the isolation.
    nonisolated public static let systemTrash: TrashOperation = { url in
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    /// Counts the folder, names anything in it that is not this book's own, and names any
    /// OTHER book in `queue` that is in there too.
    ///
    /// Everything is counted, hidden files included, because everything goes; only the
    /// STRANGERS skip hidden entries, since telling the user about `.DS_Store` is noise
    /// and telling them about `liner-notes.pdf` is the point.
    ///
    /// `async`, and the tree walk itself happens off this actor, because the walk is
    /// unbounded: this is raised from a button, and a book on a network share or one with
    /// a deep folder of extras would freeze the window for as long as the disk took. Only
    /// the two cheap reads of main-actor state — the book's own filenames, and the queue —
    /// happen here. The caller must not put a dialog on screen until this returns; a
    /// confirmation carrying half a file count is a confirmation of nothing.
    ///
    /// `queue` defaults to empty. `reclaim` passes nothing, because its survey exists only
    /// to say how much just moved; the confirmation is where the queue matters.
    public static func survey(_ book: Book, queue: [Book] = []) async -> ReclaimSurvey {
        // Read off the main actor's state up front, so nothing below has to come back for
        // it: `Book` is main-actor isolated and the walk is not.
        let folder = book.folder
        var known = Set(book.tracks.map { $0.url.lastPathComponent })
        if let cover = book.coverImage { known.insert(cover.lastPathComponent) }
        let (inside, insideURLs) = queuedBooksInside(folder, queue: queue, excluding: book)

        // Detached, and explicitly so. A bare `nonisolated async` function would also leave
        // this actor today, but only because that is the current default for one; the
        // upcoming `NonisolatedNonsendingByDefault` behaviour runs it on the CALLER's
        // executor instead, which here is the main actor — and the hitch would come back
        // on a compiler flag, with nothing in the code changed to explain it. This says
        // where the walk runs.
        let counted = await Task.detached(priority: .userInitiated) {
            walk(folder, known: known, ignoring: insideURLs)
        }.value
        return ReclaimSurvey(folder: folder, fileCount: counted.files,
                             byteCount: counted.bytes, strangers: counted.strangers,
                             queued: inside)
    }

    /// The disk half of `survey`, and the whole reason that one is `async`: an unbounded
    /// tree walk, which the caller above runs on the concurrent executor.
    ///
    /// Synchronous and `nonisolated`. Synchronous because `FileManager`'s directory
    /// enumerator is `noasync` — Foundation refuses to be iterated from an async function
    /// at all, which is the same objection stated by the compiler. `nonisolated` because
    /// nothing here may touch main-actor state: the moment it needs to, it has to come back
    /// to the main actor, and the hitch this exists to remove is back with nothing failing
    /// to say so.
    nonisolated static func walk(
        _ folder: URL, known: Set<String>, ignoring: [URL] = []
    ) -> (files: Int, bytes: Int64, strangers: [String]) {
        let manager = FileManager.default
        var files = 0
        var bytes: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        if let walker = manager.enumerator(at: folder, includingPropertiesForKeys: keys) {
            for case let url as URL in walker {
                let values = try? url.resourceValues(forKeys: Set(keys))
                guard values?.isRegularFile == true else { continue }
                files += 1
                bytes += Int64(values?.fileSize ?? 0)
            }
        }

        let strangers = ((try? manager.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles])) ?? [])
            // An entry that IS one of the queued books — or that holds one — is described
            // by name in the sentence above, so listing it again here as an anonymous
            // "item that is not one of this book's MP3s" would be the same thing said
            // twice, the second time less usefully. Same containment test as everywhere
            // else in this file, asked the other way round.
            .filter { entry in !ignoring.contains { isInside($0, entry) } }
            .map(\.lastPathComponent)
            .filter { !known.contains($0) }
            .sorted { naturalLess($0, $1) }

        return (files, bytes, strangers)
    }

    /// Every book in `queue` other than `book` that this folder would take with it, and the
    /// paths of theirs that it would take — for the strangers filter above.
    ///
    /// This is the finding: `reclaim` checks that the book's OWN output is not inside the
    /// folder, and nothing looked at the rest of the queue. Drop a parent folder and one of
    /// its children in two separate operations — which is all it takes, since
    /// `AudiobookScanner` stops recursing at the first level holding MP3s — and reclaiming
    /// the parent moves the child's source folder, and its finished .m4b if the save
    /// location points inside, to the Trash. The child stays `.verified`, still offers
    /// Reclaim, and refuses with `folderMissing` when it is taken up on it.
    ///
    /// It warns rather than refuses, deliberately:
    ///
    /// - The user may mean it. Two books, one nested in the other, both converted and both
    ///   verified: reclaiming the parent and taking the child with it is a coherent wish,
    ///   and the only thing wrong with it before was that nobody said it was happening.
    /// - Nothing is deleted. The folder goes to the Trash whole, so the child's MP3s and
    ///   its .m4b are both a Put Back away — which is not true of the case `reclaim` does
    ///   refuse, where the file being kept as justification is the one being thrown away.
    /// - A refusal here would enforce bookkeeping rather than safety. This looks at the
    ///   QUEUE, so removing the other book from the queue would clear the refusal while
    ///   changing nothing on disk — a rule with a Remove button for a bypass is not a rule,
    ///   it is a detour, and the user would learn the detour rather than the risk.
    static func queuedBooksInside(_ folder: URL, queue: [Book],
                                  excluding book: Book) -> ([QueuedBookInside], [URL]) {
        var found: [QueuedBookInside] = []
        var urls: [URL] = []
        for other in queue where other !== book {
            // A reclaimed book's MP3s are in the Trash already, so this folder is not about
            // to take them: claiming otherwise would be the one thing worse than silence.
            // Its finished .m4b, if it was saved in here, is still very much present.
            let sourceGoes = !other.isReclaimed && isInside(other.folder, folder)
            let output = other.written?.url
            let outputGoes = output.map { isInside($0, folder) } ?? false
            guard sourceGoes || outputGoes else { continue }
            found.append(QueuedBookInside(title: other.title, sourceGoes: sourceGoes,
                                          outputGoes: outputGoes))
            if sourceGoes { urls.append(other.folder) }
            if outputGoes, let output { urls.append(output) }
        }
        return (found, urls)
    }

    /// Sends `book.folder` to the Trash, or throws a `ReclaimRefusal` having moved nothing.
    ///
    /// On success the book becomes `.reclaimed` here rather than at the call site: the
    /// invariant is that a book whose folder is in the Trash never again looks convertible,
    /// and an invariant a caller has to remember is one a future caller will forget.
    @discardableResult
    public static func reclaim(_ book: Book, tools: FFmpegTools,
                               trashing: TrashOperation = systemTrash) async throws -> ReclaimReceipt {
        guard book.isReclaimable else { throw ReclaimRefusal.notVerified }

        // What the run wrote, and what it wrote into it. The file is then examined as it is
        // right now — not as the run left it — against exactly those figures.
        guard let written = book.written else { throw ReclaimRefusal.noOutputRecorded }
        let output = written.url
        let manager = FileManager.default
        guard manager.fileExists(atPath: output.path) else {
            throw ReclaimRefusal.outputMissing(output)
        }
        // A save location may be the book's own folder: Settings allows it and so does the
        // inspector's "Save to" row. Trashing the folder would take the .m4b with it, and
        // the user would be left with neither the MP3s nor the book made from them.
        guard !isInside(output, book.folder) else {
            throw ReclaimRefusal.outputInsideTheFolder(output: output, folder: book.folder)
        }
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: book.folder.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw ReclaimRefusal.folderMissing(book.folder)
        }

        // Re-verify. This is the whole argument for removing the originals — that a good
        // copy exists — so it is established here, now, by reading the file, rather than
        // inherited from a status flag that was true when it was set. The expectations are
        // the run's own: the same two numbers `ConversionQueue` verified this file against
        // when it finished, so this asks the identical question a second time.
        let report: VerificationReport
        do {
            report = try await OutputVerifier(tools: tools).verify(
                output, expectedChapters: written.chapterCount,
                expectedDuration: written.duration,
                // Cosmetic either way, and nothing here should be refused over artwork:
                // only `fatalProblems` decides, and a missing cover is not one.
                expectedCover: false)
        } catch {
            throw ReclaimRefusal.couldNotCheckOutput(error.localizedDescription)
        }
        guard report.passed else {
            throw ReclaimRefusal.outputNoLongerVerifies(problems: report.fatalProblems,
                                                        output: output)
        }

        // Count it before it goes, or there is nothing left to count.
        let survey = await survey(book)
        let trashed: URL?
        do {
            trashed = try trashing(book.folder)
        } catch {
            throw ReclaimRefusal.couldNotTrash(folder: book.folder,
                                               reason: error.localizedDescription)
        }

        book.status = .reclaimed
        let subject = survey.fileCount == 1
            ? "the one file in \(book.folder.lastPathComponent) is"
            : "the \(survey.fileCount) files in \(book.folder.lastPathComponent) are"
        book.notes.append(
            "Reclaimed \(survey.formattedSize): \(subject) in the Trash, not deleted. "
            + "\(output.path) was checked again first.")
        return ReclaimReceipt(survey: survey, trashedURL: trashed)
    }

    /// Whether `url` lies inside `folder`, or is it.
    ///
    /// By path components rather than a `hasPrefix` on the strings, which would call
    /// "/books/Ivanhoe 2.m4b" a child of "/books/Ivanhoe". Both sides are resolved through
    /// symlinks first, so the two spellings of one place (`/var` and `/private/var`, an
    /// iCloud-synced Desktop) compare equal.
    ///
    /// **This comparison is case-insensitive only by accident, and only while the files
    /// exist.** `pathComponents` are compared with `==`, which is case-SENSITIVE; what
    /// makes "/Books/ivanhoe.m4b" match "/books/Ivanhoe" on a normal (case-insensitive) APFS
    /// volume is `resolvingSymlinksInPath()`, which replaces each component with the
    /// canonical on-disk spelling — and does so ONLY for a path that exists. Delete the
    /// leaf and the same call hands back the caller's literal spelling again, verified: a
    /// file created as `Ivanhoe/Book.m4b` and asked for as `IVANHOE/BOOK.m4b` resolves to
    /// `Ivanhoe/Book.m4b` while it is there and to `IVANHOE/BOOK.m4b` the moment it is
    /// removed.
    ///
    /// The caller whose CORRECTNESS turns on that — `reclaim`'s `outputInsideTheFolder`
    /// guard — is safe only because it has ALREADY confirmed the output exists, three lines
    /// above. Moving that existence check after this one silently turns the comparison
    /// case-sensitive: a save location stored in a different case than the folder on disk
    /// would no longer be recognised as being inside it, and the reclaim would send the
    /// .m4b to the Trash along with the MP3s it was the justification for keeping. Nothing
    /// would fail loudly; the guard would simply stop firing.
    ///
    /// The survey's callers — `queuedBooksInside` and the strangers filter — do ask this
    /// about paths that may not exist (a queued book's folder or its recorded output can
    /// have been moved since). They accept the weaker answer knowingly: a case-differing
    /// spelling costs an advisory warning that is not shown, not a file. Anything stricter
    /// than a warning must not be built on this without an existence check of its own.
    nonisolated static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let target = url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        let container = folder.resolvingSymlinksInPath().standardizedFileURL.pathComponents
        guard target.count >= container.count else { return false }
        return Array(target.prefix(container.count)) == container
    }
}
