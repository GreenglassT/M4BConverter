import Testing
@testable import M4BConverter

@Test func numbersCompareNumericallyNotLexically() {
    #expect(naturalLess("Chapter 2.mp3", "Chapter 10.mp3"))
    #expect(!naturalLess("Chapter 10.mp3", "Chapter 2.mp3"))
}

@Test func comparisonIsCaseInsensitive() {
    #expect(naturalLess("apple", "Banana"))
}

@Test func zeroPaddedAndBareNumbersAgree() {
    #expect(naturalLess("track 007", "track 8"))
}

@Test func trailingLetterSuffixesOrderCorrectly() {
    // Some rips use 01a / 01b / 02a
    #expect(naturalLess("Treasure Island - 01a.mp3", "Treasure Island - 01b.mp3"))
    #expect(naturalLess("Treasure Island - 01b.mp3", "Treasure Island - 02a.mp3"))
}

@Test func identicalStringsAreNotLess() {
    #expect(!naturalLess("same", "same"))
}

@Test func handlesEmptyStrings() {
    #expect(!naturalLess("", ""))
    #expect(naturalLess("", "a"))
    #expect(!naturalLess("a", ""))
}

@Test func pureNumeralStringsCompareNumerically() {
    #expect(naturalLess("2", "10"))
    #expect(!naturalLess("10", "2"))
}

@Test func handlesNonASCIITitles() {
    // Accented and hyphenated titles, as real filenames carry them
    #expect(naturalLess("Misérables - 02 - Chapter 1.mp3", "Misérables - 10 - Chapter 9.mp3"))
    #expect(naturalLess("Moby-Dick - 05.mp3", "Moby-Dick - 40.mp3"))

    // Case-insensitive: strings differing only in case are equivalent,
    // so neither precedes the other in either direction.
    #expect(!naturalLess("MISÉRABLES.mp3", "misérables.mp3"))
    #expect(!naturalLess("misérables.mp3", "MISÉRABLES.mp3"))

    // Case is ignored while digits still compare numerically.
    #expect(naturalLess("MISÉRABLES - 2.mp3", "misérables - 10.mp3"))
}

// Pins the Int.max fallback: unparseable digit runs sort after real numbers.
// Deterministic and intentional, not a bug — but must not change silently.
@Test func unparseableDigitRunsSortLast() {
    #expect(naturalLess("Chapter 75.mp3", "Chapter Ⅷ.mp3"))
    #expect(!naturalLess("Chapter Ⅷ.mp3", "Chapter 2.mp3"))
}
