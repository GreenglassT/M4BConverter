import AppKit
import SwiftUI
import UniformTypeIdentifiers

public struct ContentView: View {
    // Handed in by the App so the termination handler shares this exact instance. No
    // default value: a defaulted `AppModel()` would be rebuilt on every re-render,
    // silently emptying the queue.
    private let model: AppModel
    @State private var isTargeted = false

    public init(model: AppModel) { self.model = model }

    public var body: some View {
        NavigationSplitView {
            QueueSidebar(model: model)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            if let book = model.selectedBook {
                BookInspector(book: book, model: model)
            } else {
                ContentUnavailableView(
                    "No books yet",
                    systemImage: "books.vertical",
                    description: Text("Drop a folder of MP3s here, or use Add Folder.")
                )
            }
        }
        .safeAreaInset(edge: .bottom) { footer }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // A second add while the first is still probing races the dedup check
                // inside `add`, and two entries for one folder share an output path.
                Button("Add Folder…", systemImage: "plus") { chooseFolder() }
                    .disabled(model.isScanning)
            }
            ToolbarItem(placement: .primaryAction) {
                // Also blocked mid-scan: `convertAll` snapshots `books`, so starting one
                // now would silently strand every book the scan has yet to append. The
                // footer would read "4 of 4" while the stragglers sat at `.ready` with
                // nothing on screen saying they had been left out.
                Button("Convert All", systemImage: "play.fill") {
                    Task { await model.convertAll() }
                }
                .disabled(model.books.isEmpty || model.isScanning
                          || model.isConverting)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            Task { await model.add(urls) }
            return true
        } isTargeted: { isTargeted = $0 }
        .overlay {
            if isTargeted {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .padding(8)
            }
        }
        .sheet(isPresented: .constant(model.needsSetup)) {
            // macOS sheets are interactively dismissible, and Escape makes SwiftUI write
            // `false` into the binding — which a `.constant` throws away. The presentation
            // state was torn down while `needsSetup` was still true, so the sheet never
            // came back and the user was stranded with no route to "Locate manually…".
            // This is a blocking setup gate: it closes when `needsSetup` goes false.
            SetupSheet(model: model)
                .interactiveDismissDisabled()
        }
        .frame(minWidth: 900, minHeight: 600)
    }

    /// Progress and messages are independent rows, not branches of one if/else chain.
    /// With `queue.isRunning` tested first, a drop refused mid-conversion rendered
    /// nothing at all — defeating the deliberate choice in `AppModel.add` to refuse
    /// loudly, since all the user saw was the folder not appearing.
    @ViewBuilder private var footer: some View {
        let queue = model.queue
        let isConverting = queue?.isRunning == true
        if isConverting || model.isScanning || model.scanMessage != nil {
            VStack(alignment: .leading, spacing: 6) {
                if isConverting, let queue {
                    HStack(spacing: 10) {
                        ProgressView(value: Double(queue.completed),
                                     total: Double(max(queue.total, 1)))
                        Text("\(queue.completed) of \(queue.total)")
                            .font(.caption).monospacedDigit()
                        Button("Cancel", role: .destructive) { queue.cancelAll() }
                            .controlSize(.small)
                    }
                } else if model.isScanning {
                    HStack { ProgressView().controlSize(.small); Text("Scanning…").font(.caption) }
                }
                if let message = model.scanMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle").foregroundStyle(.secondary)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.bar)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            let urls = panel.urls
            Task { await model.add(urls) }
        }
    }
}
