import Foundation
import Observation

@Observable
@MainActor
public final class AppModel {
    public var tools: FFmpegTools?
    public var books: [Book] = []
    public var selection: Book.ID?
    public var queue: ConversionQueue?
    public var isScanning = false

    /// Non-nil when ffmpeg is missing, or present but unusable. Drives the setup sheet.
    public var setupMessage: String?
    /// True while a validation run is in flight. Only for the setup sheet's own UI —
    /// deliberately NOT part of `needsSetup`, or the launch validation would flash the
    /// sheet on screen for 10-50 ms on every healthy system.
    public var isValidating = false
    /// Transient feedback for the footer: a drop that produced no books — an unreadable
    /// folder looks exactly like an empty one, so say something rather than leaving the
    /// window blank — or a request refused because a conversion is running.
    public var scanMessage: String?

    /// Where finished books are written unless one overrides it.
    ///
    /// Pushed down to every book on assignment. Each `Book` holds its own copy so
    /// `outputURL` needs nothing but the book itself, which means a book already in the
    /// queue would otherwise keep aiming at the old folder — the inspector would show the
    /// previous path, and the conversion would write there. A book with its own
    /// `destinationOverride` is untouched by this: the override wins in `Book.destination`,
    /// so the new default simply sits behind it, ready if the override is cleared.
    /// Assignments in `init` do not fire `didSet`, and there are no books yet then anyway.
    public var defaultDestination: OutputDestination = .besideSource {
        didSet { for book in books { book.defaultDestination = defaultDestination } }
    }

    /// Non-nil when the save location cannot be used: a folder that has gone away since it
    /// was chosen, or one the user just picked that is not writable. Shown in the settings
    /// pane.
    public var destinationMessage: String?

    /// Checking .m4b files this app did not make. Its own object, not part of the queue:
    /// it converts nothing, writes nothing and owns no books, and running it while a
    /// conversion is going takes nothing away from that conversion but CPU — which is real,
    /// and is why both bounds come out of one `FFmpegBudget` rather than being chosen apart.
    public let libraryCheck = LibraryCheck()

    /// Transient feedback for the check window's own header: a choice that held no .m4b
    /// files, a report copied, a report saved.
    public var libraryCheckMessage: String?

    private let defaults: UserDefaults

    public var needsSetup: Bool { tools == nil || setupMessage != nil }

    /// Takes its `UserDefaults` so a test can exercise the stored setting without reading
    /// or overwriting the one the person running the suite has chosen in the app.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // A stored location can go stale between launches: an external volume that is not
        // mounted, a folder that was moved or deleted. It is KEPT rather than quietly
        // reverted to `.besideSource` — reverting would scatter finished books back into
        // the source folders, which is both a place the user did not choose and, for a
        // nested book, the very behaviour this setting exists to escape. Say so instead,
        // and let `Preflight` refuse each conversion by name until it is fixed.
        let stored = OutputDestination.fromDefaults(defaults)
        defaultDestination = stored
        destinationMessage = stored.problem().map {
            "The saved location cannot be used right now: \($0) Books will not convert "
            + "until it is available again, or you choose another folder."
        }
        relocateTools()
    }

    /// Whether app-level state may change right now. False while the queue is running:
    /// `relocateTools` has refused under exactly this condition since it existed, and the
    /// save location is the same kind of state for the same reason.
    public var isConverting: Bool { queue?.isRunning == true }

    /// Whether anything in this app has child processes running right now.
    ///
    /// Two things can: the conversion queue, and the existing-books check — which runs
    /// `FFmpegBudget.concurrentDecodes` full decodes with an ffprobe each, all of them
    /// `Process` children that outlive this app if it goes away without reaping them.
    /// `applicationShouldTerminate` asks this one question instead of naming either. It used
    /// to guard on the queue alone; the check was added afterwards and the guard was never
    /// widened, so quitting during a check returned `.terminateNow` and left twelve
    /// processes running after the app had disappeared (six decodes and their ffprobes, the
    /// bound at the time) — the exact hazard that handler exists to prevent. Anything else
    /// that grows children belongs here, in the one place, rather than as a third special
    /// case alongside the first two.
    public var isBusy: Bool { isConverting || libraryCheck.isRunning }

    /// Stops all of it, by the same routes the Cancel buttons use rather than a second
    /// shutdown path that nothing else exercises. Both are safe to call when idle.
    public func cancelEverything() {
        queue?.cancelAll()
        libraryCheck.cancelAll()
    }

    /// Waits for everything to actually stop, reporting whether it did within `timeout`.
    ///
    /// With a deadline. An unbounded wait on those flags makes the app impossible to quit if
    /// one of them never clears, and the user's only remaining move is Force Quit — which
    /// orphans the very children the wait exists to reap. Ten seconds is far longer than
    /// terminating a handful of processes takes, and a slow quit beats an unquittable app.
    @discardableResult
    public func waitUntilIdle(within timeout: TimeInterval = 10) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while isBusy, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        return !isBusy
    }

    /// Returns nil when the destination was adopted, or a message when it was refused —
    /// in which case the previous setting stands, in the model and on disk.
    @discardableResult
    public func setDefaultDestination(_ destination: OutputDestination) -> String? {
        // `defaultDestination.didSet` pushes down to EVERY book, including the ones being
        // converted right now — whose `outputURL` was resolved and claimed at preflight
        // and cannot move. The inspector would then name a folder the file is not being
        // written to, which is the exact thing its own `.disabled(book.isConverting)`
        // guard exists to prevent, and books still queued behind the running ones resolve
        // their `outputURL` afterwards — so one click of Convert All would split its
        // output across two folders while the footer still read "3 of 9". The Settings
        // window disables its controls for this, and this is the guard behind it: ⌘, is
        // reachable during a conversion and a disabled control is not a rule.
        guard !isConverting else {
            let message = "A conversion is running, so the save location cannot be "
                        + "changed yet. Books already converting are writing to the "
                        + "folder they started with. Cancel the run, or wait for it to "
                        + "finish."
            destinationMessage = message
            return message
        }
        if let problem = destination.problem() {
            let message = "That folder cannot be used as the save location: \(problem) "
                        + "The save location is unchanged."
            destinationMessage = message
            return message
        }
        destinationMessage = nil
        defaultDestination = destination
        destination.writeToDefaults(defaults)
        return nil
    }

    public func relocateTools() {
        // Never swap the queue out from under a running conversion. The old queue would
        // keep its ffmpeg processes while becoming unreachable: the footer's Cancel
        // disappears, and `applicationShouldTerminate` inspects the NEW idle queue,
        // returns `.terminateNow` and quits the app while ffmpeg is still writing —
        // producing exactly the never-verified leftover file that handler exists to
        // prevent. The tools cannot change mid-run anyway; the run is using them.
        guard !isConverting else {
            scanMessage = "A conversion is running, so the ffmpeg tools cannot be "
                        + "changed yet. Cancel it first, or wait for it to finish."
            return
        }
        tools = FFmpegLocator.locateFromDefaults()
        queue = tools.map { ConversionQueue(tools: $0) }
        if tools == nil {
            setupMessage = "ffmpeg could not be found. Install it with Homebrew, "
                         + "or point M4B Converter at an existing copy."
        } else {
            // Leave `setupMessage` alone: clearing it optimistically made `needsSetup`
            // false for the 10-50 ms the validation takes, so "Check again" dismissed
            // the sheet and the result immediately snapped it back open.
            isValidating = true
            Task { await validateTools() }
        }
    }

    /// Confirms the binary actually runs and carries the AudioToolbox AAC encoder.
    /// Without this the first conversion fails with raw ffmpeg text that reads like a
    /// problem with the user's audio rather than with their ffmpeg install.
    public func validateTools() async {
        defer { isValidating = false }
        guard let tools else { return }
        setupMessage = await Preflight.validate(tools)
    }

    public func setToolsDirectory(_ directory: URL) {
        UserDefaults.standard.set(directory.path, forKey: FFmpegLocator.overrideDefaultsKey)
        relocateTools()
    }

    public var selectedBook: Book? { books.first { $0.id == selection } }

    public func add(_ urls: [URL]) async {
        guard let tools else { return }
        isScanning = true
        scanMessage = nil
        defer { isScanning = false }

        // The scanner only ever yields folders, so a dropped file produces no candidates
        // at all — and the empty-folder message would send the user hunting for a
        // permissions problem that is not there.
        let droppedAPlainFile = urls.contains { !$0.hasDirectoryPath }

        let scanner = AudiobookScanner()
        let candidates = scanner.scan(urls)
        guard !candidates.isEmpty else {
            scanMessage = droppedAPlainFile
                ? "Drop a folder, not individual files. Each folder of MP3s becomes one book."
                : "No MP3s found there. Note a folder that cannot be read looks "
                + "the same as an empty one."
            return
        }

        var added = 0
        var refusal: String?
        for candidate in candidates {
            // Cheap short-circuit: skip the probing entirely for a folder already queued.
            guard !isQueued(candidate.folder) else { continue }
            let (tracks, unreadable) = await probeConcurrently(candidate.files, using: tools)
            // Refuse the whole folder rather than build a book out of what was readable.
            // A dropped track produces an audiobook that is short by that track, and
            // because the chapter plan and OutputVerifier are both derived from the same
            // truncated list, it converts and verifies clean: nothing on screen would
            // ever suggest the book is incomplete. Re-dropping fixes a transient failure
            // and names the file for a permanent one, and neither outcome lies.
            if let first = unreadable.first {
                refusal = refusal ?? message(forUnreadable: unreadable.count,
                                             firstNamed: first, in: candidate)
                continue
            }
            guard !tracks.isEmpty else { continue }
            // Same refusal for a file whose REAL codec is not MP3. The scanner selects
            // by extension, so AAC/ALAC/FLAC renamed to `.mp3` gets in — and it decodes
            // correctly on its own, so the probe and the duration measurement both say
            // it is fine. Only the concat demuxer disagrees: it forces the FIRST input's
            // format onto every input, so the misnamed file decodes to nothing, ffmpeg
            // exits 0, and that audio is silently absent from the output. OutputVerifier
            // does catch it as a duration mismatch — after a multi-hour encode — and its
            // 3 s tolerance would let a file shorter than that pass with a matching
            // chapter count and no complaint at all. One second here instead.
            let notMP3 = tracks.filter { !$0.isMP3 }
            if let first = notMP3.first {
                refusal = refusal ?? message(forNonMP3: notMP3.count,
                                             firstNamed: first, in: candidate)
                continue
            }
            // Re-check after the await. `add` has no reentrancy guard, so two overlapping
            // drops of the same folder both cleared the check above and both appended:
            // two books, one folder, one output path — straight into the concurrent
            // same-path collision the queue then has to defend against. Nothing suspends
            // between this check and the append, so on the main actor it is atomic.
            guard !isQueued(candidate.folder) else { continue }
            let book = Book(folder: candidate.folder, tracks: tracks,
                            coverImage: scanner.coverImage(in: candidate.folder),
                            defaultDestination: defaultDestination)
            // Drop the reclaimed entry this folder is coming back over, if there is one.
            // Only ever a reclaimed one — `isQueued` let anything else stop us above — so
            // this cannot displace a book that is queued, running or finished.
            let wasSelected = books.contains { $0.folder == candidate.folder
                                               && $0.id == selection }
            books.removeAll { $0.folder == candidate.folder && $0.isReclaimed }
            books.append(book)
            added += 1
            // Keep the row selected across the swap, or the inspector jumps somewhere else
            // at the exact moment the user is looking at the book they just put back.
            if selection == nil || wasSelected { selection = book.id }
        }
        // A refusal outranks the already-queued note: it is the only one that tells the
        // user something is wrong and what to do about it.
        if let refusal { scanMessage = refusal }
        else if added == 0 { scanMessage = "Those books are already in the queue." }
    }

    /// Whether a book already in the queue still stands for this folder.
    ///
    /// A RECLAIMED book does not. Its MP3s are in the Trash, so a folder on disk at that
    /// path again is one the user put back, and they mean to work with it. Plain equality
    /// swallowed the re-drop — "Those books are already in the queue" — while the entry it
    /// matched could never convert anything again.
    private func isQueued(_ folder: URL) -> Bool {
        books.contains { $0.folder == folder && !$0.isReclaimed }
    }

    private func message(forUnreadable count: Int, firstNamed first: URL,
                         in candidate: BookCandidate) -> String {
        let subject = count == 1
            ? "Could not read \(first.lastPathComponent) in \(candidate.name)."
            : "Could not read \(count) files in \(candidate.name), "
              + "starting with \(first.lastPathComponent)."
        return "\(subject) No book was added, since it would be missing that audio. "
             + "Drop the folder again to retry."
    }

    private func message(forNonMP3 count: Int, firstNamed first: TrackInfo,
                         in candidate: BookCandidate) -> String {
        let subject = count == 1
            ? "\(first.filename) in \(candidate.name) is not an MP3 "
              + "(it is \(first.codecName))."
            : "\(count) files in \(candidate.name) are not MP3s "
              + "(\(first.filename) is \(first.codecName))."
        return "\(subject) No book was added: the audio of a file in another format is "
             + "silently dropped when the MP3s are joined. Convert those files to MP3 "
             + "and drop the folder again."
    }

    /// One ffprobe per file, six at a time. Sequentially, a 342-file library took 7.0 s
    /// of pure waiting; bounded at six it takes 1.6 s.
    ///
    /// Six of ITS OWN, deliberately not `FFmpegBudget`'s: these are metadata reads that take
    /// milliseconds and spend them waiting on the disk, not the decodes that bound governs.
    /// `LibraryCheck` used to cite this number as precedent for six concurrent full-file
    /// decodes, which is the mistake in the other direction — and the reason this says so.
    ///
    /// Takes the tools rather than a `MediaProbe` so each child can build its own. A
    /// `ProcessRunner` tracks exactly one process — `beginRun` clears the slot and
    /// `publishLaunched` overwrites it — so sharing one probe across six concurrent
    /// runs leaves five of them unkillable, and a single `terminate()` would set the
    /// runner's sticky cancellation flag and fail every probe made through it afterwards.
    ///
    /// Reports the failures instead of swallowing them. Dropping an unprobeable file on
    /// the floor is invisible all the way to the finished .m4b, so the caller has to be
    /// able to see that it happened.
    private func probeConcurrently(
        _ files: [URL], using tools: FFmpegTools, limit: Int = 6
    ) async -> (tracks: [TrackInfo], unreadable: [URL]) {
        // Each result is stored at ITS OWN index, so the array comes back in the order the
        // files were given. Appending in completion order would scramble it, and
        // TrackOrderer breaks ties on exactly that order — so same-numbered files would
        // shuffle silently, with nothing on screen to suggest anything had gone wrong.
        var probed = [TrackInfo?](repeating: nil, count: files.count)
        await runConcurrently(count: files.count, limit: limit) { index in
            let file = files[index]
            return { try? await MediaProbe(tools: tools).probe(file) }
        } onResult: { index, info in
            probed[index] = info
            // Nothing cancels a scan: every file gets probed, and an unreadable one is
            // reported below rather than ending the run.
            return true
        }

        return (probed.compactMap(\.self),
                probed.enumerated().filter { $0.element == nil }.map { files[$0.offset] })
    }

    public func remove(_ book: Book) {
        // A converting book is still owned by ConversionQueue: dropping it from the
        // array would leave the run writing a file the user can no longer see or cancel.
        guard !book.isConverting else { return }
        books.removeAll { $0.id == book.id }
        if selection == book.id { selection = books.first?.id }
    }

    /// The books a run has failed, in queue order. Drives both the "Retry All Failed"
    /// item and its count, so the menu cannot offer to retry a number of books that is
    /// not the number it would actually retry.
    public var failedBooks: [Book] {
        books.filter { if case .failed = $0.status { return true } else { return false } }
    }

    /// Puts one failed book back in the queue, reporting whether it took.
    ///
    /// Refused mid-run for the same reason as `relocateTools` and `setDefaultDestination`:
    /// `convertAll` snapshots its pending list at the start, so a book made `.ready` now
    /// would NOT join the run in progress — it would sit there looking queued while the
    /// footer counted down to a total that never included it. The UI disables the control,
    /// and this is the guard behind it, because a disabled control is not a rule.
    @discardableResult
    public func retry(_ book: Book) -> Bool {
        guard !isConverting else {
            scanMessage = "A conversion is running, so nothing can be retried yet. "
                        + "Cancel it first, or wait for it to finish, then retry."
            return false
        }
        return book.retry()
    }

    /// Sends a verified book's source MP3s to the Trash, reporting what happened.
    ///
    /// Never automatic and never part of converting: this runs only when the user has asked
    /// for it and confirmed a dialog naming the folder. Refused mid-run for the same reason
    /// as `retry`, `relocateTools` and `setDefaultDestination` — app state must not move
    /// under a conversion in flight, and this one would move a folder.
    ///
    /// `SourceReclaimer` does the checking, the trashing and the book's own bookkeeping;
    /// this reports the outcome in the footer, where every other refusal already appears.
    /// Refusals go there and NOT into `book.notes`: a note is permanent and the inspector
    /// lists notes by their own text, so a user who pressed the button twice would put two
    /// identical entries into a `ForEach(id: \.self)`.
    @discardableResult
    public func reclaimSource(of book: Book,
                              trashing: TrashOperation = SourceReclaimer.systemTrash) async -> Bool {
        guard !isConverting else {
            scanMessage = ReclaimRefusal.conversionRunning.message
            return false
        }
        guard let tools else {
            scanMessage = ReclaimRefusal.toolsMissing.message
            return false
        }
        do {
            let receipt = try await SourceReclaimer.reclaim(book, tools: tools,
                                                            trashing: trashing)
            scanMessage = "Reclaimed \(receipt.survey.formattedSize) from \(book.title): "
                        + "\(receipt.survey.folder.lastPathComponent) is in the Trash, "
                        + "not deleted."
            return true
        } catch let refusal as ReclaimRefusal {
            scanMessage = refusal.message
            return false
        } catch {
            scanMessage = "Nothing was moved: \(error.localizedDescription)"
            return false
        }
    }

    /// Every failed book at once, returning how many were actually returned to the queue.
    /// Through `retry(_:)` book by book, so the mid-run refusal and its wording exist in
    /// one place and cannot be enforced on one route and forgotten on the other.
    @discardableResult
    public func retryAllFailed() -> Int {
        failedBooks.filter { retry($0) }.count
    }

    public func convertAll() async { await queue?.convertAll(books) }

    /// Checks finished `.m4b` files the app did not create, read-only.
    ///
    /// Nothing here is compared against an expectation, because for these files there is
    /// none: `OutputVerifier` can say "this is not the book we just planned" only because
    /// the source MP3s were probed and decoded minutes earlier. `ExistingBookChecker` asks
    /// only what a file can be asked about itself, and this deliberately does not try to
    /// bridge the gap by guessing.
    ///
    /// Not refused during a conversion, unlike `retry`, `reclaimSource` and
    /// `setDefaultDestination`: those change app state under a run in flight, and this
    /// opens files for reading and moves nothing. What it does add is full-file decodes,
    /// which saturate cores — so its bound and the queue's are two shares of one
    /// `FFmpegBudget` rather than two numbers chosen independently.
    ///
    /// Every outcome is reported. A run refused because one is already going used to
    /// produce nothing at all: the user picked thirty files, the panel closed, and the
    /// window sat there unchanged.
    public func checkExistingBooks(_ urls: [URL]) async {
        guard let tools else {
            libraryCheckMessage = "ffmpeg could not be found, so nothing can be decoded. "
                                + "Set it up in the main window first."
            return
        }
        let files = ExistingBookChecker.collect(urls)
        guard !files.isEmpty else {
            libraryCheckMessage = "No .m4b files there. Note a folder that cannot be read "
                                + "looks the same as one holding none."
            return
        }
        libraryCheckMessage = nil
        guard await libraryCheck.run(files, tools: tools) else {
            libraryCheckMessage = "A check is already running, so those \(files.count) "
                                + "file(s) were not added to it. Wait for it to finish, or "
                                + "cancel it, and choose them again."
            return
        }
        if libraryCheck.isCancelled {
            libraryCheckMessage = "Cancelled. The books not marked with a verdict were "
                                + "not checked."
        }
    }
}
