import Foundation

/// How many tiles a playlist shows at once. These are the only two grids.
public enum GridSize: Int, Codable, Sendable, CaseIterable, Identifiable {
    case two = 2
    case three = 3

    public var id: Int { rawValue }

    /// Tiles on screen: 4 or 9.
    public var tiles: Int { rawValue * rawValue }

    public var label: String { "\(rawValue) × \(rawValue)" }
}

/// A named set of channels and where each one sits in the grid.
///
/// A playlist can hold more channels than its grid shows. `channels` is
/// everything in it; `tiles` says which of them is at each of the nine
/// positions. A 2×2 grid shows the first four positions; the other five keep
/// their channel, so going to 3×3 and back restores what was there.
public struct Playlist: Identifiable, Hashable, Sendable {
    public static let positions = 9

    public let id: String
    public var name: String
    public private(set) var grid: GridSize

    /// Every channel in the playlist, by id, in the order the tile menu lists them.
    public private(set) var channels: [String]

    /// The channel at each of the nine positions, left to right, top to
    /// bottom. Always `positions` long, with no channel twice.
    public private(set) var tiles: [String?]

    public init(id: String = UUID().uuidString, name: String, grid: GridSize = .two, channels: [String] = []) {
        self.id = id
        self.name = name
        self.grid = grid
        self.channels = []
        self.tiles = Array(repeating: nil, count: Self.positions)
        for channel in channels { add(channel) }
    }

    /// The channels on screen: the first `grid.tiles` positions.
    public var visible: [String?] {
        Array(tiles.prefix(grid.tiles))
    }

    public func position(of channel: String) -> Int? {
        tiles.firstIndex(of: channel)
    }

    // MARK: Editing

    /// Adds a channel to the playlist and gives it the first empty tile on
    /// screen, if there is one.
    public mutating func add(_ channel: String) {
        guard !channels.contains(channel) else { return }
        channels.append(channel)
        fill()
    }

    public mutating func remove(_ channel: String) {
        channels.removeAll { $0 == channel }
        if let position = position(of: channel) {
            tiles[position] = nil
        }
        fill()
    }

    /// Puts a channel at a position, adding it to the playlist if it's new.
    /// If it's already at another position, the two swap.
    public mutating func place(_ channel: String, at position: Int) {
        guard tiles.indices.contains(position) else { return }
        if !channels.contains(channel) {
            channels.append(channel)
        }
        if let other = self.position(of: channel) {
            tiles.swapAt(position, other)
        } else {
            tiles[position] = channel
        }
    }

    /// Swaps two positions, as when one tile is dragged onto another.
    public mutating func swap(_ a: Int, _ b: Int) {
        guard a != b, tiles.indices.contains(a), tiles.indices.contains(b) else { return }
        tiles.swapAt(a, b)
    }

    public mutating func resize(_ grid: GridSize) {
        self.grid = grid
        fill()
    }

    public mutating func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        channels.shift(fromOffsets: source, toOffset: destination)
    }

    /// Drops channels that are no longer in the library.
    public mutating func retain(_ known: Set<String>) {
        channels.removeAll { !known.contains($0) }
        normalize()
    }

    /// Gives each empty position on screen the next channel that isn't at any
    /// position.
    private mutating func fill() {
        var unused = channels.filter { !tiles.contains($0) }[...]
        for position in 0..<grid.tiles where tiles[position] == nil {
            guard let next = unused.popFirst() else { break }
            tiles[position] = next
        }
    }

    /// Makes `tiles` the right length, clears channels that aren't in the
    /// playlist or appear twice, and fills what's left empty.
    private mutating func normalize() {
        var seenChannels = Set<String>()
        channels = channels.filter { seenChannels.insert($0).inserted }

        var seen = Set<String>()
        tiles = (0..<Self.positions).map { position in
            guard position < tiles.count, let channel = tiles[position],
                  seenChannels.contains(channel), seen.insert(channel).inserted
            else { return nil }
            return channel
        }
        fill()
    }
}

// MARK: - JSON

/// playlists.json can be edited by hand, so decoding is forgiving: only `name`
/// is required, and tiles that don't make sense are cleared and refilled.
extension Playlist: Codable {
    private enum CodingKeys: String, CodingKey { case id, name, grid, channels, tiles }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try container.decode(String.self, forKey: .name)
        grid = (try? container.decodeIfPresent(GridSize.self, forKey: .grid)) ?? .two
        channels = try container.decodeIfPresent([String].self, forKey: .channels) ?? []
        tiles = (try? container.decodeIfPresent([String?].self, forKey: .tiles)) ?? []
        normalize()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(grid, forKey: .grid)
        try container.encode(channels, forKey: .channels)
        try container.encode(tiles, forKey: .tiles)
    }
}
