import SwiftUI

/// A reclaim the user has been asked about and has not yet agreed to.
///
/// The message is built when the dialog is raised rather than when it is drawn, because
/// the survey walks the folder — and because holding the text here is what lets the
/// inspector and the sidebar raise the SAME confirmation rather than two wordings of it.
struct PendingReclaim: Identifiable {
    let id = UUID()
    let book: Book
    let message: String
}

/// A request to reclaim, from the moment the button is pressed to the moment the dialog
/// closes: the survey while it is still counting, then the confirmation built from it.
///
/// A type rather than two `@State` flags in each of the two views, for the same reason
/// `PendingReclaim` is one: the inspector and the sidebar have to behave identically here,
/// and the interesting behaviour — that a dialog is NOT raised while the folder is still
/// being counted — is exactly the kind that gets implemented on one surface and forgotten
/// on the other.
@MainActor
@Observable
final class ReclaimRequest {
    /// The confirmation to present. Non-nil only once the folder has actually been counted.
    ///
    /// This is the whole point of the type. `SourceReclaimer.survey` walks the tree, which
    /// on a network share or a folder of extras takes long enough to see; raising the
    /// dialog first and filling the numbers in afterwards would put "0 files, Zero KB" in
    /// front of the user and then change it under them — asking them to agree to a figure
    /// that is not the figure. Nothing is shown until the count is real.
    var pending: PendingReclaim?
    /// The book whose folder is being counted right now, so the button that started it can
    /// say so and cannot be pressed a second time while it waits.
    private(set) var surveying: Book?
    /// Bumped by `abandon()`. A walk already in flight cannot be stopped mid-`enumerator`,
    /// so its result is checked against the token it started with instead, and dropped if
    /// the request it belonged to has been given up on.
    private var generation = 0

    var isSurveying: Bool { surveying != nil }

    /// Counts `book`'s folder — off the main actor, so the window keeps drawing — and
    /// raises the confirmation when the count is in.
    ///
    /// `queue` is every book the app is holding, so the survey can name any of the OTHERS
    /// that is inside the folder about to go.
    func ask(about book: Book, in queue: [Book]) {
        // One at a time. Two presses would run two walks and raise two dialogs, of which
        // SwiftUI shows one — and not necessarily the one belonging to the second press.
        guard surveying == nil, pending == nil else { return }
        surveying = book
        let token = generation
        Task {
            let survey = await SourceReclaimer.survey(book, queue: queue)
            // Still wanted? See `abandon()`.
            guard token == generation else { return }
            surveying = nil
            pending = PendingReclaim(book: book, message: survey.confirmation(for: book))
        }
    }

    /// Gives up on whatever is being counted or is waiting to be confirmed.
    ///
    /// For a surface that has changed what it is about. The inspector shows one book at a
    /// time, and the user can select a different one WHILE a folder is being counted — a
    /// window that exists only because the count is now asynchronous, and that is longest
    /// on exactly the slow volume which motivated making it so. Without this the walk
    /// finishes and puts "Move the source MP3s to the Trash?" on screen over an inspector
    /// showing another book: the dialog names the right paths, but everything around it
    /// names something else, and a destructive confirmation whose surroundings disagree
    /// with it is precisely what a confirmation exists to prevent. The request is dropped
    /// instead, and the user asks again from the book they are now looking at.
    ///
    /// The sidebar does not need this and does not call it: its list is about every book at
    /// once, so nothing it shows can stop agreeing with the dialog.
    func abandon() {
        generation &+= 1
        surveying = nil
        pending = nil
    }
}

extension View {
    /// The one confirmation both surfaces show before anything moves.
    ///
    /// Destructive-styled and explicit: this is the only feature in the app that removes
    /// the user's own originals, so the dialog names the folder, says how many files and
    /// how much space, says in as many words that they go to the Trash, and names any other
    /// book in the queue that is in there too.
    func reclaimConfirmation(_ request: ReclaimRequest, model: AppModel) -> some View {
        confirmationDialog(
            "Move the source MP3s to the Trash?",
            isPresented: Binding(get: { request.pending != nil },
                                 set: { if !$0 { request.pending = nil } }),
            presenting: request.pending
        ) { pending in
            Button("Move to Trash", role: .destructive) {
                let book = pending.book
                request.pending = nil
                Task { await model.reclaimSource(of: book) }
            }
            Button("Keep Them", role: .cancel) { request.pending = nil }
        } message: { pending in
            Text(pending.message)
        }
    }
}
