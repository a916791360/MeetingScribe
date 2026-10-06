import Foundation

/// Diagnostic fields are not meeting content. Treat old provider/CLI output as untrusted,
/// even when it contains no recognizable key prefix; never try to redact it by regex.
enum SafeDiagnostics {
    static let recordingPreparationCancelled = "已取消录音准备，尚未确认开始录音。可以重新开始录音。"
    static let summaryFallback = "整理未成功，已保留逐字稿与已有结果。请检查模型设置、网络与服务额度后重试。"
    static let partialFallback = "整理结果不完整，已保留可用部分。可以重新整理，或更换上下文更长的模型。"
    static let processingFallback = "处理未完成，原始文件及已保存内容已保留。请检查录音权限、磁盘空间与模型设置后重试。"
    static let captureFallback = "录音音轨可能不完整，无法确认说话人归属。请检查录音权限并回放原始音频。"
    static let incompleteTracks = "双路音频不完整，本次使用混合原件转写，无法确认说话人归属。若未授予麦克风权限，本机发言可能缺失。"

    private static let summaryMessages: Set<String> = {
        var messages: Set<String> = [summaryFallback, "整理模型未返回结果"]
        let errors: [SummaryEngineError] = [.missingAPIKey, .invalidEndpoint, .invalidModelName,
            .invalidModelList, .invalidStructuredResponse, .emptyResponse(nil)]
        for error in errors { messages.insert(error.localizedDescription) }
        for status in 100...599 { messages.insert(SummaryEngineError.requestFailed(status, "").localizedDescription) }
        for detail in ["响应体为空。", "服务商响应格式不可用。", "响应超过安全大小限制。", "（模型只输出了思考过程，没有正文）"] {
            messages.insert(SummaryEngineError.emptyResponse(detail).localizedDescription)
        }
        return messages
    }()

    static func summary(_ message: String?) -> String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return summaryMessages.contains(message) ? message : summaryFallback
    }

    static func partial(_ message: String?) -> String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return partialFallback
    }

    static func capture(_ message: String?) -> String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return message == incompleteTracks ? message : captureFallback
    }

    static func processing(_ message: String?) -> String? {
        guard let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let errors: [PipelineError] = [.missingDisplay, .missingAudioTrack, .failedToCreateRecorder,
            .failedToStartCapture, .failedToStopCapture, .missingBinary, .missingModel,
            .missingJSONOutput, .audioDurationUnavailable, .transcriptionTimedOut]
        let fixed: Set<String> = [processingFallback, recordingPreparationCancelled,
            "应用退出时录音未完成，原始文件已保留，可以重新处理。",
            "已取消转写，已保留已经完成的内容，可以重新处理。"]
        return fixed.contains(message) || errors.contains(where: { $0.localizedDescription == message })
            ? message : processingFallback
    }
}

extension MeetingSession {
    var isRecordingPreparationCancelled: Bool {
        status == .failed && errorMessage == SafeDiagnostics.recordingPreparationCancelled
    }

    var sanitizingDiagnostics: MeetingSession {
        var copy = self
        copy.analysis.summaryError = SafeDiagnostics.summary(analysis.summaryError)
        copy.analysis.partialNotice = SafeDiagnostics.partial(analysis.partialNotice)
        copy.lastRegenerationError = SafeDiagnostics.summary(lastRegenerationError)
        copy.captureWarning = SafeDiagnostics.capture(captureWarning)
        copy.errorMessage = SafeDiagnostics.processing(errorMessage)
        return copy
    }
}
