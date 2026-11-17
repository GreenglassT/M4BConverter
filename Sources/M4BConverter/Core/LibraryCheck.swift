import Foundation
import Observation

/// One window's worth of the existing-books check: the files chosen so far, how far the run
/// in flight has got, and what was found — the same shape as `ConversionQueue`, and for the
/// same reasons.
///
/// **Bounded concurrency, because this decodes.** Every file is decoded end to end, which
/// is the only way to learn what is really in it, and an eight-hour book takes real time
/// even at 200× — a shelf of thirteen run one at a time is minutes of staring at a bar. The
/// bound is `FFmpegBudget.concurrentDecodes`, which is derived from the machine and shared
/// with the conversion queue. It used to be six, copied from `AppModel.probeConcurrently`;
/// that bound governs ffprobe metadata reads that take milliseconds, while these are full
/// decodes, and `AppModel.checkExistingBooks` allows a check alongside a conversion — so the
/// two "independent" bounds added up to nine processes saturating the cores.
///
/// **Results accumulate.** "Check More…" means more: a second run appends to the first
/// rather than replacing it, so someone who checks sixty books, reads two damage findings
/// and then adds another folder still has those two findings on screen. A file chosen again
/// is re-checked in its existing row rather than added twice.
///
/// **Nothing blocks the main actor.** The children are ordinary async process runs; this
/// class only collects their results, which is what makes the window stay live and the
/// Cancel button answer.
///
/// **Cancellation tells the truth.** Each file has its own `ProcessRunner`, so cancelling
/// really does kill the ffmpeg processes in flight, and any file whose result lands after
/// the cancel is reported as *not checked* rather than as sound or damaged — a terminated
/// decode looks exactly like a file that decoded short, and reporting that as damage would
/// invent a defect out of the user's own click.
@MainActor
@Observable
public final class LibraryCheck {
    /// One ffprobe and one ffmpeg per file, this many files at a time — the share of the
    /// app's ffmpeg budget left over once the conversion queue's is set aside.
    public static var maxConcurrent: Int { FFmpegBudget.concurrentDecodes }

    public private(set) var isRunning = false
    public private(set) var isCancelled = false
    /// How far the run in flight has got, of the files THAT run was given. Both are about
    /// the current run rather than the accumulated list, because that is what the header's
    /// progress bar is describing: what is happening now.
    public private(set) var completed = 0
    public private(set) var total = 0

    /// Every file this window has been asked about, in the order it was asked: the first
    /// run's choice, then whatever each "Check More…" added.
    private var files: [URL] = []
    /// One slot per file, addressed by index and empty until that file's check lands.
    ///
    /// Index-addressed rather than appended-and-sorted. Results arrive in whatever order
    /// concurrent decodes finish, and the list the user reads has to be the list they chose;
    /// storing each at its own index gets that for nothing, where sorting on every read cost
    /// an O(n log n) sort per access — and `summary` alone reads the results four times, on
    /// top of the window's `List` body reading them again per render.
    ///
    /// Empty means "no verdict": a file the run has not reached yet, one being decoded right
    /// now, or one a cancel stopped. That is why there is no fixup loop at the end of a run
    /// marking untouched files as not checked — an untouched slot already says so.
    private var slots: [ExistingBookReport?] = []
    /// Where each file already sits in `files`, by canonicalised path, so a file chosen
    /// twice is one row. Two rows for one file would also put two identical `id`s into the
    /// window's `ForEach`, which SwiftUI does not define behaviour for.
    private var indexByPath: [String: Int] = [:]

    /// The runner for each file in flight, keyed by its position in the RUN rather than in
    /// `files`: one run can be handed the same file twice, and two tasks sharing one key
    /// would leave the first runner in the dictionary's place — and so out of `cancelAll`'s
    /// reach, decoding a whole book that nobody can stop.
    private var runners: [Int: ProcessRunner] = [:]

    public init() {}

    /// The counts, read straight off the slots: an empty slot is a file with no verdict, so
    /// none of these needs the placeholder reports `reports` builds for the window.
    public var checkedCount: Int { slots.count { $0?.wasChecked == true } }
    public var damagedCount: Int {
        slots.count { $0?.wasChecked == true && $0?.passed == false }
    }
    public var findingCount: Int {
        slots.count { $0?.passed == true && $0?.cosmeticProblems.isEmpty == false }
    }

    /// Results in the order the files were given, not the order they finished, with a file
    /// that has no verdict yet standing in as "not checked" — which is what it is, whether
    /// the run has not reached it, is decoding it now, or was cancelled before it landed.
    public var reports: [ExistingBookReport] {
        zip(files, slots).map { url, report in report ?? .notChecked(url) }
    }

    /// One line of counts, nil before anything has been chosen. Shared by the window's
    /// header and the exported text, so what someone reads on screen and what they paste
    /// into a note cannot disagree about what was found.
    public var summary: String? {
        guard !files.isEmpty else { return nil }
        let checked = checkedCount
        let damaged = damagedCount
        let findings = findingCount
        var parts = ["\(checked - damaged) sound"]
        if findings > 0 { parts[0] += " (\(findings) with findings)" }
        parts.append("\(damaged) damaged")
        let unchecked = files.count - checked
        if unchecked > 0 { parts.append("\(unchecked) not checked") }
        return parts.joined(separator: ", ")
    }

    public func cancelAll() {
        guard isRunning else { return }
        isCancelled = true
        for runner in runners.values { runner.terminate() }
        runners.removeAll()
    }

    /// Checks `urls`, adding them to whatever this window already holds.
    ///
    /// Returns false when the run was refused because one is already going — the caller owes
    /// the user a sentence, exactly as `AppModel.setDefaultDestination` and `relocateTools`
    /// do for their own refusals. Picking thirty files and having nothing happen at all is
    /// the app losing someone's request without saying so.
    @discardableResult
    public func run(_ urls: [URL], tools: FFmpegTools) async -> Bool {
        // No suspension point before this guard, so it is atomic on the main actor: a
        // second Check cannot start while the first is still going.
        guard !isRunning else { return false }
        // Nothing chosen is not a refusal, and emphatically not a reason to throw away
        // results already on screen.
        guard !urls.isEmpty else { return true }

        isRunning = true
        isCancelled = false
        completed = 0
        total = urls.count
        defer { isRunning = false; runners.removeAll() }

        // Where each of this run's files sits in the accumulated list. A file already there
        // is re-checked in its own row: its previous verdict is cleared, because the check
        // being run now is the one whose answer that row will carry.
        let targets = urls.map { url -> Int in
            let key = url.resolvingSymlinksInPath().standardized.path
            if let existing = indexByPath[key] {
                slots[existing] = nil
                return existing
            }
            indexByPath[key] = files.count
            files.append(url)
            slots.append(nil)
            return files.count - 1
        }

        await runConcurrently(count: urls.count, limit: Self.maxConcurrent) { index in
            // A runner per file: `ProcessRunner` tracks one process at a time, so a
            // shared one would leave all but one of the decodes in flight unkillable,
            // and one `terminate()` would set its sticky flag and fail every later run
            // made through it.
            let runner = ProcessRunner()
            self.runners[index] = runner
            let url = urls[index]
            return {
                let checker = ExistingBookChecker(tools: tools, runner: runner)
                // A throw here means no verdict was reached — a cancelled runner, a
                // binary that vanished, a decode killed partway — not that the file is
                // bad. Report that it was not checked rather than inventing damage out
                // of something that went wrong on this machine.
                guard let report = try? await checker.check(url) else {
                    return ExistingBookReport.notChecked(url)
                }
                return report
            }
        } onResult: { index, report in
            self.runners[index] = nil
            let slot = targets[index]
            // A result arriving after the cancel came from a process that was killed
            // mid-decode, whatever it says. Leave the slot empty, which reads as not
            // checked — because it was not.
            if !self.isCancelled { self.slots[slot] = report }
            self.completed += 1
            // And stop dispatching: files this run never started keep their empty slots,
            // and are reported as not checked for the same reason.
            return !self.isCancelled
        }

        return true
    }

    /// The whole result as plain text, so a finding can leave the app: pasted into a note,
    /// mailed, or kept beside the file it is about. Damage first, because that is the part
    /// worth someone's afternoon.
    ///
    /// A copy taken mid-run says so, twice over: every file still waiting is listed as not
    /// checked, and the line below names the run in progress. This used to print "checked 8
    /// file(s)" and a summary of eight while fifty-two books — possibly including damaged
    /// ones — were simply absent from the page, which reads as a finished audit of a
    /// small shelf.
    public var plainText: String {
        let reports = self.reports
        var lines = ["M4B Converter — \(reports.count) file(s)"]
        if let summary { lines.append(summary) }
        if isRunning {
            lines.append("This run is still going — \(completed) of \(total) file(s) "
                         + "checked so far — so this report is not finished.")
        }
        if isCancelled { lines.append("This run was cancelled before it finished.") }

        // Partitioned rather than sorted: `sort` is not stable, and within each half the
        // order the user chose is the order they will look for.
        for report in reports.filter({ !$0.passed }) + reports.filter(\.passed) {
            lines.append("")
            lines.append("\(report.verdict.uppercased())  \(report.url.lastPathComponent)")
            lines.append("  \(report.url.path)")
            if let claimed = report.containerDuration {
                let decoded = report.decodedDuration
                    .map { String(format: "%.2f s decoded", $0) } ?? "nothing decoded"
                lines.append(String(format: "  container %.2f s, %@", claimed, decoded))
            }
            if report.wasChecked {
                lines.append("  \(report.chapterCount) chapter(s), "
                             + "\(report.hasCover ? "cover" : "no cover"), "
                             + "\(report.isAudiobook ? "media_type 2" : "media_type not 2")")
            }
            for problem in report.fatalProblems { lines.append("  DAMAGE: \(problem)") }
            for problem in report.cosmeticProblems { lines.append("  finding: \(problem)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
