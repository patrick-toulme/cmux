import Foundation

/// Live sidebar ordering by agent attention ("sort by active sessions"):
/// sessions whose agents need the user, or are working, bubble upward as
/// state changes.
public enum WorkspaceActivitySortMode: String, CaseIterable, Sendable, SettingCodable {
    /// Manual ordering only (default).
    case off
    /// Sort inside each machine section (and the local group); nothing
    /// crosses a section boundary.
    case withinSections = "within-sections"
    /// Sort across the whole sidebar; machine sections interleave by
    /// attention (each run re-renders its header).
    case global
}
