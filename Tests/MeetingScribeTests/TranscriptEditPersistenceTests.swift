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
        var session = try storage.createDraftSession(captureMode: .mixed)
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

    @MainActor
    func testCloudSummaryRegenerationIsBlockedUntilKeyIsLoadedIntoMemory() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .custom,
            modelName: "deepseek-v4.1-flash",
            endpoint: "https://example.com/v1"
        )
        store.summaryAPIKeyInput = ""

        XCTAssertFalse(
            store.canRegenerateSummaryNow,
            "后台整理不能为了重试去读钥匙串密文，否则自签名 App 会再次弹系统密码框"
        )
        XCTAssertNotNil(store.summaryRegenerationBlockedMessage)
    }

    @MainActor
    func testLocalRulesCanRegenerateWithoutAPIKey() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .localRules,
            modelName: SummaryModelProvider.localRules.defaultModelName,
            endpoint: SummaryModelProvider.localRules.defaultEndpoint
        )
        store.summaryAPIKeyInput = ""

        XCTAssertTrue(
            store.canRegenerateSummaryNow,
            "本地保守整理不需要 API Key，应该允许直接重新整理"
        )
        XCTAssertNil(store.summaryRegenerationBlockedMessage)
    }

    @MainActor
    func testImportedSessionPlaybackPrefersOriginalAudioOverWhisperInput() throws {
        let storage = SessionStorage(rootURL: root)
        var session = try storage.createDraftSession(captureMode: .imported)
        let folder = storage.folderURL(for: session)
        let original = folder.appendingPathComponent("customer-meeting.m4a")
        let whisperInput = folder.appendingPathComponent("input.wav")
        try Data("original".utf8).write(to: original)
        try Data("input".utf8).write(to: whisperInput)

        session.status = .ready
        session.sourceFileName = original.lastPathComponent
        session.inputAudioFileName = whisperInput.lastPathComponent
        try storage.save(session)

        XCTAssertEqual(
            storage.playbackURL(for: session)?.lastPathComponent,
            original.lastPathComponent,
            "导入会议底部播放条应该优先播放用户导入的原始音频；input.wav 只是 whisper 中间文件"
        )
    }

    // MARK: - 阶段 1-1：主窗口的「整理模型到底能不能用」

    @MainActor
    func testReadinessNeedsKeyWhenCloudProviderHasNoLoadedKey() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .deepSeek,
            modelName: "deepseek-v4",
            endpoint: "https://api.deepseek.com/v1"
        )
        // 启动时故意不读钥匙串密文，所以内存里是空的。
        store.summaryAPIKeyInput = ""

        guard case .needsKey = store.summaryModelReadiness else {
            return XCTFail("云端服务商 + 内存无 Key 应是 needsKey，实际 \(store.summaryModelReadiness)")
        }
        XCTAssertFalse(store.summaryModelReadiness.isReady)
        XCTAssertNotNil(
            store.summaryModelReadiness.attentionMessage,
            "不可用时必须给主窗口一条可执行的提示"
        )
    }

    @MainActor
    func testReadinessNeedsModelWhenKeyPresentButModelEmpty() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .deepSeek,
            modelName: "",
            endpoint: "https://api.deepseek.com/v1"
        )
        store.summaryAPIKeyInput = "sk-test"

        guard case .needsModel = store.summaryModelReadiness else {
            return XCTFail("有 Key 但没选模型应是 needsModel，实际 \(store.summaryModelReadiness)")
        }
        XCTAssertFalse(store.summaryModelReadiness.isReady)
        XCTAssertNotNil(
            store.summaryModelReadiness.attentionMessage,
            "缺模型时主窗口也要有一条常驻提示"
        )
        // 两层的职责不同，都在：`readiness` 管"主窗口常驻怎么说"，
        // `summaryRegenerationBlockedMessage` 管"点了重新整理之后拦不拦"。
        XCTAssertNotNil(
            store.summaryRegenerationBlockedMessage,
            "缺模型时点重新整理会被拦下，这一层也该给文案"
        )
        XCTAssertFalse(store.canRegenerateSummaryNow, "缺模型时不该放行重新整理")
    }

    @MainActor
    func testReadinessLocalRulesIsAlwaysReady() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .localRules,
            modelName: SummaryModelProvider.localRules.defaultModelName,
            endpoint: SummaryModelProvider.localRules.defaultEndpoint
        )
        store.summaryAPIKeyInput = ""

        XCTAssertEqual(store.summaryModelReadiness, .localRules)
        XCTAssertTrue(store.summaryModelReadiness.isReady)
        XCTAssertNil(
            store.summaryModelReadiness.attentionMessage,
            "本地整理任何时候都可用，主窗口不该出现提示条"
        )
    }

    @MainActor
    func testReadinessConfiguredWhenProviderModelAndKeyAreAllPresent() throws {
        let (_, _, store) = try makeReadySession()
        store.summarySettings = SummaryModelSettings(
            provider: .deepSeek,
            modelName: "deepseek-v4",
            endpoint: "https://api.deepseek.com/v1"
        )
        store.summaryAPIKeyInput = "sk-test"

        guard case .configured(let provider, let model) = store.summaryModelReadiness else {
            return XCTFail("三样齐了应是 configured，实际 \(store.summaryModelReadiness)")
        }
        XCTAssertFalse(provider.isEmpty)
        XCTAssertEqual(model, "deepseek-v4")
        XCTAssertTrue(store.summaryModelReadiness.isReady)
        XCTAssertNil(
            store.summaryModelReadiness.attentionMessage,
            "配好了就别再占用主窗口的注意力"
        )
    }
}
