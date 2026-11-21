import Foundation

/// Everything the clip code throws on its own account. Errors from URLSession and
/// AVFoundation are passed through unchanged.
public enum ClipError: Error, Sendable, Equatable, LocalizedError {
    /// The playlist text could not be understood. The payload says what was wrong.
    case invalidPlaylist(String)
    /// The playlist parsed but lists no variants or no segments.
    case emptyPlaylist
    /// The segments are encrypted (`#EXT-X-KEY` with a method other than `NONE`).
    case encrypted
    /// A playlist or segment request came back with a non-2xx status.
    case http(status: Int, url: URL)
    /// The stream uses a container or codec the remuxer can't carry into MP4. The payload
    /// names it.
    case unsupportedMedia(String)
    /// The requested range is empty once clamped to the snapshot.
    case emptyRange
    /// The downloaded segments held no decodable video or audio inside the range.
    case noSamples
    /// AVAssetWriter refused the samples or failed to finish the file.
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPlaylist(let reason): "The stream playlist could not be read (\(reason))."
        case .emptyPlaylist: "The stream playlist is empty."
        case .encrypted: "The stream is encrypted and can't be clipped."
        case .http(let status, _): "The stream server answered with HTTP \(status)."
        case .unsupportedMedia(let what): "The stream uses a format that can't be clipped (\(what))."
        case .emptyRange: "The selected range is empty."
        case .noSamples: "The selected range contains no playable media."
        case .writeFailed(let reason): "The clip could not be written (\(reason))."
        }
    }
}
