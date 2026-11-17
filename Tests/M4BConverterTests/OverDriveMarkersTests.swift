import Foundation
import Testing
@testable import M4BConverter

@Test func parsesNameAndTimePairs() {
    let xml = "<Markers><Marker><Name>Frankenstein</Name><Time>0:00.000</Time></Marker>" +
              "<Marker><Name>Epigraph</Name><Time>0:29.000</Time></Marker></Markers>"
    let marks = OverDriveMarkers.parse(xml)
    #expect(marks.count == 2)
    #expect(marks[0].title == "Frankenstein")
    #expect(abs(marks[1].seconds - 29.0) < 0.001)
}

@Test func minutesMayExceedSixty() {
    // Real OverDrive data uses 62:44.000 rather than 1:02:44.000
    let marks = OverDriveMarkers.parse("<Name>Late</Name><Time>62:44.000</Time>")
    #expect(abs(marks[0].seconds - 3764.0) < 0.001)
}

@Test func parsesHourMinuteSecondForm() {
    let marks = OverDriveMarkers.parse("<Name>X</Name><Time>1:02:03.500</Time>")
    #expect(abs(marks[0].seconds - 3723.5) < 0.001)
}

@Test func decodesHTMLEntities() {
    let marks = OverDriveMarkers.parse("<Name>Tom &amp; Jerry &#8212; End</Name><Time>0:01.000</Time>")
    #expect(marks[0].title == "Tom & Jerry — End")
}

@Test func returnsEmptyForNonMarkerText() {
    #expect(OverDriveMarkers.parse("not xml at all").isEmpty)
}

// A marker missing its <Time> must be skipped, not merged into its neighbour.
// A lazy name capture would run past </Name> to the NEXT marker's <Time>,
// producing a garbled title paired with the wrong timestamp.
@Test func markerMissingTimeIsSkippedNotMerged() {
    let xml = "<Marker><Name>NoTimeHere</Name></Marker>" +
              "<Marker><Name>HasTime</Name><Time>0:10.000</Time></Marker>"
    let marks = OverDriveMarkers.parse(xml)
    #expect(marks.count == 1)
    #expect(marks[0].title == "HasTime")
    #expect(abs(marks[0].seconds - 10.0) < 0.001)
}

@Test func rejectsMalformedTimestamps() {
    #expect(OverDriveMarkers.seconds(from: "") == nil)
    #expect(OverDriveMarkers.seconds(from: ":") == nil)
    #expect(OverDriveMarkers.seconds(from: "1:2:3:4") == nil)
    #expect(OverDriveMarkers.seconds(from: "abc") == nil)
    #expect(OverDriveMarkers.seconds(from: "-5:00") == nil)
    #expect(OverDriveMarkers.seconds(from: "1:") == nil)
    #expect(OverDriveMarkers.seconds(from: "12::30") == nil)
    #expect(OverDriveMarkers.seconds(from: "10:00Z") == nil)
}

@Test func astralCharactersSurviveEntityDecoding() {
    let marks = OverDriveMarkers.parse("<Name>Dive 🐋 &#8212; deep</Name><Time>0:05.000</Time>")
    #expect(marks[0].title == "Dive 🐋 — deep")
}
