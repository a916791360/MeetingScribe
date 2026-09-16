import AppKit
import Foundation
import XCTest
@testable import MeetingScribe

/// E2 的**接线**测试：证明「按一下复制」真的把那份导出文本放进了剪贴板。
///
/// 为什么 `MeetingExportTests` 那 25 条不够：它们只证明导出文本**长什么样**。
/// 用户能感知的却是「粘出来的东西对不对」，而中间那一段（store 有没有真的写、
/// 写的是不是同一份文本、UTF-8 往返有没有掉字）在 UI 后面，只能这样验。
///
/// **不碰系统剪贴板**：走注入的具名粘贴板（`copySelectedSessionToPasteboard(to:)`）。
/// 用 `.general` 也能测，但测试进程会把用户当下复制的内容冲掉 —— 他很可能是刚复制了一段重要的东西。
///
/// **没被这条验到的**：`.general` 那个默认值本身（它是签名里的一个字面量，
/// 调用点不传参即生效）。这一句由源码复核，不由测试兜。
final class ExportWiringTests: XCTestCase {

    private var root: URL!
    private var board: NSPasteboard!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-export-wiring-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 具名粘贴板：pboard server 里一个独立槽位，与用户自己的剪贴板互不相干。
        board = NSPasteboard(name: NSPasteboard.Name("MeetingScribeTests.export.\(UUID().uuidString)"))
    }

    override func tearDown() {
        board?.releaseGlobally()
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - 夹具

    /// 一场「整理成功 + 有逐字稿 + 双声道说话人」的会议。
    ///
    /// 内容刻意做杂（中文、方括号时间锚、嵌套列表、"我方/对方"括号），
    /// 这样 UTF-8 往返里任何一个环节掉字都会露出来。
    @MainActor
    private func makeFixtures(
        hasSession: Bool = true
    ) throws -> (MeetingSession?, MeetingStore) {
        let storage = SessionStorage(rootURL: root)
        var session: MeetingSession?
        if hasSession {
            var draft = storage.createDraftSession(captureMode: .mixed)
            draft.title = "客户评审会"
            draft.status = .ready
            draft.duration = 1800
            draft.transcriptSegments = [
                TranscriptSegment(start: 0, end: 4, text: "课考那边下周来验收", confidence: 0.9, speaker: .local),
                TranscriptSegment(start: 4, end: 8, text: "报价单再核一遍", confidence: 0.8, speaker: .remote)
            ]
            draft.transcriptText = draft.transcriptSegments.map(\.text).joined(separator: "\n")
            draft.analysis = MeetingAnalysis(
                overview: [],
                timeline: [TimelineChunk(start: 0, end: 111, summary: "开场与背景", evidence: "", confidence: 0.9)],
                decisions: [InsightItem(label: "接受八五折", evidence: "客户当场同意", confidence: 0.9, timestamp: 750)],
                actions: [ActionItem(label: "把合同发过去", evidence: "", confidence: 0.9, timestamp: 900, owner: "张三")],
                confidence: 0.9,
                overviewText: "双方就价格与交付周期做了确认。",
                minutesText: "",
                summaryModel: "test-model",
                summaryError: nil,
                headline: "价格定了，交付下月。",
                overviewBullets: ["八五折成交", "下月交付"],
                openQuestions: ["发票开专票还是普票"]
            )
            try storage.save(draft)
            session = draft
        }
        return (session, MeetingStore(storage: storage))
    }

    // MARK: - 验收 #2 的剪贴板一半

    /// 判据：剪贴板里的内容与 `MeetingExporter.markdown(for:)` **完全一样**。
    ///
    /// 刻意不写成 `contains("客户评审会")` 这类弱断言：那种断言在"多了一段少了一段、
    /// 或者把 markdown 误当纯文本处理"时照样通过。
    @MainActor
    func testCopyWritesExactlyTheExportedMarkdownToThePasteboard() throws {
        let (session, store) = try makeFixtures()
        let expected = MeetingExporter.markdown(for: try XCTUnwrap(session))

        XCTAssertTrue(store.copySelectedSessionToPasteboard(to: board), "有会话时必须报告复制成功")

        XCTAssertEqual(
            board.string(forType: .string),
            expected,
            "剪贴板内容必须与导出文本逐字节一致 —— 两条路各拼一遍就会出现「复制的和导出的不一样」"
        )
        // 顺带钉住"真的是一份完整纪要"，而不是某个空串：空串也能 `== expected`（若 expected 也空）。
        XCTAssertGreaterThan(expected.count, 200, "夹具应当产出一份像样的纪要，否则这条测试没有意义")
    }

    /// 没有会话时**不写剪贴板**、且返回 `false`。
    ///
    /// 返回值的意义就在这里：`WorkbenchResultTabBar` 靠它决定给不给勾选反馈。
    /// 若这里谎报 `true`，用户会看到一个勾、粘出来却是他上一次复制的东西 —— 而且没有任何报错。
    @MainActor
    func testCopyReportsFailureAndLeavesThePasteboardUntouchedWhenThereIsNoSession() throws {
        let (_, store) = try makeFixtures(hasSession: false)
        XCTAssertTrue(store.sessions.isEmpty, "夹具不该有会话，否则这条测的不是没有会话的情况")

        board.clearContents()
        board.setString("用户原来就在剪贴板里的内容", forType: .string)

        XCTAssertFalse(store.copySelectedSessionToPasteboard(to: board), "没有会话时必须报告失败")
        XCTAssertEqual(
            board.string(forType: .string),
            "用户原来就在剪贴板里的内容",
            "失败时不该清掉剪贴板 —— 清掉等于把用户原来复制的东西弄没了"
        )
    }

    // MARK: - 验收 #2 的文件一半

    /// 判据：写盘再读回来，与导出文本一致（UTF-8 往返不掉字）。
    ///
    /// 这里复刻 `MeetingStore.exportSelectedSession()` 里那一行写盘调用 —— 因为
    /// `NSSavePanel.runModal()` 会阻塞、没法在测试里跑。**"导出到用户选的位置"这一步
    /// 本身没被自动化验过**，验的是它的内容与编码；位置选择属于 macOS 系统行为。
    @MainActor
    func testExportedFileReadsBackByteForByte() throws {
        let (session, _) = try makeFixtures()
        let markdown = MeetingExporter.markdown(for: try XCTUnwrap(session))

        let url = root.appendingPathComponent(MeetingExporter.fileName(for: try XCTUnwrap(session)))
        try markdown.write(to: url, atomically: true, encoding: .utf8)

        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(bytes, Data(markdown.utf8), "读回来的字节必须与写下去的一致")
        XCTAssertEqual(String(data: bytes, encoding: .utf8), markdown)
        // 中文与 emoji（`⚠️` 只在不完整时出现）都是 3~4 字节，最容易暴露编码问题。
        XCTAssertTrue(markdown.contains("客户评审会"))
        XCTAssertTrue(markdown.contains("（我方）课考那边下周来验收"), "中文正文里不该混进多余空格")
    }
}
