import Foundation
import Testing
@testable import M4BConverter

@Test func prefersHomebrewArmPath() {
    let tools = FFmpegLocator.locate(override: nil) { path in
        path.hasPrefix("/opt/homebrew/bin") || path.hasPrefix("/usr/local/bin")
    }
    #expect(tools?.ffmpeg.path == "/opt/homebrew/bin/ffmpeg")
    #expect(tools?.ffprobe.path == "/opt/homebrew/bin/ffprobe")
}

@Test func fallsBackToIntelHomebrewPath() {
    let tools = FFmpegLocator.locate(override: nil) { $0.hasPrefix("/usr/local/bin") }
    #expect(tools?.ffmpeg.path == "/usr/local/bin/ffmpeg")
}

@Test func overrideDirectoryWinsWhenBothToolsExist() {
    let tools = FFmpegLocator.locate(override: "/custom/bin") { $0.hasPrefix("/custom/bin") }
    #expect(tools?.ffmpeg.path == "/custom/bin/ffmpeg")
}

@Test func returnsNilWhenNothingIsExecutable() {
    #expect(FFmpegLocator.locate(override: nil) { _ in false } == nil)
}

@Test func requiresBothBinariesInTheSameDirectory() {
    // ffmpeg present but ffprobe missing -> that directory is not usable
    let tools = FFmpegLocator.locate(override: nil) { $0 == "/opt/homebrew/bin/ffmpeg" }
    #expect(tools == nil)
}
