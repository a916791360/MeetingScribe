import SwiftUI
import AppKit

// Audit-only executable. Compile with the current repository sources except MeetingScribeApp.swift.
// A unique bundle identifier isolates UserDefaults; all meetings are synthetic.
@main
struct ReviewLifecycleApp: App {
    @StateObject private var store: MeetingStore
    @NSApplicationDelegateAdaptor(MeetingApplicationDelegate.self) private var delegate

    init() {
        let isEmptyFixture = Bundle.main.bundleIdentifier?.hasSuffix(".empty") == true
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(isEmptyFixture ? "empty-fixtures" : "fixtures")
        let storage = SessionStorage(rootURL: root)
        if storage.loadSessions().isEmpty && !isEmptyFixture {
            for index in 0..<4 {
                guard var session = try? storage.createDraftSession(captureMode: .imported) else { preconditionFailure("Cannot create isolated UI fixture") }
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
        _store = StateObject(wrappedValue: MeetingStore(storage: storage, repository: SessionRepository(storage: storage, beforeMutation: { try await Task.sleep(for: .seconds(3)) }, beforeRecovery: { await withCheckedContinuation { c in DispatchQueue.global().asyncAfter(deadline: .now() + 3) { c.resume() } } }), loadSessionsInBackground: true, recordingFactory: { _, _, _ in ReviewLifecycleRecorder() }, capturePermissions: { (.granted, .granted) }, summaryAnalyzer: { _, _, _, _ in try await ReviewDelayedSummary.analyze() }))
    }

    var body: some Scene {
        WindowGroup("MeetingScribe Acceptance Review") {
            ContentView().environmentObject(store).onAppear { delegate.store = store }.background(WindowConfigurationView()).background(ReviewWindowMetrics())
        }
        .defaultSize(width: Bundle.main.bundleIdentifier?.contains("minimum") == true ? 1060 : 1360, height: Bundle.main.bundleIdentifier?.contains("minimum") == true ? 660 : 820)
        .windowResizability(.contentMinSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("设置…") { store.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
    }
}

@MainActor
final class ReviewLifecycleRecorder: RecordingSession {
    var levels: (local: Double, remote: Double) { (0, 0) }
    var onFailure: ((String) -> Void)?
    func start() async throws { try await Task.sleep(for: .seconds(600)) }
    func stop() async throws -> MixedRecordingResult { throw PipelineError.failedToStopCapture }
}


struct ReviewDelayedSummary {
    static func analyze() async throws -> MeetingAnalysis {
        do { try await Task.sleep(for: .seconds(600)) }
        catch {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) { continuation.resume() }
            }
            throw CancellationError()
        }
        return .empty
    }
}


struct ReviewWindowMetrics: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { MetricsView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class MetricsView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            NotificationCenter.default.addObserver(self, selector: #selector(snapshot), name: NSWindow.didMoveNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(snapshot), name: NSWindow.didResizeNotification, object: window)
            DispatchQueue.main.async { self.snapshot() }
        }
        @objc private func snapshot() {
            guard let window else { return }
            let f = window.frame
            func dragRects(_ view: NSView) -> [[String: Any]] {
                let own: [[String: Any]] = String(describing: type(of: view)).contains("DragView") ? [["class": String(describing: type(of: view)), "width": view.frame.width, "height": view.frame.height, "windowRect": NSStringFromRect(view.convert(view.bounds, to: nil))]] : []
                return own + view.subviews.flatMap(dragRects)
            }
            let metrics: [String: Any] = [
                "dragRegions": window.contentView.map(dragRects) ?? [],
                "frame": [f.origin.x, f.origin.y, f.width, f.height],
                "fullSizeContentView": window.styleMask.contains(.fullSizeContentView),
                "separatorRemoved": window.titlebarSeparatorStyle == .none,
                "buttonsPresent": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0) != nil },
                "buttonsEnabled": [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].map { window.standardWindowButton($0)?.isEnabled == true }
            ]
            let root = Bundle.main.bundleURL.deletingLastPathComponent()
            if let data = try? JSONSerialization.data(withJSONObject: metrics, options: .prettyPrinted) {
                try? data.write(to: root.appendingPathComponent("window-metrics.json"), options: .atomic)
            }
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
