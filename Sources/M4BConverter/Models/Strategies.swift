import Foundation

public enum OrderStrategy: String, Sendable, CaseIterable, Identifiable {
    case filename
    case trackTag

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .filename: return "Filename"
        case .trackTag: return "Track tag"
        }
    }
}

public enum ChapterStrategy: Sendable, Equatable, Hashable {
    case overdriveMarkers
    case fileBoundaries
    case filenamePattern(String)

    public static let defaultFilenamePattern = #"- \d+ - (.+)\.mp3$"#

    public var label: String {
        switch self {
        case .overdriveMarkers: return "OverDrive markers"
        case .fileBoundaries: return "One per file"
        case .filenamePattern: return "Filename pattern"
        }
    }
}
