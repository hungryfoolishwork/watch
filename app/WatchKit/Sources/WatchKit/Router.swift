import SwiftUI
import WatchProtocol

public enum Route: Identifiable, Hashable, Codable, Sendable {
    case playlist(String)
    case clip(String)
    case channel(String)
    /// Opens the clip editor on a channel that's playing.
    case clipCreate(String)
    case channelAdd
    case settings

    private var kind: String {
        switch self {
        case .playlist: "playlist"
        case .clip: "clip"
        case .channel: "channel"
        case .clipCreate: "clip-create"
        case .channelAdd: "channel-add"
        case .settings: "settings"
        }
    }

    private var subject: String? {
        switch self {
        case .playlist(let id), .clip(let id), .channel(let id), .clipCreate(let id): id
        case .channelAdd, .settings: nil
        }
    }

    public var path: String {
        subject.map { "\(kind)/\($0)" } ?? kind
    }

    public var id: String { path }

    /// `watch://playlist/<id>`, `watch://channel/<id>` and so on.
    public var url: URL {
        var components = URLComponents()
        components.scheme = Route.scheme
        components.host = kind
        components.path = subject.map { "/\($0)" } ?? ""
        return components.url!
    }

    public init?(url: URL) {
        guard url.scheme == Route.scheme, let kind = url.host() else { return nil }
        let subject = String(url.path(percentEncoded: false).dropFirst())
        switch (kind, subject.isEmpty) {
        case ("playlist", false): self = .playlist(subject)
        case ("clip", false): self = .clip(subject)
        case ("channel", false): self = .channel(subject)
        case ("clip-create", false): self = .clipCreate(subject)
        case ("channel-add", true): self = .channelAdd
        case ("settings", true): self = .settings
        default: return nil
        }
    }

    public static let scheme = Bundle.main.object(forInfoDictionaryKey: "AppURLScheme") as? String ?? "watch"
}

@MainActor
@Observable
public final class Router {

    /// What the sidebar has selected, and so what the window shows.
    public var selection: Route? = nil {
        didSet { scheduleSave() }
    }

    public var modal: Route? = nil

    public init() {}

    public func present(_ route: Route) {
        modal = route
    }

    public func dismiss() {
        modal = nil
    }

    // MARK: Persistence

    /// Puts back the selection from last time, if `resolve` says it still
    /// exists.
    public func restore(resolve: (Route) -> Bool) {
        guard
            let data = UserDefaults.standard.data(forKey: Self.snapshotKey),
            let snapshot = try? JSONDecoder().decode(RouterSnapshot.self, from: data),
            let selection = snapshot.selection, resolve(selection)
        else { return }
        self.selection = selection
    }

    public func persist() {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.snapshotKey)
    }

    private func scheduleSave() {
        saveDebouncer.run { [weak self] in
            self?.persist()
        }
    }

    private static let snapshotKey = "router.snapshot"
    private let saveDebouncer = Debouncer(delay: .milliseconds(500))

    private var snapshot: RouterSnapshot {
        RouterSnapshot(selection: selection)
    }
}

public struct RouterSnapshot: Codable {
    public var selection: Route?
}
