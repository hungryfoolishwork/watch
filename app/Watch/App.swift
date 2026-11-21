import SwiftUI
import WatchKit

@main
struct MainApp: App {
    @Environment(\.openWindow) var openWindow

    @State var state = AppState.live

    var body: some Scene {
        Window("Watch", id: "main") {
            AppRoot()
                .frame(minWidth: 720, minHeight: 480)
        }
        .environment(state)
        .defaultSize(width: 1260, height: 880)
        // Picture in Picture's return button needs somewhere to return to.
        .onChange(of: state.windowRequests) {
            openWindow(id: "main")
        }
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button.settings {
                    openWindow(id: "settings")
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
            StreamCommands(state: state)
        }

        // One editor per channel: asking for a channel that's already being
        // clipped brings its window forward.
        WindowGroup("Clip", id: ClipEditor.windowID, for: String.self) { $channel in
            ClipEditor(channel: channel)
        }
        .environment(state)
        .defaultSize(width: 880, height: 680)
        .restorationBehavior(.disabled)
        .commandsRemoved()

        Window("Settings", id: "settings") {
            SettingsMain()
                .frame(minWidth: 512, idealWidth: 512, minHeight: 360, idealHeight: 360)
        }
        .environment(state)
        .defaultSize(width: 512, height: 360)
        .windowResizability(.contentSize)
    }
}
