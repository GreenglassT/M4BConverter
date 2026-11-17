import Foundation

public struct PreflightReport: Sendable, Equatable {
    public var estimatedBytes: Int64
    public var freeBytes: Int64
    public var outputExists: Bool
    /// Whether the destination DIRECTORY can be written to. A read-only volume has plenty
    /// of free space and no file in the way, so nothing else here catches it — and the
    /// user would otherwise find out only when a multi-hour encode had nowhere to land.
    public var isWritable: Bool

    public init(estimatedBytes: Int64, freeBytes: Int64, outputExists: Bool,
                isWritable: Bool = true) {
        self.estimatedBytes = estimatedBytes
        self.freeBytes = freeBytes
        self.outputExists = outputExists
        self.isWritable = isWritable
    }

    /// Keep half a gigabyte of headroom so a conversion never fills the disk.
    public var hasEnoughSpace: Bool { freeBytes > estimatedBytes + 500_000_000 }
}

public enum CollisionPolicy: String, Sendable, CaseIterable, Identifiable {
    case keepBoth
    case replace
    case skip

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .keepBoth: return "Keep both"
        case .replace: return "Replace"
        case .skip: return "Skip"
        }
    }
}

public enum Preflight {
    public static func estimatedBytes(bitRate: Int, duration: Double) -> Int64 {
        Int64((Double(bitRate) / 8.0) * duration)
    }

    public static func freeBytes(at url: URL) -> Int64 {
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return Int64(values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }

    /// "Book.m4b" -> "Book 2.m4b" -> "Book 3.m4b" …
    ///
    /// `unavailable` counts as taken even though nothing is on disk there yet. Two books
    /// can resolve to the same `outputURL` (sibling disc folders sharing an album tag),
    /// and concurrent runs both see an absent file: without the claimed set they would
    /// pick the same name and interleave into one file.
    public static func uniqueURL(for url: URL, avoiding unavailable: Set<URL> = []) -> URL {
        // Compare standardised paths so a claim made through one spelling of a path is
        // still recognised through another.
        let claimed = Set(unavailable.map(\.standardizedFileURL))
        func isTaken(_ candidate: URL) -> Bool {
            FileManager.default.fileExists(atPath: candidate.path)
                || claimed.contains(candidate.standardizedFileURL)
        }
        guard isTaken(url) else { return url }
        let folder = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var counter = 2
        while true {
            let candidate = folder.appendingPathComponent("\(stem) \(counter).\(ext)")
            if !isTaken(candidate) { return candidate }
            counter += 1
        }
    }

    /// Whether a file can actually be created in `directory` — by creating one and
    /// removing it, not by asking the kernel's opinion.
    ///
    /// `isWritableFile(atPath:)` is `access(W_OK)`, which answers from POSIX permissions
    /// and knows nothing about macOS privacy protection. `~/Desktop`, `~/Documents` and
    /// `~/Downloads` are mode 0700 and owned by the user, so it says "writable" for all
    /// three — and then TCC refuses the open at encode time and the user gets raw ffmpeg
    /// "Permission denied" after picking a save location that validated clean. Those three
    /// folders are among the likeliest choices there are, so the early check has to be
    /// able to see the thing that actually stops the write.
    ///
    /// The probe file is dot-prefixed, uniquely named and has no `.m4b` extension, so
    /// nothing in this app or in the user's library can mistake it for output, and it is
    /// removed on every path out of here including the failing one.
    public static func canWrite(to directory: URL,
                                fileManager: FileManager = .default) -> Bool {
        let probe = directory.appendingPathComponent(
            ".m4bconverter-write-probe-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: probe) }
        return fileManager.createFile(atPath: probe.path, contents: nil)
    }

    /// Nil when a finished book can be written into `directory` right now, otherwise one
    /// sentence naming the folder and saying what is wrong with it.
    ///
    /// The single answer to "why can I not write here". It is asked when the user picks a
    /// save location and when a stored one is read back at launch (both through
    /// `OutputDestination.problem`), and again when a conversion reaches preflight
    /// (`ConversionQueue`) — which used to answer it separately, distinguishing only
    /// missing from unwritable and keeping its own copy of the privacy-settings advice.
    /// Two wordings of one diagnosis, and the one the user sees when choosing a folder is
    /// not the one that stops the encode.
    public static func writeProblem(at directory: URL,
                                    fileManager: FileManager = .default) -> String? {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return "\(directory.path) is not there — the folder is missing: moved, "
                 + "deleted, or on a volume that is not mounted."
        }
        guard isDirectory.boolValue else {
            return "\(directory.path) is a file, not a folder."
        }
        // By writing a file, not by asking `access(W_OK)` — see `canWrite` above. The three
        // folders a user is most likely to pick (Desktop, Documents, Downloads) pass the
        // permission check and are then refused by macOS privacy protection at encode time,
        // which is exactly the outcome the early check exists to prevent.
        guard canWrite(to: directory, fileManager: fileManager) else {
            return "\(directory.path) is read-only, or macOS is not letting M4B Converter "
                 + "write there. If it is Desktop, Documents or Downloads, allow the app "
                 + "under System Settings › Privacy & Security › Files and Folders."
        }
        return nil
    }

    public static func report(for outputURL: URL, bitRate: Int, duration: Double) -> PreflightReport {
        let destination = outputURL.deletingLastPathComponent()
        return PreflightReport(
            estimatedBytes: estimatedBytes(bitRate: bitRate, duration: duration),
            freeBytes: freeBytes(at: destination),
            outputExists: FileManager.default.fileExists(atPath: outputURL.path),
            isWritable: canWrite(to: destination))
    }

    /// Runs ffmpeg once at launch to confirm the binary works and carries the
    /// AudioToolbox AAC encoder. Without this, a bad binary or a build lacking
    /// `--enable-audiotoolbox` fails on the first file of the first book with raw ffmpeg
    /// text that reads like a problem with the user's audio, not their ffmpeg.
    /// Returns nil when everything is usable, or a message to show the user.
    public static func validate(_ tools: FFmpegTools,
                                runner: ProcessRunner = ProcessRunner()) async -> String? {
        guard let version = try? await runner.run(tools.ffmpeg, ["-hide_banner", "-version"]),
              version.succeeded else {
            return "ffmpeg was found but would not run. Try: brew reinstall ffmpeg"
        }
        guard let encoders = try? await runner.run(tools.ffmpeg, ["-hide_banner", "-encoders"]),
              encoders.succeeded, encoders.stdout.contains("aac_at") else {
            return "This ffmpeg build lacks the AudioToolbox AAC encoder (aac_at), which "
                 + "M4B Converter uses for audiobook-quality audio at low bitrates. "
                 + "Try: brew reinstall ffmpeg"
        }
        return nil
    }
}
