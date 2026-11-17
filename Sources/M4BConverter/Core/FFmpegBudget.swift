import Foundation

/// How many CPU-saturating ffmpeg children this app will run at once, across every feature
/// that starts them.
///
/// The bound has to be shared, because the features are not. `AppModel.checkExistingBooks`
/// deliberately allows a library check alongside a conversion — it reads files and moves
/// nothing, so there is no reason to refuse it — and each feature bounding itself in
/// isolation means the machine sees the SUM. Six full-file decodes plus three encodes is
/// nine processes competing for the cores, and the ones the user is waiting on are the three
/// they asked for first.
///
/// **Derived from the machine, not typed in.** The same build runs on a four-thread 2018 Air
/// and a sixteen-thread desktop, and a constant chosen on one is wrong on the other. One
/// thread is left over for the app itself: SwiftUI redraws a progress bar many times a
/// second while all of this runs, and a window that stops answering is how a user decides
/// the app has hung.
///
/// This is NOT the bound for ffprobe. `AppModel.probeConcurrently` runs metadata reads that
/// take milliseconds and finish waiting on the disk rather than the CPU; its own measured
/// bound belongs to it, and borrowing this one would slow a library scan down for nothing.
public enum FFmpegBudget {
    /// Every CPU-bound ffmpeg the app has running at one moment, whichever feature started
    /// it.
    ///
    /// The floor is `ConversionQueue.maxConcurrent + 1` so that a check always gets at
    /// least one decode of its own: a library check that can never start on a small machine
    /// is a feature that does not work there.
    public static var concurrentProcesses: Int {
        max(ConversionQueue.maxConcurrent + 1,
            ProcessInfo.processInfo.activeProcessorCount - 1)
    }

    /// What is left for whole-file decoding once the conversion queue's share is set aside.
    ///
    /// Set aside whether or not a conversion is running: the check may take minutes, a
    /// conversion can be started in the middle of it, and a bound that was generous when the
    /// check began cannot be taken back from the decodes already in flight.
    public static var concurrentDecodes: Int {
        concurrentProcesses - ConversionQueue.maxConcurrent
    }
}
