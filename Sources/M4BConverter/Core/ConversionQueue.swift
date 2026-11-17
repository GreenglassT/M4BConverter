import Foundation
import Observation

@MainActor
@Observable
public final class ConversionQueue {
    /// `nonisolated` because `FFmpegBudget` reserves this share for the queue, and that is
    /// a fact about the machine rather than about anything on the main actor.
    public nonisolated static let maxConcurrent = 3

    public private(set) var isRunning = false
    public private(set) var completed = 0
    public private(set) var total = 0

    let tools: FFmpegTools

    private var runners: [UUID: ProcessRunner] = [:]
    public private(set) var isCancelled = false

    /// Output paths a run in flight has taken but not yet created on disk. Deduplicating
    /// by `Book.ID` is not enough: `Book.outputURL` is a directory plus the album title,
    /// so an ordinary multi-disc rip (`Ivanhoe/Disc 1`, `Ivanhoe/Disc 2`) yields two
    /// distinct books with one output path. Run concurrently, both preflights see no file
    /// there, both encode with `-y`, and whichever verify lands last calls the resulting
    /// mess good — under `.replace` on top of a pre-existing file.
    ///
    /// A chosen save location makes that far more likely rather than introducing anything
    /// new: two books in unrelated source folders used to differ by their parents alone,
    /// and pointing both at one directory leaves only the title to tell them apart. The
    /// claim below and the collision policy handle it unchanged.
    private var claimedOutputs: Set<URL> = []

    /// How the `.replace` swap sends the file it replaced to the Trash.
    ///
    /// `SourceReclaimer.systemTrash` by default — the same four lines the reclaim uses, so
    /// there is one function in the app that moves a file to the Trash and answers where it
    /// landed, rather than two hand-rolled copies of `trashItem(at:resultingItemURL:)`.
    /// Injected for the same reason it is injected there: the outcome can be observed
    /// without a disk image, and a test that really does trash something can take it back
    /// out afterwards by the path it was actually given rather than by a guess at the name
    /// macOS chose.
    let trashing: TrashOperation

    public init(tools: FFmpegTools,
                trashing: @escaping TrashOperation = SourceReclaimer.systemTrash) {
        self.tools = tools
        self.trashing = trashing
    }

    public func cancelAll() {
        isCancelled = true
        for runner in runners.values { runner.terminate() }
        runners.removeAll()
    }

    public func convertAll(_ books: [Book]) async {
        // No suspension point before this guard, so it is atomic on the main actor: a
        // second call cannot slip past while the first is running.
        guard !isRunning else { return }
        isCancelled = false
        // Deduplicate by identity as well as filtering: the same Book appearing twice in
        // one array would otherwise start two pipelines writing the same output path
        // concurrently, and whichever verify ran last could report a corrupted file as
        // good. A status filter alone does not catch this — both entries are still
        // `.ready` at the moment the filter runs.
        var seen = Set<Book.ID>()
        let pending = books.filter { book in
            guard !book.status.isTerminal, book.status != .converting else { return false }
            return seen.insert(book.id).inserted
        }
        guard !pending.isEmpty else { return }

        isRunning = true
        completed = 0
        total = pending.count
        defer { isRunning = false }

        await runConcurrently(count: pending.count, limit: Self.maxConcurrent) { index in
            let book = pending[index]
            return { await self.convert(book) }
        } onResult: { _, _ in
            self.completed += 1
            // Stop dispatching once cancelled: otherwise every remaining book
            // returns instantly at the guard and still counts, so the footer would
            // read "9 of 9" when nothing actually converted. The stopping lives in
            // `runConcurrently` now, so the other two callers get it too.
            return !self.isCancelled
        }
    }

    func convert(_ book: Book) async {
        guard !isCancelled else { return }
        book.status = .converting
        book.progress = 0
        book.notes = []
        book.written = nil
        book.log = ""

        let runner = ProcessRunner()
        runners[book.id] = runner
        defer { runners[book.id] = nil }

        // The path THIS run is writing. Hoisted above the do/catch so cleanup can never
        // delete a pre-existing file that merely shares the book's canonical name — the
        // exact bug that made a cancelled `.keepBoth` run destroy the file it was
        // protecting.
        var writing: URL?
        // Set for `.replace`: the original to swap over, only once the new file verifies.
        var replacing: URL?
        func discardPartialOutput() {
            if let writing { try? FileManager.default.removeItem(at: writing) }
        }
        /// Either half of the `.replace` swap failing says the same three things: the
        /// conversion itself worked, nothing was deleted, and here is where each file is
        /// now. One template, so the promise not to delete anything cannot be made in one
        /// of them and forgotten in the other.
        func swapFailed(couldNot what: String, _ error: Error, leaving whereabouts: String) {
            let message = "Converted successfully, but could not \(what): "
                        + "\(error.localizedDescription) Nothing was deleted — \(whereabouts)"
            book.status = .failed(message)
            book.log = message
        }

        // Paths this run owns for as long as it lasts, released however it ends.
        var claimed: Set<URL> = []
        defer { claimedOutputs.subtract(claimed) }

        do {
            // 1. exact durations
            let measurer = DurationMeasurer(tools: tools, runner: runner)
            let ordered = book.orderedTracks
            var durations: [Double] = []
            var noisyFiles = 0
            for track in ordered {
                let measurement = try await measurer.measure(track)
                durations.append(measurement.duration)
                if measurement.hadBenignTagNoise { noisyFiles += 1 }
            }
            // Deliberately no figure for the loss. This used to say "About 17 ms is lost
            // at each chapter end" — a number derived from an MP3 frame's length, not
            // from anything the app measured, and stated to the user as if it had been.
            // What IS measured is above: every file's decoded length was checked against
            // its container's own duration, and any file materially short of it threw
            // rather than reaching here.
            if noisyFiles > 0 {
                book.notes.append(
                    "\(noisyFiles) file(s) end with an ID3v1 tag, which ffmpeg reports as "
                    + "one undecodable packet each. Every file was checked against the "
                    + "duration its container claims, and none decoded materially short "
                    + "of it.")
            }
            let totalDuration = durations.reduce(0, +)

            // 2. chapters from exact durations — unless the user edited them, in which
            // case their list is what converts, fitted to the measured length.
            let chapters = try book.conversionChapters(tracks: ordered, durations: durations)
            // The exact chapters are now known; show those rather than the estimates
            // computed from container metadata at scan time. An edited list is left alone,
            // which `Book` decides rather than this line — see `showMeasuredChapters`.
            book.showMeasuredChapters(chapters)

            // 3. pre-flight
            var job = book.makeJob(tracks: ordered, chapters: chapters,
                                   totalDuration: totalDuration)
            let report = Preflight.report(for: job.outputURL,
                                          bitRate: job.bitRate, duration: totalDuration)
            // Writability first, and before a single frame is encoded. Under the default
            // `.besideSource` the destination is the PARENT of the book folder, so a book
            // dropped from a read-only volume aims at that volume's root; under a chosen
            // save location the folder may have been unmounted or deleted since it was
            // picked. Either way, finding out when the finished file cannot be written
            // wastes the whole conversion.
            //
            // The advice has to match the destination the book actually has, or a user who
            // set a save location is told to move their source files — which would not help
            // and is not where the file was going.
            guard report.isWritable else {
                let destination = job.outputURL.deletingLastPathComponent()
                // The same diagnosis the user gets when they PICK a folder, rather than a
                // second wording of it — `OutputDestination.problem` asks this too.
                let cause = Preflight.writeProblem(at: destination)
                    ?? "\(destination.path) cannot be written to."
                let advice: String
                switch book.destination {
                case .besideSource:
                    advice = "The .m4b is written beside the book's folder, so copy the "
                           + "book somewhere writable — or choose a save location in "
                           + "Settings — and try again."
                case .fixed:
                    advice = "That is this book's save location; pick a different folder "
                           + "in Settings, or for this book in the inspector, and try again."
                }
                book.status = .failed("Cannot write the finished book. \(cause) \(advice)")
                return
            }
            guard report.hasEnoughSpace else {
                let needed = ByteCountFormatter.string(fromByteCount: report.estimatedBytes,
                                                       countStyle: .file)
                let free = ByteCountFormatter.string(fromByteCount: report.freeBytes,
                                                     countStyle: .file)
                book.status = .failed("Not enough disk space: needs about \(needed), \(free) free")
                return
            }
            // A path is unavailable if something is already there OR another run in this
            // batch has claimed it. `convert` is @MainActor and nothing below suspends
            // before the claim is recorded, so this check-then-claim is atomic and a
            // plain Set suffices — do not introduce an `await` inside this window.
            if report.outputExists || claimedOutputs.contains(job.outputURL.standardizedFileURL) {
                switch book.collisionPolicy {
                case .skip:
                    book.status = .failed("Skipped: \(job.outputURL.lastPathComponent) already exists")
                    return
                case .keepBoth:
                    job.outputURL = Preflight.uniqueURL(for: job.outputURL,
                                                        avoiding: claimedOutputs)
                    book.notes.append("Saved as \(job.outputURL.lastPathComponent) "
                                      + "to avoid overwriting an existing file.")
                case .replace:
                    // Two books cannot both replace one original. `claimedOutputs` stops
                    // them writing the same file, but under `.replace` there is no
                    // alternative target to fall back to: each would encode to its own
                    // "(converting)" file and swap onto the same original in turn, so the
                    // loser's conversion is discarded while its `writtenURL` points at
                    // audio the other book produced. Refuse to start; an explicit failure
                    // beats silently throwing away an hour of encoding.
                    guard !claimedOutputs.contains(job.outputURL.standardizedFileURL) else {
                        book.status = .failed(
                            "Another book in this run is already replacing "
                            + "\(job.outputURL.lastPathComponent). Give the books different "
                            + "titles so each one has its own file.")
                        return
                    }
                    // Never delete the original up front. If the conversion then fails or
                    // is cancelled the user would be left with neither file — silent loss
                    // of something that may have taken an hour to produce. Write beside
                    // it and swap only after the new file has verified.
                    replacing = job.outputURL
                    let stem = job.outputURL.deletingPathExtension().lastPathComponent
                    job.outputURL = Preflight.uniqueURL(
                        for: job.outputURL.deletingLastPathComponent()
                            .appendingPathComponent("\(stem) (converting).m4b"),
                        avoiding: claimedOutputs)
                }
            }
            // Claim the resolved path, plus the original under `.replace` — the file that
            // is about to be swapped over is no more available to another run than the
            // one being written.
            claimed.insert(job.outputURL.standardizedFileURL)
            if let replacing { claimed.insert(replacing.standardizedFileURL) }
            claimedOutputs.formUnion(claimed)
            writing = job.outputURL

            // 4. encode
            _ = try await FFmpegBackend(tools: tools, runner: runner).convert(job) { value in
                // Each update hops to the main actor as its own task, and detached tasks
                // carry no ordering guarantee between them — so clamp at the sink too,
                // not only at the source in MonotonicProgress.
                Task { @MainActor in if value > book.progress { book.progress = value } }
            }
            guard !isCancelled else {
                discardPartialOutput()
                // `idleStatus`, not `.ready`: a book with warnings that is cancelled must
                // come back wearing the badge it had before the run, or the sidebar
                // quietly disagrees with the warnings still listed in the inspector.
                book.status = book.idleStatus
                return
            }

            // 5. verify. A cover is only expected when one was actually available —
            // either a file in the book folder, or art embedded in the tracks that the
            // backend extracts. A book with no artwork anywhere must not be called failed.
            //
            // Runs through the book's registered runner, like the measurement and the
            // encode above. With a default runner of its own, this ffprobe was not
            // reachable from `cancelAll()`: cancelling or quitting during verification
            // could not kill it, and the quit handler then waited on it.
            let expectCover = job.coverImage != nil || ordered.first?.embeddedArtCodec != nil
            let verification = try await OutputVerifier(tools: tools, runner: runner)
                .verify(job.outputURL, expectedChapters: chapters.count,
                        expectedDuration: totalDuration, expectedCover: expectCover)

            // Distinguish "this book has no artwork" from "the art was there and could
            // not be extracted" — the second is an anomaly worth explaining, and would
            // otherwise surface only as the verifier's generic cover message.
            if !verification.hasCover, job.coverImage == nil,
               ordered.first?.embeddedArtCodec != nil {
                book.notes.append("Cover art is embedded in the source files but could not be extracted.")
            }

            if verification.passed {
                if let replacing {
                    // Swap now that the new file is known good, moving the file being
                    // replaced to the Trash rather than deleting it.
                    //
                    // `replaceItemAt(_:withItemAt:)` with no `backupItemName` deletes the
                    // item it replaces, unrecoverably. That was survivable while `.replace`
                    // could only ever reach the source folder's parent, where the file it
                    // hit was almost certainly this app's own earlier output. With a chosen
                    // save location it can reach anything in the user's library that
                    // happens to share a title, and the user picked a policy called
                    // "Replace" — not "destroy whatever is in the way".
                    //
                    // The cost is that a volume with no Trash now refuses the swap instead
                    // of completing it. That is the right way round: it keeps both files
                    // and names them, which the user can finish by hand in a second, and
                    // it never silently destroys a file this app did not create.
                    var trashed: URL?
                    do {
                        trashed = try trashing(replacing)
                    } catch {
                        // Delete NOTHING here. The old fallback removed the original and
                        // then moved the new file into place with two `try?` calls: with a
                        // read-only parent every call failed and the book still reported
                        // `.verified` while pointing at the old unconverted file, and when
                        // `replaceItemAt` had already consumed its source (which Apple
                        // documents it may do before throwing) the remove succeeded, the
                        // move failed, and the folder was left empty. Losing the swap is an
                        // inconvenience; losing the original is the thing this code exists
                        // to prevent. Leave both files exactly where they are and name them
                        // both so the user can finish it by hand.
                        swapFailed(couldNot: "replace \(replacing.path)", error,
                                   leaving: "the original is untouched and the new file "
                                          + "is at \(job.outputURL.path)")
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: job.outputURL, to: replacing)
                    } catch {
                        // The window between the two steps. Nothing is lost — the file
                        // that was there is in the Trash and the conversion is on disk
                        // under its "(converting)" name — but the user has to be told
                        // where both of them are, or they will go looking for a file that
                        // is not where either of its names says.
                        let previous = trashed?.path ?? "the Trash"
                        swapFailed(couldNot: "move the new file onto \(replacing.path)",
                                   error,
                                   leaving: "the file that was there is in the Trash at "
                                          + "\(previous), and the new file is at "
                                          + "\(job.outputURL.path)")
                        return
                    }
                    book.notes.append(
                        "Replaced \(replacing.lastPathComponent). The file that was there "
                        + "is in the Trash, not deleted.")
                }
                // Report the path the user should go looking for. Under `.replace` that
                // is the original name just swapped onto, not the "(converting)" file
                // this run encoded into and that no longer exists.
                //
                // With what was written into it, recorded here because here is the only
                // place both numbers are known to be true of the file: these are the two
                // the verify above just passed on. `SourceReclaimer` repeats that verify
                // before it trashes anything, and it has to repeat it with the run's own
                // figures — the book's live chapter list is still assignable afterwards,
                // and a reclaim whose evidence the window can move is not evidence.
                book.written = WrittenOutput(url: replacing ?? job.outputURL,
                                             chapterCount: chapters.count,
                                             duration: totalDuration)
                book.status = .verified
                book.progress = 1
                // Cosmetic problems keep the file — the audio is complete and correct —
                // but they are still worth naming. Silently verifying a book whose cover
                // never made it would leave the user to discover that in their player.
                for problem in verification.cosmeticProblems {
                    book.notes.append("\(problem). The audio is complete and correct; "
                                      + "this affects only how the file is presented.")
                }
            } else {
                // Delete the file that failed to verify. Leaving it turns a loud failure
                // into a quiet one: a complete-looking .m4b sits in the library next to
                // the good copy, and the next run with `.skip` skips this book on the
                // strength of a file the app never certified. `writing` is only ever a
                // path THIS run created, so removing it cannot touch the user's own.
                //
                // Only FATAL problems reach here: `passed` is `fatalProblems.isEmpty`.
                // Deleting on a cosmetic problem destroyed hours of finished encoding
                // because a tag was missing.
                discardPartialOutput()
                // One list, two renderings: the status is a single line for the sidebar
                // and the inspector's label, the log gives each problem its own line.
                let problems = verification.problems
                book.status = .failed(problems.joined(separator: "; "))
                book.log = problems.joined(separator: "\n")
            }
        } catch {
            // Unconditional: the old `replacing != nil` guard let every `.keepBoth` and
            // no-collision failure leak its half-written file. The invariant above holds
            // for all of them — `writing` is a path this run created — so the guard was
            // never protecting anything.
            discardPartialOutput()
            if isCancelled {
                // Same as the guard above: the status a cancelled book returns to is the
                // one it would have had if it had never started, warnings and all.
                book.status = book.idleStatus
            } else {
                book.status = .failed(failureSummary(for: error))
                book.log = failureLog(for: error)
            }
        }
    }
}

/// The full detail of a failure, for the inspector's log.
///
/// `ProcessError.failed` already carries ffmpeg's stderr, and that is the first thing
/// anyone wants when a conversion fails — it says which file, which stream and what the
/// decoder made of it. Both the status and the log used to be `error.localizedDescription`,
/// which for that case is one string with the whole dump embedded: the red label carried
/// hundreds of lines and the log below it repeated them, so the disclosure group showed
/// nothing that was not already on screen. Keep the raw output here and summarise it there.
func failureLog(for error: Error) -> String {
    guard case ProcessError.failed(let code, let stderr) = error else {
        return error.localizedDescription
    }
    let output = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !output.isEmpty else { return "ffmpeg exited \(code), writing nothing to stderr." }
    return "ffmpeg exited \(code)\n\n" + tailOfOutput(output)
}

/// The one line for the red failure label and the sidebar.
func failureSummary(for error: Error) -> String {
    guard case ProcessError.failed(let code, let stderr) = error else {
        return error.localizedDescription
    }
    // ffmpeg's verdict is its last line; everything above it is usually the same
    // decoder complaint repeated once per bad frame.
    guard let last = stderr.split(whereSeparator: \.isNewline)
        .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
        return "ffmpeg exited \(code), writing nothing to stderr."
    }
    let line = last.count > 200 ? String(last.prefix(200)) + "…" : String(last)
    return "ffmpeg exited \(code). \(line) The log below has ffmpeg's full output."
}

/// The last `maxLines` lines of `text`, and at most `maxBytes` of them.
///
/// The tail, not the head. ffmpeg states what actually went wrong on its final line and
/// can precede it with thousands of repeats of one message — an undecodable file produced
/// 130+ "Header missing" lines in testing — so truncating from the end would throw away
/// the only line worth reading. Whatever is dropped is named rather than silently lost.
func tailOfOutput(_ text: String, maxLines: Int = 200, maxBytes: Int = 16 * 1024) -> String {
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    var kept: [Substring] = []
    var bytes = 0
    for line in lines.reversed() {
        let cost = line.utf8.count + 1
        // `kept.isEmpty` keeps one line however long it is: a result of nothing at all
        // would be worse than an oversized one, and the clamp below bounds it anyway.
        guard kept.count < maxLines, bytes + cost <= maxBytes || kept.isEmpty else { break }
        kept.append(line)
        bytes += cost
    }
    var tail = kept.reversed().joined(separator: "\n")
    if tail.utf8.count > maxBytes { tail = "…" + String(tail.suffix(maxBytes)) }
    let omitted = lines.count - kept.count
    guard omitted > 0 else { return tail }
    return "[\(omitted) earlier line\(omitted == 1 ? "" : "s") omitted]\n" + tail
}
