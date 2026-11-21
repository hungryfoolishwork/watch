import Foundation

/// Loads playlists and segments for the clip code. HTTP goes through URLSession; file URLs
/// are read directly so that byte ranges work for them too, which URLSession's file loader
/// ignores. That is what lets the tests run the whole pipeline against fixtures on disk.
struct ClipFetcher: Sendable {

    var session: URLSession = .shared

    /// Returns the bytes at `url`, limited to `range` when one is given.
    func data(from url: URL, range: HLSMediaPlaylist.ByteRange? = nil) async throws -> Data {
        try await load(url, range: range).data
    }

    /// Returns playlist text together with the URL it finally came from, so that relative
    /// URIs resolve against the redirect target rather than the URL that was asked for.
    func playlist(from url: URL) async throws -> (text: String, url: URL) {
        let (data, finalURL) = try await load(url, range: nil)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ClipError.invalidPlaylist("not UTF-8 text")
        }
        return (text, finalURL)
    }

    private func load(_ url: URL, range: HLSMediaPlaylist.ByteRange?) async throws -> (data: Data, url: URL) {
        if url.isFileURL {
            guard let range else { return (try Data(contentsOf: url), url) }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(range.offset))
            return (try handle.read(upToCount: range.length) ?? Data(), url)
        }

        var request = URLRequest(url: url)
        if let range {
            request.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { return (data, response.url ?? url) }
        guard (200..<300).contains(http.statusCode) else {
            throw ClipError.http(status: http.statusCode, url: url)
        }
        // A server that ignores Range answers 200 with the whole resource.
        if let range, http.statusCode == 200, data.count > range.length {
            let start = min(range.offset, data.count)
            let end = min(range.offset + range.length, data.count)
            return (data.subdata(in: start..<end), response.url ?? url)
        }
        return (data, response.url ?? url)
    }
}
