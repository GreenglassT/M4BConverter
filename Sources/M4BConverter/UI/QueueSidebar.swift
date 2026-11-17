import SwiftUI

struct QueueSidebar: View {
    @Bindable var model: AppModel
    /// A request to send a book's source MP3s to the Trash, being counted or waiting to be
    /// confirmed. Held by the list rather than by the row: a context menu's own view is
    /// gone by the time the dialog would be presented from it — which now matters twice
    /// over, since the survey is asynchronous and the menu is certainly gone by the time
    /// it answers.
    @State private var reclaim = ReclaimRequest()

    var body: some View {
        List(selection: $model.selection) {
            ForEach(model.books) { book in
                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title).lineLimit(1)
                    HStack(spacing: 6) {
                        statusBadge(book.status)
                        Text("\(book.chapters.count) ch")
                        Text(formatHours(book.totalDuration))
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if book.status == .converting {
                        ProgressView(value: book.progress).controlSize(.small)
                    }
                }
                .padding(.vertical, 2)
                .tag(book.id)
                .contextMenu {
                    // Only for a book that actually failed: `.verified` is deliberately
                    // not retryable, and a book that has not run yet has nothing to
                    // retry. `AppModel.retry` refuses mid-run as well as being disabled.
                    if case .failed = book.status {
                        Button("Retry", systemImage: "arrow.clockwise") { model.retry(book) }
                            .disabled(model.isConverting)
                        // Shown from a failed book's own menu rather than on a new
                        // surface, and only when there is more than this one to put back.
                        let failed = model.failedBooks.count
                        if failed > 1 {
                            Button("Retry All \(failed) Failed") { model.retryAllFailed() }
                                .disabled(model.isConverting)
                        }
                        Divider()
                    }
                    // Only for a verified book, matching the inspector's own button, and
                    // raising the same confirmation. `AppModel.reclaimSource` refuses
                    // mid-run as well as being disabled.
                    if book.isReclaimable {
                        Button("Reclaim Source MP3s…", systemImage: "trash") {
                            reclaim.ask(about: book, in: model.books)
                        }
                        .disabled(model.isConverting || reclaim.isSurveying)
                        Divider()
                    }
                    // `AppModel.remove` refuses too; this is what tells the user why.
                    Button("Remove", role: .destructive) { model.remove(book) }
                        .disabled(book.isConverting)
                }
            }
        }
        .navigationTitle("Queue")
        .reclaimConfirmation(reclaim, model: model)
    }

    @ViewBuilder private func statusBadge(_ status: BookStatus) -> some View {
        switch status {
        case .ready:      Image(systemName: "circle").foregroundStyle(.secondary)
        case .warning:    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .converting: Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.blue)
        case .verified:   Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        // Finished AND its sources reclaimed. Green like `.verified`, because that is what
        // it is — the book converted and verified — but its own symbol, so a row whose
        // MP3s are in the Trash cannot be mistaken for one whose files are still there.
        case .reclaimed:  Image(systemName: "archivebox.fill").foregroundStyle(.green)
        case .failed:     Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        }
    }
}

func formatHours(_ seconds: Double) -> String {
    let hours = Int(seconds) / 3600
    let minutes = (Int(seconds) % 3600) / 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}
