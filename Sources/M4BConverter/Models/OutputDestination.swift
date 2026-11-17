import Foundation

/// Where a book's finished `.m4b` is written.
///
/// `.besideSource` is what the app has always done, and stays the default: the file
/// lands in the source folder's PARENT. That reads correctly for a folder dropped from
/// the library root, but a nested book — `Audiobooks/Waverley Novels/Ivanhoe`
/// — writes into the saga folder rather than into the library. `.fixed` sends every
/// book to one directory instead.
public enum OutputDestination: Sendable {
    case besideSource
    case fixed(URL)

    /// The directory a book whose own folder is `folder` writes into.
    public func directory(forSource folder: URL) -> URL {
        switch self {
        case .besideSource: return folder.deletingLastPathComponent()
        case .fixed(let url): return url
        }
    }
}

/// Compared by standardised path rather than by `URL`'s own equality, which distinguishes
/// `/Users/x/Audiobooks` from `/Users/x/Audiobooks/`. Both spellings arrive in practice — the
/// defaults string is read back without the directory hint, while `NSOpenPanel` hands over
/// a URL that has it — and a picker whose selection silently fails to match its own stored
/// value shows nothing selected.
extension OutputDestination: Equatable, Hashable {
    public static func == (lhs: OutputDestination, rhs: OutputDestination) -> Bool {
        switch (lhs, rhs) {
        case (.besideSource, .besideSource): return true
        case let (.fixed(a), .fixed(b)):
            return a.standardizedFileURL.path == b.standardizedFileURL.path
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch self {
        case .besideSource: hasher.combine(0)
        case .fixed(let url):
            hasher.combine(1)
            hasher.combine(url.standardizedFileURL.path)
        }
    }
}

extension OutputDestination {
    /// The app-wide setting, stored the way `FFmpegLocator.overrideDefaultsKey` stores the
    /// tools directory: a plain path string. The app is unsandboxed, so no security-scoped
    /// bookmark is needed to reach the folder again on the next launch.
    public static let defaultsKey = "outputDestinationDirectory"

    /// Absent key means `.besideSource`, so an install that never touches the setting
    /// behaves exactly as it did before the setting existed.
    public static func fromDefaults(_ defaults: UserDefaults = .standard) -> OutputDestination {
        guard let path = defaults.string(forKey: defaultsKey), !path.isEmpty else {
            return .besideSource
        }
        return .fixed(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func writeToDefaults(_ defaults: UserDefaults = .standard) {
        switch self {
        case .besideSource: defaults.removeObject(forKey: Self.defaultsKey)
        case .fixed(let url): defaults.set(url.standardizedFileURL.path, forKey: Self.defaultsKey)
        }
    }

    /// Nil when this destination can be written to right now, otherwise a sentence saying
    /// why not. Checked when the user picks a folder and again when a stored one is read
    /// back at launch — an external volume can be unmounted, and a folder can be moved,
    /// between one run and the next. `Preflight` re-checks writability before any encode
    /// starts, so this is the early warning rather than the safety net.
    ///
    /// `.besideSource` has no answer here: its directory depends on the book, and each
    /// book's own parent is `Preflight`'s to judge.
    public func problem(fileManager: FileManager = .default) -> String? {
        guard case .fixed(let url) = self else { return nil }
        return Preflight.writeProblem(at: url, fileManager: fileManager)
    }

    /// For the inspector's menu and the settings pane.
    public var label: String {
        switch self {
        case .besideSource: return "Beside each source folder"
        case .fixed(let url): return url.path
        }
    }
}
