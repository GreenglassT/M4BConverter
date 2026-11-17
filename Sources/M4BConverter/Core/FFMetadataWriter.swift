import Foundation

public enum FFMetadataWriter {
    public static func render(metadata: [String: String], chapters: [Chapter]) -> String {
        var lines = [";FFMETADATA1"]
        for key in metadata.keys.sorted() {
            let value = metadata[key] ?? ""
            guard !value.isEmpty else { continue }
            lines.append("\(escape(key))=\(escape(value))")
        }
        for chapter in chapters {
            lines.append("[CHAPTER]")
            lines.append("TIMEBASE=1/1000")
            lines.append("START=\(Int((chapter.start * 1000).rounded()))")
            lines.append("END=\(Int((chapter.end * 1000).rounded()))")
            lines.append("title=\(escape(chapter.title))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func escape(_ value: String) -> String {
        var out = ""
        // Iterate unicode scalars, NOT Characters. Swift groups CRLF into a single
        // extended grapheme cluster, so a Character-based loop matches neither "\r"
        // nor "\n" and lets a Windows line break through unescaped — ffmpeg then
        // truncates the value at the CR, silently losing everything after it.
        for scalar in value.unicodeScalars {
            switch scalar {
            case "=", ";", "#", "\\", "\n", "\r":
                out.append("\\")
            default:
                break
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }
}
