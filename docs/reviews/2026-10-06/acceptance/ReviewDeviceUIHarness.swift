import SwiftUI
import AppKit

/// Production capture/transcription, isolated data and preferences, no remote credentials.
@main
struct ReviewDeviceApp: App {
    @StateObject private var store: MeetingStore
    @NSApplicationDelegateAdaptor(MeetingApplicationDelegate.self) private var delegate
    init() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("device-fixtures")
        let store = MeetingStore(storage: SessionStorage(rootURL: root), loadSessionsInBackground: true)
        store.summarySettings = .default
        let runtime = URL(fileURLWithPath: "/Users/qingmeng/.codex/worktrees/meetingscribe-review/luyinzhuanxie/.build/MeetingScribe.app/Contents/Resources/whisper")
        store.whisperCLIPath = runtime.appendingPathComponent("bin/whisper-cli").path
        store.whisperModelPath = runtime.appendingPathComponent("models/ggml-small.bin").path
        _store = StateObject(wrappedValue: store)
    }
    var body: some Scene {
        WindowGroup("MeetingScribe Device Acceptance") {
            ContentView().environmentObject(store).onAppear { delegate.store = store }
        }
        .defaultSize(width: 1200, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }.keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
