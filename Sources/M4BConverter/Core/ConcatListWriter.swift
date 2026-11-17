import Foundation

public enum ConcatListWriter {
    public enum Failure: Error, LocalizedError {
        case pathContainsNewline(URL)

        public var errorDescription: String? {
            switch self {
            case .pathContainsNewline(let url):
                return "Cannot process \(url.lastPathComponent): the file path contains a line break."
            }
        }
    }

    /// ffmpeg's concat demuxer splits the script on raw newlines before it parses
    /// quoting, so a path containing one cannot be represented by any escaping and
    /// would corrupt every following entry. Reject it instead of emitting it.
    public static func render(_ urls: [URL]) throws -> String {
        for url in urls where url.path.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" }) {
            throw Failure.pathContainsNewline(url)
        }
        return urls.map { "file '\(escape($0.path))'\n" }.joined()
    }

    static func escape(_ path: String) -> String {
        path.replacingOccurrences(of: "'", with: "'\\''")
    }
}
