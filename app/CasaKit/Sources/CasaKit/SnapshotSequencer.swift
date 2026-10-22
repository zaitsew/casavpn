import Foundation

/// Orders overlapping refreshes. Each request takes a number when it starts; a result is
/// accepted only if it is newer than the last accepted one, so a slow old answer can never
/// replace a newer one.
public struct SnapshotSequencer: Sendable {
    private var issued = 0
    private var accepted = 0

    public init() {}

    public mutating func begin() -> Int {
        issued += 1
        return issued
    }

    /// True when `ticket` is newer than every result accepted so far (and records it).
    public mutating func accept(_ ticket: Int) -> Bool {
        guard ticket > accepted else { return false }
        accepted = ticket
        return true
    }
}
