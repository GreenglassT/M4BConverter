import AppKit
import SwiftUI

struct BookInspector: View {
    @Bindable var book: Book
    /// Needed for Retry: `AppModel` owns both the mid-run guard and the "all of them"
    /// variant, so the inspector asks it rather than reaching into the book directly.
    let model: AppModel
    /// Why the folder the user just picked for THIS book was refused. Kept here rather
    /// than on the book: it is about the picking, not about the book, and it goes away as
    /// soon as a usable folder is chosen.
    @State private var destinationProblem: String?
    /// A change that would throw hand-edited chapters away, waiting to be confirmed.
    @State private var regeneration: ChapterRegeneration?
    /// A request to send this book's source MP3s to the Trash, being counted or waiting to
    /// be confirmed.
    @State private var reclaim = ReclaimRequest()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                CoverThumbnail(url: book.coverImage)
                VStack(spacing: 6) {
                    TextField("Title", text: $book.title)
                    HStack {
                        TextField("Author", text: $book.author)
                        TextField("Year", text: $book.year).frame(width: 70)
                    }
                }
                .textFieldStyle(.roundedBorder)
                // The title decides the output path and the metadata, both of which the
                // running conversion has already read — and which a reclaimed book will
                // never write again.
                .disabled(!book.acceptsEdits)
            }

            // The reason and the remedy together. A failure that is transient — a full
            // disk, a save location that had been unmounted, an ffmpeg hiccup — is fixed
            // outside the app and then needs one click here; without it the only route
            // back was Remove and re-drop, which loses every setting on this pane.
            if case let .failed(message) = book.status {
                VStack(alignment: .leading, spacing: 8) {
                    Label(message, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red).font(.callout)
                        .textSelection(.enabled)
                    HStack(spacing: 12) {
                        Button("Retry", systemImage: "arrow.clockwise") { model.retry(book) }
                        // More than this one to put back, so offer the lot from here too
                        // rather than making the user visit each book in turn.
                        let failed = model.failedBooks.count
                        if failed > 1 {
                            Button("Retry All \(failed) Failed") { model.retryAllFailed() }
                                .buttonStyle(.link)
                        }
                    }
                    // Same guard as the pickers below, and the one `AppModel.retry`
                    // enforces: `convertAll` snapshots its pending list at the start, so a
                    // book returned to `.ready` now would not join the run in progress.
                    .disabled(model.isConverting)
                }
            }

            // The failure detail the run recorded. The status label above summarises it
            // on one line; a verification failure lists each problem on its own, and a
            // failed encode puts ffmpeg's own stderr here — up to 200 lines of it, which
            // only reads properly in a monospaced, selectable, and above all SCROLLING
            // box. Without the fixed height the group expands to whatever ffmpeg said
            // and pushes the chapter table and the output path off the window.
            if !book.log.isEmpty {
                DisclosureGroup("Show log") {
                    ScrollView {
                        Text(book.log)
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.trailing, 4)
                    }
                    .frame(maxHeight: 220)
                }
                .font(.callout)
            }

            ForEach(book.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }

            ForEach(book.notes, id: \.self) { note in
                Label(note, systemImage: "info.circle")
                    .foregroundStyle(.secondary).font(.callout)
            }

            HStack(spacing: 20) {
                // `Book` recomputes its ordering, chapters and warnings whenever one of
                // these is assigned, so no picker needs its own `.onChange`. Neither is
                // bound straight to the model, though: see `orderSelection`.
                Picker("Order", selection: orderSelection) {
                    ForEach(OrderStrategy.allCases) { Text($0.label).tag($0) }
                }

                Picker("Chapters", selection: chapterSelection) {
                    ForEach(Array(Self.chapterChoices.enumerated()), id: \.offset) { index, choice in
                        Text(choice.label).tag(index)
                    }
                }

                Picker("If output exists", selection: $book.collisionPolicy) {
                    ForEach(CollisionPolicy.allCases) { Text($0.label).tag($0) }
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 620)
            // A conversion reads the ordering once, then measures durations and plans
            // chapters from that snapshot. Changing Order mid-run would otherwise attach
            // chapters computed for one ordering to audio concatenated in another —
            // chapter count and duration still match, so the verifier passes and the
            // wrong file is marked verified. A reclaimed book has no audio to order.
            .disabled(!book.acceptsEdits)

            HStack(spacing: 8) {
                Text("Save to")
                Menu(book.outputURL.deletingLastPathComponent().path) {
                    // Naming the resolved folder rather than just "Default" — otherwise
                    // the user has to open Settings to find out what they would be
                    // choosing.
                    Button("Default (\(book.defaultDestination.directory(forSource: book.folder).path))") {
                        book.destinationOverride = nil
                        destinationProblem = nil
                    }
                    Button("Beside source folder") {
                        book.destinationOverride = .besideSource
                        destinationProblem = nil
                    }
                    Button("Choose…") { chooseDestination() }
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 420, alignment: .leading)
            }
            .font(.callout)
            // Same guard as the pickers above: the conversion resolved `outputURL` at
            // preflight and has claimed that path. Moving the destination mid-run would
            // leave the inspector naming a folder the file is not being written to, and
            // for a reclaimed book there is no run left for it to describe.
            .disabled(!book.acceptsEdits)

            if let destinationProblem {
                Label(destinationProblem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Text("\(book.chapters.count) chapters · \(formatHours(book.totalDuration)) · \(book.tracks.count) files")
                    .font(.caption).foregroundStyle(.secondary)
                // Which of the two the list is has to be visible, or a book whose chapters
                // no longer follow the Chapters picker looks like the picker is broken —
                // and the way back out is not discoverable.
                if book.hasManualChapters {
                    // Tinted, not orange: this is a state the user chose, not a warning
                    // about their book. Orange in this window means "something here needs
                    // your attention before you convert".
                    Label("edited by hand", systemImage: "square.and.pencil")
                        .font(.caption).foregroundStyle(.tint)
                    Button("Revert to Automatic") { confirmRevert() }
                        .buttonStyle(.link).font(.caption)
                        .disabled(!book.acceptsEdits)
                }
            }

            ChapterTable(book: book)

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                // Once a run has written a file, name that file: `outputURL` is derived from
                // the title and would contradict the "Saved as …" note after a keepBoth run.
                Text(book.writtenURL.map { "Written to: \($0.path)" }
                     ?? "Output: \(book.outputURL.path)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Spacer(minLength: 0)
                // Offered only for a verified book, and only ever as a separate deliberate
                // act — never as part of converting. Beside the path on purpose: what makes
                // this safe to do is the file named to its left.
                if book.isReclaimable {
                    Button("Reclaim Source MP3s…", systemImage: "trash") {
                        reclaim.ask(about: book, in: model.books)
                    }
                    // The same mid-run guard as Retry and the pickers, and
                    // `AppModel.reclaimSource` refuses too — this is only how the user
                    // sees it. Also while the folder is being counted: the dialog cannot
                    // be raised until that finishes, so without this the button would
                    // look dead for as long as a slow volume takes to answer.
                    .disabled(model.isConverting || reclaim.isSurveying)
                    // The only thing on screen between the press and the dialog on a
                    // folder big enough to notice.
                    if reclaim.isSurveying {
                        ProgressView().controlSize(.small)
                    }
                }
            }
        }
        .padding(16)
        .navigationTitle(book.title)
        // Nothing has been applied at the point this appears, and nothing is applied if it
        // is dismissed: the model, and therefore the picker, is still exactly as it was.
        .confirmationDialog("Discard your chapter edits?",
                            isPresented: Binding(get: { regeneration != nil },
                                                 set: { if !$0 { regeneration = nil } }),
                            presenting: regeneration) { pending in
            Button(pending.confirm, role: .destructive) {
                pending.apply()
                regeneration = nil
            }
            Button("Keep My Edits", role: .cancel) { regeneration = nil }
        } message: { pending in
            Text(pending.message)
        }
        .reclaimConfirmation(reclaim, model: model)
        // This view is not rebuilt when the selection changes: `ContentView` puts it at one
        // place in the tree with no `.id`, so SwiftUI keeps its `@State` and re-renders it
        // around a different book. Everything else on this pane reads from `book` and
        // follows along; a reclaim already counting does not, and would arrive as a dialog
        // about the previous book over an inspector showing this one.
        .onChange(of: book.id) { reclaim.abandon() }
    }

    /// A change that would replace hand-edited chapters with generated ones, held until
    /// the user says yes.
    ///
    /// Held, not applied and then undone. A `Picker` bound straight to `book.order` writes
    /// the new value before anything here can react — and `Book`'s `didSet` recomputes the
    /// ordering, the chapters and the warnings from it on the way past — so "revert it on
    /// cancel" would mean the book had genuinely changed and changed back, twice per
    /// mistaken click. Both pickers go through bindings whose setters put the change here
    /// instead; the getters still read the model, so the control snaps back on its own.
    private struct ChapterRegeneration: Identifiable {
        let id = UUID()
        let confirm: String
        let message: String
        let apply: () -> Void
    }

    private func confirmRevert() {
        regeneration = ChapterRegeneration(
            confirm: "Revert to Automatic",
            message: "This book's chapters were edited by hand. Reverting rebuilds them "
                   + "from \(book.chapterStrategy.label), and your edits — titles, "
                   + "boundaries, merges and splits — are not kept.",
            apply: { book.revertToAutomaticChapters() })
    }

    /// Assigns straight through when the chapters are the strategy's own, and asks first
    /// when they are the user's.
    private var orderSelection: Binding<OrderStrategy> {
        Binding(
            get: { book.order },
            set: { newValue in
                guard newValue != book.order else { return }
                // The rule behind the picker's `.disabled(!book.acceptsEdits)`, because a
                // disabled control is not a rule — the sentence this file repeats and this
                // was the one binding it did not hold for. `adoptOrder` below refuses for
                // itself; the plain assignment on this path did not, so a book that reached
                // `.converting` or a terminal state with the menu already open could still
                // be re-ordered, and mid-run that attaches chapters computed for one
                // ordering to audio concatenated in another.
                guard book.acceptsEdits else { return }
                guard book.hasManualChapters else {
                    book.order = newValue
                    return
                }
                regeneration = ChapterRegeneration(
                    confirm: "Change Order",
                    message: "This book's chapters were edited by hand. Changing the file "
                           + "order changes where every chapter falls in the audio, so the "
                           + "list is rebuilt from \(book.chapterStrategy.label) and your "
                           + "edits are not kept.",
                    apply: { book.adoptOrder(newValue) })
            }
        )
    }

    /// `ChapterStrategy` carries an associated value, so it is not `CaseIterable` and the
    /// picker offers these three representatives instead. The selection is their index:
    /// tagging with the values themselves would leave the picker showing nothing for a
    /// `.filenamePattern` whose pattern is not the default one.
    private static let chapterChoices: [ChapterStrategy] = [
        .overdriveMarkers,
        .fileBoundaries,
        .filenamePattern(ChapterStrategy.defaultFilenamePattern),
    ]

    /// Refuses a folder that cannot be written to, there and then. `Preflight` would catch
    /// it before any audio was encoded, but only once the user had started the run and
    /// gone away.
    private func chooseDestination() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder to save \(book.title) in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination = OutputDestination.fixed(url)
        if let problem = destination.problem() {
            destinationProblem = "That folder cannot be used: \(problem) "
                               + "This book's save location is unchanged."
            return
        }
        destinationProblem = nil
        book.destinationOverride = destination
    }

    private var chapterSelection: Binding<Int> {
        Binding(
            get: {
                switch book.chapterStrategy {
                case .overdriveMarkers: return 0
                case .fileBoundaries: return 1
                case .filenamePattern: return 2
                }
            },
            set: { index in
                let choice = Self.chapterChoices[index]
                guard choice != book.chapterStrategy else { return }
                // Both of `orderSelection`'s guards, for the picker that says most directly
                // where the chapters come from: the same refusal for a book that no longer
                // accepts edits, and the same confirmation for a hand-edited list.
                guard book.acceptsEdits else { return }
                guard book.hasManualChapters else {
                    book.chapterStrategy = choice
                    return
                }
                regeneration = ChapterRegeneration(
                    confirm: "Use \(choice.label)",
                    message: "This book's chapters were edited by hand. Taking them from "
                           + "\(choice.label) instead rebuilds the whole list, and your "
                           + "edits — titles, boundaries, merges and splits — are not kept.",
                    apply: { book.adoptChapterStrategy(choice) })
            }
        )
    }
}

struct CoverThumbnail: View {
    let url: URL?

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 6).fill(.quaternary)
                    .overlay { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
        }
        .frame(width: 84, height: 84)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
