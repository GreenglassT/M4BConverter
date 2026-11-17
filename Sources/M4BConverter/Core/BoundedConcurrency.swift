import Foundation

/// Runs `count` pieces of work with at most `limit` of them in flight, starting the next as
/// each one finishes, and handing every result back on the main actor tagged with the index
/// it belongs to.
///
/// Three places had grown their own copy of this — the conversion queue, the scan's probing,
/// and the existing-books check — and a copy is not free. `ConversionQueue` had to learn,
/// from a bug, that a cancelled run must stop refilling the group: otherwise every remaining
/// book returns instantly at its own `isCancelled` guard and still counts, so the footer read
/// "9 of 9" when nothing had converted. Neither of the other two copies knew that, and both
/// count the same way. `onResult`'s return value asks the question once, in the one place
/// that refills.
///
/// **Results carry their index, not their arrival order.** Twelve concurrent children finish
/// in whatever order they please; a caller that stores each result at its index gets its
/// input order back for nothing. Appending does not — and `TrackOrderer` breaks ties on
/// input order, so a scrambled array silently misorders files that share a track number,
/// with nothing on screen to suggest anything went wrong.
///
/// **Everything but the work itself runs on the main actor.** `start` is called there to
/// build each operation, so a caller can register a `ProcessRunner` for the child it is
/// about to launch; `onResult` is called there with each result, so a caller's bookkeeping —
/// progress counts, result slots, runner deregistration — needs no locking of its own.
/// Only the returned operation runs off it, which is what keeps the window live while
/// several full-file decodes are going.
///
/// - Parameters:
///   - count: how many pieces of work there are; each is identified by its index.
///   - limit: how many may be in flight at once. Clamped to at least one, since a bound of
///     zero would start nothing at all and never return a single result.
///   - start: called on the main actor for index `i` just before its work is dispatched,
///     and returns the work itself.
///   - onResult: called on the main actor with each result and the index it came from.
///     Return false to stop dispatching work that has not started yet — the cancellation
///     case above. Work already in flight still lands here.
@MainActor
func runConcurrently<Output: Sendable>(
    count: Int,
    limit: Int,
    start: @MainActor (Int) -> @Sendable () async -> Output,
    onResult: @MainActor (Int, Output) -> Bool
) async {
    guard count > 0 else { return }
    var next = 0

    await withTaskGroup(of: (Int, Output).self) { group in
        // Takes the group explicitly: a nested function cannot capture an `inout`
        // parameter, and the alternative is the hand-rolled bookkeeping this exists to
        // remove.
        @MainActor
        func dispatch(in group: inout TaskGroup<(Int, Output)>) {
            let index = next
            next += 1
            let operation = start(index)
            group.addTask { (index, await operation()) }
        }

        for _ in 0..<min(max(limit, 1), count) { dispatch(in: &group) }
        while let (index, output) = await group.next() {
            // `onResult` first and always: a caller counts what landed even when the run
            // is being wound down, and only then decides whether anything more starts.
            guard onResult(index, output), next < count else { continue }
            dispatch(in: &group)
        }
    }
}
