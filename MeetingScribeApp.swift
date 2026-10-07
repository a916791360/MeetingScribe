import SwiftUI
import AppKit

@main
struct MeetingScribeApp: App {
    @StateObject private var store = MeetingStore()
    @NSApplicationDelegateAdaptor(MeetingApplicationDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("MeetingScribe") {
            ContentView()
                .environmentObject(store)
                .onAppear { delegate.store = store }
                .background(WindowConfigurationView())
        }
        .defaultSize(width: 1360, height: 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            // 空态与结果页均保留菜单中的设置入口及标准快捷键。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    store.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
