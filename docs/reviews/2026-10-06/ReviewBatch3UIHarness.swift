import SwiftUI
import AppKit

// Audit-only executable. Compile with the baseline sources except MeetingScribeApp.swift.
// A unique bundle identifier isolates UserDefaults; all meetings are synthetic.
@main
struct ReviewBatch3App: App {
    @StateObject private var store: MeetingStore

    init() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("fixtures")
        let storage = SessionStorage(rootURL: root)
        if storage.loadSessions().isEmpty {
            for index in 0..<4 {
                var session = storage.createDraftSession(captureMode: .imported)
                session.title = ["审查夹具：编辑与待办", "审查夹具：旧版全文", "审查夹具：空结果", "审查夹具：1000段长逐字稿"][index]
                session.createdAt = Date(timeIntervalSince1970: 1_790_000_000 - Double(index * 60))
                session.status = .ready
                session.duration = 12
                if index == 0 {
                    session.transcriptSegments = [
                        TranscriptSegment(start: 0, end: 6, text: "审查甲下周一交付报价单。", confidence: 0.9, speaker: .local),
                        TranscriptSegment(start: 6, end: 12, text: "审查乙负责验证接口。", confidence: 0.9, speaker: .remote)
                    ]
                    for i in 0..<4 {
                        session.transcriptSegments.append(TranscriptSegment(
                            start: Double(12 + i * 10), end: Double(22 + i * 10),
                            text: "审查背景第\(i + 1)段：这是完全合成的测试内容，用来核对待办负责人和手工校正后的纪要一致性。录音流程正常结束，报价单由指定成员提交，接口需要另一个成员验证，每项工作均应有清晰的来源。",
                            confidence: 0.9, speaker: .local
                        ))
                    }
                    session.duration = 52
                    session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
                    session.analysis = MeetingAnalysis(
                        overview: [], timeline: [], decisions: [],
                        actions: [ActionItem(label: "交付报价单", priority: .p1, dueText: "下周一", evidence: "", confidence: 0.9, timestamp: 0, owner: "审查甲")],
                        confidence: 0.9, minutesText: "审查甲下周一交付报价单。", summaryModel: "审查模型", headline: "报价单下周一交付"
                    )
                } else if index == 1 {
                    session.transcriptText = "旧版正文仍保存在 transcriptText，这是一段完整的审查合成文本。"
                } else if index == 3 {
                    for i in 0..<1000 {
                        let start = Double(i) * 3.6
                        session.transcriptSegments.append(TranscriptSegment(
                            start: start, end: start + 3.6,
                            text: "合成第\(i + 1)句：审查甲说明报价安排，审查乙说明接口验证流程。",
                            confidence: 0.9, speaker: i.isMultiple(of: 2) ? .local : .remote
                        ))
                    }
                    session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
                    session.duration = 3600
                    session.analysis = MeetingAnalysis(overview: [], timeline: [], decisions: [], actions: [], confidence: 0.9, minutesText: "这是一份长逐字稿合成夹具。", summaryModel: "审查模型")
                }
                try! storage.save(session)
            }
        }
        _store = StateObject(wrappedValue: MeetingStore(storage: storage))
    }

    var body: some Scene {
        WindowGroup("MeetingScribe Review Batch 3") {
            ContentView().environmentObject(store)
        }
        .defaultSize(width: 1200, height: 740)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}
