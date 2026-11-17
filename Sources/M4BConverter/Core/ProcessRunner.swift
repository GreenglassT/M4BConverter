import Foundation

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var stdout: String
    public var stderr: String
    public var succeeded: Bool { exitCode == 0 }
}

public enum ProcessError: Error, LocalizedError {
    case launchFailed(String)
    case failed(code: Int32, stderr: String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let message): return "Could not start process: \(message)"
        case .failed(let code, let stderr): return "Process failed (\(code)): \(stderr)"
        case .cancelled: return "Cancelled"
        }
    }
}

/// Accumulates one stream's bytes, and — when a caller wants them — hands out complete
/// lines as they arrive. Both pipes use this: stdout with a callback, stderr without.
final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        all.append(chunk)
        // Without a callback nothing consumes lines, so do not split them: stderr is
        // captured whole and read once at the end, and ffmpeg can produce a lot of it.
        guard let onLine else { lock.unlock(); return }
        pending.append(chunk)
        var lines: [String] = []
        while let index = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: Data(pending[pending.startIndex..<index]), as: UTF8.self))
            pending = Data(pending[pending.index(after: index)...])
        }
        lock.unlock()
        for line in lines { onLine(line) }
    }

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return String(decoding: all, as: UTF8.self)
    }
}

/// Decides when a run is over.
///
/// A run finishes when three things have happened: stdout has reached EOF, stderr has
/// reached EOF, and the process has exited. They arrive on different queues in any
/// order, so whichever lands last resumes the continuation — exactly once.
///
/// Waiting for the pipe EOFs is the point. The old code resumed straight from
/// `terminationHandler` after nilling each `readabilityHandler` and calling
/// `readDataToEndOfFile()`. Nilling a handler does not wait for a block already
/// dispatched for that descriptor, so two readers could split one fd: the in-flight
/// block appended its chunk *after* the result had snapshotted the buffer, and that
/// chunk was lost. Under CPU pressure this truncated or emptied ffprobe's stdout on a
/// process that exited 0. EOF on the pipe cannot arrive before the last byte has been
/// handed to the single owning reader, so the buffer is complete when it does.
final class RunCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var openStreams = 2
    private var exitCode: Int32?
    private var resumed = false
    private let onFinished: @Sendable (Int32) -> Void

    init(onFinished: @escaping @Sendable (Int32) -> Void) { self.onFinished = onFinished }

    func streamReachedEOF() { settle { self.openStreams -= 1 } }

    func processExited(_ code: Int32) { settle { self.exitCode = code } }

    /// The launch never happened, so no EOF and no termination will ever arrive.
    /// Claims the continuation for the caller's error path; false if already resumed.
    func claimForLaunchFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }

    /// `<=`, not `==`. A duplicate EOF — the very hazard described above, since nilling a
    /// `readabilityHandler` does not cancel a block already dispatched for that descriptor
    /// — would drive the counter past zero to -1, and an equality test can never hold
    /// again after that. The continuation was then never resumed: `run` never returned,
    /// the book stayed `.converting`, `queue.isRunning` stayed true, and the quit
    /// handler's wait loop span forever, leaving the app impossible to quit. `EOFOnce`
    /// below stops the double count at source; this makes the arithmetic unable to wedge
    /// the run even if one ever gets through.
    private func settle(_ update: () -> Void) {
        lock.lock()
        update()
        guard openStreams <= 0, let exitCode, !resumed else { lock.unlock(); return }
        resumed = true
        lock.unlock()
        onFinished(exitCode)
    }
}

/// One-shot latch, one per stream: reports true to exactly one caller.
final class EOFOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var reported = false

    func shouldReport() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !reported else { return false }
        reported = true
        return true
    }
}

public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Process?
    private var terminationRequested = false

    public init() {}

    /// Cancellation is sticky for the life of the instance: once `terminate()` has been
    /// called, every later `run` fails immediately without launching anything. A queue
    /// shares one runner across a book's duration measurements, cover extraction and
    /// encode, so a cancel arriving *between* steps must not be forgotten — otherwise
    /// the multi-hour encode starts anyway and the click is silently absorbed.
    private func beginRun() throws {
        lock.lock(); defer { lock.unlock() }
        guard !terminationRequested else { throw ProcessError.cancelled }
        current = nil
    }

    /// Publishes the freshly launched process and reports whether cancellation was
    /// requested while it was still starting.
    private func publishLaunched(_ process: Process) -> Bool {
        lock.lock(); defer { lock.unlock() }
        current = process
        return terminationRequested
    }

    public func run(_ executable: URL,
                    _ arguments: [String],
                    onStdoutLine: (@Sendable (String) -> Void)? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let stdoutBuffer = LineBuffer(onLine: onStdoutLine)
        let stderrBuffer = LineBuffer(onLine: nil)

        try beginRun()

        return try await withCheckedThrowingContinuation { continuation in
            let completion = RunCompletion { code in
                continuation.resume(returning: ProcessResult(exitCode: code,
                                                             stdout: stdoutBuffer.text,
                                                             stderr: stderrBuffer.text))
            }

            // One reader owns each descriptor for the whole life of the process. An
            // empty `availableData` is EOF: retire this handler and report the stream
            // closed. Nothing else ever touches these fds — in particular there is no
            // `readDataToEndOfFile()` anywhere, which is what used to introduce a
            // second, racing reader. Draining both pipes concurrently as data arrives
            // is also what keeps a chatty process from deadlocking on a full pipe, and
            // what lets `onStdoutLine` fire incrementally rather than only at exit.
            func drain(_ pipe: Pipe, into append: @escaping @Sendable (Data) -> Void) {
                // One latch per stream: nilling the handler does not cancel a block
                // already dispatched for this descriptor, so an empty read can arrive
                // twice for one pipe. Counting it twice used to strand the run forever.
                let eof = EOFOnce()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    guard !chunk.isEmpty else {
                        handle.readabilityHandler = nil
                        if eof.shouldReport() { completion.streamReachedEOF() }
                        return
                    }
                    append(chunk)
                }
            }
            drain(outPipe) { stdoutBuffer.append($0) }
            drain(errPipe) { stderrBuffer.append($0) }

            process.terminationHandler = { completion.processExited($0.terminationStatus) }

            do {
                try process.run()
                // Publish only after a successful launch: Process.terminate() raises
                // an uncaught NSInvalidArgumentException ("task not launched") on a
                // process that has not started, which would kill the app. If cancel
                // arrived during the launch window, honour it now.
                if publishLaunched(process) { process.terminate() }
            } catch {
                outPipe.fileHandleForReading.readabilityHandler = nil
                errPipe.fileHandleForReading.readabilityHandler = nil
                process.terminationHandler = nil
                if completion.claimForLaunchFailure() {
                    continuation.resume(
                        throwing: ProcessError.launchFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Used by cancellation in Task 17. Safe to call at any time, including before
    /// a run starts, during the launch window, and after a run has finished.
    public func terminate() {
        lock.lock()
        terminationRequested = true
        let process = current
        lock.unlock()
        // isRunning is false both before launch and after exit; in the first case the
        // terminationRequested flag causes run() to kill the process once it starts.
        if let process, process.isRunning { process.terminate() }
    }
}
