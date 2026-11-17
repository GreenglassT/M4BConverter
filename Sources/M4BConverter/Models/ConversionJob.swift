import Foundation

public struct ConversionJob: Sendable {
    public var tracks: [TrackInfo]
    public var chapters: [Chapter]
    public var metadata: [String: String]
    public var coverImage: URL?
    public var outputURL: URL
    public var bitRate: Int
    public var sampleRate: Int
    public var channels: Int
    public var totalDuration: Double

    public init(tracks: [TrackInfo], chapters: [Chapter], metadata: [String: String],
                coverImage: URL?, outputURL: URL, bitRate: Int, sampleRate: Int,
                channels: Int, totalDuration: Double) {
        self.tracks = tracks
        self.chapters = chapters
        self.metadata = metadata
        self.coverImage = coverImage
        self.outputURL = outputURL
        self.bitRate = bitRate
        self.sampleRate = sampleRate
        self.channels = channels
        self.totalDuration = totalDuration
    }
}
