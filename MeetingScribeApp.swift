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
        .commands {
            // 空态会把标题栏里的全局操作整条撤掉，所以「设置…」必须同时在 app 菜单里
            // 有一条原生入口（⌘,），否则那个界面就再也进不去设置了。
            // macOS 上设置本来就该在这里，标题栏那颗齿轮只是同一个动作的快捷方式。
            CommandGroup(replacing: .appSettings) {
                Button("设置…") {
                    store.showSettings = true
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
