import XCTest
@testable import MeetingScribe

/// 钉住「逐字稿就地编辑」（方案 P1-4）。
///
/// 这一层要写回**用户自己看得见的数据**，所以判错的代价不是崩溃，而是
/// 「改坏了、看不出来、明天打开发现不是自己写的那个版本」。三个判据各自防一件事：
///
/// - `normalize`：防"用户按了一次回车，段里就多出一个换行符"（改坏了也不报错）；
/// - `apply` 的分支：防"点一下保存、什么都没动，却写了盘、还打上『已人工校正』"；
/// - **跳过人工改过的段**：防术语表把用户刚确认过的那句再换回去（改了半天白改）。
final class TranscriptEditorTests: XCTestCase {

    // MARK: - 造数据

    private let t0 = Date(timeIntervalSince1970: 1_760_000_000)

    private func segment(
        _ text: String,
        start: TimeInterval = 0,
        editedAt: Date? = nil
    ) -> TranscriptSegment {
        TranscriptSegment(
            start: start,
            end: start + 4,
            text: text,
            confidence: 0.9,
            manuallyEditedAt: editedAt
        )
    }

    /// 一份固定样本。
    ///
    /// **必须只构造一次**（所以是 `lazy var` 而不是计算属性）：`TranscriptSegment.id`
    /// 是随机 UUID，每次访问都重新造的话，「拿 `sample[1]` 的 id 去改 `sample`」
    /// 会因为在两批不同的段之间比对而落空 —— 测试会变成永远返回 `.unchanged`。
    private lazy var sample: [TranscriptSegment] = [
        segment("课考那边下周来验收", start: 0),
        segment("我们把报价单再核一遍", start: 4),
        segment("行，那就这么定", start: 8)
    ]

    // MARK: - 归一化

    func testNormalizeTrimsAndFoldsNewlinesIntoSpaces() {
        // 编辑器允许折行显示，但一段逐字稿是**一段话**，不是多段。
        XCTAssertEqual(
            TranscriptEditor.normalize("  客户那边\n下周来验收  "),
            "客户那边 下周来验收"
        )
        XCTAssertEqual(TranscriptEditor.normalize("第一行\r\n第二行"), "第一行 第二行")
        XCTAssertEqual(TranscriptEditor.normalize("前面\n\n\n后面"), "前面 后面")
        XCTAssertEqual(TranscriptEditor.normalize("\n\n   \n"), "")
        XCTAssertEqual(TranscriptEditor.normalize("客户那边"), "客户那边")
    }

    // MARK: - 落定一段

    func testApplyRewritesOnlyThatSegment() throws {
        let target = sample[1]
        let outcome = TranscriptEditor.apply(
            text: "我们把报价单再核一遍，顺便把合同编号对一下",
            to: sample,
            segmentID: target.id,
            at: t0
        )

        guard case let .saved(updated) = outcome else {
            return XCTFail("应当落定，实际 \(outcome)")
        }
        XCTAssertEqual(updated.count, 3, "改一段不该增减段数")
        XCTAssertEqual(updated[1].text, "我们把报价单再核一遍，顺便把合同编号对一下")
        XCTAssertEqual(updated[1].manuallyEditedAt, t0)

        // 时间戳、置信度、id 一律不动 —— 它们说的是"这段录音在哪儿、机器有多少把握"，
        // 与用户改了哪个字无关（改文字不该让这段跳到别的时刻去）。
        XCTAssertEqual(updated[1].id, target.id)
        XCTAssertEqual(updated[1].start, target.start)
        XCTAssertEqual(updated[1].end, target.end)
        XCTAssertEqual(updated[1].confidence, target.confidence)

        XCTAssertEqual(updated[0].text, sample[0].text)
        XCTAssertEqual(updated[0].manuallyEditedAt, nil, "没被改的段不该被打上标记")
        XCTAssertEqual(updated[2].text, sample[2].text)
        XCTAssertEqual(updated.map(\.id), sample.map(\.id), "顺序不该变")
    }

    func testApplyTrimsTheInputBeforeWriting() throws {
        let target = sample[0]
        let outcome = TranscriptEditor.apply(
            text: "  客户那边下周来验收  ",
            to: sample,
            segmentID: target.id,
            at: t0
        )
        guard case let .saved(updated) = outcome else {
            return XCTFail("应当落定，实际 \(outcome)")
        }
        XCTAssertEqual(updated[0].text, "客户那边下周来验收", "写进盘的是归一化之后的文本")
    }

    // MARK: - 三个不落盘的分支

    func testUnchangedWhenTextIsIdenticalAfterNormalizing() {
        // 用户点开、看了一遍、又点了保存 —— 什么都没变，就不该写盘、不该打标记。
        // 否则每点一次都会：页眉改口成「已人工校正」、段尾置信度变成「已校正」，
        // 而这些都发生在一次**没有修改**的点击之后。
        XCTAssertEqual(
            TranscriptEditor.apply(text: "行，那就这么定", to: sample, segmentID: sample[2].id, at: t0),
            .unchanged
        )
        XCTAssertEqual(
            TranscriptEditor.apply(text: "  行，那就这么定\n", to: sample, segmentID: sample[2].id, at: t0),
            .unchanged,
            "只多了首尾空白/换行，不算改动"
        )
    }

    func testRejectsEmptyTextAndKeepsTheOriginal() {
        // 删掉一段等于删掉那几十秒音频在纸面上的存在 —— 项目里「逐字稿任何时候都不删」
        // 是硬约束（同 2C）。要丢掉整段，得连录音一起删这场会议。
        for blank in ["", "   ", "\n\n"] {
            guard case .rejected = TranscriptEditor.apply(
                text: blank, to: sample, segmentID: sample[0].id, at: t0
            ) else {
                return XCTFail("「\(blank)」应当被拒绝")
            }
        }
    }

    func testUnknownSegmentIDIsNoOp() {
        // 界面手里那个 id 与数据不同步时，静默什么都不做 —— 比"对着邻近的一段写进去"强得多。
        XCTAssertEqual(
            TranscriptEditor.apply(text: "随便改点", to: sample, segmentID: UUID(), at: t0),
            .unchanged
        )
    }

    // MARK: - 计数（页眉那句「已人工校正 N 处」）

    func testEditedCountCountsOnlyEditedSegments() {
        XCTAssertEqual(TranscriptEditor.editedCount(in: sample), 0)
        XCTAssertEqual(
            TranscriptEditor.editedCount(in: [
                segment("甲", start: 0, editedAt: t0),
                segment("乙", start: 4),
                segment("丙", start: 8, editedAt: t0)
            ]),
            2
        )
    }

    // MARK: - 判据只有一处

    func testVerdictReportsTheThreeCases() {
        XCTAssertEqual(TranscriptEditor.verdict(for: "行，那就这么定", against: "行，那就这么定"), .unchanged)
        XCTAssertEqual(
            TranscriptEditor.verdict(for: "  行，那就这么定\n", against: "行，那就这么定"),
            .unchanged,
            "只有首尾空白/换行的差异不算改动"
        )
        guard case let .effective(text) = TranscriptEditor.verdict(
            for: " 行，那就这么定了 ", against: "行，那就这么定"
        ) else {
            return XCTFail("这是一次有效改动")
        }
        XCTAssertEqual(text, "行，那就这么定了", "effective 带的是归一化之后的文本")
        guard case .rejected = TranscriptEditor.verdict(for: "  \n ", against: "行，那就这么定") else {
            return XCTFail("空的应当被拒绝")
        }
    }

    func testVerdictAndApplyNeverDisagree() {
        // 「保存按钮亮不亮」（verdict）与「写不写盘」（apply）必须永远一致。
        // 两处各写一份判据时，走岔的表现是"按钮亮着但点不动"（或反过来），
        // 两个方向都不会报错 —— 所以用一条遍历把两者拴在一起。
        let inputs = ["", "   ", "\n\n", "课考那边下周来验收", " 课考那边下周来验收 ", "客户那边下周来验收", "课考\n那边"]
        for input in inputs {
            let verdict = TranscriptEditor.verdict(for: input, against: sample[0].text)
            let outcome = TranscriptEditor.apply(text: input, to: sample, segmentID: sample[0].id, at: t0)
            let verdictSaysEffective: Bool = {
                if case .effective = verdict { return true }
                return false
            }()
            let applySaysSaved: Bool = {
                if case .saved = outcome { return true }
                return false
            }()
            XCTAssertEqual(
                verdictSaysEffective, applySaysSaved,
                "输入「\(input)」上两者判反了：verdict=\(verdict) apply=\(outcome)"
            )
        }
    }

    // MARK: - 存盘兼容

    func testOldSegmentWithoutTheNewKeyStillDecodes() throws {
        // 老会话的 session.json 里没有 `manuallyEditedAt` 这个键。
        // 合成的 `Decodable` 对 Optional 属性走 `decodeIfPresent`，所以能解出来；
        // 而这条单测是钉住"以后有人把它改成非 Optional 时会立刻红"。
        let json = """
        {"id":"0B0E1B1C-1111-2222-3333-444455556666","start":12.5,"end":16.5,"text":"老会话的一段","confidence":0.72}
        """
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TranscriptSegment.self, from: Data(json.utf8))
        XCTAssertNil(decoded.manuallyEditedAt)
        XCTAssertEqual(decoded.text, "老会话的一段")
    }

    func testUneditedSegmentDoesNotGainANewKey() throws {
        // nil 要**省略键**，不写 `null`：指标脚本靠"键在不在"区分「不可算」与「0」，
        // 而这里也一样 —— 一个凭空出现的 `"manuallyEditedAt": null` 会让
        // "这场会动过没有" 变成需要解析值才能回答的问题。
        let data = try JSONEncoder().encode(sample[0])
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("manuallyEditedAt"), "没有编辑过的段不该写出这个键：\(text)")
    }

    // MARK: - 术语表不能覆盖人工校正

    func testTerminologySkipsManuallyEditedSegments() {
        let table = ["课考": "客户"]
        let segments = [
            segment("课考那边下周来验收", start: 0, editedAt: t0),
            segment("课考说报价单要重签", start: 4)
        ]

        let output = TranscriptCleaner.applyingTerminology(segments, table: table)

        XCTAssertEqual(
            output[0].text, "课考那边下周来验收",
            "这一段是人工校正过的，术语表必须原样穿过 —— 否则用户改完再点重整理就白改"
        )
        XCTAssertEqual(output[1].text, "客户说报价单要重签", "没被人工改过的段照常替换")
        XCTAssertEqual(output[0].manuallyEditedAt, t0, "标记不能因为一次替换就丢掉")
    }

    func testTerminologyCanStillTouchEditedSegmentsWhenExplicitlyAsked() {
        // 开关存在的意义：证明上面那条"跳过"是**这个开关**在做的事，
        // 而不是某处凑巧提前返回了。
        let output = TranscriptCleaner.applyingTerminology(
            [segment("课考那边下周来验收", start: 0, editedAt: t0)],
            table: ["课考": "客户"],
            skippingManuallyEdited: false
        )
        XCTAssertEqual(output[0].text, "客户那边下周来验收")
    }

    // MARK: - 端到端：改一句 → 重整理的材料里就是改后的那句

    func testEditThenRegenerateFeedsTheCorrectedText() throws {
        // 用户在原文页把「课考」改成「客户」，随后点「重新整理纪要」。
        // 整理模型读到的必须是**改后**的文本 —— 这正是就地编辑存在的理由
        // （改错词不用等模型猜对，也不必反复重试）。
        let target = sample[0]
        guard case let .saved(edited) = TranscriptEditor.apply(
            text: "客户那边下周来验收", to: sample, segmentID: target.id, at: t0
        ) else {
            return XCTFail("应当落定")
        }

        // 重整理时先过一遍替换表（用户可能刚补齐术语），手改的段原样穿过。
        let corrected = TranscriptCleaner.applyingTerminology(
            edited,
            table: ["课考": "客户"]
        )
        XCTAssertEqual(corrected.map(\.text), ["客户那边下周来验收", "我们把报价单再核一遍", "行，那就这么定"])
    }
}
