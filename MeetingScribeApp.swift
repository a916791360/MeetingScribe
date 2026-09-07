import SwiftUI
import AppKit

@main
struct MeetingScribeApp: App {
    @StateObject private var store = MeetingStore()

    init() {
        if let url = Bundle.module.url(forResource: "AppIcon", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            NSApplication.shared.applicationIconImage = image
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
        }
        .windowStyle(.automatic)
    }
}
