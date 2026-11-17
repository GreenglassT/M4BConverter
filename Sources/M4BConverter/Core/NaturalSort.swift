import Foundation

enum NaturalToken: Comparable {
    case number(Int)
    case text(String)

    static func < (lhs: NaturalToken, rhs: NaturalToken) -> Bool {
        switch (lhs, rhs) {
        case let (.number(a), .number(b)): return a < b
        case let (.text(a), .text(b)): return a < b
        case (.number, .text): return true
        case (.text, .number): return false
        }
    }
}

func naturalTokens(_ s: String) -> [NaturalToken] {
    var out: [NaturalToken] = []
    var current = ""
    var currentIsDigit: Bool?

    func flush() {
        guard let isDigit = currentIsDigit, !current.isEmpty else { return }
        out.append(isDigit ? .number(Int(current) ?? Int.max) : .text(current))
        current = ""
    }

    for ch in s.lowercased() {
        let isDigit = ch.isNumber
        if currentIsDigit == nil || isDigit == currentIsDigit {
            current.append(ch)
        } else {
            flush()
            current = String(ch)
        }
        currentIsDigit = isDigit
    }
    flush()
    return out
}

/// Compares two strings in natural order: digit runs compare numerically rather
/// than lexically, so "Chapter 2" precedes "Chapter 10". Comparison is
/// case-insensitive. When one string's tokens are a prefix of the other's, the
/// shorter sorts first.
///
/// Digit runs that cannot be parsed as `Int` — non-ASCII numerals such as
/// fullwidth `１２３`, Arabic-Indic `٣`, or Roman numerals, and runs long enough to
/// overflow `Int` — are treated as `Int.max` and therefore sort after all
/// ordinary numbered files. This is deliberate and pinned by tests.
public func naturalLess(_ a: String, _ b: String) -> Bool {
    let ta = naturalTokens(a), tb = naturalTokens(b)
    for (x, y) in zip(ta, tb) where x != y { return x < y }
    return ta.count < tb.count
}
