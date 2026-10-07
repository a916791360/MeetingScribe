import SwiftUI
import AppKit

// Release acceptance only: isolated meetings and UserDefaults, production UI/store/pipeline.
// Resources are copied from the extracted release ZIP. Never configured with cloud credentials.
@main
struct ReleaseAcceptanceApp: App {
    @StateObject private var store: MeetingStore
    @NSApplicationDelegateAdaptor(MeetingApplicationDelegate.self) private var delegate

    init() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fresh-fixtures")
        _store = StateObject(wrappedValue: MeetingStore(
            storage: SessionStorage(rootURL: root),
            capturePermissions: { (.granted, .granted) }
        ))
    }

    var body: some Scene {
        WindowGroup("MeetingScribe Release Acceptance") {
            ContentView().environmentObject(store)
                .onAppear { delegate.store = store }
                .background(WindowConfigurationView())
        }
        .defaultSize(width: 1200, height: 740)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
