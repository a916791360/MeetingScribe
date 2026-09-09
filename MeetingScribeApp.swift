import SwiftUI

@main
struct MeetingScribeApp: App {
    @StateObject private var store = MeetingStore()

    var body: some Scene {
        WindowGroup("MeetingScribe") {
            ContentView()
                .environmentObject(store)
                .background(WindowConfigurationView())
        }
        .defaultSize(width: 1360, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.automatic)
    }
}
