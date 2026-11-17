import Foundation
import Testing
@testable import M4BConverter

@Test func metadataStartsWithMagicHeader() {
    let text = FFMetadataWriter.render(metadata: ["title": "Book"], chapters: [])
    #expect(text.hasPrefix(";FFMETADATA1\n"))
}

@Test func metadataEscapesReservedCharacters() {
    let text = FFMetadataWriter.render(metadata: ["title": "A=B;C#D\\E"], chapters: [])
    #expect(text.contains("title=A\\=B\\;C\\#D\\\\E"))
}

@Test func metadataSkipsEmptyValues() {
    let text = FFMetadataWriter.render(metadata: ["title": "X", "artist": ""], chapters: [])
    #expect(!text.contains("artist="))
}

@Test func chaptersRenderWithMillisecondTimebase() {
    let text = FFMetadataWriter.render(
        metadata: [:],
        chapters: [Chapter(start: 0, end: 1.5, title: "One")]
    )
    #expect(text.contains("[CHAPTER]"))
    #expect(text.contains("TIMEBASE=1/1000"))
    #expect(text.contains("START=0"))
    #expect(text.contains("END=1500"))
    #expect(text.contains("title=One"))
}

@Test func concatListQuotesPathsAndEscapesSingleQuotes() throws {
    let urls = [URL(fileURLWithPath: "/books/Rock 'n' Roll.mp3")]
    let text = try ConcatListWriter.render(urls)
    #expect(text == "file '/books/Rock '\\''n'\\'' Roll.mp3'\n")
}

@Test func concatListHandlesSpacesInPaths() throws {
    let text = try ConcatListWriter.render([URL(fileURLWithPath: "/M4B Converter/a.mp3")])
    #expect(text == "file '/M4B Converter/a.mp3'\n")
}

// Swift groups CRLF into one grapheme cluster, so a Character-based escape loop
// misses it entirely and ffmpeg truncates the tag at the CR. Verified: before the
// fix, a comment of "line1\r\nline2" came back from ffprobe as just "line1".
@Test func metadataEscapesCarriageReturnsAndCRLF() {
    let crlf = FFMetadataWriter.render(metadata: ["comment": "line1\r\nline2"], chapters: [])
    #expect(crlf.contains("\\\r\\\n"))

    let bareCR = FFMetadataWriter.render(metadata: ["comment": "a\rb"], chapters: [])
    #expect(bareCR.contains("\\\r"))
}

@Test func metadataEscapesKeysAsWellAsValues() {
    let text = FFMetadataWriter.render(metadata: ["we=ird": "v"], chapters: [])
    #expect(text.contains("we\\=ird=v"))
}

@Test func concatListRejectsPathsContainingNewlines() {
    #expect(throws: ConcatListWriter.Failure.self) {
        _ = try ConcatListWriter.render([URL(fileURLWithPath: "/books/bad\nname.mp3")])
    }
}

@Test func metadataRendersMultipleChaptersInOrder() {
    let text = FFMetadataWriter.render(metadata: [:], chapters: [
        Chapter(start: 0, end: 1.5, title: "One"),
        Chapter(start: 1.5, end: 3.0, title: "Two"),
    ])
    let firstStart = text.range(of: "START=0")
    let secondStart = text.range(of: "START=1500")
    #expect(firstStart != nil && secondStart != nil)
    #expect(firstStart!.lowerBound < secondStart!.lowerBound)
    #expect(text.contains("END=3000"))
}

@Test func emptyDocumentIsJustTheHeader() {
    #expect(FFMetadataWriter.render(metadata: [:], chapters: []) == ";FFMETADATA1\n")
}
