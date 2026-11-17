import AppKit
import SwiftUI

struct SetupSheet: View {
    @Bindable var model: AppModel

    /// Shown and copied, so it is written once.
    private static let installCommand = "brew install ffmpeg"

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.tools == nil ? "ffmpeg not found" : "ffmpeg is not usable",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.title3.bold()).foregroundStyle(.orange)

            Text(model.setupMessage
                 ?? "M4B Converter drives ffmpeg to read and encode audio.")
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text(Self.installCommand)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(Self.installCommand, forType: .string)
                }
            }

            HStack {
                Button("Locate manually…") { locate() }
                    .disabled(model.isConverting)
                // The sheet now stays up across a re-check rather than blinking, so it
                // has to show that the check is running or it just looks frozen.
                Button(model.isValidating ? "Checking…" : "Check again") {
                    model.relocateTools()
                }
                .disabled(model.isValidating || model.isConverting)
                if model.isValidating {
                    ProgressView().controlSize(.small)
                }
            }

            // Both buttons rebuild the queue, which would orphan a conversion already in
            // flight: its ffmpeg processes would keep running with nothing able to cancel
            // them, and the quit handler would see an idle queue and let the app go.
            if model.isConverting {
                Text("A conversion is running, so the tools cannot be changed yet. "
                     + "Cancel it or let it finish first.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 460)
    }

    private func locate() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder containing ffmpeg and ffprobe"
        if panel.runModal() == .OK, let url = panel.url {
            model.setToolsDirectory(url)
        }
    }
}
