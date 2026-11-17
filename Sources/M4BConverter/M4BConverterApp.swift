import AppKit
import SwiftUI

@main
struct M4BConverterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    // Owned here rather than inside ContentView so the termination handler can reach
    // the queue. SwiftUI keeps App-level @State for the life of the process.
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup("M4B Converter") {
            ContentView(model: model)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1040, height: 680)
        .commands {
            // In File, beside the other things that bring files into the app. The check
            // reads books rather than making them, so it does not belong on the toolbar
            // next to Convert All.
            CommandGroup(after: .newItem) {
                CheckExistingBooksCommand(model: model)
            }
        }

        // A window of its own rather than a sheet: a check of a shelf of books takes
        // minutes, and it must not block the queue behind it.
        Window("Existing Books", id: LibraryCheckView.windowID) {
            LibraryCheckView(model: model)
        }
        .defaultSize(width: 760, height: 520)

        // ⌘, — the same `AppModel`, so changing the save location here immediately moves
        // every book in the queue that has not been given one of its own.
        Settings {
            DestinationSettings(model: model)
        }
    }
}

/// Stops the app's child processes before the process goes away.
///
/// Foundation `Process` children outlive their parent: quitting mid-conversion left
/// ffmpeg running, and it would finish minutes later and drop a complete-looking but
/// never-verified .m4b into the library — which a later run under `.skip` then trusts
/// and skips. Pre-existing files were never at risk, because everything that touches an
/// original happens after verification inside the app; the danger is the unverified
/// leftover.
///
/// The existing-books check grows children too — a decode and an ffprobe per file in
/// flight, `FFmpegBudget.concurrentDecodes` files at a time — and it
/// arrived after this handler did. So the question here is `model.isBusy`, which is "is
/// anything running?", rather than a list of the things that might be: a guard naming one
/// source of children is a guard that is wrong the day a second one is added, which is
/// precisely what happened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Nothing running: quit immediately. Deferring unconditionally would make every
        // ordinary Cmd-Q feel like a hang.
        guard let model, model.isBusy else { return .terminateNow }

        // Terminates the running ffmpeg processes; a cancelled conversion then deletes its
        // own partial output on the way out. The same paths the Cancel buttons use, rather
        // than a second cleanup route that nothing tests.
        model.cancelEverything()
        Task { @MainActor in
            await model.waitUntilIdle()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
