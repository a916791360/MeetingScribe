import Foundation

enum SummaryEngineError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case invalidModelName
    case modelUnavailable(String, [String])
    case requestFailed(Int, String)
    case networkFailed(String)
    case emptyResponse(String?)
    /// 推理模型把 max_tokens 全花在思考链上、正文一字未出（finish_reason=length）。
    case budgetExhausted(Int)
    case invalidModelList
    case invalidStructuredResponse

    var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "当前总结模型需要 API Key，请先在设置中保存。"
        case .invalidEndpoint:
            return "总结模型地址无效。请填写服务商 API 根地址，例如 https://example.com/v1。应用会自动补全 /chat/completions。"
        case .invalidModelName:
            return "模型 ID 不能为空。请填写服务商提供的真实模型 ID，不要填写服务商名称。"
        case .modelUnavailable(let requested, let available):
            let preview = available.prefix(8).joined(separator: "、")
            if preview.isEmpty {
                return "找不到模型“\(requested)”。请填写服务商提供的真实模型 ID。"
            }
            return "找不到模型“\(requested)”。可用模型：\(preview)。请在设置中改成其中一个真实模型 ID。"
        case .requestFailed(let status, let message):
            if status == 401 || status == 403 {
                return "总结模型认证失败（\(status)）。请确认 API Key 有效，并重新获取可用模型。"
            }
            if status == 404 {
                return "总结模型接口不存在（404）。请填写服务商 API 根地址，例如 https://example.com/v1；应用会自动补全 /chat/completions。"
            }
            return "总结模型请求失败（\(status)）：\(message)"
        case .networkFailed(let message):
            return "总结模型连接失败：\(message)"
        case .emptyResponse(let detail):
            // 只说「没有返回内容」用户没法排查——服务商可能 200 回了一个错误信封、
            // 或者回了别家格式。把原样回包截一段带出来，问题一眼可见。
            if let detail, !detail.isEmpty {
                return "总结模型没有返回可用内容。服务商回包：\(detail)"
            }
            return "总结模型没有返回内容。"
        case .budgetExhausted(let tokens):
            // 这是推理模型的典型行为，不是用户配置错——文案要给出可执行的下一步。
            return """
            总结模型把 \(tokens) token 的预算全部花在了思考过程上，没能输出正文。\
            已自动翻倍预算重试；若反复出现，说明该模型面对长材料时思考链过长，\
            建议在设置里换一个非推理模型（例如 deepseek-v4-flash）。
            """
        case .invalidModelList:
            return "服务商返回的模型列表格式无法识别。可以检查 API 地址，或使用手动模型 ID 兜底。"
        case .invalidStructuredResponse:
            return "总结模型返回格式无法识别。"
        }
    }
}

struct MeetingSummaryEngine: Sendable {
    // MARK: - token 预算
    //
    // max_tokens 是「思考链 + 正文」的总预算，推理模型（如 deepseek-v4.1-flash）
    // 会先产出一大段思考链再写正文。实测在 1.6 万字材料上，思考链稳定吃掉
    // 2000~3500 token —— 给 1800 的预算时接口返回 200 但 content 完全为空
    // （reasoning_tokens=1800、text_tokens=0、finish_reason=length）。
    //
    // **2026-09-13 复测（阶段 0 基线）**：真正的病根比"正文为空"更阴——1.6 万字
    // 材料上思考链能吃掉七到九成预算，`finish_reason=length` 时**正文非空但被砍断**，
    // JSON 断在数组中间 → `parseAnalysis` 抛错 → 整场静默降级成本地规则。
    // 所以这两件事必须一起改：预算给足（下面这些数）+ 截断判定认 `length`（见 requestText）。
    // 只抬预算不改判定、或只改 prompt 不抬预算，实测都会更差。

    /// 单章摘要：思考链余量 + 几百字正文。
    static let chapterTokenBudget = 16_000
    /// 速览 / 结构化一次调用：overview + timeline + decisions + actions 的整份 JSON。
    static let analysisTokenBudget = 32_000
    /// 纪要正文一次调用：纯散文，比结构化那段短，但同样要先花掉一整条思考链。
    static let minutesTokenBudget = 16_000
    /// 连通性测试：只要求回四个字，但推理模型光思考就要几百 token。
    static let probeTokenBudget = 2_048
    /// 遇到截断时抬预算的天花板。抬到顶还是 `length`，就收下截断内容并在 UI 明说。
    static let maxTokenBudget = 48_000

    func analyze(
        segments: [TranscriptSegment],
        settings: SummaryModelSettings,
        apiKey: String?,
        /// 用户术语表（P1-3 / 2D）。默认空表，现有测试与"没配术语表"的路径不必关心它。
        /// 空表时 prompt 里**一个字都不加** —— 见 `Glossary.summaryInstruction`。
        glossary: Glossary = .empty
    ) async throws -> MeetingAnalysis {
        // 前置门禁：**材料不够就一个 token 都不花**。
        //
        // 这道检查必须在 `chatCompletionsURL` 和 API Key 校验**之前** ——
        // 材料不足是一个关于录音本身的结论，不该因为"用户还没填 Key"而变成另一个报错，
        // 也不该为了得出这个结论而先跑一趟网络。
        //
        // 不做这道门禁的原始现场：25 秒的误录被送进模型，而模型返回的**不是空**，
        // 是一段元评论 ——「本次材料仅包含一句栏目推广语，未出现任何会议讨论内容，
        // 因此无法识别会议主题……」。它花掉预算、占着「速览」最显眼的位置、
        // 还长得像结论。见 `TranscriptMaterial`。
        if TranscriptMaterial.measure(segments).shortfall != nil {
            return MeetingAnalysisBuilder.build(from: segments)
        }

        if settings.provider == .localRules {
            return MeetingAnalysisBuilder.build(from: segments)
        }

        let endpoint = try chatCompletionsURL(from: settings.endpoint)

        if settings.provider.requiresAPIKey &&
            (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw SummaryEngineError.missingAPIKey
        }
        guard !settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SummaryEngineError.invalidModelName
        }

        try Task.checkCancellation()

        let transcript = makeTranscript(from: segments)
        // Keep direct requests small enough for local models and 8K/32K cloud contexts.
        if transcript.count <= 24_000 {
            return try await requestAnalysis(
                source: transcript,
                endpoint: endpoint,
                settings: settings,
                apiKey: apiKey,
                glossary: glossary
            )
        }

        let chapterSummaries = try await summarizeChapters(
            segments: segments,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            glossary: glossary
        )
        let synthesisSource = chapterSummaries.enumerated()
            .map { index, summary in "第 \(index + 1) 章\n\(summary)" }
            .joined(separator: "\n\n")
        return try await requestAnalysis(
            source: synthesisSource,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            sourceIsChapterSummary: true,
            glossary: glossary
        )
    }

    func test(
        settings: SummaryModelSettings,
        apiKey: String?
    ) async throws {
        guard settings.provider != .localRules else { return }
        let endpoint = try chatCompletionsURL(from: settings.endpoint)
        if settings.provider.requiresAPIKey &&
            (apiKey?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            throw SummaryEngineError.missingAPIKey
        }
        let requestedModel = settings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !requestedModel.isEmpty else {
            throw SummaryEngineError.invalidModelName
        }

        _ = try await requestText(
            prompt: """
            只回复“连接正常”四个字，不要输出其他内容。
            """,
            system: "你是一个接口连通性测试器。",
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            // 推理模型光思考就要几百 token，16 会让连通性测试假失败。
            maxTokens: Self.probeTokenBudget,
            timeoutInterval: 60
        )
    }

    func discoverModels(
        settings: SummaryModelSettings,
        apiKey: String?
    ) async throws -> [String]? {
        guard settings.provider != .localRules else { return nil }
        let endpoint = try chatCompletionsURL(from: settings.endpoint)
        guard let modelsEndpoint = modelsURL(from: endpoint) else {
            return nil
        }
        return try await requestModels(
            endpoint: modelsEndpoint,
            apiKey: apiKey
        )
    }

    private func chatCompletionsURL(from rawEndpoint: String) throws -> URL {
        try SummaryModelEndpoint.chatCompletionsURL(from: rawEndpoint)
    }

    private func modelsURL(from chatEndpoint: URL) -> URL? {
        SummaryModelEndpoint.modelsURL(from: chatEndpoint)
    }

    private func requestModels(endpoint: URL, apiKey: String?) async throws -> [String]? {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw SummaryEngineError.networkFailed(networkMessage(for: error))
        } catch {
            throw SummaryEngineError.networkFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryEngineError.emptyResponse(nil)
        }

        if httpResponse.statusCode == 404 {
            // Some compatible gateways do not expose /models. Let the chat
            // request remain the source of truth in that case.
            return []
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryEngineError.requestFailed(
                httpResponse.statusCode,
                responseMessage(from: data)
            )
        }

        do {
            return try SummaryModelDiscovery.parse(data)
        } catch {
            throw SummaryEngineError.invalidModelList
        }
    }

    private func summarizeChapters(
        segments: [TranscriptSegment],
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        glossary: Glossary
    ) async throws -> [String] {
        let chapters = makeChapters(from: segments, maxCharacters: 20_000)
        var results = Array(repeating: "", count: chapters.count)
        let batchSize = min(3, max(1, chapters.count))
        // 章节摘要是后面综合**唯一**的输入，专名在这里就该写对 —— 综合那一步拿不到原文，
        // 这里写错了后面没有任何机会纠正。所以术语约束也要给到这一层。
        let terminology = glossary.summaryInstruction
        var batchStart = 0

        while batchStart < chapters.count {
            try Task.checkCancellation()
            let batchEnd = min(chapters.count, batchStart + batchSize)
            let batch = Array(chapters.indices[batchStart..<batchEnd])
            let batchResults = try await withThrowingTaskGroup(
                of: (Int, String).self,
                returning: [(Int, String)].self
            ) { group in
                for index in batch {
                    let chapter = chapters[index]
                    group.addTask {
                        let prompt = """
                        下面是一场会议的其中一章原文。请只根据原文做保守整理，不补充原文没有的事实。
                        输出简洁的章节摘要，并分别列出明确结论和明确待办。
                        待办必须包含清晰动作和对象；没有把握就留空。
                        \(terminology ?? "")
                        输出格式：
                        章节摘要：……
                        明确结论：
                        - …
                        明确待办：
                        - …

                        原文：
                        \(chapter)
                        """
                        let result = try await self.requestText(
                            prompt: prompt,
                            system: Self.systemPrompt,
                            endpoint: endpoint,
                            settings: settings,
                            apiKey: apiKey,
                            maxTokens: Self.chapterTokenBudget
                        )
                        return (index, result.text)
                    }
                }

                var completed: [(Int, String)] = []
                for try await result in group {
                    completed.append(result)
                }
                return completed
            }

            for (index, result) in batchResults {
                results[index] = result
            }
            batchStart = batchEnd
        }

        return results.filter { !$0.isEmpty }
    }

    // MARK: - 两段式整理
    //
    // 旧版是「一次调用做完所有事」：一个 prompt 里同时要 overview、minutes、
    // timeline、decisions、actions，JSON 又长、预算又被思考链吃掉，实测在 1.6 万字
    // 材料上稳定被截断 —— JSON 断在数组中间，解析抛错，**整场静默降级成本地规则**。
    //
    // 旧 prompt 原文留在这里，方便对照「改了什么」：
    //
    //   你正在整理一场中文工作会议。
    //   只根据给定材料输出 JSON，不要输出 Markdown、解释或代码围栏。
    //   不确定、语义不完整或只是提问的内容，一律不要写入决策和待办。
    //   逐字稿不是让你改写；速览和纪要必须是理解后的归纳。
    //   纪要正文只写讨论脉络、背景和过程，不要重复列出决策与待办。   ← 致命的一句
    //   决策和待办会由 App 单独展示；没有明确内容时输出空数组。
    //   …（输出结构略）
    //
    // 那句「纪要正文只写讨论脉络、背景和过程，**不要重复列出决策与待办**」是第二个
    // 病根：它把"纪要"定义成了纯过程叙述，模型于是交回 682 字、0 小标题、通篇"围绕…
    // 展开"的流水账。纪要里本来最值钱的就是结论和待办，偏偏被这句话点名排除掉了。

    /// 速览 / 结构化那一段的产物。
    struct StructuredFacts: Sendable {
        var overviewText: String
        var timeline: [TimelineChunk]
        var decisions: [InsightItem]
        var actions: [ActionItem]
        var confidence: Double
        var truncated: Bool
        var finishReason: String?
        var escalations: Int
        /// 2A 新增：一句话结论 / 带时间锚的要点 / 待确认问题。
        ///
        /// 给默认值是为了让既有的两处构造点（正常解析 + 截断救援）不用改参数。
        var headline: String? = nil
        var overviewBullets: [String] = []
        var openQuestions: [String] = []

        /// 一个字段都没拿到 —— 用来判断"这次等于白跑了"。
        ///
        /// `headline` / `overviewBullets` / `openQuestions` 也算内容：它们和
        /// `overviewText` 一样是用户看得见的产出，只拿到要点就退化成"什么都嫌少"，
        /// 反而会把一份可用的结果判成白跑。
        var isEmpty: Bool {
            overviewText.isEmpty &&
                (headline?.isEmpty ?? true) &&
                overviewBullets.isEmpty &&
                openQuestions.isEmpty &&
                timeline.isEmpty &&
                decisions.isEmpty &&
                actions.isEmpty
        }
    }

    /// 纪要正文那一段的产物。
    struct MinutesOutput: Sendable {
        var text: String
        var truncated: Bool
        var finishReason: String?
        var escalations: Int
    }

    /// 两段并发跑完之后各自的结果。
    ///
    /// **故意不抛错**：两段之间没有依赖，一段失败不该把另一段已经拿到的成果一起带走。
    /// 速览成了但纪要正文网络抖动失败 → 至少速览、决策、待办能留下来，并明确告诉用户
    /// "纪要正文这次没生成出来"，而不是整场退回本地规则（那样连速览都没了）。
    private enum StageOutcome: Sendable {
        case facts(StructuredFacts)
        case factsFailed(SummaryEngineError)
        case minutes(MinutesOutput)
        case minutesFailed(SummaryEngineError)
        case cancelled
    }

    /// 整理一场会议 = 两次调用（速览/结构化 + 纪要正文），并发发出。
    ///
    /// 并发的理由：两条请求之间没有依赖，串行会让用户白等一倍时间。
    /// `withTaskGroup` 之后总耗时 ≈ `max(速览, 纪要)` 而不是 `sum`。
    private func requestAnalysis(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool = false,
        glossary: Glossary = .empty
    ) async throws -> MeetingAnalysis {
        // 术语约束在这一层算一次，两个并发分支共用 —— 两段 prompt 必须说同一件事，
        // 各算各的早晚会漂移（一处改了另一处没改）。
        let terminology = glossary.summaryInstruction
        let outcomes = await withTaskGroup(of: StageOutcome.self) { group in
            group.addTask {
                await self.runFactsStage(
                    source: source,
                    endpoint: endpoint,
                    settings: settings,
                    apiKey: apiKey,
                    sourceIsChapterSummary: sourceIsChapterSummary,
                    terminology: terminology
                )
            }
            group.addTask {
                await self.runMinutesStage(
                    source: source,
                    endpoint: endpoint,
                    settings: settings,
                    apiKey: apiKey,
                    sourceIsChapterSummary: sourceIsChapterSummary,
                    terminology: terminology
                )
            }
            var collected: [StageOutcome] = []
            for await outcome in group {
                collected.append(outcome)
            }
            return collected
        }

        try Task.checkCancellation()

        var facts: StructuredFacts?
        var minutes: MinutesOutput?
        var factsError: SummaryEngineError?
        var minutesError: SummaryEngineError?

        for outcome in outcomes {
            switch outcome {
            case .facts(let value): facts = value
            case .factsFailed(let error): factsError = error
            case .minutes(let value): minutes = value
            case .minutesFailed(let error): minutesError = error
            case .cancelled: break
            }
        }

        // 速览/结构化那半是主干：速览页、决策、待办全由它产出。它整个失败时，
        // 光有一段纪要正文救不了场（速览页是空的、决策待办一条没有），
        // 照旧抛错、走本地兜底 + summaryError —— 那是唯一能给出"为什么"的地方。
        guard let facts else {
            throw factsError ?? SummaryEngineError.emptyResponse(nil)
        }

        let minutesText = minutes?.text ?? ""

        // 「不完整」要说人话，而且必须真的显示出来（见执行计划 §2 工程细节 ②）。
        var incompleteReasons: [String] = []
        if facts.truncated {
            incompleteReasons.append("速览部分在模型输出上限处被截断")
        }
        if let minutes {
            if minutes.truncated {
                incompleteReasons.append("纪要正文在模型输出上限处被截断")
            }
        } else if let minutesError {
            incompleteReasons.append("纪要正文这次没生成出来（\(minutesError.localizedDescription)）")
        }
        let isPartial = !incompleteReasons.isEmpty
        let partialNotice = isPartial
            ? incompleteReasons.joined(separator: "；")
                + "。已保留模型产出的可用部分；可以直接重试，或在设置里换一个上下文更长的模型。"
            : nil

        // `facts.isEmpty` 已经把 2A 新增的 headline / overviewBullets / openQuestions
        // 也算作内容，所以这里不再逐字段罗列 —— 逐字段罗列的写法会在下次加字段时漏一处。
        guard !facts.isEmpty || !minutesText.isEmpty else {
            throw SummaryEngineError.invalidStructuredResponse
        }

        return MeetingAnalysis(
            overview: [],
            timeline: facts.timeline,
            decisions: facts.decisions,
            actions: facts.actions,
            confidence: facts.confidence,
            overviewText: facts.overviewText,
            minutesText: minutesText,
            summaryModel: settings.displayName,
            summaryError: nil,
            partialNotice: partialNotice,
            diagnostics: SummaryDiagnostics(
                overviewFinishReason: facts.finishReason,
                minutesFinishReason: minutes?.finishReason,
                escalationCount: facts.escalations + (minutes?.escalations ?? 0),
                partial: isPartial
            ),
            headline: facts.headline,
            overviewBullets: facts.overviewBullets,
            openQuestions: facts.openQuestions
        )
    }

    private func runFactsStage(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool,
        terminology: String?
    ) async -> StageOutcome {
        do {
            let facts = try await requestStructuredFacts(
                source: source,
                endpoint: endpoint,
                settings: settings,
                apiKey: apiKey,
                sourceIsChapterSummary: sourceIsChapterSummary,
                terminology: terminology
            )
            return .facts(facts)
        } catch is CancellationError {
            return .cancelled
        } catch let error as SummaryEngineError {
            return .factsFailed(error)
        } catch {
            return .factsFailed(.networkFailed(error.localizedDescription))
        }
    }

    private func runMinutesStage(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool,
        terminology: String?
    ) async -> StageOutcome {
        do {
            let minutes = try await requestMinutesText(
                source: source,
                endpoint: endpoint,
                settings: settings,
                apiKey: apiKey,
                sourceIsChapterSummary: sourceIsChapterSummary,
                terminology: terminology
            )
            return .minutes(minutes)
        } catch is CancellationError {
            return .cancelled
        } catch let error as SummaryEngineError {
            return .minutesFailed(error)
        } catch {
            return .minutesFailed(.networkFailed(error.localizedDescription))
        }
    }

    /// 第一段：速览 + 时间线 + 决策 + 待办，一次性给全的结构化 JSON。
    ///
    /// 字段名仍然是 `overview` / `minutes` 那套的老名字见 `parseStructuredFacts`，
    /// 但这里**不再要 `minutes`**——纪要正文由第二段单独产出，各给各的预算。
    private func requestStructuredFacts(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool,
        terminology: String?
    ) async throws -> StructuredFacts {
        let prompt = """
        你正在整理一场中文工作会议的"速览"。只根据给定材料输出 JSON，不要输出 Markdown、解释或代码围栏。
        读者是没参会、但要立刻知道"结论是什么、我该做什么"的同事。
        不确定、语义不完整或只是提问的内容，一律不要写入决策和待办。
        逐字稿不是让你改写；速览必须是理解后的归纳，不是原文照抄。
        决策和待办会由 App 单独展示；没有明确内容时输出空数组。

        **必须遵守的两条硬要求**：
        1. 禁止空话动词。以下措辞一律不许出现：会上介绍了、会上讨论了、会上提到、谈到了、提到了、围绕……展开、延伸到、进行了讨论、交换了意见。要写实质内容（谁提了什么、数字是多少、为什么否掉）。
        2. 必须保留原文里的具体数字、版本号、日期、人名、系统名，一个都不能省。
        \(terminology ?? "")

        把材料中每一处明确的决定、承诺和待办都列出来，不要只挑最重要的几条。
        只有当一条内容只是提问、只是可能性或没定下来时，才不写进决策和待办。
        依据必须引用材料中的原句或原句片段，不要编造。
        置信度是你对该条结论确实被材料支持的判断，保守填写 0 到 1。
        时间戳使用材料中的秒数，无法确定就填 null。
        不要在结果里评价材料本身（比如"材料不足""未提及"），材料里没有的内容直接不写。

        输出结构：
        {
          "headline": "一句话说清这场会最终是什么结果（30 字以内，直接写结论，不要以'本次会议'开头）",
          "overview": "一段速览导语，200 到 400 字。第一句直接给结论（例如'确定…''决定…''本期只做…'），禁止用'本次会议围绕……展开''会上讨论了……'这类套话开头；随后说清形成了什么结果、下一步是什么",
          "overviewBullets": [
            "[12:30] 一条要点。每条必须以 [分:秒] 开头并在材料里找到对应位置，正文里尽量带上具体数字、版本号、日期或人名"
          ],
          "openQuestions": [
            "会上提出但这次没定下来的问题（没有就输出空数组）"
          ],
          "timeline": [
            {"start": 0, "end": 300, "summary": "这一阶段讨论了什么", "evidence": "依据", "confidence": 0.8}
          ],
          "decisions": [
            {"label": "明确结论", "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
          ],
          "actions": [
            {"label": "具体待办", "owner": "谁来做；材料没点名就填 null", "priority": "p1", "dueText": null, "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
          ],
          "confidence": 0.8
        }

        overviewBullets 给 4 到 7 条，覆盖整场的重点（决定、关键数字、风险、下一步），不要写成 overview 的分句抄写。
        openQuestions 最多 5 条，只收"明确被提出来但没结论"的，不要把普通提问塞进去。
        actions 的 owner 只在材料点出负责的人**或角色**时才填 —— "苏总""赵瑞梅""产品经理""业务人员""经销商"这类都算；
        填了 owner 就要把它**从 label 里挪出去**，不要让同一条待办的 label 和 owner 各留一份责任人。
        材料没点名一律 null，不要写"负责人""待定""相关同事"这类占位词。

        \(sourceIsChapterSummary ? "给定材料是按时间整理的章节摘要，请综合所有章节，避免把章节标题当成结论。" : "给定材料是带时间戳的会议逐字稿，请覆盖整场会议。")

        给定材料：
        \(source)
        """

        let result = try await requestText(
            prompt: prompt,
            system: Self.systemPrompt,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            maxTokens: Self.analysisTokenBudget
        )
        return try parseStructuredFacts(result, allowPartial: result.truncated)
    }

    /// 第二段：纪要正文（纯散文，不要 JSON）。
    ///
    /// **为什么用纯文本而不是 JSON**：这一段的产出是一两千字的长散文，塞进 JSON
    /// 字符串要转义换行和引号，模型隔三差五就会漏一个 —— 那是另一条"看起来正常
    /// 但其实坏了"的路。纯文本没有这种失败模式。
    private func requestMinutesText(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool,
        terminology: String?
    ) async throws -> MinutesOutput {
        let prompt = """
        你正在整理一场中文工作会议的纪要正文，只输出正文本身。
        用自然段写清讨论脉络，用必要的小标题分段；小标题用 `一、二、三` 或 `## 标题` 都可以。
        纪要要说清：讨论了哪些问题、各自的背景与取舍、最后定了什么、接下来要做什么。
        写的是实质性内容（谁提了什么方案、数字是多少、为什么否掉），不是过程叙述。
        不要重复罗列决策清单和待办清单——那两块由 App 另外展示，但结论和待办本身要写进正文里说清楚。

        **两条硬要求**：
        1. 绝对禁止这些空话动词：会上介绍了、会上讨论了、会上提到、会上说、会上确认、谈到了、提到了、围绕……展开、延伸到、中段主要围绕、进行了讨论、交换了意见。直接写事实与结论，不要用"会上提到"这类转述引子。
        2. 原文里的数字、版本号、日期、人名、系统名必须写进正文，一个都不能省。
        \(terminology ?? "")

        不要输出开场白（"以下是""好的"之类）、不要输出 JSON、代码围栏或对本次整理的说明。
        不要在正文里评价材料本身（比如"材料不足""未提及""无法判断"），材料里没有的内容直接不写。
        不要编造材料里没有的事实。

        \(sourceIsChapterSummary ? "给定材料是按时间整理的章节摘要，请综合所有章节。" : "给定材料是带时间戳的会议逐字稿，请覆盖整场会议。")

        给定材料：
        \(source)
        """

        let result = try await requestText(
            prompt: prompt,
            system: Self.systemPrompt,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            maxTokens: Self.minutesTokenBudget
        )
        return MinutesOutput(
            text: minutesBody(from: result.text),
            truncated: result.truncated,
            finishReason: result.finishReason,
            escalations: result.escalations
        )
    }

    /// 纪要正文是纯文本回包，除了 JSON 不该有的转义，还要挡掉两类常见噪音：
    /// 代码围栏、以及模型习惯性加的开场白。只做「首行/首句」级别的剥除，
    /// 不碰正文内部 —— 正文里出现"好的"是正常的，只错在开头那一句。
    private func minutesBody(from raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text
                .replacingOccurrences(of: "```markdown", with: "")
                .replacingOccurrences(of: "```md", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let preamblePrefixes = [
            "以下是", "下面是", "好的，", "好的:", "好的：", "这是本次会议的纪要",
            "会议纪要如下", "以下是会议纪要"
        ]
        if let firstLine = text.split(separator: "\n", omittingEmptySubsequences: false).first,
           firstLine.count <= 40 {
            let line = String(firstLine)
            for prefix in preamblePrefixes where line.hasPrefix(prefix) {
                // 整行都只是开场白（≤40 字）时才整行删掉；否则保留，避免误伤正文首句。
                text = String(text.dropFirst(line.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }
        return text
    }

    /// 一次文本调用（`requestText`）的完整回包。
    ///
    /// 关键是 `truncated`：**正文非空也可能是截断**。旧代码把"截断"定义成
    /// 「正文为空 + finish_reason=length」，于是模型写完一半被砍这种最常见的情况
    /// 被当成成功，半截 JSON 直接进解析器 → 抛错 → 整场静默降级。
    struct SummaryTextResult: Sendable {
        let text: String
        let truncated: Bool
        let finishReason: String?
        /// 为躲开截断而抬预算的次数（0 表示一次成功）。
        let escalations: Int

        var isComplete: Bool { !text.isEmpty && !truncated }

        /// 把「这次一共抬了几次预算」写进回包，交给上层汇总成诊断信息。
        func recording(escalations: Int) -> SummaryTextResult {
            SummaryTextResult(
                text: text,
                truncated: truncated,
                finishReason: finishReason,
                escalations: escalations
            )
        }
    }

    /// 请求总结模型并取回纯文本。
    ///
    /// **为什么改成流式**：非流式请求在服务端生成完之前本机收不到任何字节，
    /// 这条"长时间静默"的连接会被中间任何一环按空闲超时掐掉——系统代理、
    /// FlClash 这类本地代理、服务商网关都算。实测本机两场会议的 `summaryError`
    /// 都是同一句「网络连接已中断」（`NSURLErrorNetworkConnectionLost`），
    /// 逐字稿本身好好的，就是这一步被掐的。
    /// 改成 SSE 之后 token 是持续吐出来的，连接始终有流量，空闲超时不成立；
    /// 超时口径也从"整段回复"变成"两个 token 之间"，对长文总结友好得多。
    ///
    /// **为什么要重试**：网络抖动不该让整场会议的整理白跑。重试 2 次、1.2s 起步
    /// 退避；401/403/404 这类确定性错误不重试，重试只会让用户多等一遍同样的报错。
    ///
    /// **返回值带 `truncated`**：见下面的注释，「被截断」和「失败」是两种不同的病，
    /// 调用方要能分开处理 —— 截断的内容有救（收下 + 明说不完整），失败没有。
    private func requestText(
        prompt: String,
        system: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        maxTokens: Int? = nil,
        timeoutInterval: TimeInterval = 10 * 60
    ) async throws -> SummaryTextResult {
        struct Message: Encodable {
            let role: String
            let content: String
        }

        struct RequestBody: Encodable {
            let model: String
            let messages: [Message]
            let temperature: Double
            let maxTokens: Int?
            let stream: Bool

            private enum CodingKeys: String, CodingKey {
                case model
                case messages
                case temperature
                case maxTokens = "max_tokens"
                case stream
            }
        }

        func makeRequest(streaming: Bool, maxTokens: Int?) throws -> URLRequest {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = timeoutInterval
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if streaming {
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            }
            if let apiKey, !apiKey.isEmpty {
                request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            }
            let body = RequestBody(
                model: settings.modelName,
                messages: [
                    Message(role: "system", content: system),
                    Message(role: "user", content: prompt)
                ],
                temperature: 0.1,
                maxTokens: maxTokens,
                stream: streaming
            )
            request.httpBody = try JSONEncoder().encode(body)
            return request
        }

        try Task.checkCancellation()

        // max_tokens 是「思考链 + 正文」的总预算。推理模型会把额度先花在思考上，
        // 预算不够时接口 200 但正文被砍断 —— 这不是用户配置错，加预算就能救。
        //
        // **判截断只看 `finish_reason`，不看正文空不空**。这是本轮修的第二个病根：
        // 旧代码写成 `if trimmed.isEmpty { if finishReason == "length" { throw budgetExhausted } }`，
        // 于是**正文非空但被砍断**的情况（实测里最常见的那种）压根不算截断，
        // 半截 JSON 被当成完整结果交给 parseAnalysis，解析抛错 → 整场静默降级。
        var budget = maxTokens
        var networkAttempts = 0
        var escalations = 0
        var lastError: Error = SummaryEngineError.emptyResponse(nil)
        /// 截断但**有内容**的回包先留着：抬到天花板还是截断时，它比"什么都没有"强。
        var truncatedFallback: SummaryTextResult?

        while networkAttempts < 3 {
            try Task.checkCancellation()
            if networkAttempts > 0 {
                try await Task.sleep(nanoseconds: UInt64(networkAttempts) * 1_200_000_000)
            }
            networkAttempts += 1
            do {
                let result = try await performStreamingRequest(
                    makeRequest(streaming: true, maxTokens: budget),
                    maxTokens: budget
                )
                if result.isComplete {
                    return result.recording(escalations: escalations)
                }

                if result.truncated {
                    if let next = escalatedBudget(from: budget, escalations: escalations) {
                        escalations += 1
                        budget = next
                        if !result.text.isEmpty { truncatedFallback = result }
                        lastError = SummaryEngineError.budgetExhausted(next)
                        // 抬预算算「换个方式再试」，不占用正常的失败重试次数。
                        networkAttempts -= 1
                        continue
                    }
                    // 已经顶到天花板：有内容就收下（外层会标记"不完整"并说给用户），
                    // 一字没有才算真的失败。
                    if !result.text.isEmpty {
                        return result.recording(escalations: escalations)
                    }
                    lastError = SummaryEngineError.budgetExhausted(budget ?? 0)
                    break
                }

                // 正文为空且不是截断（`performStreamingRequest` 会替这种情况直接抛错），
                // 走到这里说明是别的原因，重试一次看看。
                lastError = SummaryEngineError.emptyResponse(nil)
            } catch is CancellationError {
                throw CancellationError()
            } catch let error as SummaryEngineError {
                // 认证 / 地址 / 模型名这类确定性错误，重试没有意义。
                if case .requestFailed(let status, _) = error,
                   (400..<500).contains(status), status != 429 {
                    throw error
                }
                lastError = error
            } catch {
                lastError = error
            }
        }

        // 抬到顶也还是截断，但至少拿到了一段正文 → 交出去，别丢。
        // 预算不够是确定的，再退化成"非流式"重跑一遍也只会同样截断。
        if let fallback = truncatedFallback {
            return fallback.recording(escalations: escalations)
        }

        // 流式全军覆没（个别服务商就是不支持 SSE）→ 退回非流式再试一次。
        try Task.checkCancellation()
        do {
            let result = try await performBufferedRequest(
                makeRequest(streaming: false, maxTokens: budget),
                maxTokens: budget
            )
            if !result.text.isEmpty {
                return result.recording(escalations: escalations)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummaryEngineError {
            if case .requestFailed = error { throw error }
        } catch {
            // 非流式也失败 → 最终抛流式那次的错，它更贴近真实原因。
        }

        throw lastError
    }

    /// 抬预算：翻倍，但不超过天花板，而且必须真的变大（相等会原地打转）。
    /// `current` 为空时按纪要正文那档起步 —— 只有连通性测试会不带预算调进来。
    private func escalatedBudget(from current: Int?, escalations: Int) -> Int? {
        guard escalations < 2 else { return nil }
        let base = current ?? Self.minutesTokenBudget
        let next = min(base * 2, Self.maxTokenBudget)
        return next > base ? next : nil
    }

    /// SSE 流式读取：逐行解析 `data: {...}`，把 `choices[].delta.content` 拼起来。
    private func performStreamingRequest(
        _ request: URLRequest,
        maxTokens: Int?
    ) async throws -> SummaryTextResult {
        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                    /// 推理模型把思考过程单独放在这个字段，它不算正文。
                    let reasoning: String?
                }

                let delta: Delta?
                let message: Delta?
                let finishReason: String?

                private enum CodingKeys: String, CodingKey {
                    case delta
                    case message
                    case finishReason = "finish_reason"
                }
            }

            let choices: [Choice]
        }

        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await URLSession.shared.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw SummaryEngineError.networkFailed(networkMessage(for: error))
        } catch {
            throw SummaryEngineError.networkFailed(error.localizedDescription)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryEngineError.emptyResponse(nil)
        }

        // 非 2xx 时错误体通常不是 SSE，按普通 body 收一点拿服务商的错误文案。
        guard (200..<300).contains(httpResponse.statusCode) else {
            var buffer = Data()
            do {
                for try await byte in bytes {
                    buffer.append(byte)
                    if buffer.count > 8_192 { break }
                }
            } catch {
                // 读错误体失败不影响抛出状态码本身。
            }
            throw SummaryEngineError.requestFailed(
                httpResponse.statusCode,
                responseMessage(from: buffer)
            )
        }

        var accumulated = ""
        var rawTap = ""
        var finishReason: String?
        var sawReasoning = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            // 留一份原样回包（最多 300 字符），内容为空时用来还原现场。
            if rawTap.count < 300 { rawTap += payload + " " }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                continue
            }
            let choice = chunk.choices.first
            if let reason = choice?.delta?.reasoning, !reason.isEmpty { sawReasoning = true }
            if let reason = choice?.message?.reasoning, !reason.isEmpty { sawReasoning = true }
            if let value = choice?.finishReason, !value.isEmpty { finishReason = value }
            let piece = choice?.delta?.content ?? choice?.message?.content
            if let piece, !piece.isEmpty {
                accumulated += piece
            }
        }
        let trimmed = accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = finishReason == "length"
        if trimmed.isEmpty {
            // 正文为空 + finish_reason=length：预算被思考链整段吃光（sawReasoning 为真）。
            // 不当错误抛，交给外层抬预算重试 —— 外层还要区分"截断"和"失败"。
            if truncated {
                return SummaryTextResult(
                    text: "",
                    truncated: true,
                    finishReason: finishReason,
                    escalations: 0
                )
            }
            // 其余情况：服务商忽略 stream 回了普通 JSON，或回的是错误信封。
            // 带出原样回包，外层还有非流式兜底。
            let hint = sawReasoning ? "（模型只输出了思考过程，没有正文）" : ""
            let detail = rawTap.isEmpty ? nil : hint + String(rawTap.prefix(300))
            throw SummaryEngineError.emptyResponse(detail)
        }
        // **正文非空也要看 finish_reason**：模型写完一半被砍是最常见的那种截断，
        // 旧代码在这里直接 return，于是半截内容被当成完整结果收下。
        return SummaryTextResult(
            text: trimmed,
            truncated: truncated,
            finishReason: finishReason,
            escalations: 0
        )
    }

    /// 非流式兜底：一次性等完整回复。
    private func performBufferedRequest(
        _ request: URLRequest,
        maxTokens: Int?
    ) async throws -> SummaryTextResult {
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                    let reasoning: String?
                }

                let message: Message
                let finishReason: String?

                private enum CodingKeys: String, CodingKey {
                    case message
                    case finishReason = "finish_reason"
                }
            }

            let choices: [Choice]
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            throw SummaryEngineError.networkFailed(networkMessage(for: error))
        } catch {
            throw SummaryEngineError.networkFailed(error.localizedDescription)
        }
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SummaryEngineError.emptyResponse(nil)
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryEngineError.requestFailed(
                httpResponse.statusCode,
                responseMessage(from: data)
            )
        }
        // 用 try? 而不是 try：服务商 200 回错误信封（没有 choices 键）时，
        // 抛 DecodingError 对用户毫无意义，不如把原样回包带出去。
        guard let decoded = try? JSONDecoder().decode(ResponseBody.self, from: data) else {
            throw SummaryEngineError.emptyResponse(rawSnippet(from: data))
        }
        let first = decoded.choices.first
        if let content = first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty {
            // 同流式：正文非空也可能是截断（finish_reason=length），一并带出去。
            return SummaryTextResult(
                text: content,
                truncated: first?.finishReason == "length",
                finishReason: first?.finishReason,
                escalations: 0
            )
        }
        // 正文空 + length：同样是被 token 上限截断。不当错误抛，外层统一处理。
        if first?.finishReason == "length" {
            return SummaryTextResult(
                text: "",
                truncated: true,
                finishReason: first?.finishReason,
                escalations: 0
            )
        }
        if let reasoning = first?.message.reasoning, !reasoning.isEmpty {
            throw SummaryEngineError.emptyResponse("（模型只输出了思考过程，没有正文）")
        }
        throw SummaryEngineError.emptyResponse(rawSnippet(from: data))
    }

    /// 服务商 200 但正文不可用时，把原样回包截一小段带出去。
    /// 「没有返回内容」这句话本身没法排查，用户需要看到服务商到底回了什么。
    private func rawSnippet(from data: Data, limit: Int = 300) -> String? {
        guard !data.isEmpty else { return "（响应体为空）" }
        guard let text = String(data: data, encoding: .utf8) else {
            return "（非 UTF-8 响应体，\(data.count) 字节）"
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return "（响应体为空）" }
        return collapsed.count <= limit ? collapsed : String(collapsed.prefix(limit)) + "…"
    }

    private func responseMessage(from data: Data) -> String {
        struct ErrorEnvelope: Decodable {
            struct APIError: Decodable {
                let message: String?
                let code: String?
                let type: String?
            }

            let error: APIError?
        }

        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: data),
           let apiError = envelope.error {
            let parts: [String] = [apiError.message, apiError.code, apiError.type]
                .compactMap { value in
                    guard let value else { return nil }
                    let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    return clean.isEmpty ? nil : clean
                }
            if !parts.isEmpty {
                return String(parts.joined(separator: " · ").prefix(500))
            }
        }

        let raw = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "服务端没有提供错误信息。" : String(raw.prefix(500))
    }

    private func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .timedOut:
            return "请求超时，服务商在限定时间内没有返回。可以换一个模型，或稍后重试。"
        case .notConnectedToInternet:
            return "当前没有可用网络。"
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed:
            return "无法连接服务商地址，请检查网络和 API 地址。"
        case .secureConnectionFailed, .serverCertificateUntrusted:
            return "HTTPS 安全连接失败，请检查服务商证书或地址。"
        case .networkConnectionLost:
            return "连接被中途断开（长时间没有数据往来时，网络或代理容易掐掉这种连接）。已自动重试；若反复出现，请检查代理设置。"
        default:
            return error.localizedDescription
        }
    }

    /// 解析速览那一段的结构化 JSON。
    ///
    /// `allowPartial` 只在**确认截断**（`finish_reason == "length"`）时传 true，
    /// 见执行计划 §2 工程细节 ②：宽容解析的收益是"救回已经写完的字段"，
    /// 不是"容忍坏 JSON"。不确认截断也宽容，等于把模型的残次品当结果收下。
    private func parseStructuredFacts(
        _ result: SummaryTextResult,
        allowPartial: Bool
    ) throws -> StructuredFacts {
        let responseText = result.text
            .replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let json: String
        if let start = responseText.firstIndex(of: "{"),
           let end = responseText.lastIndex(of: "}"),
           start <= end {
            json = String(responseText[start...end])
        } else {
            json = responseText
        }

        struct Payload: Decodable {
            struct Timeline: Decodable {
                let start: TimeInterval?
                let end: TimeInterval?
                let summary: String?
                let evidence: String?
                let confidence: Double?
            }

            struct Decision: Decodable {
                let label: String?
                let evidence: String?
                let confidence: Double?
                let timestamp: TimeInterval?
            }

            struct Action: Decodable {
                let label: String?
                let priority: String?
                let dueText: String?
                let evidence: String?
                let confidence: Double?
                let timestamp: TimeInterval?
                /// 2A：谁来做。材料没点名就为 nil。
                let owner: String?
            }

            let overview: String?
            let timeline: [Timeline]?
            let decisions: [Decision]?
            let actions: [Action]?
            let confidence: Double?
            /// 2A 新增三键，老会话/老 prompt 的返回里没有，全部 Optional。
            let headline: String?
            let overviewBullets: [String]?
            let openQuestions: [String]?
        }

        var payload: Payload?
        if let data = json.data(using: .utf8) {
            payload = try? JSONDecoder().decode(Payload.self, from: data)
        }

        // 严格解析失败 + 确认截断 → 把砍断的 JSON 修回可解析的形状。
        if payload == nil, allowPartial,
           let repaired = Self.repairTruncatedJSON(json),
           let data = repaired.data(using: .utf8) {
            payload = try? JSONDecoder().decode(Payload.self, from: data)
        }

        var facts: StructuredFacts?
        if let payload {
            let timeline = payload.timeline?.compactMap { item -> TimelineChunk? in
                guard let summary = nonEmpty(item.summary),
                      let start = item.start,
                      let end = item.end else { return nil }
                return TimelineChunk(
                    start: max(0, start),
                    end: max(start, end),
                    summary: summary,
                    evidence: nonEmpty(item.evidence) ?? "",
                    confidence: clamp(item.confidence ?? 0.5)
                )
            } ?? []
            let decisions = payload.decisions?.compactMap { item -> InsightItem? in
                guard let label = nonEmpty(item.label),
                      let evidence = nonEmpty(item.evidence),
                      Self.admitsDecision(
                          label: label,
                          evidence: evidence,
                          confidence: item.confidence ?? 0.5
                      ) else { return nil }
                return InsightItem(
                    label: label,
                    evidence: evidence,
                    confidence: clamp(item.confidence ?? 0.5),
                    timestamp: item.timestamp
                )
            } ?? []
            let actions = payload.actions?.compactMap { item -> ActionItem? in
                guard let label = nonEmpty(item.label),
                      let evidence = nonEmpty(item.evidence),
                      Self.admitsAction(
                          label: label,
                          evidence: evidence,
                          confidence: item.confidence ?? 0.5
                      ) else { return nil }
                return ActionItem(
                    label: label,
                    priority: item.priority.flatMap { PriorityLevel(rawValue: $0.lowercased()) },
                    dueText: nonEmpty(item.dueText),
                    evidence: evidence,
                    confidence: clamp(item.confidence ?? 0.5),
                    timestamp: item.timestamp,
                    owner: nonEmpty(item.owner)
                )
            } ?? []
            // 要点和待确认问题：逐条清洗，空串丢掉（模型偶尔会用空串占位）。
            let bullets = (payload.overviewBullets ?? []).compactMap { nonEmpty($0) }
            let questions = (payload.openQuestions ?? []).compactMap { nonEmpty($0) }
            facts = StructuredFacts(
                overviewText: nonEmpty(payload.overview) ?? "",
                timeline: timeline,
                decisions: decisions,
                actions: actions,
                confidence: clamp(
                    payload.confidence ??
                        average(decisions.map(\.confidence) + actions.map(\.confidence))
                ),
                truncated: result.truncated,
                finishReason: result.finishReason,
                escalations: result.escalations,
                headline: nonEmpty(payload.headline),
                overviewBullets: bullets,
                openQuestions: questions
            )
        }

        // 连修都修不好（或者修出来是空的）→ 退一步只抠 overview。
        // 一段像样的速览导语本身就是有用的产出，不该因为它后面那段数组被砍掉就全丢。
        if (facts?.isEmpty ?? true), allowPartial,
           let salvaged = Self.salvageOverview(from: json) {
            facts = StructuredFacts(
                overviewText: salvaged,
                timeline: [],
                decisions: [],
                actions: [],
                // 残缺产出不给高置信度，界面上"待确认"的观感才诚实。
                confidence: 0.3,
                truncated: true,
                finishReason: result.finishReason,
                escalations: result.escalations
            )
        }

        guard let facts, !facts.isEmpty else {
            throw SummaryEngineError.invalidStructuredResponse
        }
        return facts
    }

    /// 把砍断的 JSON 修回「能解析」的形状：先算出未闭合的括号栈，
    /// 再收尾未闭合的字符串，并用「退一步试一次」的方式砍掉尾巴上悬空的
    /// `,` / `:` / 半截键，最后补齐缺失的 `}` `]`。
    ///
    /// 只用在确认截断的分支里。修不回来返回 nil，交给 `salvageOverview`。
    static func repairTruncatedJSON(_ source: String) -> String? {
        guard source.hasPrefix("{") else { return nil }

        var stack: [Character] = []
        var inString = false
        var escaped = false
        for character in source {
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                continue
            }
            switch character {
            case "\"": inString = true
            case "{", "[": stack.append(character)
            case "}":
                guard stack.last == "{" else { return nil }
                stack.removeLast()
            case "]":
                guard stack.last == "[" else { return nil }
                stack.removeLast()
            default: break
            }
        }

        let closers = stack.reversed().map { $0 == "{" ? "}" : "]" }.joined()
        var trimmed = source
        // 最多退 40 步：够砍掉 `"key":` 这种悬空尾巴，又不会退进正文里乱试。
        for _ in 0..<40 {
            var candidate = trimmed
            if inString { candidate.append("\"") }
            candidate += closers
            if (try? JSONSerialization.jsonObject(with: Data(candidate.utf8))) != nil {
                return candidate
            }
            guard let last = trimmed.last else { return nil }
            if last.isWhitespace || last == "," || last == ":" || last == "\"" {
                trimmed.removeLast()
            } else {
                return nil
            }
        }
        return nil
    }

    /// 从残缺 JSON 里抠出 `overview` 的字符串值。
    ///
    /// 用正则而不是 JSON 解析器，因为这里的前提就是"JSON 已经不完整"。
    /// 抠出来还要按 JSON 字符串规则反转义（模型会在里面塞 `\n` 和引号）。
    static func salvageOverview(from json: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: "\"overview\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        ) else { return nil }
        let range = NSRange(json.startIndex..<json.endIndex, in: json)
        guard let match = regex.firstMatch(in: json, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: json) else { return nil }

        let literal = "\"" + String(json[captured]) + "\""
        guard let data = literal.data(using: .utf8),
              let value = try? JSONDecoder().decode(String.self, from: data) else { return nil }

        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        // 太短的"速览"没有信息量，不如当作没抠到，让上层如实报失败。
        return text.count >= 20 ? text : nil
    }

    private func makeTranscript(from segments: [TranscriptSegment]) -> String {
        segments.map {
            "[\($0.start.oneDecimalSeconds)] \($0.text)"
        }.joined(separator: "\n")
    }

    private func makeChapters(
        from segments: [TranscriptSegment],
        maxCharacters: Int
    ) -> [String] {
        var chapters: [String] = []
        var current: [String] = []
        var count = 0

        for segment in segments {
            let line = "[\(segment.start.oneDecimalSeconds)] \(segment.text)"
            if !current.isEmpty && count + line.count > maxCharacters {
                chapters.append(current.joined(separator: "\n"))
                current = []
                count = 0
            }
            current.append(line)
            count += line.count + 1
        }

        if !current.isEmpty {
            chapters.append(current.joined(separator: "\n"))
        }
        return chapters
    }

    private static let systemPrompt = """
    你是一个严谨的中文会议整理助手。
    你不负责猜测发言人、补齐听不清的内容或把讨论中的可能性写成结论。
    只使用输入材料中明确出现的事实。
    """

    private func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? nil : clean
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }

    private func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// 决策条目的准入门槛。
    ///
    /// **抽成静态判据是为了能单测**（原来决策/待办两处 `compactMap` 各抄一遍同样的 guard，
    /// 结果待办那条里的 `looksUncertain` 把「建议先做 X」整条丢掉，很久没人发现）。
    static func admitsDecision(label: String, evidence: String, confidence: Double) -> Bool {
        label.count >= 4
            && evidence.count >= 6
            && !looksUncertain(label)
            && confidence >= 0.62
    }

    /// 待办条目的准入门槛。比决策松一点：**「建议先做 X」本身就是一条真待办**，
    /// 不该因为字面带「建议」就被整条丢掉。实测（2026-09-13 阶段 1 复评）待办条数
    /// 长期只有目标的 1/2，一部分就是在这里被误杀的。
    static func admitsAction(label: String, evidence: String, confidence: Double) -> Bool {
        label.count >= 4
            && evidence.count >= 6
            && !looksUndecidedForAction(label)
            && confidence >= 0.62
    }

    static func looksUncertain(_ text: String) -> Bool {
        [
            "可能", "也许", "大概", "考虑", "建议", "可以考虑",
            "是否", "如果", "待定", "再看", "不确定"
        ].contains(where: text.contains)
    }

    /// 待办用更松的判据。决策仍走 `looksUncertain` —— 字面带"建议/考虑"的往往确实还没定，
    /// 但写成待办时它就是一件要做的事。
    static func looksUndecidedForAction(_ text: String) -> Bool {
        ["可能", "也许", "大概", "是否", "待定", "不确定"].contains(where: text.contains)
    }
}

private extension TimeInterval {
    var oneDecimalSeconds: String {
        String(format: "%.1f", max(0, self))
    }
}
