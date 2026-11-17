import Foundation
import Testing
@testable import M4BConverter

private let fixture = """
{
  "streams": [
    { "codec_type": "audio", "codec_name": "mp3", "sample_rate": "44100",
      "channels": 2, "bit_rate": "64000" },
    { "codec_type": "video", "codec_name": "mjpeg" }
  ],
  "format": {
    "duration": "4387.829875",
    "bit_rate": "64009",
    "tags": {
      "artist": "Mary Shelley",
      "TITLE": "Frankenstein - Part 1",
      "OverDrive MediaMarkers": "<Name>Epigraph</Name><Time>0:29.000</Time>"
    }
  }
}
"""

@Test func parsesAudioStreamProperties() throws {
    let info = try MediaProbe.parse(json: Data(fixture.utf8),
                                    url: URL(fileURLWithPath: "/b/a.mp3"))
    #expect(info.codecName == "mp3")
    #expect(info.sampleRate == 44100)
    #expect(info.channels == 2)
    #expect(info.bitRate == 64000)
    #expect(abs(info.estimatedDuration - 4387.829875) < 0.001)
}

@Test func lowercasesTagKeys() throws {
    let info = try MediaProbe.parse(json: Data(fixture.utf8),
                                    url: URL(fileURLWithPath: "/b/a.mp3"))
    #expect(info.tags["title"] == "Frankenstein - Part 1")
    #expect(info.tags[OverDriveMarkers.tagKey] != nil)
}

@Test func detectsEmbeddedArtCodec() throws {
    let info = try MediaProbe.parse(json: Data(fixture.utf8),
                                    url: URL(fileURLWithPath: "/b/a.mp3"))
    #expect(info.embeddedArtCodec == "mjpeg")
}

@Test func fallsBackToFormatBitrateWhenStreamLacksOne() throws {
    let json = """
    {"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"22050","channels":1}],
     "format":{"duration":"10.0","bit_rate":"64070"}}
    """
    let info = try MediaProbe.parse(json: Data(json.utf8), url: URL(fileURLWithPath: "/b/a.mp3"))
    #expect(info.bitRate == 64070)
    #expect(info.embeddedArtCodec == nil)
}

@Test func throwsWhenNoAudioStreamPresent() {
    let json = #"{"streams":[],"format":{"duration":"1.0"}}"#
    #expect(throws: (any Error).self) {
        try MediaProbe.parse(json: Data(json.utf8), url: URL(fileURLWithPath: "/b/a.mp3"))
    }
}

// ffprobe can emit "title" (standard TIT2) and "TITLE" (a TXXX frame whose
// description is TITLE) for the same file. Both lowercase to "title", so the
// winner must be chosen deterministically rather than by dictionary ordering.
@Test func collidingTagKeysResolveDeterministically() throws {
    let json = """
    {"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2}],
     "format":{"duration":"1.0","tags":{"title":"Standard TIT2 Title","TITLE":"Custom TXXX Title"}}}
    """
    var seen = Set<String>()
    for _ in 0..<200 {
        let info = try MediaProbe.parse(json: Data(json.utf8), url: URL(fileURLWithPath: "/b/a.mp3"))
        seen.insert(info.tags["title"] ?? "<nil>")
    }
    #expect(seen.count == 1)
    #expect(seen.first == "Standard TIT2 Title")
}

@Test func outOfRangeNumericValuesDoNotTrap() throws {
    func bitRate(_ literal: String) throws -> Int {
        let json = """
        {"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2,"bit_rate":\(literal)}],
         "format":{"duration":"1.0"}}
        """
        return try MediaProbe.parse(json: Data(json.utf8), url: URL(fileURLWithPath: "/b/a.mp3")).bitRate
    }
    #expect(try bitRate("1e20") == 64000)     // beyond Int.max -> falls back
    #expect(try bitRate("-1e400") == 64000)   // -inf -> falls back
    #expect(try bitRate("128000") == 128000)  // ordinary value still parsed
}

// `int()` guards `isFinite` because JSON permits infinity; `double()` did not, and a
// non-finite duration reaches `Int(seconds)` in formatHours, `Int64(...)` in Preflight
// and `Int(...)` in FFMetadataWriter — each of which traps, killing the app on a file
// ffprobe merely described oddly.
@Test func nonFiniteDurationsDoNotSurviveParsing() throws {
    func duration(_ literal: String) throws -> Double {
        let json = """
        {"streams":[{"codec_type":"audio","codec_name":"mp3","sample_rate":"44100","channels":2}],
         "format":{"duration":\(literal)}}
        """
        return try MediaProbe.parse(json: Data(json.utf8),
                                    url: URL(fileURLWithPath: "/b/a.mp3")).estimatedDuration
    }
    #expect(try duration("\"inf\"") == 0)
    #expect(try duration("\"-inf\"") == 0)
    #expect(try duration("\"nan\"") == 0)
    // JSONSerialization rejects a positive overflow but hands back -inf for this one.
    #expect(try duration("-1e400") == 0)
    #expect(try duration("\"10.5\"") == 10.5) // ordinary value still parsed
    // The trap itself, exercised rather than argued about.
    #expect(formatHours(try duration("\"inf\"")) == "0m")
}
