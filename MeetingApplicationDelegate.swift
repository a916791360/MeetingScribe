import AppKit

@MainActor
final class MeetingApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var store: MeetingStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        if store.isSavingSessions || store.isDeletingSessions {
            store.errorMessage = "正在保存或删除会议，请等待完成后再退出。"
            return .terminateCancel
        }
        if store.isRecording || store.isPreparingRecording {
            store.errorMessage = "录音尚未结束，请先停止录音，等待文件保存完成后再退出。"
            return .terminateCancel
        }
        if store.isProcessing {
            store.errorMessage = "正在处理会议，请等待完成，或先取消处理并等待内容保存后再退出。"
            return .terminateCancel
        }
        return .terminateNow
    }
}
