import XCTest
@testable import MeetingScribe

/// 钉住「材料不足前置门禁」。
///
/// 原始现场（方案 O5，会话 `…DE6205D8`）：25 秒的误录被送进整理模型，
/// 模型返回的不是空，而是一段**元评论** ——「本次材料仅包含一句栏目推广语，
/// 未出现任何会议讨论内容，因此无法识别会议主题……」。它花了 token、
/// 占着「速览」最显眼的位置、还长得像结论。
///
/// 门禁的意义有两个，缺一不可：
/// ① **不花那个 token**（所以它必须在任何网络调用之前）；
/// ② **不把"没调模型"伪装成"调模型失败了"**（`summaryError` 必须留空，
///    否则界面会挂出失败横幅 + 一颗点了也没用的「重试」）。
final class TranscriptMaterialTests: XCTestCase {

    // MARK: - 造材料

    private func segment(_ text: String, start: TimeInterval = 0) -> TranscriptSegment {
        TranscriptSegment(start: start, end: start + 4, text: text, confidence: 0.9)
    }

    /// 造一份「刚好 n 字」的逐字稿：字数按**有效字符**算（这里全是汉字）。
    private func transcript(characters: Int, segmentCount: Int) -> [TranscriptSegment] {
        guard segmentCount > 0 else { return [] }
        let perSegment = characters / segmentCount
        let remainder = characters % segmentCount
        return (0..<segmentCount).map { index in
            let length = perSegment + (index < remainder ? 1 : 0)
            return segment(String(repeating: "会", count: length), start: TimeInterval(index * 5))
        }
    }

    // MARK: - 两条度量

    func testCountsOnlyContentCharacters() {
        // 空白、标点、符号都不算「有效字」—— 否则一段只有「……」的转写能骗过门禁。
        XCTAssertEqual(
            TranscriptMaterial.contentCharacterCount("嗯，好。那我们先这样（\n）"),
            8,
            "十三个字符里只有「嗯好那我们先这样」八个算数，逗号句号括号换行都不该计入"
        )
    }

    func testPunctuationAndWhitespaceOnlyTranscriptIsNoContent() {
        let material = TranscriptMaterial.measure([
            segment("、。！？"),
            segment("   \n  "),
            segment("……"),
            segment("--")
        ])

        XCTAssertEqual(material.characters, 0)
        XCTAssertEqual(material.segments, 0)
        XCTAssertEqual(material.shortfall?.reason, .noContent)
    }

    func testSingleCharacterSegmentsAreNotCountedAsSpeech() {
        // 「嗯」「啊」各算一个字，但不能算一次发言 —— 段数这条线量的就是"说过话没有"。
        let material = TranscriptMaterial.measure((0..<10).map { segment("嗯", start: TimeInterval($0 * 3)) })

        XCTAssertEqual(material.characters, 10)
        XCTAssertEqual(material.segments, 0)
        XCTAssertEqual(material.shortfall?.reason, .noContent)
    }

    // MARK: - 边界

    func testExactThresholdIsAccepted() {
        let material = TranscriptMaterial.measure(
            transcript(
                characters: TranscriptMaterial.minimumCharacters,
                segmentCount: TranscriptMaterial.minimumSegments
            )
        )

        XCTAssertEqual(material.characters, TranscriptMaterial.minimumCharacters)
        XCTAssertEqual(material.segments, TranscriptMaterial.minimumSegments)
        XCTAssertNil(material.shortfall, "刚好达标就走正常整理，门禁不能把边界吃掉")
    }

    func testOneCharacterBelowTheLineTrips() {
        let material = TranscriptMaterial.measure(
            transcript(
                characters: TranscriptMaterial.minimumCharacters - 1,
                segmentCount: TranscriptMaterial.minimumSegments + 5
            )
        )

        XCTAssertEqual(material.shortfall?.reason, .tooFewCharacters)
    }

    func testFewSegmentsTripsEvenWhenTheTextIsLong() {
        // 段数这条是**独立**的：很长但只切出三段，同样是"没内容可整理"的常见形态
        // （转写引擎把整段并成一条时就是这样）。
        let material = TranscriptMaterial.measure(transcript(characters: 3_000, segmentCount: 3))

        XCTAssertEqual(material.segments, 3)
        XCTAssertEqual(material.shortfall?.reason, .tooFewSegments)
    }

    func testRealisticMeetingPassesTheGate() {
        let material = TranscriptMaterial.measure(
            (0..<75).map { segment(String(repeating: "会", count: 40), start: TimeInterval($0 * 35)) }
        )

        XCTAssertNil(material.shortfall, "本机长会实测是每分钟 1.7~2.3 段，不该被误拦")
    }

    // MARK: - 门禁在模型之前（这一条是 2C 的全部意义）

    func testAnalyzeNeverReachesTheNetworkWhenMaterialIsThin() async throws {
        // 端点故意留空：只要代码走到建 URL 那一步就会抛 `invalidEndpoint`。
        // 所以「没抛错」本身就是「一个 token 都没花」的证据。
        let settings = SummaryModelSettings(provider: .custom, modelName: "whatever", endpoint: "")

        let analysis = try await MeetingSummaryEngine().analyze(
            segments: [segment("嗯，好的，那我们先这样吧")],
            settings: settings,
            apiKey: nil
        )

        XCTAssertEqual(analysis.insufficientMaterial?.reason, .tooFewCharacters)
        XCTAssertEqual(analysis.insufficientMaterial?.segments, 1)
    }

    // MARK: - 产物不能长成一次失败

    func testInsufficientAnalysisDoesNotPretendToBeAFailure() {
        let shortfall = MaterialShortfall(reason: .tooFewCharacters, characters: 87, segments: 3)
        let analysis = MeetingAnalysisBuilder.buildInsufficient(shortfall: shortfall)

        XCTAssertNil(analysis.summaryError, "这里没有失败；写进去会让界面挂出失败横幅和一颗白点的「重试」")
        XCTAssertNil(analysis.noticeMessage, "不该有任何提醒横幅")
        XCTAssertFalse(analysis.isLocalFallback)
        XCTAssertTrue(analysis.isMaterialInsufficient)
        XCTAssertFalse(analysis.hasNarrative)
        XCTAssertTrue(analysis.decisions.isEmpty && analysis.actions.isEmpty && analysis.timeline.isEmpty)
    }

    func testRepairLoopSeesAStableResult() {
        // `reloadSessions` 会拿本地规则重算一遍 `summaryModel == 本地整理` 的会话。
        // 两次结果必须**相等**，否则每次启动都会判定"变了"并写盘。
        let segments = [segment("嗯，好的，那我们先这样吧")]
        let first = MeetingAnalysisBuilder.build(from: segments)
        let second = MeetingAnalysisBuilder.build(from: segments)

        XCTAssertTrue(first.isMaterialInsufficient)
        XCTAssertEqual(first, second)
    }

    // MARK: - 空态文案

    func testMessageCarriesTheActualNumbers() {
        let shortfall = MaterialShortfall(reason: .tooFewCharacters, characters: 87, segments: 3)
        let message = shortfall.message

        XCTAssertTrue(message.contains("87"), "要说清到底有多少字，否则用户没法判断是不是白录了")
        XCTAssertTrue(message.contains("3"))
        XCTAssertTrue(message.contains("\(TranscriptMaterial.minimumCharacters)"), "也要给出那条线")
        XCTAssertTrue(message.contains("没有调用整理模型"), "要拦住「换个模型再试」这条死路")
        XCTAssertFalse(message.contains("失败"), "这是一条结论，不是一次失败")
    }

    func testNoContentHasItsOwnWording() {
        let shortfall = MaterialShortfall(reason: .noContent, characters: 0, segments: 0)

        XCTAssertEqual(shortfall.title, "这段录音没有会议内容")
        XCTAssertTrue(shortfall.message.contains("原文"))
        XCTAssertNotEqual(shortfall.message, MaterialShortfall(reason: .tooFewCharacters, characters: 87, segments: 3).message)
    }

    // MARK: - 历史数据修补（决定"要不要动用户存盘的数据"，必须有测试）

    /// 造一条会话：材料 + 已存盘的分析。
    private func session(
        segments: [TranscriptSegment],
        analysis: MeetingAnalysis,
        status: MeetingStatus = .ready
    ) -> MeetingSession {
        var draft = MeetingSession.makeDraft(
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            captureMode: .mixed,
            folderName: "fixture"
        )
        draft.status = status
        draft.transcriptSegments = segments
        draft.analysis = analysis
        return draft
    }

    /// 升级前那条 25 秒误录的样子：一个片段 + 一份模型写的元评论。
    private var legacyMetaCommentary: MeetingAnalysis {
        MeetingAnalysis(
            overview: [],
            timeline: [TimelineChunk(start: 0, end: 25, summary: "栏目推广语", evidence: "请不吝点赞", confidence: 0.9)],
            decisions: [],
            actions: [],
            confidence: 0.9,
            overviewText: "本次材料仅包含一句栏目推广语，未出现任何会议讨论内容，因此无法识别会议主题。",
            minutesText: "材料中没有任何工作会议发言或讨论过程。",
            summaryModel: "自定义兼容接口 · deepseek-v4.1-flash"
        )
    }

    func testRepairCatchesTheLegacyMetaCommentary() {
        // 这条的 `summaryModel` 是个真实模型名，所以 `reloadSessions` 里那个
        // 只认「本地整理」的循环不会碰它 —— 修复正是在这里被漏掉的。
        let target = session(
            segments: [segment("请不吝点赞 订阅 转发 打赏支持明镜与点点栏目。")],
            analysis: legacyMetaCommentary
        )

        XCTAssertTrue(MeetingAnalysisBuilder.needsMaterialGateRepair(target))
    }

    func testRepairLeavesSufficientMaterialAlone() {
        let target = session(
            segments: transcript(characters: 4_000, segmentCount: 60),
            analysis: legacyMetaCommentary
        )

        XCTAssertFalse(
            MeetingAnalysisBuilder.needsMaterialGateRepair(target),
            "材料够就是真结果，一个字都不许动"
        )
    }

    func testRepairLeavesAnythingWithStructuredFindingsAlone() {
        var analysis = legacyMetaCommentary
        analysis.decisions = [
            InsightItem(label: "本期只做接口预留", evidence: "本期只做接口预留", confidence: 0.9, timestamp: 12)
        ]
        let target = session(segments: [segment("嗯，那就先这样定下来")], analysis: analysis)

        XCTAssertFalse(
            MeetingAnalysisBuilder.needsMaterialGateRepair(target),
            "材料再少，只要有决策 / 待办 / 结论，那也是用户真正拿到过的东西"
        )
    }

    func testRepairIsNotRepeatedOnceApplied() {
        let shortfall = MaterialShortfall(reason: .tooFewCharacters, characters: 20, segments: 1)
        let target = session(
            segments: [segment("嗯，好的")],
            analysis: MeetingAnalysisBuilder.buildInsufficient(shortfall: shortfall)
        )

        XCTAssertFalse(
            MeetingAnalysisBuilder.needsMaterialGateRepair(target),
            "已经标过了就别再动 —— 否则每次启动都要重写一遍"
        )
    }

    func testRepairSkipsUnfinishedSessions() {
        let target = session(
            segments: [segment("嗯，好的")],
            analysis: legacyMetaCommentary,
            status: .processing
        )

        XCTAssertFalse(MeetingAnalysisBuilder.needsMaterialGateRepair(target))
    }

    // MARK: - 存盘兼容

    func testShortfallSurvivesARoundTrip() throws {
        let shortfall = MaterialShortfall(reason: .tooFewSegments, characters: 640, segments: 2)
        let analysis = MeetingAnalysisBuilder.buildInsufficient(shortfall: shortfall)

        let data = try JSONEncoder().encode(analysis)
        let decoded = try JSONDecoder().decode(MeetingAnalysis.self, from: data)

        XCTAssertEqual(decoded.insufficientMaterial, shortfall, "重启后不该重新判一次（判据依赖逐字稿还在不在）")
    }

    func testNormalAnalysisOmitsTheKeyEntirely() throws {
        // nil 必须**省略键**而不是写 `null`/空对象：指标脚本靠"键在不在"区分
        // 「不可算」与「0」。这条铁律在 2A 的 `owner` 上已经踩过一次。
        let analysis = MeetingAnalysisBuilder.build(
            from: transcript(characters: 400, segmentCount: 8)
        )

        let data = try JSONEncoder().encode(analysis)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertNil(json["insufficientMaterial"])
        XCTAssertNil(analysis.insufficientMaterial)
    }

    func testSessionSavedBeforeThisFeatureStillDecodes() throws {
        // 老会话（2A/2C 之前存盘的）里没有这个键 —— 非 Optional 会让升级后读不出历史记录。
        let legacy = """
        {
          "overview": [],
          "timeline": [],
          "decisions": [],
          "actions": [],
          "confidence": 0.4,
          "overviewText": "旧会话的导语",
          "minutesText": ""
        }
        """

        let decoded = try JSONDecoder().decode(MeetingAnalysis.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.insufficientMaterial)
        XCTAssertEqual(decoded.overviewText, "旧会话的导语")
    }
}
