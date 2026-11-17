import Foundation

public enum TrackOrderer {
    public static func trackNumber(_ info: TrackInfo) -> Int? {
        guard let raw = info.tags["track"] else { return nil }
        let digits = raw.prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }

    public static func order(_ tracks: [TrackInfo], by strategy: OrderStrategy) -> [TrackInfo] {
        switch strategy {
        case .filename:
            return tracks.sorted { naturalLess($0.filename, $1.filename) }
        case .trackTag:
            return tracks.enumerated().sorted { a, b in
                let na = trackNumber(a.element), nb = trackNumber(b.element)
                switch (na, nb) {
                case let (x?, y?):
                    if x != y { return x < y }
                    return a.offset < b.offset
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil):
                    let fa = a.element.filename, fb = b.element.filename
                    if fa != fb { return naturalLess(fa, fb) }
                    return a.offset < b.offset
                }
            }.map(\.element)
        }
    }
}
