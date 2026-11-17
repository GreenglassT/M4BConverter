import Foundation

public struct Chapter: Sendable, Equatable {
    public var start: Double
    public var end: Double
    public var title: String

    public init(start: Double, end: Double, title: String) {
        self.start = start
        self.end = end
        self.title = title
    }
}
