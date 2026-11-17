import Foundation

public struct TrackInfo: Sendable, Equatable {
    public var url: URL
    public var estimatedDuration: Double
    public var codecName: String
    public var sampleRate: Int
    public var channels: Int
    public var bitRate: Int
    public var tags: [String: String]
    public var embeddedArtCodec: String?

    public init(url: URL,
                estimatedDuration: Double = 0,
                codecName: String = "mp3",
                sampleRate: Int = 44100,
                channels: Int = 2,
                bitRate: Int = 64000,
                tags: [String: String] = [:],
                embeddedArtCodec: String? = nil) {
        self.url = url
        self.estimatedDuration = estimatedDuration
        self.codecName = codecName
        self.sampleRate = sampleRate
        self.channels = channels
        self.bitRate = bitRate
        self.tags = tags
        self.embeddedArtCodec = embeddedArtCodec
    }

    public var filename: String { url.lastPathComponent }

    /// Whether the file's REAL codec is MP3, which the `.mp3` extension does not settle:
    /// a rip or a batch conversion that renamed rather than re-encoded leaves AAC, ALAC
    /// or FLAC under an MP3 name, and the scanner selects by extension alone.
    ///
    /// ffprobe reports `codec_name` as "mp3" for a genuine MP3 (verified against ffmpeg
    /// 8.1); "mp3float" is the decoder's own name, which reaches `codec_name` on some
    /// builds, so accept it too. Matched case-insensitively — nothing guarantees the
    /// case ffprobe chooses.
    public var isMP3: Bool { ["mp3", "mp3float"].contains(codecName.lowercased()) }
}
