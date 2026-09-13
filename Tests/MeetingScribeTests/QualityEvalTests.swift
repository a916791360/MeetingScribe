import Foundation
import XCTest

@testable import MeetingScribe

/// 质量评测集的驱动器。
///
/// 它**不做任何自己的 HTTP 请求**，而是直接调 `MeetingSummaryEngine().analyze(...)` ——
/// 测的就是 App 真实走的代码路径（预算、重试、解析、抛错全都在里面）。
/// 自己拿 curl 搓请求只能证明接口通，证明不了「App 的这套逻辑对不对」。
///
/// 需要凭据，所以默认跳过：
/// ```
/// MS_E2E_KEY=sk-... swift test --disable-sandbox --filter QualityEvalTests
/// ```
/// 可选：
/// - `MS_QUALITY_DIR`     评测集目录（默认自动定位仓库内 `docs/verification/quality`）
/// - `MS_SUMMARY_ENDPOINT` / `MS_SUMMARY_MODEL`  覆盖服务商与模型
///
/// 输出：`<quality>/runs/<caseId>.json`，交给 `Scripts/quality_report.py` 出指标。
final class QualityEvalTests: XCTestCase {

    // MARK: - 评测集文件结构

    private struct CaseFile: Decodable {
        let caseId: String
        let label: String
        let expect: String
        let durationSeconds: Double
        let segments: [Segment]
    }

    private struct Segment: Decodable {
        let start: Double
        let end: Double
        let text: String
        let confidence: Double
    }

    // MARK: - 环境

    private func repoRoot() -> URL {
        var dir = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir
            }
            dir.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private func qualityDir() -> URL {
        if let custom = ProcessInfo.processInfo.environment["MS_QUALITY_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: custom)
        }
        return repoRoot().appendingPathComponent("docs/verification/quality")
    }

    /// 复刻 `MeetingSummaryEngine.makeTranscript` 的拼装方式，用于量「真正喂给模型的字符数」。
    /// 上游那个扩展是 fileprivate 的，这里按同样格式重现 —— 上游改了格式，这里要跟着改。
    private func transcriptChars(_ segments: [TranscriptSegment]) -> Int {
        segments
            .map { "[\(String(format: "%.1f", max(0, $0.start)))] \($0.text)" }
            .joined(separator: "\n")
            .count
    }

    private func errorName(_ error: Error) -> String {
        guard let e = error as? SummaryEngineError else {
            return String(describing: type(of: error))
        }
        switch e {
        case .missingAPIKey: return "missingAPIKey"
        case .invalidEndpoint: return "invalidEndpoint"
        case .invalidModelName: return "invalidModelName"
        case .modelUnavailable: return "modelUnavailable"
        case .requestFailed(let status, _): return "requestFailed(\(status))"
        case .networkFailed: return "networkFailed"
        case .emptyResponse: return "emptyResponse"
        case .budgetExhausted: return "budgetExhausted"
        case .invalidModelList: return "invalidModelList"
        case .invalidStructuredResponse: return "invalidStructuredResponse"
        }
    }

    // MARK: - 主流程

    func testRunQualityEvalSet() async throws {
        let key = ProcessInfo.processInfo.environment["MS_E2E_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key, !key.isEmpty else {
            throw XCTSkip("未提供 MS_E2E_KEY，跳过需要联网的质量评测。")
        }

        let env = ProcessInfo.processInfo.environment
        let settings = SummaryModelSettings(
            provider: .custom,
            modelName: env["MS_SUMMARY_MODEL"] ?? "deepseek-v4.1-flash",
            endpoint: env["MS_SUMMARY_ENDPOINT"] ?? "https://xtapi.site/v1"
        )

        let quality = qualityDir()
        let casesDir = quality.appendingPathComponent("cases")
        let runsDir = quality.appendingPathComponent("runs")
        try FileManager.default.createDirectory(at: runsDir, withIntermediateDirectories: true)

        let files = (try FileManager.default.contentsOfDirectory(at: casesDir, includingPropertiesForKeys: nil))
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        // MS_QUALITY_CASES=long-full,slice2-15-30min 可只跑指定 case。
        // 排查单点问题、或不想为一次小改动重跑整套（每个 case 都是一次真实计费调用）时用得上。
        var selected = files
        if let only = ProcessInfo.processInfo.environment["MS_QUALITY_CASES"] {
            let wanted = Set(
                only.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            )
            if !wanted.isEmpty {
                selected = files.filter { wanted.contains($0.deletingPathExtension().lastPathComponent) }
                XCTAssertEqual(
                    selected.count, wanted.count,
                    "MS_QUALITY_CASES 里有点名不存在的 case：\(wanted)"
                )
            }
        }

        XCTAssertFalse(selected.isEmpty, "评测集为空，先跑 Scripts/build_eval_set.py")

        let engine = MeetingSummaryEngine()

        for file in selected {
            let data = try Data(contentsOf: file)
            let source = try JSONDecoder().decode(CaseFile.self, from: data)

            let segments = source.segments.map {
                TranscriptSegment(start: $0.start, end: $0.end, text: $0.text, confidence: $0.confidence)
            }
            let rawChars = segments.reduce(0) { $0 + $1.text.trimmingCharacters(in: .whitespaces).count }

            // 本地兜底产物：用户在「整场降级」时实际看到的就是它 —— 必须记下来，
            // 否则「内容非常差」在指标里看不见（它不报错、看起来正常）。
            let fallback = MeetingAnalysisBuilder.build(from: segments)

            var record: [String: Any] = [
                "caseId": source.caseId,
                "label": source.label,
                "expect": source.expect,
                "durationSeconds": source.durationSeconds,
                "inputSegmentCount": segments.count,
                "inputCharCount": rawChars,
                // P0-1（TranscriptCleaner）落地前，喂给模型的就是原始段
                "preparedSegmentCount": segments.count,
                "preparedCharCount": rawChars,
                "transcriptCharsSentToModel": transcriptChars(segments),
                "finishReason": NSNull(),  // P0-3 起由引擎回传，见《质量提升执行计划》
                "localFallback": [
                    "overviewChars": fallback.overviewText.count,
                    "minutesChars": fallback.minutesText.count,
                    "decisions": fallback.decisions.count,
                    "actions": fallback.actions.count,
                ],
            ]

            let started = Date()
            do {
                let analysis = try await engine.analyze(
                    segments: segments,
                    settings: settings,
                    apiKey: key
                )
                record["elapsedSeconds"] = Date().timeIntervalSince(started)
                record["ok"] = true
                record["errorType"] = NSNull()
                record["errorMessage"] = NSNull()
                let encoded = try JSONEncoder().encode(analysis)
                record["analysis"] = try JSONSerialization.jsonObject(with: encoded)
            } catch {
                record["elapsedSeconds"] = Date().timeIntervalSince(started)
                record["ok"] = false
                record["errorType"] = errorName(error)
                record["errorMessage"] = error.localizedDescription
                record["analysis"] = NSNull()
            }

            let out = runsDir.appendingPathComponent("\(source.caseId).json")
            let payload = try JSONSerialization.data(
                withJSONObject: record,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            )
            try payload.write(to: out)
        }

        let produced = try FileManager.default.contentsOfDirectory(atPath: runsDir.path)
        for file in selected {
            XCTAssertTrue(
                produced.contains("\(file.deletingPathExtension().lastPathComponent).json"),
                "\(file.lastPathComponent) 应产出一份 run 记录"
            )
        }
    }
}
