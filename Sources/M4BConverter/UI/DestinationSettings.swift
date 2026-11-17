import AppKit
import SwiftUI

/// The app-wide save location, in the standard ⌘, settings window.
struct DestinationSettings: View {
    @Bindable var model: AppModel

    private var isFixed: Bool {
        if case .fixed = model.defaultDestination { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save finished books").font(.headline)

            Picker("", selection: choice) {
                Text("Beside each source folder").tag(false)
                Text("In this folder:").tag(true)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.isConverting)

            HStack(spacing: 8) {
                Text(isFixed ? model.defaultDestination.label : "No folder chosen")
                    .font(.callout)
                    .foregroundStyle(isFixed ? .primary : .secondary)
                    .truncationMode(.middle).lineLimit(1)
                    .textSelection(.enabled)
                Spacer()
                Button("Choose…") { choose() }
                    .disabled(model.isConverting)
            }
            .padding(.leading, 20)

            // Changing the save location rebuilds where every book in the queue is
            // headed, including the ones being written right now — whose output path was
            // resolved and claimed at preflight and cannot move. `SetupSheet` refuses the
            // tools for the same reason, and `AppModel.setDefaultDestination` enforces it
            // whatever the UI allows: ⌘, opens this window during a conversion.
            if model.isConverting {
                Text("A conversion is running, so the save location cannot be changed "
                     + "yet. Cancel it or let it finish first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // A folder can go away between launches — an unmounted volume, a folder the
            // user moved — and a destination that was picked while writable can stop being
            // so. Say it here rather than letting every book fail one at a time later.
            if let message = model.destinationMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Beside each source folder writes the .m4b next to the folder it came "
                 + "from, which for a book nested inside a box set means inside that box "
                 + "set. One folder puts every book in the same place. Books already in "
                 + "the queue follow this setting unless you have given one a save "
                 + "location of its own.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
        .frame(width: 460, alignment: .leading)
    }

    /// Switching to "In this folder" with nothing chosen yet has to ask for a folder, or
    /// the radio button selects a destination that does not exist. A cancelled panel snaps
    /// back to the previous choice rather than leaving the UI claiming a folder is set.
    private var choice: Binding<Bool> {
        Binding(
            get: { isFixed },
            set: { wantsFixed in
                if wantsFixed {
                    if !isFixed { choose() }
                } else {
                    model.setDefaultDestination(.besideSource)
                }
            }
        )
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose the folder to save finished .m4b files in"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Validated inside `setDefaultDestination`, which refuses an unusable folder and
        // leaves the previous setting in force — the message above then explains why.
        model.setDefaultDestination(.fixed(url))
    }
}
