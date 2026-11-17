import Foundation

public struct FFmpegTools: Sendable, Equatable {
    public var ffmpeg: URL
    public var ffprobe: URL
}

public enum FFmpegLocator {
    public static let defaultSearchDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
    ]

    public static let overrideDefaultsKey = "ffmpegDirectoryOverride"

    public static func locate(
        override: String?,
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> FFmpegTools? {
        var directories: [String] = []
        if let override, !override.isEmpty { directories.append(override) }
        directories.append(contentsOf: defaultSearchDirectories)

        for directory in directories {
            let ffmpeg = "\(directory)/ffmpeg"
            let ffprobe = "\(directory)/ffprobe"
            if isExecutable(ffmpeg), isExecutable(ffprobe) {
                return FFmpegTools(ffmpeg: URL(fileURLWithPath: ffmpeg),
                                   ffprobe: URL(fileURLWithPath: ffprobe))
            }
        }
        return nil
    }

    public static func locateFromDefaults() -> FFmpegTools? {
        locate(override: UserDefaults.standard.string(forKey: overrideDefaultsKey))
    }
}
