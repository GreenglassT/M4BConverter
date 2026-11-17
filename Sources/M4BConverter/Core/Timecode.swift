import Foundation

/// The one place a chapter time becomes text and text becomes a chapter time.
///
/// Forgiving about what it parses, strict about what it stores. A user correcting a
/// boundary in the chapter table types what they read off their player — `1:04:30`,
/// `64:30`, `3870`, sometimes with a comma for the decimal point — and none of those
/// spellings is wrong. What is kept, though, is rounded to the millisecond, because a
/// millisecond is the resolution the .m4b metadata has: `FFMetadataWriter` renders
/// `TIMEBASE=1/1000` and rounds to it. Without the rounding, `format` and `parse` would
/// disagree in the last digit, and a field the user merely tabbed through would commit a
/// value a hair from the one on screen.
public enum Timecode {
    /// `h:mm:ss`, with `.mmm` appended only when the value is not a whole second.
    ///
    /// Hours always, even for a short book. `1:00` is ambiguous on sight — one minute or
    /// one hour — and this string is not just displayed, it is the text the user edits.
    public static func format(_ seconds: Double) -> String {
        // Non-finite reaches here from a duration ffprobe reported as "nan" or "inf";
        // `Int64(nan)` traps.
        guard seconds.isFinite, seconds > 0 else { return "0:00:00" }
        let milliseconds = Int64((seconds * 1000).rounded())
        let base = String(format: "%d:%02d:%02d",
                          milliseconds / 3_600_000,
                          (milliseconds % 3_600_000) / 60_000,
                          (milliseconds % 60_000) / 1000)
        let fraction = milliseconds % 1000
        return fraction == 0 ? base : base + String(format: ".%03d", fraction)
    }

    /// Seconds, or nil when the text is not a time at all.
    ///
    /// One, two or three colon-separated fields — seconds, `m:ss`, `h:mm:ss` — the last of
    /// which may carry a fraction. Overflowing fields are accepted (`1:90` is 150 s): the
    /// user is correcting a number, not filling in a form, and refusing that would be
    /// pedantry. A negative sign is not: every chapter time is an offset into the book.
    public static func parse(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
                          .replacingOccurrences(of: ",", with: ".")
        let fields = trimmed.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(fields.count) else { return nil }

        var seconds = 0.0
        for (index, field) in fields.enumerated() {
            guard let value = number(field, allowingFraction: index == fields.count - 1) else {
                return nil
            }
            seconds = seconds * 60 + value
        }
        return (seconds * 1000).rounded() / 1000
    }

    /// Digits, and at most one decimal point in the final field. Deliberately not
    /// `Double.init` alone, which accepts "1e3", "0x1p3", "inf" and "-0".
    private static func number(_ text: Substring, allowingFraction: Bool) -> Double? {
        guard !text.isEmpty,
              text.allSatisfy({ $0.isASCII && ($0.isNumber || ($0 == "." && allowingFraction)) }),
              text.filter({ $0 == "." }).count <= 1 else { return nil }
        return Double(text)
    }
}
