import Foundation

public struct OverDriveMarker: Sendable, Equatable {
    public var seconds: Double
    public var title: String
}

public enum OverDriveMarkers {
    public static let tagKey = "overdrive mediamarkers"

    private static let pattern = try! NSRegularExpression(
        pattern: "<Name>([^<]*)</Name>\\s*<Time>([^<]*)</Time>",
        options: [.dotMatchesLineSeparators]
    )

    /// Parses `<Name>`/`<Time>` pairs from an OverDrive MediaMarkers tag.
    ///
    /// Returns markers in document order with no sorting, deduplication, or
    /// monotonicity guarantee — callers must handle out-of-order or duplicate
    /// timestamps themselves. Pairs missing either element are skipped.
    /// Hexadecimal entities (`&#x2014;`) are not decoded; OverDrive emits
    /// decimal form.
    public static func parse(_ xml: String) -> [OverDriveMarker] {
        let ns = xml as NSString
        let matches = pattern.matches(in: xml, range: NSRange(location: 0, length: ns.length))
        return matches.compactMap { m in
            let name = ns.substring(with: m.range(at: 1))
            let time = ns.substring(with: m.range(at: 2))
            guard let secs = seconds(from: time) else { return nil }
            return OverDriveMarker(seconds: secs,
                                   title: decodeEntities(name).trimmingCharacters(in: .whitespaces))
        }
    }

    /// "0:29.000", "62:44.000" and "1:02:03.500" all fold left-to-right.
    /// Rejects anything that is not 1–3 non-negative, finite, colon-separated
    /// segments, so malformed input yields nil rather than a plausible-looking
    /// timestamp that would place a chapter mark in the wrong spot.
    static func seconds(from text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces)
            .split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0, value.isFinite else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Hoisted, like `pattern` above. Compiling this per call meant hundreds of
    /// NSRegularExpression builds for every `recompute()` — one per marker per file.
    private static let numericEntity = try! NSRegularExpression(pattern: "&#(\\d+);")

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (entity, replacement) in [("&lt;", "<"), ("&gt;", ">"),
                                      ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        let ns = out as NSString
        var result = ""
        var last = 0
        for m in numericEntity.matches(in: out,
                                       range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            if let code = UInt32(ns.substring(with: m.range(at: 1))),
               let scalar = Unicode.Scalar(code) {
                result.append(Character(scalar))
            }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
