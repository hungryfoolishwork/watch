import Foundation

/// A saved clip: an .mp4 in the clips folder. The file is the record. Its
/// name is the clip's name, so renaming or deleting it in Finder is the same
/// as doing it in Watch.
public struct Clip: Identifiable, Hashable, Sendable {
    public let url: URL
    public let created: Date

    /// Nil until the file has been read.
    public var duration: TimeInterval?

    public var id: String { url.lastPathComponent }
    public var name: String { url.deletingPathExtension().lastPathComponent }

    public init(url: URL, created: Date, duration: TimeInterval? = nil) {
        self.url = url
        self.created = created
        self.duration = duration
    }
}
