import AppKit
import SwiftUI

/// The results of checking books the app did not make.
///
/// Deliberately the app's existing look and nothing more: the queue sidebar's status
/// symbols, the inspector's note styling, the footer's progress row. A separate surface
/// with its own vocabulary would make the same two ideas — this file's audio is wrong,
/// this file's tags are imperfect — look like different ideas depending on which window
/// they appeared in.
struct LibraryCheckView: View {
    static let windowID = "existing-books"

    let model: AppModel

    var body: some View {
        let check = model.libraryCheck
        Group {
            // `!isRunning` as well as empty: `run` sets `total` and `isRunning` at once
            // while the first result is minutes away for a large book, so keying on the
            // results alone put "No books checked yet" and a disabled Choose button
            // directly under a header reading "0 of 13" beside a Cancel button.
            if !check.isRunning && check.reports.isEmpty {
                ContentUnavailableView {
                    Label("No books checked yet", systemImage: "checkmark.seal")
                } description: {
                    Text("Choose .m4b files, or folders of them. Each one is decoded end "
                         + "to end and checked against what it claims about itself.")
                } actions: {
                    Button("Choose Files or Folders…") { choose() }
                        .disabled(model.tools == nil || check.isRunning)
                }
            } else {
                List {
                    ForEach(check.reports) { row($0) }
                }
                .listStyle(.inset)
            }
        }
        .safeAreaInset(edge: .top) { header }
        .frame(minWidth: 640, minHeight: 440)
        .navigationTitle("Existing Books")
    }

    // MARK: - header

    @ViewBuilder private var header: some View {
        let check = model.libraryCheck
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if check.isRunning {
                    ProgressView(value: Double(check.completed),
                                 total: Double(max(check.total, 1)))
                        .frame(maxWidth: 220)
                    Text("\(check.completed) of \(check.total)")
                        .font(.caption).monospacedDigit()
                    Button("Cancel", role: .destructive) { check.cancelAll() }
                        .controlSize(.small)
                } else if let summary = check.summary {
                    // Nil until something has been chosen: the empty state below already
                    // says so, and saying it twice reads as two different messages.
                    Text(summary).font(.callout)
                }
                Spacer()
                Button("Check More…") { choose() }
                    .disabled(model.tools == nil || check.isRunning)
                // Plain text, so a finding can be acted on outside this window. Left
                // enabled mid-run on purpose — a damage finding is worth copying the
                // moment it appears — which is only honest because `plainText` names the
                // run in progress and lists every file still waiting as not checked.
                Button("Copy") { copyReport() }
                    .disabled(check.reports.isEmpty)
                Button("Save…") { save() }
                    .disabled(check.reports.isEmpty)
            }
            if let message = model.libraryCheckMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundStyle(.secondary)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - one book

    @ViewBuilder private func row(_ report: ExistingBookReport) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                badge(report)
                Text(report.url.lastPathComponent).lineLimit(1)
                Spacer()
                Text(report.verdict).font(.caption).foregroundStyle(.secondary)
            }
            Text(report.url.path)
                .font(.caption).foregroundStyle(.secondary)
                .truncationMode(.middle).lineLimit(1)
                .textSelection(.enabled)
            if let line = durations(report) {
                Text(line).font(.caption).monospacedDigit()
                    .foregroundStyle(.secondary).textSelection(.enabled)
            }
            // Damage in red, findings in grey — the same distinction the conversion
            // already draws between a book that failed and a note on one that did not.
            ForEach(Array(report.fatalProblems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            ForEach(Array(report.cosmeticProblems.enumerated()), id: \.offset) { _, problem in
                Label(problem, systemImage: "info.circle")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder private func badge(_ report: ExistingBookReport) -> some View {
        if !report.wasChecked {
            Image(systemName: "minus.circle").foregroundStyle(.secondary)
        } else if !report.passed {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        } else if !report.cosmeticProblems.isEmpty {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        } else {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        }
    }

    /// Both numbers, always together: the whole check is the difference between them, and
    /// showing one alone invites the reader to trust it.
    ///
    /// With the shortfall spelled out in seconds when there is one, because `formatHours`
    /// rounds to the minute — an eight-hour book missing four seconds would otherwise print
    /// the same figure twice on a row flagged as damaged, which reads as a contradiction.
    private func durations(_ report: ExistingBookReport) -> String? {
        guard report.wasChecked else { return nil }
        let claimed = report.containerDuration.map { formatHours($0) } ?? "unknown"
        let decoded = report.decodedDuration.map { formatHours($0) } ?? "nothing"
        var line = "claims \(claimed), decodes \(decoded) · \(report.chapterCount) ch"
        if let container = report.containerDuration, let played = report.decodedDuration,
           container - played > 0.5 {
            line += String(format: " · short by %.2f s", container - played)
        }
        return line
    }

    // MARK: - actions

    private func choose() { LibraryCheckView.chooseAndCheck(model: model) }

    /// Files AND folders: the user is picking finished books, not folders of tracks, and
    /// one book is as reasonable a thing to check as a whole shelf. No content-type filter,
    /// because the answer to "that folder holds no .m4b files" belongs in the window as a
    /// sentence rather than as a folder that mysteriously will not open —
    /// `ExistingBookChecker.collect` does the filtering and `AppModel` says so.
    ///
    /// Shared with the File-menu command, which opens this window and then this panel.
    @MainActor
    static func chooseAndCheck(model: AppModel) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Choose .m4b files, or folders containing them"
        panel.prompt = "Check"
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await model.checkExistingBooks(urls) }
    }

    private func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.libraryCheck.plainText, forType: .string)
        model.libraryCheckMessage = "The report is on the clipboard."
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Existing Books.txt"
        panel.message = "Save the check results as plain text"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.libraryCheck.plainText.write(to: url, atomically: true, encoding: .utf8)
            model.libraryCheckMessage = "Saved to \(url.path)."
        } catch {
            model.libraryCheckMessage = "Could not save: \(error.localizedDescription)"
        }
    }
}

/// The File-menu item, as its own view so it can reach `openWindow` from the environment.
struct CheckExistingBooksCommand: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Check Existing Books…") {
            // The window first, so there is somewhere for a check that may take minutes to
            // report progress, and so a run already on screen is not hidden behind the
            // panel. The picker follows on the next turn of the main actor, or the modal
            // panel would run before the window had a chance to appear.
            openWindow(id: LibraryCheckView.windowID)
            Task { @MainActor in LibraryCheckView.chooseAndCheck(model: model) }
        }
        .keyboardShortcut("k", modifiers: [.command, .shift])
        .disabled(model.tools == nil || model.libraryCheck.isRunning)
    }
}
