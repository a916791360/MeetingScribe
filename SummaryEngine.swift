import Foundation

enum SummaryEngineError: LocalizedError {
    case missingAPIKey
    case invalidEndpoint
    case invalidModelName
    case modelUnavailable(String, [String])
    case requestFailed(Int, String)
    case networkFailed(String)
    case emptyResponse
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
        case .emptyResponse:
            return "总结模型没有返回内容。"
        case .invalidModelList:
            return "服务商返回的模型列表格式无法识别。可以检查 API 地址，或使用手动模型 ID 兜底。"
        case .invalidStructuredResponse:
            return "总结模型返回格式无法识别。"
        }
    }
}

struct MeetingSummaryEngine: Sendable {
    func analyze(
        segments: [TranscriptSegment],
        settings: SummaryModelSettings,
        apiKey: String?
    ) async throws -> MeetingAnalysis {
        guard !segments.isEmpty else {
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
                apiKey: apiKey
            )
        }

        let chapterSummaries = try await summarizeChapters(
            segments: segments,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey
        )
        let synthesisSource = chapterSummaries.enumerated()
            .map { index, summary in "第 \(index + 1) 章\n\(summary)" }
            .joined(separator: "\n\n")
        return try await requestAnalysis(
            source: synthesisSource,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            sourceIsChapterSummary: true
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
            maxTokens: 16,
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
            throw SummaryEngineError.emptyResponse
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
        apiKey: String?
    ) async throws -> [String] {
        let chapters = makeChapters(from: segments, maxCharacters: 20_000)
        var results = Array(repeating: "", count: chapters.count)
        let batchSize = min(3, max(1, chapters.count))
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
                            maxTokens: 1_800
                        )
                        return (index, result)
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

    private func requestAnalysis(
        source: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        sourceIsChapterSummary: Bool = false
    ) async throws -> MeetingAnalysis {
        let prompt = """
        你正在整理一场中文工作会议。
        只根据给定材料输出 JSON，不要输出 Markdown、解释或代码围栏。
        不确定、语义不完整或只是提问的内容，一律不要写入决策和待办。
        逐字稿不是让你改写；速览和纪要必须是理解后的归纳。
        纪要正文只写讨论脉络、背景和过程，不要重复列出决策与待办。
        决策和待办会由 App 单独展示；没有明确内容时输出空数组。
        依据必须引用材料中的原句或原句片段，不要编造。
        置信度是你对该条结论确实被材料支持的判断，保守填写 0 到 1。
        时间戳使用材料中的秒数，无法确定就填 null。

        输出结构：
        {
          "overview": "一段能快速说明整场会议在讨论什么、形成了什么结果、下一步是什么的文字",
          "minutes": "会议纪要正文，只写讨论脉络、背景和过程，使用自然段和必要的小标题，不要重复决策与待办",
          "timeline": [
            {"start": 0, "end": 300, "summary": "这一阶段讨论了什么", "evidence": "依据", "confidence": 0.8}
          ],
          "decisions": [
            {"label": "明确结论", "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
          ],
          "actions": [
            {"label": "具体待办", "priority": "p1", "dueText": null, "evidence": "原文依据", "confidence": 0.8, "timestamp": 123.4}
          ],
          "confidence": 0.8
        }

        \(sourceIsChapterSummary ? "给定材料是按时间整理的章节摘要，请综合所有章节，避免把章节标题当成结论。" : "给定材料是带时间戳的会议逐字稿，请覆盖整场会议。")

        给定材料：
        \(source)
        """

        let response = try await requestText(
            prompt: prompt,
            system: Self.systemPrompt,
            endpoint: endpoint,
            settings: settings,
            apiKey: apiKey,
            maxTokens: 6_000
        )
        return try parseAnalysis(response, settings: settings)
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
    private func requestText(
        prompt: String,
        system: String,
        endpoint: URL,
        settings: SummaryModelSettings,
        apiKey: String?,
        maxTokens: Int? = nil,
        timeoutInterval: TimeInterval = 10 * 60
    ) async throws -> String {
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

        func makeRequest(streaming: Bool) throws -> URLRequest {
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

        var lastError: Error = SummaryEngineError.emptyResponse
        for attempt in 0..<3 {
            try Task.checkCancellation()
            if attempt > 0 {
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_200_000_000)
            }
            do {
                let text = try await performStreamingRequest(makeRequest(streaming: true))
                if !text.isEmpty { return text }
                lastError = SummaryEngineError.emptyResponse
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

        // 流式全军覆没（个别服务商就是不支持 SSE）→ 退回非流式再试一次。
        try Task.checkCancellation()
        do {
            let text = try await performBufferedRequest(makeRequest(streaming: false))
            if !text.isEmpty { return text }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as SummaryEngineError {
            if case .requestFailed = error { throw error }
        } catch {
            // 非流式也失败 → 最终抛流式那次的错，它更贴近真实原因。
        }

        throw lastError
    }

    /// SSE 流式读取：逐行解析 `data: {...}`，把 `choices[].delta.content` 拼起来。
    private func performStreamingRequest(_ request: URLRequest) async throws -> String {
        struct StreamChunk: Decodable {
            struct Choice: Decodable {
                struct Delta: Decodable {
                    let content: String?
                }

                let delta: Delta?
                let message: Delta?
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
            throw SummaryEngineError.emptyResponse
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
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload.isEmpty { continue }
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data) else {
                continue
            }
            let choice = chunk.choices.first
            let piece = choice?.delta?.content ?? choice?.message?.content
            if let piece, !piece.isEmpty {
                accumulated += piece
            }
        }
        return accumulated.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 非流式兜底：一次性等完整回复。
    private func performBufferedRequest(_ request: URLRequest) async throws -> String {
        struct ResponseBody: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    let content: String?
                }

                let message: Message
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
            throw SummaryEngineError.emptyResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SummaryEngineError.requestFailed(
                httpResponse.statusCode,
                responseMessage(from: data)
            )
        }
        let decoded = try JSONDecoder().decode(ResponseBody.self, from: data)
        guard let content = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !content.isEmpty else {
            throw SummaryEngineError.emptyResponse
        }
        return content
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

    private func parseAnalysis(
        _ response: String,
        settings: SummaryModelSettings
    ) throws -> MeetingAnalysis {
        let responseText = response
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
        guard let data = json.data(using: .utf8) else {
            throw SummaryEngineError.invalidStructuredResponse
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
            }

            let overview: String?
            let minutes: String?
            let timeline: [Timeline]?
            let decisions: [Decision]?
            let actions: [Action]?
            let confidence: Double?
        }

        let payload = try JSONDecoder().decode(Payload.self, from: data)
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
                  label.count >= 4,
                  evidence.count >= 6,
                  !looksUncertain(label),
                  (item.confidence ?? 0.5) >= 0.62 else { return nil }
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
                  label.count >= 4,
                  evidence.count >= 6,
                  !looksUncertain(label),
                  (item.confidence ?? 0.5) >= 0.62 else { return nil }
            return ActionItem(
                label: label,
                priority: item.priority.flatMap { PriorityLevel(rawValue: $0.lowercased()) },
                dueText: nonEmpty(item.dueText),
                evidence: evidence,
                confidence: clamp(item.confidence ?? 0.5),
                timestamp: item.timestamp
            )
        } ?? []

        let confidence = clamp(
            payload.confidence ??
                average((decisions.map(\.confidence) + actions.map(\.confidence)))
        )
        let overview = nonEmpty(payload.overview) ?? ""
        let minutes = nonEmpty(payload.minutes) ?? ""
        guard !overview.isEmpty ||
              !minutes.isEmpty ||
              !decisions.isEmpty ||
              !actions.isEmpty else {
            throw SummaryEngineError.invalidStructuredResponse
        }

        return MeetingAnalysis(
            overview: [],
            timeline: timeline,
            decisions: decisions,
            actions: actions,
            confidence: confidence,
            overviewText: overview,
            minutesText: minutes,
            summaryModel: settings.displayName,
            summaryError: nil
        )
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

    private func looksUncertain(_ text: String) -> Bool {
        [
            "可能", "也许", "大概", "考虑", "建议", "可以考虑",
            "是否", "如果", "待定", "再看", "不确定"
        ].contains(where: text.contains)
    }
}

private extension TimeInterval {
    var oneDecimalSeconds: String {
        String(format: "%.1f", max(0, self))
    }
}
