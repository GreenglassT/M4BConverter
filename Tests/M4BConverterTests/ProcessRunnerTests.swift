import Foundation
import Testing
@testable import M4BConverter

@Test func capturesStdoutAndExitCode() async throws {
    let result = try await ProcessRunner().run(URL(fileURLWithPath: "/bin/echo"), ["hello"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func reportsNonZeroExitAndStderr() async throws {
    let result = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "echo oops >&2; exit 3"])
    #expect(result.exitCode == 3)
    #expect(result.stderr.contains("oops"))
}

@Test func streamsStdoutLinesAsTheyArrive() async throws {
    let collected = LineCollector()
    _ = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "echo a; echo b; echo c"],
        onStdoutLine: { collected.add($0) })
    #expect(collected.lines == ["a", "b", "c"])
}

final class LineCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    func add(_ line: String) { lock.lock(); storage.append(line); lock.unlock() }
    var lines: [String] { lock.lock(); defer { lock.unlock() }; return storage }
}

@Test func handlesLargeOutputWithoutDeadlock() async throws {
    let result = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "yes hello | head -50000"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.count > 100_000)
}

@Test func handlesBothPipesLargeWithoutDeadlock() async throws {
    let result = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", "for i in $(seq 1 20000); do echo out$i; echo err$i >&2; done"])
    #expect(result.exitCode == 0)
    #expect(result.stdout.count > 100_000)
    #expect(result.stderr.count > 100_000)
}

// The pipe race, tested the only honest way: repetition under load.
//
// `terminationHandler` used to nil each `readabilityHandler` and then call
// `readDataToEndOfFile()` on the same descriptor. Nilling does not wait for a block
// already dispatched for that fd, so a second reader could take a chunk that then
// landed in the buffer *after* the result had been snapshotted — lost. The visible
// symptom was ffprobe exiting 0 with truncated or empty JSON, so this reproduces that
// shape exactly: a large JSON document that either round-trips whole or does not.
//
// Every assertion here is on content, never on timing, so the test cannot flake on a
// slow machine — it only gets more chances to catch a real defect on a loaded one.
// Against the old implementation these two caught the defect in 3 of 10 runs under
// eight background CPU hogs; against the fixed one, 0 of 30.
@Test func concurrentRunsNeverTruncateOrScrambleStdout() async throws {
    let values = 1...20_000                      // ~130 KB, many pipe-buffer refills
    let emitJSON = #"printf '{"values":['; seq 1 20000 | paste -sd, -; printf ']}'"#

    for _ in 0..<3 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<24 {
                group.addTask {
                    let result = try await ProcessRunner().run(
                        URL(fileURLWithPath: "/bin/sh"), ["-c", emitJSON])
                    #expect(result.exitCode == 0)
                    // Exactly what MediaProbe does, and exactly where it used to throw
                    // ProbeError.badJSON on a process that had succeeded.
                    let root = try? JSONSerialization.jsonObject(
                        with: Data(result.stdout.utf8)) as? [String: Any]
                    let parsed = root?["values"] as? [Int]
                    #expect(parsed == Array(values),
                            "stdout did not round-trip: \(result.stdout.count) bytes")
                }
            }
            try await group.waitForAll()
        }
    }
}

// The same race on stderr, and with both pipes busy at once: the losing chunk could
// just as easily be the diagnostic text a failure gets reported with. A process this
// chatty that then exits immediately is the shape that lost data most often, because
// termination lands while handler blocks for both descriptors are still in flight.
@Test func concurrentRunsNeverTruncateEitherPipe() async throws {
    let expected = (1...8_000).map { "line\($0)" }
    let emitBoth = "for i in $(seq 1 8000); do echo line$i; echo line$i >&2; done"

    for _ in 0..<4 {
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask {
                    let result = try await ProcessRunner().run(
                        URL(fileURLWithPath: "/bin/sh"), ["-c", emitBoth])
                    #expect(result.exitCode == 0)
                    #expect(result.stdout.split(separator: "\n").map(String.init) == expected)
                    #expect(result.stderr.split(separator: "\n").map(String.init) == expected)
                }
            }
            try await group.waitForAll()
        }
    }
}

// The line callback has to fire while the process is still alive: FFmpegBackend reads
// progress from `-progress pipe:1`, and a bar that only moves at exit is no bar at all.
//
// Proved by handshake rather than by clock. The child prints "first" and then waits for
// the callback to create a file; only then does it print "second". If lines were only
// flushed at exit the child would time out and print "waited-in-vain" instead, so the
// assertion is on content and no timing threshold can make it flake.
@Test func stdoutLinesReachTheCallbackWhileTheProcessIsStillRunning() async throws {
    let folder = try Fixtures.temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: folder) }
    let marker = folder.appendingPathComponent("saw-first")

    let collected = LineCollector()
    let result = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"),
        ["-c", """
         echo first
         i=0
         while [ $i -lt 200 ] && [ ! -f "$1" ]; do sleep 0.05; i=$((i+1)); done
         if [ -f "$1" ]; then echo second; else echo waited-in-vain; fi
         """, "sh", marker.path],
        onStdoutLine: { line in
            collected.add(line)
            if line == "first" { FileManager.default.createFile(atPath: marker.path, contents: nil) }
        })
    #expect(result.exitCode == 0)
    #expect(collected.lines == ["first", "second"])
}

@Test func capturesOutputWithNoTrailingNewline() async throws {
    let result = try await ProcessRunner().run(
        URL(fileURLWithPath: "/bin/sh"), ["-c", "printf 'no-trailing-newline'"])
    #expect(result.stdout == "no-trailing-newline")
}

@Test func throwsWhenExecutableIsMissing() async {
    await #expect(throws: (any Error).self) {
        _ = try await ProcessRunner().run(URL(fileURLWithPath: "/nonexistent/binary"), [])
    }
}

// terminate() must be safe at every point in a run's lifecycle. Publishing the
// process before launch let a concurrent terminate() hit a not-yet-launched
// Process, which raises an uncaught NSException and kills the app.
@Test func terminateIsSafeAtAnyPointInTheLifecycle() async throws {
    let fresh = ProcessRunner()
    fresh.terminate()   // before any run

    let done = ProcessRunner()
    _ = try await done.run(URL(fileURLWithPath: "/bin/echo"), ["x"])
    done.terminate()    // after completion
}

@Test func terminateSurvivesRacingTheLaunchWindow() async throws {
    let runner = ProcessRunner()
    let stop = TerminateFlag()
    let spammer = Task.detached { while !stop.isSet { runner.terminate() } }
    for i in 0..<200 {
        _ = try? await runner.run(URL(fileURLWithPath: "/bin/echo"), ["\(i)"])
    }
    stop.set()
    _ = await spammer.value
}

final class TerminateFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

@Test func terminateStopsAnInFlightProcess() async throws {
    let runner = ProcessRunner()
    let started = Date()
    async let result = runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 30"])
    try await Task.sleep(nanoseconds: 300_000_000)
    runner.terminate()
    let finished = try await result
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(finished.exitCode != 0)
}

// A queue shares one runner across a book's measurement, extraction and encode
// steps. A cancel landing between two steps must not be forgotten, or the encode
// starts anyway and the user's click does nothing.
@Test func cancellationPersistsBetweenRuns() async throws {
    let runner = ProcessRunner()
    _ = try await runner.run(URL(fileURLWithPath: "/bin/echo"), ["step-1"])
    runner.terminate()

    let started = Date()
    await #expect(throws: (any Error).self) {
        _ = try await runner.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "sleep 2; echo encoded"])
    }
    #expect(Date().timeIntervalSince(started) < 0.5)   // rejected, not run
}

@Test func cancellationDoesNotLeakBetweenInstances() async throws {
    let cancelled = ProcessRunner()
    cancelled.terminate()

    let fresh = ProcessRunner()
    let result = try await fresh.run(URL(fileURLWithPath: "/bin/echo"), ["hi"])
    #expect(result.exitCode == 0)
}

final class FinishRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Int32] = []
    func record(_ code: Int32) { lock.lock(); storage.append(code); lock.unlock() }
    var codes: [Int32] { lock.lock(); defer { lock.unlock() }; return storage }
}

// A duplicate EOF is the hazard RunCompletion's own header describes: nilling a
// `readabilityHandler` does not cancel a block already dispatched for that descriptor,
// so one pipe can report EOF twice. The counter then went 2 -> 1 -> 0 -> -1 and
// `openStreams == 0` could never hold again, so the continuation was never resumed:
// `run` never returned, the book stayed `.converting`, `queue.isRunning` stayed true,
// and the quit handler's wait loop span forever with no way to quit the app.
@Test func aDuplicateEOFStillFinishesTheRun() {
    let finished = FinishRecorder()
    let completion = RunCompletion { finished.record($0) }

    completion.streamReachedEOF()
    completion.streamReachedEOF()
    completion.streamReachedEOF()      // the duplicate, before the process exits
    completion.processExited(0)

    #expect(finished.codes == [0])
}

// The same duplicate arriving after termination must not resume twice either — a second
// `continuation.resume` is a hard crash, not a hang.
@Test func aDuplicateEOFAfterExitResumesExactlyOnce() {
    let finished = FinishRecorder()
    let completion = RunCompletion { finished.record($0) }

    completion.processExited(7)
    completion.streamReachedEOF()
    completion.streamReachedEOF()
    completion.streamReachedEOF()
    completion.streamReachedEOF()

    #expect(finished.codes == [7])
}

// The same defect closed off at source: each pipe reader owns a latch, so however many
// times its handler fires empty, the stream is only ever counted out once.
@Test func oneStreamCannotReportEOFTwice() {
    let finished = FinishRecorder()
    let completion = RunCompletion { finished.record($0) }
    let stdout = EOFOnce(), stderr = EOFOnce()

    for _ in 0..<5 where stdout.shouldReport() { completion.streamReachedEOF() }
    completion.processExited(0)
    #expect(finished.codes.isEmpty)          // stderr has not finished yet

    for _ in 0..<5 where stderr.shouldReport() { completion.streamReachedEOF() }
    #expect(finished.codes == [0])
}

