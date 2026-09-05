import SwiftUI

@main
struct MeetingScribeApp: App {
    @StateObject private var store = MeetingStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.automatic)
    }
}
