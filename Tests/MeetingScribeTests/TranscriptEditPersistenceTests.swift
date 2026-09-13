import XCTest
@testable import MeetingScribe

/// 端到端钉住「改一句 → 真的落到盘上」。
///
/// 为什么光有 `TranscriptEditorTests` 不够：那 12 条只证明了**该不该改**，
/// 而用户真正冒的风险是"下次打开还是不是我写的那个版本"。那取决于
/// `updateTranscriptSegment` 有没有把改动写进 `session.json`、派生字段
/// `transcriptText` 有没有跟着走 —— 两者都在 UI 后面，只能这样验。
///
/// 数据根是**显式传进来的临时目录**（`MeetingStore(storage:)`），
/// 绝不走环境变量、绝不碰真实数据根。
///
/// 类本身**不标** `@MainActor`：`setUp` / `tearDown` 是基类的 nonisolated 方法，
/// 整体标注会让它们（连同 `root` 属性）都变成主 actor 隔离而编译不过。
/// 需要 store 的那几个方法各自标注即可。
final class TranscriptEditPersistenceTests: XCTestCase {

    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ms-transcript-edit-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// 造一场「已转写完成、两段逐字稿」的会议，返回 (存储, 会话, store)。
    @MainActor
    private func makeReadySession() throws -> (SessionStorage, MeetingSession, MeetingStore) {
        let storage = SessionStorage(rootURL: root)
        var session = storage.createDraftSession(captureMode: .mixed)
        session.status = .ready
        session.transcriptSegments = [
            TranscriptSegment(start: 0, end: 4, text: "课考那边下周来验收", confidence: 0.9),
            TranscriptSegment(start: 4, end: 8, text: "我们把报价单再核一遍", confidence: 0.8)
        ]
        session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
        try storage.save(session)
        return (storage, session, MeetingStore(storage: storage))
    }

    @MainActor
    func testSavingOneSegmentLandsOnDiskAndKeepsTheDerivedTextInSync() throws {
        let (storage, session, store) = try makeReadySession()
        XCTAssertEqual(store.sessions.count, 1, "夹具只有一个会话，说明读的确实是这个临时目录")

        let target = session.transcriptSegments[0]
        let outcome = store.updateTranscriptSegment(
            sessionID: session.id,
            segmentID: target.id,
            text: "  客户那边下周来验收  "
        )
        guard case let .saved(segments) = outcome else {
            return XCTFail("应当落定，实际 \(outcome)")
        }
        XCTAssertEqual(segments[0].text, "客户那边下周来验收", "写回去的是归一化之后的文本")

        // ① 盘上那一份
        let reloaded = try storage.session(with: session.id)
        XCTAssertEqual(reloaded.transcriptSegments[0].text, "客户那边下周来验收")
        XCTAssertNotNil(reloaded.transcriptSegments[0].manuallyEditedAt)
        XCTAssertNotNil(reloaded.transcriptEditedAt, "会话级标记也要落下（页眉靠它改口）")
        XCTAssertEqual(
            reloaded.transcriptText,
            "客户那边下周来验收\n我们把报价单再核一遍",
            "派生全文必须跟着段一起走，否则一个会话里会有两份不一致的逐字稿"
        )
        XCTAssertEqual(reloaded.transcriptSegments[1].text, "我们把报价单再核一遍", "别的段一个字都不该动")
        XCTAssertEqual(reloaded.transcriptSegments.count, 2, "改一段不增减段数")
        XCTAssertNil(reloaded.transcriptSegments[1].manuallyEditedAt)

        // ② 内存里那份（界面读的是它，不刷新就等于用户看不见自己刚改的）
        XCTAssertEqual(store.sessions.first?.transcriptSegments.first?.text, "客户那边下周来验收")
    }

    @MainActor
    func testRejectedEditWritesNothingAtAll() throws {
        let (storage, session, store) = try makeReadySession()
        let target = session.transcriptSegments[0]

        for blank in ["", "   ", "\n\n"] {
            guard case .rejected = store.updateTranscriptSegment(
                sessionID: session.id,
                segmentID: target.id,
                text: blank
            ) else {
                return XCTFail("「\(blank)」应当被拒绝")
            }
        }

        let reloaded = try storage.session(with: session.id)
        XCTAssertEqual(reloaded.transcriptSegments[0].text, "课考那边下周来验收", "被拒绝的输入不该留下痕迹")
        XCTAssertNil(reloaded.transcriptSegments[0].manuallyEditedAt)
        XCTAssertNil(reloaded.transcriptEditedAt, "一次没改成的尝试不该让页眉改口")
    }

    @MainActor
    func testSavingWithoutChangingAnythingDoesNotTouchTheFile() throws {
        let (storage, session, store) = try makeReadySession()
        let target = session.transcriptSegments[0]

        let outcome = store.updateTranscriptSegment(
            sessionID: session.id,
            segmentID: target.id,
            text: "课考那边下周来验收"
        )
        XCTAssertEqual(outcome, .unchanged)

        let reloaded = try storage.session(with: session.id)
        XCTAssertNil(reloaded.transcriptSegments[0].manuallyEditedAt, "没有改动就不该打上「已人工校正」")
        XCTAssertNil(reloaded.transcriptEditedAt)
    }

    /// 改过的那一段，在「重新整理纪要」的纯替换里必须原样穿过。
    ///
    /// 这条把两层连起来测：用户改完 → 点重整理 → 术语表不再动它。
    /// （单测里已分别验过 `applyingTerminology` 会跳过，这里验的是**store 里那个用法**
    /// 没有把它关掉。）
    @MainActor
    func testEditedSegmentSurvivesTheTerminologyPassThatRegenerationRuns() throws {
        let (_, session, store) = try makeReadySession()
        let target = session.transcriptSegments[0]
        _ = store.updateTranscriptSegment(
            sessionID: session.id,
            segmentID: target.id,
            text: "客户那边下周来验收"
        )

        let table = ["课考": "客户", "报价单": "报价单模板"]
        let current = try SessionStorage(rootURL: root).session(with: session.id)
        let corrected = TranscriptCleaner.applyingTerminology(current.transcriptSegments, table: table)

        XCTAssertEqual(
            corrected[0].text, "客户那边下周来验收",
            "人工改过的段必须原样穿过：术语表把它再换一次，用户就白改了（而且不会有任何报错）"
        )
        XCTAssertEqual(corrected[1].text, "我们把报价单模板再核一遍", "没改过的段照常替换")
    }
}
