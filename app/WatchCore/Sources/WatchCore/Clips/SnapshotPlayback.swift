import AVFoundation
import Foundation

/// Plays a `LiveSnapshot` as an ordinary seekable video, running from zero to the snapshot's
/// duration, with sound.
///
/// AVPlayer refuses to play an HLS playlist from a `file:` URL, so the snapshot is described
/// by playlists that exist only in memory. The asset's URL uses a private scheme, which
/// makes AVFoundation ask this object's resource loader delegate for the playlists; those
/// are finished (`#EXT-X-ENDLIST`) listings of the frozen segments. The segments themselves
/// keep their original `https:` URLs, so AVPlayer downloads media straight from the stream's
/// servers just as it does for the live tile. No local server and no copy of the media is
/// involved.
///
/// Keep this object alive for as long as the asset is in use: the resource loader holds its
/// delegate weakly.
public final class SnapshotPlayback: Sendable {

    /// The asset to hand to `AVPlayerItem`.
    public let asset: AVURLAsset

    private let loader: PlaylistLoader

    public init(_ snapshot: LiveSnapshot) {
        let playlists = snapshot.playbackPlaylists()
        var files = ["master.m3u8": playlists.master, "video.m3u8": playlists.video]
        files["audio.m3u8"] = playlists.audio
        loader = PlaylistLoader(files: files.mapValues { Data($0.utf8) })

        // The host only makes each asset's URLs distinct from one another's.
        let url = URL(string: "\(PlaylistLoader.scheme)://\(UUID().uuidString)/master.m3u8")!
        asset = AVURLAsset(url: url)
        asset.resourceLoader.setDelegate(loader, queue: loader.queue)
    }
}

/// Answers AVFoundation's requests for the in-memory playlists.
private final class PlaylistLoader: NSObject, AVAssetResourceLoaderDelegate, Sendable {

    static let scheme = "watch-snapshot"

    let queue = DispatchQueue(label: "watch.snapshot-playback")
    private let files: [String: Data]

    init(files: [String: Data]) {
        self.files = files
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let url = loadingRequest.request.url, url.scheme == Self.scheme, let data = files[url.lastPathComponent] else {
            return false
        }
        if let information = loadingRequest.contentInformationRequest {
            information.contentType = "public.m3u-playlist"
            information.contentLength = Int64(data.count)
            information.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
        return true
    }
}

extension LiveSnapshot {

    /// The playlists that present this snapshot as video on demand: a master naming one
    /// variant (and the audio rendition, when it is separate) and a finished media playlist
    /// per rendition. The master refers to the media playlists by relative name; segment
    /// URIs are absolute.
    func playbackPlaylists() -> (master: String, video: String, audio: String?) {
        var master = ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"]
        if audio != nil {
            master.append(#"#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="Default",DEFAULT=YES,AUTOSELECT=YES,URI="audio.m3u8""#)
        }
        // BANDWIDTH is the one required attribute. The value only matters for choosing
        // between variants, and there is just this one, but the player logs an error for
        // every segment larger than it promises. When the snapshot came from a bare media
        // playlist and the real figure is unknown, promise more than any stream uses.
        let bandwidth = variant.map(\.bandwidth).flatMap { $0 > 0 ? $0 : nil } ?? 50_000_000
        var attributes = ["BANDWIDTH=\(bandwidth)"]
        if let codecs = variant?.codecs, !codecs.isEmpty {
            attributes.append("CODECS=\"\(codecs.joined(separator: ","))\"")
        }
        if let width = variant?.width, let height = variant?.height {
            attributes.append("RESOLUTION=\(width)x\(height)")
        }
        if let frameRate = variant?.frameRate {
            attributes.append("FRAME-RATE=\(String(format: "%.3f", frameRate))")
        }
        if audio != nil {
            attributes.append("AUDIO=\"audio\"")
        }
        master.append("#EXT-X-STREAM-INF:" + attributes.joined(separator: ","))
        master.append("video.m3u8")

        return (
            master.joined(separator: "\n") + "\n",
            Self.mediaPlaylist(video),
            audio.map(Self.mediaPlaylist)
        )
    }

    private static func mediaPlaylist(_ segments: [Segment]) -> String {
        let longest = segments.map(\.duration).max() ?? 0
        var lines = [
            "#EXTM3U",
            "#EXT-X-VERSION:7",
            "#EXT-X-TARGETDURATION:\(Int(longest.rounded(.up)))",
            "#EXT-X-MEDIA-SEQUENCE:0",
            "#EXT-X-PLAYLIST-TYPE:VOD",
        ]
        var previous: Segment?
        for segment in segments {
            if let previous, previous.discontinuitySequence != segment.discontinuitySequence {
                lines.append("#EXT-X-DISCONTINUITY")
            }
            if let map = segment.map, map != previous?.map {
                var tag = "#EXT-X-MAP:URI=\"\(map.url.absoluteString)\""
                if let range = map.byteRange {
                    tag += ",BYTERANGE=\"\(range.length)@\(range.offset)\""
                }
                lines.append(tag)
            }
            lines.append("#EXTINF:\(String(format: "%.6f", segment.duration)),")
            if let range = segment.byteRange {
                lines.append("#EXT-X-BYTERANGE:\(range.length)@\(range.offset)")
            }
            lines.append(segment.url.absoluteString)
            previous = segment
        }
        lines.append("#EXT-X-ENDLIST")
        return lines.joined(separator: "\n") + "\n"
    }
}
