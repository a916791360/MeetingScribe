import AppKit

@MainActor
final class MeetingApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: MeetingStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard store?.isSavingSessions == true else { return .terminateNow }
        store?.errorMessage = "正在保存会议修改，请等待保存完成后再退出。"
        return .terminateCancel
    }
}
