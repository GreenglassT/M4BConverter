import SwiftUI

/// Which cell of the chapter table has the keyboard.
///
/// Held once for the whole table rather than per row, so Return can hand focus to the next
/// field. A real audiobook can carry 190 chapters: a table that size is not editable
/// if reaching each field costs a click, and an edit that only commits on a click somewhere
/// else is an edit the user will lose.
enum ChapterField: Hashable {
    case start(Int)
    case title(Int)
}

/// Shared by the header and the rows, which have to line up.
private let numberWidth: CGFloat = 30
private let startWidth: CGFloat = 104
private let actionsWidth: CGFloat = 54

/// The chapter list, editable in place.
///
/// Titles and boundaries are typed; merge and split are a button each. What is NOT here is
/// as deliberate: no reordering (the list is time-ordered, so moving a row without moving
/// its times means nothing), no delete (removing a chapter would leave its audio in no
/// chapter at all), and no separate end field — see `ChapterEditor` for why the boundary
/// between two chapters is one value and not two.
struct ChapterTable: View {
    let book: Book

    @FocusState private var focus: ChapterField?
    /// Why the last edit was refused, under the table. Not an alert: a mistyped boundary
    /// is a typo, and a modal for a typo is punishment.
    @State private var problem: String?
    /// The chapter whose split popover is open.
    @State private var splitting: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            header
            List {
                ForEach(Array(book.chapters.enumerated()), id: \.offset) { index, chapter in
                    ChapterRow(
                        index: index, chapter: chapter,
                        isLast: index == book.chapters.count - 1,
                        focus: $focus, splitting: $splitting,
                        commitTitle: { commitTitle($0, at: index, was: chapter) },
                        commitStart: { commitStart($0, at: index, was: chapter) },
                        merge: { problem = attempt { try book.mergeChapter(at: index) } },
                        split: { split($0, at: index, was: chapter) },
                        advance: advance)
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
            }
            .listStyle(.plain)
            .alternatingRowBackgrounds()
            .frame(minHeight: 220)

            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // The same guard as every other per-book control: the conversion read the chapter
        // list once, at the start, and has already written it to the metadata file ffmpeg
        // is muxing from. An edit now would change what the table says without changing
        // what is being encoded — and once the run is over, for ever: the .m4b carries the
        // list it was given, and this one would drift away from it with nothing to say so.
        .disabled(!book.acceptsEdits)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("#").frame(width: numberWidth, alignment: .trailing)
            Text("Start").frame(width: startWidth, alignment: .leading)
            Text("Title").frame(maxWidth: .infinity, alignment: .leading)
            Spacer().frame(width: actionsWidth)
        }
        .font(.caption).foregroundStyle(.secondary)
        .padding(.horizontal, 8)
    }

    /// Runs an edit, returning the message to show when it is refused and nil when it took.
    private func attempt(_ edit: () throws -> Void) -> String? {
        do {
            try edit()
            return nil
        } catch let error as ChapterEditError {
            return error.message
        } catch {
            return error.localizedDescription
        }
    }

    private func commitTitle(_ text: String, at index: Int, was original: Chapter) -> Bool {
        guard isStillThere(index, original) else { return false }
        problem = attempt { try book.setChapterTitle(text, at: index) }
        return problem == nil
    }

    /// Row N's start is the boundary after chapter N-1, and setting it moves both sides.
    /// Row 0 has no field at all, so `index` is always at least 1 here.
    private func commitStart(_ text: String, at index: Int, was original: Chapter) -> Bool {
        guard isStillThere(index, original) else { return false }
        guard let time = Timecode.parse(text) else {
            problem = ChapterEditError.unreadableTime(text).message
            return false
        }
        problem = attempt { try book.moveChapterBoundary(after: index - 1, to: time) }
        return problem == nil
    }

    /// Returns the refusal to show inside the popover, or nil once the split has happened.
    private func split(_ text: String, at index: Int, was original: Chapter) -> String? {
        guard isStillThere(index, original) else { return problem }
        guard let time = Timecode.parse(text) else {
            return ChapterEditError.unreadableTime(text).message
        }
        if let refusal = attempt({ try book.splitChapter(at: index, at: time) }) {
            return refusal
        }
        problem = nil
        splitting = nil
        return nil
    }

    /// Whether the row's chapter is still the chapter at that row.
    ///
    /// A field commits when it loses focus, and a merge or a split renumbers every row
    /// below it — so a title typed but not yet committed could otherwise land on whichever
    /// chapter had shuffled up into that row, silently renaming the wrong one. It is
    /// refused instead, and said out loud: the row puts back what is actually there.
    private func isStillThere(_ index: Int, _ original: Chapter) -> Bool {
        guard book.chapters.indices.contains(index),
              book.chapters[index] == original else {
            problem = "That edit was not applied: the chapter list changed while it was "
                    + "being typed. Check the row and make it again."
            return false
        }
        return true
    }

    /// Return moves to the next field in reading order — a boundary, its title, the next
    /// boundary — and stops at the end rather than wrapping round to the top.
    private func advance(from field: ChapterField) {
        switch field {
        case .start(let index):
            focus = .title(index)
        case .title(let index):
            focus = index + 1 < book.chapters.count ? .start(index + 1) : nil
        }
    }
}

private struct ChapterRow: View {
    let index: Int
    let chapter: Chapter
    let isLast: Bool
    @FocusState.Binding var focus: ChapterField?
    @Binding var splitting: Int?
    /// Both report whether the edit took; a refused one puts the field back.
    let commitTitle: (String) -> Bool
    let commitStart: (String) -> Bool
    let merge: () -> Void
    let split: (String) -> String?
    let advance: (ChapterField) -> Void

    /// What is in the fields, which is not what is in the model until it commits. Bound
    /// straight to the chapter, every keystroke would be a separate edit — and "1:2" on
    /// the way to typing "1:23" is a boundary 81 seconds from the one intended.
    @State private var titleDraft: String
    @State private var startDraft: String

    init(index: Int, chapter: Chapter, isLast: Bool,
         focus: FocusState<ChapterField?>.Binding, splitting: Binding<Int?>,
         commitTitle: @escaping (String) -> Bool, commitStart: @escaping (String) -> Bool,
         merge: @escaping () -> Void, split: @escaping (String) -> String?,
         advance: @escaping (ChapterField) -> Void) {
        self.index = index
        self.chapter = chapter
        self.isLast = isLast
        self._focus = focus
        self._splitting = splitting
        self.commitTitle = commitTitle
        self.commitStart = commitStart
        self.merge = merge
        self.split = split
        self.advance = advance
        _titleDraft = State(initialValue: chapter.title)
        _startDraft = State(initialValue: Timecode.format(chapter.start))
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("\(index + 1)")
                .monospacedDigit().foregroundStyle(.secondary)
                .frame(width: numberWidth, alignment: .trailing)

            if index == 0 {
                // Fixed. The first chapter starts where the audio starts: that is not a
                // boundary between two chapters, and there is nothing on the other side
                // of it to hand the time to.
                Text(Timecode.format(chapter.start))
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: startWidth, alignment: .leading)
                    .help("The first chapter starts where the audio does.")
            } else {
                TextField("Start", text: $startDraft)
                    .textFieldStyle(.roundedBorder).monospacedDigit()
                    .frame(width: startWidth)
                    .focused($focus, equals: .start(index))
                    .onSubmit { advance(.start(index)) }
                    .help("Where chapter \(index) ends and chapter \(index + 1) begins. "
                          + "h:mm:ss, or h:mm:ss.mmm.")
            }

            TextField("Title", text: $titleDraft)
                .textFieldStyle(.roundedBorder)
                .focused($focus, equals: .title(index))
                .onSubmit { advance(.title(index)) }

            Button { splitting = index } label: { Image(systemName: "scissors") }
                .buttonStyle(.borderless)
                .help("Split this chapter in two")
                .popover(isPresented: isSplitting) {
                    SplitPopover(chapter: chapter, split: split)
                }

            Button(action: merge) { Image(systemName: "arrow.triangle.merge") }
                .buttonStyle(.borderless)
                .help("Merge with the next chapter")
                // The last chapter has nothing after it. `ChapterEditor` refuses this too;
                // a disabled button is not a rule, it is just a kinder way to say so.
                .disabled(isLast)
        }
        // The row's chapter changed under it — its own commit, or a merge or split
        // elsewhere shuffling the list — so the fields show what is there now.
        .onChange(of: chapter) { _, new in
            titleDraft = new.title
            startDraft = Timecode.format(new.start)
        }
        // Leaving a field is what commits it. Tab is how a long table is filled in, and
        // an edit that needed a click elsewhere to take would be lost by the user who
        // typed it and moved on.
        .onChange(of: focus) { old, new in
            if old == .title(index), new != .title(index) { submitTitle() }
            if old == .start(index), new != .start(index) { submitStart() }
        }
    }

    private var isSplitting: Binding<Bool> {
        Binding(get: { splitting == index }, set: { if !$0 { splitting = nil } })
    }

    /// Nothing typed, nothing to commit: tabbing through a row must not rewrite it. The
    /// comparison is against the text the field was given, so a start that merely
    /// re-formats — `1:2:3` for `1:02:03` — still counts as a change and gets tidied.
    private func submitTitle() {
        guard titleDraft != chapter.title else { return }
        if !commitTitle(titleDraft) { titleDraft = chapter.title }
    }

    private func submitStart() {
        let current = Timecode.format(chapter.start)
        guard startDraft != current else { return }
        if !commitStart(startDraft) { startDraft = current }
    }
}

/// Where to cut a chapter in two, asked next to the chapter it is about.
private struct SplitPopover: View {
    let chapter: Chapter
    /// Returns the refusal to show, or nil once the split has happened.
    let split: (String) -> String?

    @State private var text: String
    @State private var problem: String?
    /// One split per popover. Return reaches both the field's `onSubmit` and the default
    /// button, and the second call would land on a chapter that no longer exists.
    @State private var done = false
    @FocusState private var focused: Bool

    init(chapter: Chapter, split: @escaping (String) -> String?) {
        self.chapter = chapter
        self.split = split
        // The midpoint, because it is always valid and always wrong: it invites the real
        // time rather than pretending to know it.
        _text = State(initialValue: Timecode.format((chapter.start + chapter.end) / 2))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Split “\(chapter.title)”").font(.headline)
            Text("Anywhere between \(Timecode.format(chapter.start)) and "
                 + "\(Timecode.format(chapter.end)).")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Time", text: $text)
                .textFieldStyle(.roundedBorder).monospacedDigit()
                .focused($focused)
                .onSubmit(attempt)
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Split", action: attempt).keyboardShortcut(.defaultAction)
            }
        }
        .padding(14)
        .frame(width: 280)
        .onAppear { focused = true }
    }

    private func attempt() {
        guard !done else { return }
        problem = split(text)
        done = problem == nil
    }
}
