import XCTest
@testable import MeetingScribe

/// 守住 2A 新增字段的**向后兼容**合约。
///
/// 背景（执行计划 §4 的 2A 验收）：给 `MeetingAnalysis` 加
/// `headline` / `overviewBullets` / `openQuestions`、给 `ActionItem` 加 `owner`，
/// 但**已存在的历史会话必须还能读出来**。数据根里的 `session.json` 是用户自己的
/// 会议记录，读不出来就等于升级即丢数据 —— 所以这里既测手工构造的"老 JSON"，
/// 也拿真实数据根里存在的会话做一次只读回归（没有则跳过）。
final class MeetingAnalysisV2Tests: XCTestCase {

    // MARK: - 老会话

    /// 2A 之前的 `analysis` 长这样：没有 headline / overviewBullets / openQuestions，
    /// `actions` 里也没有 owner。必须能解出来，且新字段是 nil。
    ///
    /// 注意这里的 `id` 不能省：**Swift 合成的 `Decodable` 不理会属性默认值** ——
    /// `var id: UUID = UUID()` 只是让构造时可以省参数，解码时缺键依然抛
    /// `keyNotFound`。真实会话文件里 `id` 一定存在（`encode` 总会写），
    /// 所以"老 JSON"也必须带着它，否则测的就不是老会话而是被手改过的坏文件。
    func testDecodesLegacyAnalysisWithoutNewKeys() throws {
        let legacy = """
        {
          "overview": [],
          "timeline": [
            {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302", "start": 0, "end": 300,
             "summary": "开场", "evidence": "…", "confidence": 0.8}
          ],
          "decisions": [
            {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3303", "label": "本期只做三个模块",
             "evidence": "原文", "confidence": 0.8}
          ],
          "actions": [
            {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "label": "周五前把报价发出来",
             "evidence": "原文", "confidence": 0.7}
          ],
          "confidence": 0.8,
          "overviewText": "导语",
          "minutesText": "纪要",
          "summaryModel": "自定义兼容接口 · deepseek-v4.1-flash"
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(MeetingAnalysis.self, from: legacy)

        XCTAssertEqual(analysis.decisions.count, 1)
        XCTAssertEqual(analysis.actions.count, 1)
        XCTAssertNil(analysis.headline, "老会话没有 headline")
        XCTAssertNil(analysis.overviewBullets, "老会话没有 overviewBullets")
        XCTAssertNil(analysis.openQuestions, "老会话没有 openQuestions")
        XCTAssertNil(analysis.actions[0].owner, "老会话的待办没有 owner")
    }

    /// `ActionItem` 单独解一次，确认 `owner` 缺席时是 nil 而不是解码失败。
    func testActionItemDecodesWithoutOwner() throws {
        let json = """
        {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301", "label": "跟进验收",
         "evidence": "原文", "confidence": 0.6}
        """.data(using: .utf8)!
        let item = try JSONDecoder().decode(ActionItem.self, from: json)
        XCTAssertNil(item.owner)
        XCTAssertEqual(item.label, "跟进验收")
    }

    // MARK: - 新字段往返

    func testRoundTripsNewFields() throws {
        let original = MeetingAnalysis(
            overview: [],
            timeline: [],
            decisions: [],
            actions: [
                ActionItem(label: "周五前把报价发出来", evidence: "原文", confidence: 0.7, owner: "李工"),
                ActionItem(label: "补一份排期", evidence: "原文", confidence: 0.7, owner: nil)
            ],
            confidence: 0.7,
            headline: "本期只做三个模块，其余排到下季度",
            overviewBullets: ["[12:30] 预算 80 万，比去年少 20 万"],
            openQuestions: ["渠道分成比例还没定"]
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(MeetingAnalysis.self, from: data)

        XCTAssertEqual(decoded.headline, original.headline)
        XCTAssertEqual(decoded.overviewBullets, original.overviewBullets)
        XCTAssertEqual(decoded.openQuestions, original.openQuestions)
        XCTAssertEqual(decoded.actions[0].owner, "李工")
        XCTAssertNil(decoded.actions[1].owner, "没点名负责人的待办不该被写成空串")
    }

    /// **这条同时是指标脚本的契约**：新字段为 nil 时不能出现在 JSON 里，
    /// 否则 `quality_report.py` 会把"这次没产出要点"和"这次压根没要这个字段"
    /// 记成同一个 0，而 §1.5 的教训正是"用 0 冒充不可算会把结论带偏"。
    func testNilNewFieldsAreOmittedFromJSON() throws {
        let analysis = MeetingAnalysis(
            overview: [],
            timeline: [],
            decisions: [],
            actions: [],
            confidence: 0
        )
        let json = String(data: try JSONEncoder().encode(analysis), encoding: .utf8)!
        XCTAssertFalse(json.contains("headline"), "nil 的 headline 不该进 JSON：\(json)")
        XCTAssertFalse(json.contains("overviewBullets"), "nil 的 overviewBullets 不该进 JSON")
        XCTAssertFalse(json.contains("openQuestions"), "nil 的 openQuestions 不该进 JSON")
    }

    /// 空数组是"明确产出了 0 条"，与 nil 是两件事，必须留在 JSON 里。
    func testEmptyArraysSurviveAsEmptyArrays() throws {
        let analysis = MeetingAnalysis(
            overview: [], timeline: [], decisions: [], actions: [], confidence: 0,
            overviewBullets: [], openQuestions: []
        )
        let json = String(data: try JSONEncoder().encode(analysis), encoding: .utf8)!
        XCTAssertTrue(json.contains("\"overviewBullets\":[]"), "空数组要保留：\(json)")
        XCTAssertTrue(json.contains("\"openQuestions\":[]"), "空数组要保留")
    }

    // MARK: - 真实历史会话（只读，缺失即跳过）

    /// 拿数据根里真实存在的会话做一次解码回归 —— 2A 的验收标准是
    /// 「老会话仍可解析」，用手工 JSON 模拟一万次也不如读一次真文件。
    /// **只读**：绝不写、绝不删数据根里的任何东西。
    func testRealSessionFilesStillDecode() throws {
        let root = FileManager.default
            .homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MeetingScribe")
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else {
            throw XCTSkip("数据根不存在，跳过（此测试只做回归，不要求环境有数据）")
        }

        let files = dirs
            .map { $0.appendingPathComponent("session.json") }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else {
            throw XCTSkip("数据根里没有会话文件，跳过")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files {
            let data = try Data(contentsOf: file)
            XCTAssertNoThrow(
                try decoder.decode(MeetingSession.self, from: data),
                "历史会话读不出来就等于升级即丢数据：\(file.lastPathComponent)"
            )
        }
    }
}
