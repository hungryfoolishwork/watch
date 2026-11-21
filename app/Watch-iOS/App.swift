import SwiftUI
import WatchKit

@main
struct MainApp: App {

    #if targetEnvironment(simulator)
    @State var state = AppState.preview
    #else
    @State var state = AppState.live
    #endif

    var body: some Scene {
        WindowGroup {
            AppRoot()
        }
        .environment(state)
    }
}
