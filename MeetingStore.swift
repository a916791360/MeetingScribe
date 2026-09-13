import AppKit
import Foundation

@MainActor
final class MeetingStore: ObservableObject {
    @Published var sessions: [MeetingSession] = []
    @Published var selectedSessionID: UUID?
    @Published var appearance: AppAppearance {
        didSet {
            guard oldValue != appearance else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Preferences.appearance)
            AppAppearance.apply(appearance)
        }
    }
    @Published var captureMode: CaptureMode {
        didSet {
            guard oldValue != captureMode else { return }
            UserDefaults.standard.set(captureMode.rawValue, forKey: Preferences.captureMode)
        }
    }
    @Published var whisperCLIPath: String
    @Published var whisperModelPath: String
    @Published var summarySettings: SummaryModelSettings
    @Published var summaryAPIKeyInput: String = ""
    @Published var summaryAPIKeyStatus: String = ""
    @Published var summaryTestStatus: String = ""
    @Published var availableSummaryModels: [String] = []
    @Published var canEditSummaryModelManually = false
    @Published var isLoadingSummaryModels = false
    @Published var statusText: String = "准备就绪"
    @Published var isRecording: Bool = false
    @Published var isProcessing: Bool = false
    @Published var processingProgress: Double = 0
    @Published var processingStage: String = ""
    @Published var showSettings: Bool = false {
        didSet {
            // 打开设置时才去取密文。
            //
            // 原来这一步在 `init()` 里做，后果是：应用每次重新打包（自签名证书下
            // 代码签名必然变），钥匙串 ACL 就不认得新签名，macOS 弹一个系统模态框
            // 要登录密码 —— 而它卡在 `NSApplicationMain` 完成之前，
            // **窗口根本来不及建出来**。用户看到的是"双击图标没反应"。
            // 现在启动只查"有没有"（不解密、不弹框），要显示时才取。
            guard showSettings, !oldValue else { return }
            loadSummaryAPIKeyFromKeychain()
        }
    }
    @Published var importAudioPresented: Bool = false
    @Published var errorMessage: String?

    private let storage = SessionStorage()
    private let transcoder = AudioTranscoder()
    private let durationReader = AudioDurationReader()
    private let transcriber = WhisperCLIRunner()
    private let summaryEngine = MeetingSummaryEngine()
    private let keychain = KeychainStore.shared
    private var microphoneSession: MicrophoneRecordingSession?
    private var mixedSession: MixedRecordingSession?
    private var processingTask: Task<Void, Never>?
    private var recordingLimitTask: Task<Void, Never>?
    private var summaryModelDiscoveryTask: Task<Void, Never>?
    private var summaryModelDiscoveryID: UUID?
    private var pendingSummaryModelSelection: String?
    private var activeSessionID: UUID?
    private var summaryRegenerationID: UUID?

    private static let chunkDuration: TimeInterval = 10 * 60

    /// 每段音频的长度（秒）。界面拿它估"段内"的连续进度，见 `WorkbenchProcessingState`。
    static var chunkDurationSeconds: TimeInterval { chunkDuration }
    private static let chunkOverlap: TimeInterval = 2
    /// 录音上限（秒）。界面拿它来做「快到点了」的提前预警。
    static let maxRecordingSeconds: TimeInterval = 3 * 60 * 60
    private static let maxRecordingDuration: UInt64 = UInt64(maxRecordingSeconds) * 1_000_000_000

    private enum Preferences {
        static let appearance = "meetingScribe.appearance"
        static let captureMode = "meetingScribe.captureMode"
        static let whisperCLIPath = "meetingScribe.whisperCLIPath"
        static let whisperModelPath = "meetingScribe.whisperModelPath"
        static let summaryProvider = "meetingScribe.summaryProvider"
        static let summaryModel = "meetingScribe.summaryModel"
        static let summaryEndpoint = "meetingScribe.summaryEndpoint"
    }

    init() {
        let defaults = Self.defaultRuntimePaths()
        let legacyDefaults = Self.legacyRuntimePaths()
        let storedCLIPath = UserDefaults.standard.string(forKey: Preferences.whisperCLIPath)
        let storedModelPath = UserDefaults.standard.string(forKey: Preferences.whisperModelPath)
        let summaryProvider = SummaryModelProvider(
            rawValue: UserDefaults.standard.string(forKey: Preferences.summaryProvider) ?? ""
        ) ?? .localRules
        let storedSummaryModel = UserDefaults.standard.string(forKey: Preferences.summaryModel)
        let storedSummaryEndpoint = UserDefaults.standard.string(forKey: Preferences.summaryEndpoint)
        let storedAppearance = AppAppearance(
            rawValue: UserDefaults.standard.string(forKey: Preferences.appearance) ?? ""
        ) ?? .system
        appearance = storedAppearance
        // init 不会触发 didSet，这里用**局部量**补一次应用（读 self 会撞上
        // 「尚有存储属性未初始化」），保证「设为深色 → 关掉再开」仍然是深色。
        AppAppearance.apply(storedAppearance)
        // New recordings always use the combined system-audio and microphone path.
        // Keep CaptureMode on the model for backwards compatibility with old sessions.
        captureMode = .mixed
        whisperCLIPath = storedCLIPath == nil || storedCLIPath == legacyDefaults.cliURL.path
            ? defaults.cliURL.path
            : storedCLIPath!
        // 模型路径只在「用户没自己挑过模型」时才跟着默认值走。
        // 判定依据是存的值等于某个内置默认路径（内置 small / 历史外部路径 / 上一次自动选定）——
        // 只要用户在设置里指过别的文件，这里就一个字都不动。
        whisperModelPath = storedModelPath == nil || Self.isImplicitModelPath(storedModelPath!)
            ? defaults.modelURL.path
            : storedModelPath!
        summarySettings = SummaryModelSettings(
            provider: summaryProvider,
            modelName: storedSummaryModel ?? summaryProvider.defaultModelName,
            endpoint: storedSummaryEndpoint ?? summaryProvider.defaultEndpoint
        )
        canEditSummaryModelManually = false
        // **不在启动时取密文**，只问一句"存过没有"。取密文会解密，
        // 换过签名的应用会因此被 macOS 拦下来要登录密码，而那时窗口还没建出来
        // （详见 `showSettings` didSet 与 `KeychainStore.contains` 的注释）。
        summaryAPIKeyInput = ""
        summaryAPIKeyStatus = keychain.contains(for: summaryProvider) ? "已保存到钥匙串" : "未保存"
        reloadSessions()
        savePreferences()

        Task { @MainActor [weak self] in
            self?.resumePendingProcessing()
        }
    }

    /// 选中的会话。这里**故意不过滤 status**：失败 / 中断的会话同样要能被选中，
    /// 否则用户既看不到它、也点不进去、更点不到「重新处理」——
    /// 等于把一段还在磁盘上的录音从界面上藏起来。
    ///
    /// 上一版这里 filter 掉 .failed，后果是 `workspaceSession` 永远只返回非 failed 会话，
    /// 于是 `WorkbenchSessionWorkspace` 里的 `case .failed` 分支根本没有机会执行，
    /// `WorkbenchFailureState`（以及全项目唯一一处 `retryProcessing` 调用）整块成了死代码；
    /// 而 `reloadSessions()` 又会把「应用退出时未完成的录音」标成 failed 并写下
    /// 「可以重新处理」的提示——那句话因此一直是空头支票。
    var selectedSession: MeetingSession? {
        guard let selectedSessionID else { return sessions.first }
        return sessions.first { $0.id == selectedSessionID }
    }

    var workspaceSession: MeetingSession? {
        selectedSession ?? sessions.first
    }

    func reloadSessions() {
        var loadedSessions = storage.loadSessions()
        for index in loadedSessions.indices
            where loadedSessions[index].status == .ready &&
                (
                    loadedSessions[index].analysis.summaryModel == nil ||
                        loadedSessions[index].analysis.summaryModel == "本地整理" ||
                        loadedSessions[index].analysis.summaryModel == SummaryModelProvider.localRules.title
                ) {
            let analysis = MeetingAnalysisBuilder.build(from: loadedSessions[index].transcriptSegments)
            if analysis != loadedSessions[index].analysis {
                loadedSessions[index].analysis = analysis
                loadedSessions[index].updatedAt = Date()
                try? storage.save(loadedSessions[index])
            }
        }

        for index in loadedSessions.indices where loadedSessions[index].status == .recording {
            loadedSessions[index].status = .failed
            loadedSessions[index].errorMessage = "应用退出时录音未完成，原始文件已保留，可以重新处理。"
            loadedSessions[index].updatedAt = Date()
            try? storage.save(loadedSessions[index])
        }

        sessions = loadedSessions
        normalizeSelection()
    }

    func startRecording() {
        guard !isRecording, !isProcessing else { return }

        // A single recording action captures both system audio and the Mac microphone.
        captureMode = .mixed
        let draft = storage.createDraftSession(captureMode: .mixed)
        sessions.insert(draft, at: 0)
        selectedSessionID = draft.id
        activeSessionID = draft.id
        errorMessage = nil
        statusText = "正在准备录音..."
        processingStage = ""
        processingProgress = 0
        summaryRegenerationID = nil
        savePreferences()

        let recorder = MixedRecordingSession(
            movieURL: storage.sourceURL(for: draft, preferredFileName: "source.mov")
        )
        mixedSession = recorder
        Task {
            do {
                try await recorder.start()
                await MainActor.run {
                    self.isRecording = true
                    self.statusText = "正在录音"
                    self.updateSessionStatus(draft.id, status: .recording)
                    self.startRecordingLimit(for: draft.id)
                }
            } catch {
                await MainActor.run {
                    self.failSession(draft.id, message: error.localizedDescription)
                }
            }
        }
    }

    func stopRecording() {
        guard isRecording, let sessionID = activeSessionID else { return }
        isRecording = false
        isProcessing = true
        processingProgress = 0
        processingStage = "正在整理录音..."
        statusText = processingStage
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
        updateSessionStatus(sessionID, status: .processing)

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try storage.session(with: sessionID)
                let sourceURL = storage.sourceURL(for: session, preferredFileName: session.sourceFileName)
                let inputURL: URL

                switch session.captureMode {
                case .microphone:
                    inputURL = sourceURL
                    _ = microphoneSession?.stop()
                    microphoneSession = nil
                case .mixed:
                    _ = try await mixedSession?.stop()
                    mixedSession = nil
                    inputURL = storage.inputURL(for: session, preferredFileName: "input.wav")
                    try await transcoder.convertToWav(inputURL: sourceURL, outputURL: inputURL)
                case .imported:
                    inputURL = processingInputURL(for: session) ?? sourceURL
                }

                try await process(sessionID: session.id, inputURL: inputURL, resume: false)
            } catch is CancellationError {
                cancelFinishedProcessing(sessionID: sessionID)
            } catch {
                failProcessing(sessionID: sessionID, message: error.localizedDescription)
            }
        }
    }

    func importAudio(url: URL) {
        guard !isRecording, !isProcessing else { return }

        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        var draftID: UUID?
        do {
            let draft = storage.createDraftSession(captureMode: .imported)
            draftID = draft.id
            sessions.insert(draft, at: 0)
            selectedSessionID = draft.id
            activeSessionID = draft.id
            errorMessage = nil
            isProcessing = true
            processingProgress = 0
            processingStage = "正在导入音频..."
            statusText = "正在导入音频..."
            summaryRegenerationID = nil
            savePreferences()

            let copiedSource = try storage.copyImportedAudio(url: url, into: draft)
            if var importedSession = try? storage.session(with: draft.id) {
                importedSession.status = .processing
                importedSession.processingStage = "正在转换音频..."
                importedSession.processingProgress = 0
                importedSession.processingStartedAt = Date()
                importedSession.updatedAt = Date()
                try? storage.save(importedSession)
                replaceSession(importedSession)
            }
            processingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    let inputURL = storage.inputURL(for: draft, preferredFileName: "input.wav")
                    processingStage = "正在转换音频..."
                    statusText = processingStage
                    try await transcoder.convertToWav(inputURL: copiedSource, outputURL: inputURL)
                    try await process(sessionID: draft.id, inputURL: inputURL, resume: false)
                } catch is CancellationError {
                    cancelFinishedProcessing(sessionID: draft.id)
                } catch {
                    failProcessing(sessionID: draft.id, message: error.localizedDescription)
                }
            }
        } catch {
            if let draftID {
                failSession(draftID, message: error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
                statusText = error.localizedDescription
            }
        }
    }

    func openSelectedSessionFolder() {
        guard let session = selectedSession else { return }
        let folderURL = storage.folderURL(for: session)
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    func audioURL(for session: MeetingSession) -> URL? {
        storage.playbackURL(for: session)
    }

    func refreshPreferences() {
        savePreferences()
    }

    /// 把钥匙串里那条凭据读回输入框。**只在窗口已经在屏幕上时调用**
    /// （打开设置、切换服务商）—— 读密文可能需要用户解一次锁，
    /// 那一下必须发生在他看得见窗口的时候。
    func loadSummaryAPIKeyFromKeychain() {
        summaryAPIKeyInput = keychain.string(for: summarySettings.provider) ?? ""
        summaryAPIKeyStatus = summaryAPIKeyInput.isEmpty
            ? "未保存"
            : "已保存到钥匙串"
    }

    func updateSummaryProvider(_ provider: SummaryModelProvider) {
        guard summarySettings.provider != provider else { return }
        cancelSummaryModelDiscovery()
        pendingSummaryModelSelection = nil
        summarySettings = SummaryModelSettings(
            provider: provider,
            modelName: provider == .localRules ? provider.defaultModelName : "",
            endpoint: provider.defaultEndpoint
        )
        summaryAPIKeyInput = keychain.string(for: provider) ?? ""
        summaryAPIKeyStatus = summaryAPIKeyInput.isEmpty ? "未保存" : "已保存到钥匙串"
        summaryTestStatus = ""
        availableSummaryModels = []
        canEditSummaryModelManually = false
        isLoadingSummaryModels = false
        savePreferences()
    }

    @discardableResult
    func saveSummaryAPIKey() -> Bool {
        let value = summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let previousValue = keychain.string(for: summarySettings.provider) ?? ""
        if value.isEmpty {
            keychain.delete(for: summarySettings.provider)
            summaryAPIKeyInput = ""
            summaryAPIKeyStatus = "未保存"
            if previousValue != value {
                invalidateSummaryModels()
            }
            return true
        } else if keychain.save(value, for: summarySettings.provider) {
            summaryAPIKeyInput = value
            summaryAPIKeyStatus = "已保存到钥匙串"
            if previousValue != value {
                invalidateSummaryModels()
            }
            return true
        } else {
            summaryAPIKeyStatus = "保存失败"
            return false
        }
    }

    func clearSummaryAPIKey() {
        keychain.delete(for: summarySettings.provider)
        summaryAPIKeyInput = ""
        summaryAPIKeyStatus = "未保存"
        invalidateSummaryModels()
    }

    func summaryAPIKeyInputDidChange() {
        let enteredValue = summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let savedValue = keychain.string(for: summarySettings.provider) ?? ""
        if enteredValue != savedValue {
            invalidateSummaryModels()
        }
    }

    func testSummaryModel() {
        cancelSummaryModelDiscovery()
        // Testing should use the same credentials that a later meeting will use.
        // Persist the current field first so a successful test cannot be followed
        // by a failed summary because the key was only held in the text field.
        let enteredAPIKey = summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard saveSummaryAPIKey() else {
            summaryTestStatus = "API Key 保存失败，请重试后再获取模型"
            return
        }
        savePreferences()
        let settings = summarySettings
        let apiKey = keychain.string(for: settings.provider)
            ?? (enteredAPIKey.isEmpty ? nil : enteredAPIKey)
        let selectionCandidate = SummaryModelDiscovery.selectionCandidate(
            current: settings.modelName,
            pending: pendingSummaryModelSelection
        )
        let discoveryID = UUID()
        summaryModelDiscoveryID = discoveryID
        summaryTestStatus = "正在连接服务商…"
        isLoadingSummaryModels = true

        summaryModelDiscoveryTask = Task { [weak self] in
            guard let self else { return }
            defer { finishSummaryModelDiscovery(id: discoveryID) }
            do {
                let discoveredModels = try await summaryEngine.discoverModels(
                    settings: settings,
                    apiKey: apiKey
                )
                guard isCurrentSummaryModelDiscovery(
                    id: discoveryID,
                    settings: settings,
                    enteredAPIKey: enteredAPIKey,
                    resolvedAPIKey: apiKey
                ) else { return }

                if let models = discoveredModels, !models.isEmpty {
                    availableSummaryModels = models
                    canEditSummaryModelManually = false
                    let retainedSelection = SummaryModelDiscovery.selectionAfterDiscovery(
                        current: selectionCandidate,
                        available: models
                    )
                    summarySettings.modelName = retainedSelection ?? ""
                    pendingSummaryModelSelection = nil
                    savePreferences()
                    summaryTestStatus = retainedSelection == nil
                        ? "已获取 \(models.count) 个模型，请选择一个"
                        : "连接正常 · 已获取 \(models.count) 个模型"
                } else {
                    availableSummaryModels = []
                    canEditSummaryModelManually = true
                    let currentModel = selectionCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentModel.isEmpty {
                        summaryTestStatus = "连接正常 · 服务商未提供模型列表，请手动填写模型 ID"
                    } else {
                        summaryTestStatus = "正在测试当前模型…"
                        var fallbackSettings = settings
                        fallbackSettings.modelName = currentModel
                        try await summaryEngine.test(settings: fallbackSettings, apiKey: apiKey)
                        guard isCurrentSummaryModelDiscovery(
                            id: discoveryID,
                            settings: settings,
                            enteredAPIKey: enteredAPIKey,
                            resolvedAPIKey: apiKey
                        ) else { return }
                        summarySettings.modelName = currentModel
                        pendingSummaryModelSelection = nil
                        savePreferences()
                        summaryTestStatus = "连接正常 · 当前模型可用"
                    }
                }
            } catch {
                guard isCurrentSummaryModelDiscovery(
                    id: discoveryID,
                    settings: settings,
                    enteredAPIKey: enteredAPIKey,
                    resolvedAPIKey: apiKey
                ) else { return }
                if settings.provider != .localRules && availableSummaryModels.isEmpty {
                    canEditSummaryModelManually = true
                }
                summaryTestStatus = error.localizedDescription
            }
        }
    }

    func selectSummaryModel(_ model: String) {
        let cleanModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanModel.isEmpty else { return }
        cancelSummaryModelDiscovery()
        summarySettings.modelName = cleanModel
        pendingSummaryModelSelection = nil
        canEditSummaryModelManually = false
        summaryTestStatus = "已选择 \(cleanModel) · 会后整理将使用它"
        savePreferences()
    }

    func updateManualSummaryModel(_ model: String) {
        cancelSummaryModelDiscovery()
        pendingSummaryModelSelection = nil
        summarySettings.modelName = model
        summaryTestStatus = ""
        savePreferences()
    }

    func invalidateSummaryModels() {
        cancelSummaryModelDiscovery()
        availableSummaryModels = []
        canEditSummaryModelManually = false
        if summarySettings.provider != .localRules {
            let currentSelection = summarySettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !currentSelection.isEmpty {
                pendingSummaryModelSelection = currentSelection
            }
            summarySettings.modelName = ""
        }
        summaryTestStatus = ""
        savePreferences()
    }

    private func cancelSummaryModelDiscovery() {
        summaryModelDiscoveryTask?.cancel()
        summaryModelDiscoveryTask = nil
        summaryModelDiscoveryID = nil
        isLoadingSummaryModels = false
    }

    private func isCurrentSummaryModelDiscovery(
        id: UUID,
        settings: SummaryModelSettings,
        enteredAPIKey: String,
        resolvedAPIKey: String?
    ) -> Bool {
        !Task.isCancelled &&
            summaryModelDiscoveryID == id &&
            summarySettings.provider == settings.provider &&
            summarySettings.endpoint == settings.endpoint &&
            summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines) == enteredAPIKey &&
            keychain.string(for: settings.provider) == resolvedAPIKey
    }

    private func finishSummaryModelDiscovery(id: UUID) {
        guard summaryModelDiscoveryID == id else { return }
        summaryModelDiscoveryTask = nil
        summaryModelDiscoveryID = nil
        isLoadingSummaryModels = false
    }

    func loadSummaryModelsIfNeeded() {
        guard summarySettings.provider != .localRules,
              !summarySettings.endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              availableSummaryModels.isEmpty,
              summaryTestStatus.isEmpty,
              !isLoadingSummaryModels else {
            return
        }
        // 输入框空**不等于**没配 Key：启动时故意不取密文（见 `init`），
        // 所以这里还要问一句钥匙串里存过没有，否则设置页刚打开的那一瞬间
        // 会被误判成"没凭据"而不去拉模型列表。
        if summarySettings.provider.requiresAPIKey,
           summaryAPIKeyInput.isEmpty,
           !keychain.contains(for: summarySettings.provider) {
            return
        }
        testSummaryModel()
    }

    func renameSession(_ session: MeetingSession, to title: String) {
        let cleanTitle = title
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !cleanTitle.isEmpty else {
            errorMessage = "会议名称不能为空。"
            statusText = errorMessage ?? ""
            return
        }
        guard cleanTitle != session.title else { return }

        do {
            var updated = try storage.session(with: session.id)
            updated.title = cleanTitle
            updated.updatedAt = Date()
            try storage.save(updated)
            replaceSession(updated)
            selectedSessionID = updated.id
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func regenerateSummary(for session: MeetingSession) {
        guard session.status == .ready, !isRecording, !isProcessing else { return }
        guard !session.transcriptSegments.isEmpty else {
            statusText = "这场会议还没有逐字稿，暂时无法整理纪要。"
            return
        }

        selectedSessionID = session.id
        activeSessionID = session.id
        isProcessing = true
        processingProgress = 0
        processingStage = "正在用 \(summarySettings.displayName) 整理纪要…"
        statusText = processingStage
        errorMessage = nil
        let regenerationID = UUID()
        summaryRegenerationID = regenerationID

        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let analysis = try await buildAnalysis(from: session.transcriptSegments)
                try Task.checkCancellation()
                guard summaryRegenerationID == regenerationID else { return }

                var updated = try storage.session(with: session.id)
                updated.analysis = analysis
                updated.updatedAt = Date()
                try storage.save(updated)
                replaceSession(updated)
                if analysis.isLocalFallback {
                    statusText = "纪要已更新，使用本地整理兜底"
                } else if analysis.partialNotice != nil {
                    // 结果不完整也要说出来 —— 不然用户不知道"这次少了一半"，
                    // 只会以为会议本来就没内容。
                    statusText = "纪要已更新，结果不完整"
                } else {
                    statusText = "纪要已更新"
                }
                processingStage = statusText
                processingProgress = 1
                isProcessing = false
                activeSessionID = nil
                summaryRegenerationID = nil
                processingTask = nil
            } catch is CancellationError {
                cancelFinishedSummary(sessionID: session.id, regenerationID: regenerationID)
            } catch {
                failProcessing(sessionID: session.id, message: error.localizedDescription)
            }
        }
    }

    func cancelProcessing() {
        guard isProcessing else { return }
        statusText = "正在停止处理..."
        processingStage = "正在停止处理..."
        processingTask?.cancel()
        if let regenerationID = summaryRegenerationID,
           let sessionID = activeSessionID {
            cancelFinishedSummary(sessionID: sessionID, regenerationID: regenerationID)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.transcriber.cancel()
            await self.transcoder.cancel()
        }
    }

    func retryProcessing(_ session: MeetingSession) {
        guard !isRecording, !isProcessing else { return }
        guard let inputURL = processingInputURL(for: session) else {
            errorMessage = "找不到这场会议的音频文件。"
            statusText = errorMessage ?? ""
            return
        }

        var resetSession = session
        resetSession.status = .processing
        resetSession.updatedAt = Date()
        resetSession.transcriptText = ""
        resetSession.transcriptSegments = []
        resetSession.analysis = .empty
        resetSession.inputAudioFileName = inputURL.lastPathComponent
        resetSession.errorMessage = nil
        resetSession.processingProgress = 0
        resetSession.processingStage = "准备重新处理"
        resetSession.processingStartedAt = nil
        resetSession.processingCompletedChunks = 0
        resetSession.processingTotalChunks = nil
        resetSession.processingNextOffset = 0
        resetSession.processingChunkStartedAt = nil

        do {
            try storage.save(resetSession)
            replaceSession(resetSession)
            selectedSessionID = resetSession.id
            activeSessionID = resetSession.id
            isProcessing = true
            processingProgress = 0
            processingStage = "准备重新处理"
            statusText = "准备重新处理..."
            errorMessage = nil
            summaryRegenerationID = nil

            processingTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await process(sessionID: resetSession.id, inputURL: inputURL, resume: false)
                } catch is CancellationError {
                    cancelFinishedProcessing(sessionID: resetSession.id)
                } catch {
                    failProcessing(sessionID: resetSession.id, message: error.localizedDescription)
                }
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    func deleteSession(_ session: MeetingSession) {
        if activeSessionID == session.id {
            processingTask?.cancel()
            recordingLimitTask?.cancel()
            Task {
                await transcriber.cancel()
                await transcoder.cancel()
            }
            activeSessionID = nil
            summaryRegenerationID = nil
            isRecording = false
            isProcessing = false
        }
        do {
            try storage.delete(session)
            sessions.removeAll { $0.id == session.id }
            if selectedSessionID == session.id {
                selectedSessionID = sessions.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
        }
    }

    private func process(sessionID: UUID, inputURL: URL, resume: Bool) async throws {
        guard let cliURL = resolvedWhisperCLIURL(), let modelURL = resolvedModelURL() else {
            throw PipelineError.missingBinary
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw PipelineError.transcriptionFailed("找不到待处理的音频文件。")
        }

        let duration = try durationReader.duration(for: inputURL)
        let totalChunks = max(1, Int(ceil(duration / Self.chunkDuration)))
        var session = try storage.session(with: sessionID)
        let startedAt = session.processingStartedAt ?? Date()
        var completedChunks = resume ? min(session.processingCompletedChunks ?? 0, totalChunks) : 0
        var nextOffset = resume
            ? min(max(session.processingNextOffset ?? Double(completedChunks) * Self.chunkDuration, 0), duration)
            : 0
        var segments = resume ? session.transcriptSegments : []

        session.status = .processing
        session.updatedAt = Date()
        session.inputAudioFileName = inputURL.lastPathComponent
        session.whisperCLIPath = cliURL.path
        session.whisperModelPath = modelURL.path
        session.processingProgress = Double(completedChunks) / Double(totalChunks)
        session.processingStage = completedChunks >= totalChunks
            ? "正在整理会议结果..."
            : "准备第 \(completedChunks + 1)/\(totalChunks) 段"
        session.processingStartedAt = startedAt
        session.processingCompletedChunks = completedChunks
        session.processingTotalChunks = totalChunks
        session.processingNextOffset = nextOffset
        // 第一段的起点就是"现在"。进度条用它算段内的连续百分比（见 MeetingSession 注释）。
        session.processingChunkStartedAt = Date()
        session.errorMessage = nil
        try storage.save(session)
        replaceSession(session)
        processingProgress = session.processingProgress ?? 0
        processingStage = session.processingStage ?? "正在转写..."
        statusText = processingStage
        isProcessing = true

        while completedChunks < totalChunks {
            try Task.checkCancellation()

            let coreStart = Double(completedChunks) * Self.chunkDuration
            let coreEnd = min(duration, coreStart + Self.chunkDuration)
            let chunkStart = max(0, coreStart - (completedChunks == 0 ? 0 : Self.chunkOverlap))
            let chunkEnd = min(duration, coreEnd + (coreEnd < duration ? Self.chunkOverlap : 0))
            let chunkDuration = max(0.1, chunkEnd - chunkStart)
            let chunkNumber = completedChunks + 1
            let prefix = storage.folderURL(for: session)
                .appendingPathComponent("chunks", isDirectory: true)
                .appendingPathComponent(String(format: "chunk-%04d", chunkNumber))

            processingProgress = Double(completedChunks) / Double(totalChunks)
            processingStage = "正在转写第 \(chunkNumber)/\(totalChunks) 段"
            statusText = "\(processingStage) · \(processingProgress.percentLabel)"
            updateProcessingState(
                sessionID: sessionID,
                progress: processingProgress,
                stage: processingStage,
                completedChunks: completedChunks,
                totalChunks: totalChunks,
                nextOffset: nextOffset,
                startedAt: startedAt
            )

            let chunkTranscript = try await transcribeChunkWithTimeout(
                audioURL: inputURL,
                cliURL: cliURL,
                modelURL: modelURL,
                outputPrefix: prefix,
                offset: chunkStart,
                duration: chunkDuration
            )

            let ownedSegments = chunkTranscript.segments.filter { segment in
                if completedChunks == 0 {
                    return segment.start < coreEnd
                }
                return segment.start >= coreStart && segment.start < coreEnd
            }
            segments = Self.mergeSegments(existing: segments, incoming: ownedSegments)
            completedChunks += 1
            nextOffset = coreEnd

            session = try storage.session(with: sessionID)
            session.status = .processing
            session.updatedAt = Date()
            session.transcriptSegments = segments
            session.transcriptText = segments.map(\.text).joined(separator: "\n")
            session.duration = duration
            session.inputAudioFileName = inputURL.lastPathComponent
            session.whisperCLIPath = cliURL.path
            session.whisperModelPath = modelURL.path
            session.processingProgress = Double(completedChunks) / Double(totalChunks)
            session.processingStage = completedChunks == totalChunks
                ? "正在整理会议结果..."
                : "已完成第 \(completedChunks)/\(totalChunks) 段"
            session.processingStartedAt = startedAt
            session.processingCompletedChunks = completedChunks
            session.processingTotalChunks = totalChunks
            session.processingNextOffset = nextOffset
            // 这一段已经落地，把"当前段起点"推到此刻 —— 界面上的估算进度会回到
            // (已完成段 / 总段数) 这条**真实**基线上，然后继续往上走，绝不回缩。
            session.processingChunkStartedAt = Date()
            session.errorMessage = nil
            try storage.save(session)
            replaceSession(session)
            processingProgress = session.processingProgress ?? 0
            processingStage = session.processingStage ?? "正在转写..."
            statusText = "\(processingStage) · \(processingProgress.percentLabel)"
        }

        processingStage = "正在整理会议结果..."
        statusText = processingStage

        // 逐字稿后处理（P0-1C）。放在**所有分块都转完之后、整理之前**，一次过：
        // 复读是跨块的（whisper 在长静音上会自重复），逐块清洗看不见。
        // 清洗结果会写回会话，所以「逐字稿」页里也是清洗后的样子 ——
        // 原来一屏几十条 15 字的碎行，读起来像电报。
        let cleanedSegments = TranscriptCleaner.clean(segments)

        updateProcessingState(
            sessionID: sessionID,
            progress: 1,
            stage: processingStage,
            completedChunks: totalChunks,
            totalChunks: totalChunks,
            nextOffset: duration,
            startedAt: startedAt
        )

        let analysis = try await buildAnalysis(from: cleanedSegments)
        try Task.checkCancellation()

        session = try storage.session(with: sessionID)
        session.status = .ready
        session.updatedAt = Date()
        session.transcriptSegments = cleanedSegments
        session.transcriptText = cleanedSegments.map(\.text).joined(separator: "\n")
        session.analysis = analysis
        session.inputAudioFileName = inputURL.lastPathComponent
        session.whisperCLIPath = cliURL.path
        session.whisperModelPath = modelURL.path
        session.duration = duration
        session.errorMessage = nil
        session.title = MeetingAnalysisBuilder.title(for: session, segments: segments)
        session.processingProgress = 1
        session.processingStage = "已完成"
        session.processingStartedAt = startedAt
        session.processingCompletedChunks = totalChunks
        session.processingTotalChunks = totalChunks
        session.processingNextOffset = duration
        session.processingChunkStartedAt = nil
        try storage.save(session)

        replaceSession(session)
        selectedSessionID = session.id
        statusText = "已完成"
        processingStage = "已完成"
        processingProgress = 1
        isProcessing = false
        activeSessionID = nil
        summaryRegenerationID = nil
        processingTask = nil
    }

    private func replaceSession(_ session: MeetingSession) {
        sessions.removeAll { $0.id == session.id }
        sessions.insert(session, at: 0)
        sessions.sort { $0.createdAt > $1.createdAt }
        normalizeSelection()
    }

    private func normalizeSelection() {
        guard let selectedSessionID,
              sessions.contains(where: { $0.id == selectedSessionID }) else {
            selectedSessionID = sessions.first?.id
            return
        }
    }

    private func buildAnalysis(from segments: [TranscriptSegment]) async throws -> MeetingAnalysis {
        try Task.checkCancellation()
        let fallback = await Task.detached(priority: .utility) {
            MeetingAnalysisBuilder.build(from: segments)
        }.value
        try Task.checkCancellation()
        let settings = summarySettings
        let enteredKey = summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = enteredKey.isEmpty
            ? keychain.string(for: settings.provider)
            : enteredKey

        do {
            let analysis = try await summaryEngine.analyze(
                segments: segments,
                settings: settings,
                apiKey: apiKey
            )
            try Task.checkCancellation()
            return analysis
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            var fallback = fallback
            fallback.summaryModel = settings.displayName
            fallback.summaryError = error.localizedDescription
            return fallback
        }
    }

    private func failSession(_ sessionID: UUID, message: String) {
        if var session = try? storage.session(with: sessionID) {
            session.status = .failed
            session.errorMessage = message
            session.updatedAt = Date()
            session.processingStage = "处理失败"
            try? storage.save(session)
            replaceSession(session)
        }
        errorMessage = message
        statusText = message
        isRecording = false
        isProcessing = false
        activeSessionID = nil
        summaryRegenerationID = nil
        microphoneSession = nil
        mixedSession = nil
        processingTask = nil
        recordingLimitTask?.cancel()
        recordingLimitTask = nil
    }

    private func failProcessing(sessionID: UUID, message: String) {
        if var session = try? storage.session(with: sessionID) {
            session.status = .failed
            session.errorMessage = message
            session.updatedAt = Date()
            session.processingStage = "处理失败"
            try? storage.save(session)
            replaceSession(session)
        }
        errorMessage = message
        statusText = message
        isRecording = false
        isProcessing = false
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        summaryRegenerationID = nil
        microphoneSession = nil
        mixedSession = nil
        processingTask = nil
    }

    private func cancelFinishedProcessing(sessionID: UUID) {
        if var session = try? storage.session(with: sessionID) {
            session.status = .failed
            session.errorMessage = "已取消转写，已保留已经完成的内容，可以重新处理。"
            session.processingStage = "已取消"
            session.updatedAt = Date()
            try? storage.save(session)
            replaceSession(session)
        }
        errorMessage = nil
        statusText = "已取消转写"
        processingStage = "已取消"
        isRecording = false
        isProcessing = false
        activeSessionID = nil
        summaryRegenerationID = nil
        processingTask = nil
    }

    private func cancelFinishedSummary(sessionID: UUID, regenerationID: UUID) {
        guard summaryRegenerationID == regenerationID else { return }
        summaryRegenerationID = nil
        errorMessage = nil
        statusText = "已取消整理，保留原有纪要"
        processingStage = "已取消整理"
        processingProgress = 0
        isRecording = false
        isProcessing = false
        if activeSessionID == sessionID {
            activeSessionID = nil
        }
        processingTask = nil
    }

    private func resumePendingProcessing() {
        guard !isRecording, !isProcessing else { return }
        guard let session = sessions.first(where: { $0.status == .processing }) else { return }
        guard let inputURL = processingInputURL(for: session) else {
            failProcessing(sessionID: session.id, message: "找不到待恢复的音频文件。")
            return
        }

        activeSessionID = session.id
        selectedSessionID = session.id
        isProcessing = true
        processingProgress = session.processingProgress ?? 0
        processingStage = session.processingStage ?? "正在恢复转写..."
        statusText = "正在恢复转写..."
        processingTask = Task { [weak self] in
            guard let self else { return }
            do {
                var preparedURL = inputURL
                if preparedURL.pathExtension.lowercased() != "wav" {
                    let convertedURL = storage.inputURL(for: session, preferredFileName: "input.wav")
                    processingStage = "正在恢复音频转换..."
                    statusText = processingStage
                    try await transcoder.convertToWav(inputURL: preparedURL, outputURL: convertedURL)
                    preparedURL = convertedURL
                }
                try await process(sessionID: session.id, inputURL: preparedURL, resume: true)
            } catch is CancellationError {
                cancelFinishedProcessing(sessionID: session.id)
            } catch {
                failProcessing(sessionID: session.id, message: error.localizedDescription)
            }
        }
    }

    private func startRecordingLimit(for sessionID: UUID) {
        recordingLimitTask?.cancel()
        recordingLimitTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.maxRecordingDuration)
            } catch {
                return
            }
            guard let self, self.isRecording, self.activeSessionID == sessionID else { return }
            self.statusText = "已达到 3 小时上限，正在结束录音..."
            self.stopRecording()
        }
    }

    private func updateProcessingState(
        sessionID: UUID,
        progress: Double,
        stage: String,
        completedChunks: Int,
        totalChunks: Int,
        nextOffset: TimeInterval,
        startedAt: Date
    ) {
        guard var session = try? storage.session(with: sessionID) else { return }
        session.status = .processing
        session.updatedAt = Date()
        session.processingProgress = progress
        session.processingStage = stage
        session.processingCompletedChunks = completedChunks
        session.processingTotalChunks = totalChunks
        session.processingNextOffset = nextOffset
        session.processingStartedAt = startedAt
        try? storage.save(session)
        replaceSession(session)
    }

    private func transcribeChunkWithTimeout(
        audioURL: URL,
        cliURL: URL,
        modelURL: URL,
        outputPrefix: URL,
        offset: TimeInterval,
        duration: TimeInterval
    ) async throws -> WhisperTranscript {
        try await withThrowingTaskGroup(of: WhisperTranscript.self) { group in
            group.addTask { [transcriber] in
                try await transcriber.transcribe(
                    audioURL: audioURL,
                    cliURL: cliURL,
                    modelURL: modelURL,
                    outputPrefix: outputPrefix,
                    offset: offset,
                    duration: duration,
                    language: "zh"
                )
            }
            group.addTask {
                let timeoutSeconds = max(12 * 60, Int((duration * 1.5).rounded()))
                try await Task.sleep(nanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)
                throw PipelineError.transcriptionTimedOut
            }

            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw PipelineError.transcriptionFailed("转写没有返回结果。")
            }
            return result
        }
    }

    private func processingInputURL(for session: MeetingSession) -> URL? {
        var candidates: [String] = []
        if let inputAudioFileName = session.inputAudioFileName {
            candidates.append(inputAudioFileName)
        }
        candidates.append("input.wav")
        candidates.append(session.sourceFileName)

        for name in candidates where !name.isEmpty {
            let url = storage.sourceURL(for: session, preferredFileName: name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    private static func mergeSegments(
        existing: [TranscriptSegment],
        incoming: [TranscriptSegment]
    ) -> [TranscriptSegment] {
        var merged = existing
        for segment in incoming.sorted(by: { $0.start < $1.start }) {
            guard let previous = merged.last else {
                merged.append(segment)
                continue
            }

            let overlaps = segment.start < previous.end && previous.start < segment.end
            let sameText = normalized(segment.text) == normalized(previous.text)
            if overlaps && sameText {
                if segment.confidence > previous.confidence {
                    merged[merged.count - 1] = segment
                }
                continue
            }
            merged.append(segment)
        }
        return merged.sorted { $0.start < $1.start }
    }

    private static func normalized(_ text: String) -> String {
        text
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .punctuationCharacters)
    }

    private func updateSessionStatus(_ sessionID: UUID, status: MeetingStatus) {
        guard var session = try? storage.session(with: sessionID) else { return }
        session.status = status
        session.updatedAt = Date()
        try? storage.save(session)
        replaceSession(session)
    }

    private func savePreferences() {
        UserDefaults.standard.set(CaptureMode.mixed.rawValue, forKey: Preferences.captureMode)
        UserDefaults.standard.set(whisperCLIPath, forKey: Preferences.whisperCLIPath)
        UserDefaults.standard.set(whisperModelPath, forKey: Preferences.whisperModelPath)
        UserDefaults.standard.set(summarySettings.provider.rawValue, forKey: Preferences.summaryProvider)
        UserDefaults.standard.set(summarySettings.modelName, forKey: Preferences.summaryModel)
        UserDefaults.standard.set(summarySettings.endpoint, forKey: Preferences.summaryEndpoint)
    }

    private func resolvedWhisperCLIURL() -> URL? {
        let candidate = URL(fileURLWithPath: whisperCLIPath)
        if FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        let fallback = Self.defaultRuntimePaths().cliURL
        return FileManager.default.isExecutableFile(atPath: fallback.path) ? fallback : nil
    }

    private func resolvedModelURL() -> URL? {
        let candidate = URL(fileURLWithPath: whisperModelPath)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }
        let fallback = Self.defaultRuntimePaths().modelURL
        return FileManager.default.fileExists(atPath: fallback.path) ? fallback : nil
    }

    static func defaultRuntimePaths() -> (cliURL: URL, modelURL: URL) {
        let legacy = legacyRuntimePaths()
        // CLI 与模型分开解析，别再用「两个都在才算数」的捆绑判断。
        let cli = bundledCLIURL() ?? legacy.cliURL
        // 模型按质量优先级挑：用户模型目录里的更强模型 > 内置 small > 历史外部路径。
        // 这样把 ggml-*.bin 丢进模型目录、重启就能用上，不必手动改设置。
        let model = preferredManagedModelURL() ?? bundledModelURL() ?? legacy.modelURL
        return (cli, model)
    }

    /// 应用包内自带的 whisper-cli。
    private static func bundledCLIURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent("bin/whisper-cli")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    /// 应用包内自带的 whisper 模型（small）。
    private static func bundledModelURL() -> URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let url = resourceURL
            .appendingPathComponent("whisper", isDirectory: true)
            .appendingPathComponent("models/ggml-small.bin")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 用户级模型目录。把 ggml-*.bin 放进这里就会被自动发现。
    /// 它和会话目录同级，但 `SessionStorage.loadSession` 找不到 session.json 会返回 nil，
    /// 所以多出这个子目录不会影响会话扫描。
    static func modelsDirectoryURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("MeetingScribe", isDirectory: true)
            .appendingPathComponent("models", isDirectory: true)
    }

    /// 质量优先级。turbo 用的是 large-v3 的编码器 + 蒸馏后的浅解码器，
    /// 中文准确率接近 large-v3、速度快好几倍，所以排第一。
    private static let modelPriority = [
        "ggml-large-v3-turbo.bin",
        "ggml-large-v3.bin",
        "ggml-medium.bin",
        "ggml-small.bin",
        "ggml-base.bin",
        "ggml-tiny.bin"
    ]

    /// 模型目录里质量最高的那个模型。
    static func preferredManagedModelURL() -> URL? {
        let directory = modelsDirectoryURL()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for preferred in modelPriority where names.contains(preferred) {
            return directory.appendingPathComponent(preferred)
        }
        // 名字不认识时，退而求其次取任意一个 ggml-*.bin。
        if let fallback = names
            .filter({ $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") })
            .sorted()
            .first {
            return directory.appendingPathComponent(fallback)
        }
        return nil
    }

    /// 是否是「应用自己选定的」模型路径，即用户没表达过偏好。
    private static func isImplicitModelPath(_ path: String) -> Bool {
        var implicit = [legacyRuntimePaths().modelURL.path, defaultRuntimePaths().modelURL.path]
        if let bundled = bundledModelURL() {
            implicit.append(bundled.path)
        }
        return implicit.contains(path)
    }

    private static func legacyRuntimePaths() -> (cliURL: URL, modelURL: URL) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let whisperRoot = home
            .appendingPathComponent("Documents/Codex/易运盈/outputs/crm-mall-flow/whisper.cpp")
        let cli = whisperRoot.appendingPathComponent("build/bin/whisper-cli")
        let model = whisperRoot.appendingPathComponent("models/ggml-small.bin")
        return (cli, model)
    }
}

struct SessionStorage {
    private let rootURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(rootURL: URL? = nil) {
        let base = rootURL ?? Self.defaultRootURL()
        self.rootURL = base
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    func loadSessions() -> [MeetingSession] {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return items.compactMap { folderURL in
            loadSession(from: folderURL)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }

    func createDraftSession(captureMode: CaptureMode) -> MeetingSession {
        let createdAt = Date()
        let id = UUID()
        let folderName = Self.folderName(for: createdAt, id: id)
        let session = MeetingSession(
            id: id,
            folderName: folderName,
            title: Self.defaultTitle(for: createdAt),
            createdAt: createdAt,
            updatedAt: createdAt,
            captureMode: captureMode,
            status: .recording,
            sourceFileName: Self.sourceFileName(for: captureMode),
            inputAudioFileName: nil,
            transcriptText: "",
            transcriptSegments: [],
            analysis: .empty,
            whisperCLIPath: "",
            whisperModelPath: "",
            duration: nil,
            errorMessage: nil
        )

        do {
            try FileManager.default.createDirectory(at: folderURL(for: session), withIntermediateDirectories: true)
            try save(session)
        } catch {
            // If the save fails, return the in-memory session and let the caller surface the error.
        }

        return session
    }

    func session(with id: UUID) throws -> MeetingSession {
        let folderURLs = try FileManager.default.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for folderURL in folderURLs {
            guard let session = loadSession(from: folderURL), session.id == id else { continue }
            return session
        }
        throw PipelineError.transcriptionFailed("找不到会话。")
    }

    func save(_ session: MeetingSession) throws {
        try FileManager.default.createDirectory(at: folderURL(for: session), withIntermediateDirectories: true)
        let data = try encoder.encode(session)
        try data.write(to: sessionFileURL(for: session), options: [.atomic])
    }

    func delete(_ session: MeetingSession) throws {
        let folderURL = self.folderURL(for: session)
        if FileManager.default.fileExists(atPath: folderURL.path) {
            try FileManager.default.removeItem(at: folderURL)
        }
    }

    func folderURL(for session: MeetingSession) -> URL {
        rootURL.appendingPathComponent(session.folderName, isDirectory: true)
    }

    func sourceURL(for session: MeetingSession, preferredFileName: String) -> URL {
        folderURL(for: session).appendingPathComponent(preferredFileName)
    }

    func inputURL(for session: MeetingSession, preferredFileName: String) -> URL {
        folderURL(for: session).appendingPathComponent(preferredFileName)
    }

    func playbackURL(for session: MeetingSession) -> URL? {
        var candidates: [String] = []
        if let inputAudioFileName = session.inputAudioFileName {
            candidates.append(inputAudioFileName)
        }
        candidates.append("input.wav")
        candidates.append(session.sourceFileName)

        for name in candidates where !name.isEmpty {
            let url = sourceURL(for: session, preferredFileName: name)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    func copyImportedAudio(url: URL, into session: MeetingSession) throws -> URL {
        let destination = sourceURL(for: session, preferredFileName: url.lastPathComponent)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: url, to: destination)
        var updated = session
        updated.sourceFileName = destination.lastPathComponent
        try save(updated)
        return destination
    }

    private func loadSession(from folderURL: URL) -> MeetingSession? {
        let fileURL = folderURL.appendingPathComponent("session.json")
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? decoder.decode(MeetingSession.self, from: data)
    }

    private func sessionFileURL(for session: MeetingSession) -> URL {
        folderURL(for: session).appendingPathComponent("session.json")
    }

    /// 数据根。默认是 `~/Library/Application Support/MeetingScribe`。
    ///
    /// **可以用环境变量 `MS_DATA_ROOT` 覆盖，指向一个隔离目录。**
    ///
    /// 这条覆盖不是给用户用的，是给**界面验证**用的：要截一张"会话列表里有内容"
    /// 或"速览页有结论和要点"的图，就得先有一场那样的会 —— 而往用户真实的
    /// 数据根里塞夹具，代价已经被证明过一次（见 `docs/未解决问题与正确做法.md`：
    /// 真实数据根被整目录级移除，无备份可恢复）。有了这个开关，夹具永远活在
    /// 临时目录里，真实根**一次都不被写**。
    ///
    /// 取不到、或取到空串时静默回落 —— 一个拼错的环境变量不该让 App 起不来。
    private static func defaultRootURL() -> URL {
        let fallback = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("MeetingScribe", isDirectory: true)

        guard let override = ProcessInfo.processInfo.environment["MS_DATA_ROOT"],
              !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return fallback }
        return URL(fileURLWithPath: override, isDirectory: true)
    }

    private static func folderName(for date: Date, id: UUID) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        let stamp = formatter.string(from: date)
        return "\(stamp)_\(id.uuidString.prefix(8))"
    }

    private static func defaultTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return "会议 \(formatter.string(from: date))"
    }

    private static func sourceFileName(for captureMode: CaptureMode) -> String {
        switch captureMode {
        case .microphone:
            return "source.wav"
        case .mixed:
            return "source.mov"
        case .imported:
            return "source"
        }
    }
}

enum MeetingAnalysisBuilder {
    static func title(for session: MeetingSession, segments: [TranscriptSegment]) -> String {
        if session.captureMode == .imported {
            let fileTitle = URL(fileURLWithPath: session.sourceFileName)
                .deletingPathExtension()
                .lastPathComponent
            if !fileTitle.isEmpty, fileTitle != "source", fileTitle != "input" {
                return fileTitle
            }
        }

        if let first = buildOverview(from: segments).first {
            let prefix = first.label.prefix(24)
            return "会议 \(prefix)"
        }
        return session.title
    }

    static func build(from segments: [TranscriptSegment]) -> MeetingAnalysis {
        let overview: [InsightItem] = []
        let timeline: [TimelineChunk] = []
        let decisions = buildDecisions(from: segments)
        let actions = buildActions(from: segments)

        let scores = decisions.map(\.confidence) + actions.map(\.confidence)
        let confidence = scores.isEmpty ? 0 : scores.reduce(0, +) / Double(scores.count)

        return MeetingAnalysis(
            overview: overview,
            timeline: timeline,
            decisions: decisions,
            actions: actions,
            confidence: confidence,
            overviewText: buildOverviewText(
                timeline: timeline,
                decisions: decisions,
                actions: actions
            ),
            minutesText: buildMinutesText(
                timeline: timeline,
                decisions: decisions,
                actions: actions
            ),
            summaryModel: SummaryModelProvider.localRules.title,
            summaryError: nil
        )
    }

    private static func buildOverviewText(
        timeline: [TimelineChunk],
        decisions: [InsightItem],
        actions: [ActionItem]
    ) -> String {
        ""
    }

    private static func buildMinutesText(
        timeline: [TimelineChunk],
        decisions: [InsightItem],
        actions: [ActionItem]
    ) -> String {
        ""
    }

    private static func buildOverview(from segments: [TranscriptSegment]) -> [InsightItem] {
        let candidates = segments
            .filter { segment in
                segment.text.count >= 18 &&
                    segment.confidence >= 0.78 &&
                    !isFiller(segment.text) &&
                    !looksLikeQuestion(segment.text) &&
                    !isLowQuality(segment.text) &&
                    !hasRepeatedClause(segment.text) &&
                    hasSummarySignal(segment.text)
            }
            .map { segment in
                (
                    segment,
                    overviewScore(for: segment)
                )
            }
            .sorted { lhs, rhs in
                if lhs.1 == rhs.1 {
                    return lhs.0.start < rhs.0.start
                }
                return lhs.1 > rhs.1
            }

        var items: [InsightItem] = []
        var occupiedRanges: [ClosedRange<Double>] = []
        for (segment, score) in candidates {
            let start = segment.start
            guard score >= 4.5 else { continue }
            let confidence = segment.confidence

            if occupiedRanges.contains(where: { range in
                abs(range.lowerBound - start) < 180 || range.contains(start)
            }) {
                continue
            }

            let label = shorten(segment.text, limit: 42)
            items.append(
                InsightItem(
                    label: label,
                    evidence: segment.text,
                    confidence: confidence,
                    timestamp: segment.start
                )
            )
            occupiedRanges.append((segment.start - 180)...(segment.start + 180))
            if items.count == 4 { break }
        }

        return items
    }

    private static func buildTimeline(from segments: [TranscriptSegment]) -> [TimelineChunk] {
        let grouped = Dictionary(grouping: segments) { Int($0.start / 300) }
        return grouped.keys.sorted().compactMap { bucket in
            let bucketSegments = (grouped[bucket] ?? []).sorted { $0.start < $1.start }
            guard let first = bucketSegments.first else { return nil }
            let last = bucketSegments.last ?? first
            let reliableSegments = bucketSegments
                .filter { isReliableSummarySegment($0, minimumConfidence: 0.78) }
                .sorted { $0.confidence > $1.confidence }
            guard !reliableSegments.isEmpty else { return nil }
            let summary = reliableSegments
                .prefix(2)
                .map { shorten($0.text, limit: 28) }
                .joined(separator: "；")
            let evidence = reliableSegments
                .prefix(2)
                .map(\.text)
                .joined(separator: " / ")
            let avg = reliableSegments.map(\.confidence).reduce(0, +) / Double(reliableSegments.count)
            return TimelineChunk(
                start: first.start,
                end: last.end,
                summary: summary.isEmpty ? "这一段转写内容置信度不足，建议查看原文。" : summary,
                evidence: evidence,
                confidence: avg
            )
        }
    }

    private static func buildDecisions(from segments: [TranscriptSegment]) -> [InsightItem] {
        let keywords = [
            "决定", "确定为", "定为", "结论是", "最终采用",
            "最终选择", "就这样", "先这样", "不再使用", "取消", "统一采用"
        ]
        return uniqueMatches(
            in: segments,
            keywords: keywords,
            minimumConfidence: 0.80,
            predicate: { text in
                containsDecisionStructure(text) &&
                    !hasRepeatedClause(text) &&
                    !isLowQuality(text)
            }
        )
    }

    private static func buildActions(from segments: [TranscriptSegment]) -> [ActionItem] {
        let keywords = [
            "需要", "负责", "跟进", "整理", "补充", "发给", "提交给",
            "排期", "同步", "准备", "创建", "改成", "完成", "处理", "发起"
        ]
        let matches = uniqueMatches(
            in: segments,
            keywords: keywords,
            minimumConfidence: 0.78,
            predicate: { text in
                !looksLikeQuestion(text) &&
                    !hasRepeatedClause(text) &&
                    !isLowQuality(text) &&
                    containsActionStructure(text)
            }
        )
        return matches.compactMap { item in
            let priority = priority(from: item.label, confidence: item.confidence)
            let dueText = dueText(from: item.evidence)
            return ActionItem(
                label: item.label,
                priority: priority,
                dueText: dueText,
                evidence: item.evidence,
                confidence: item.confidence,
                timestamp: item.timestamp
            )
        }
    }

    private static func uniqueMatches(
        in segments: [TranscriptSegment],
        keywords: [String],
        minimumConfidence: Double,
        predicate: (String) -> Bool = { _ in true }
    ) -> [InsightItem] {
        var seen = Set<String>()
        var items: [InsightItem] = []

        for segment in segments {
            let text = segment.text
            guard keywords.contains(where: { text.contains($0) }) else { continue }
            guard segment.confidence >= minimumConfidence, predicate(text) else { continue }
            guard text.replacingOccurrences(of: " ", with: "").count >= 12 else { continue }

            let label = shorten(text, limit: 44)
            let normalized = label.replacingOccurrences(of: " ", with: "")
            guard seen.insert(normalized).inserted else { continue }

            items.append(
                InsightItem(
                    label: label,
                    evidence: text,
                    confidence: segment.confidence,
                    timestamp: segment.start
                )
            )

            if items.count == 5 { break }
        }

        return items
    }

    private static func priority(from text: String, confidence: Double) -> PriorityLevel? {
        let urgent = ["必须", "务必", "尽快", "马上", "今天", "立即", "优先", "先做"]
        let soon = ["本周", "下周", "近期", "早点", "尽量"]

        if urgent.contains(where: text.contains) {
            return .p1
        }
        guard confidence >= 0.7 else { return nil }
        if soon.contains(where: text.contains) {
            return .p2
        }
        return .p3
    }

    private static func dueText(from text: String) -> String? {
        let patterns = [
            #"\d{4}[-/年]\d{1,2}[-/月]\d{1,2}日?"#,
            #"\d{1,2}月\d{1,2}日"#,
            #"今天"#,
            #"明天"#,
            #"后天"#,
            #"本周"#,
            #"下周"#,
            #"月底"#,
            #"周[一二三四五六日天]"#
        ]

        for pattern in patterns {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return String(text[range])
            }
        }
        return nil
    }

    private static func overviewScore(for segment: TranscriptSegment) -> Double {
        let text = segment.text
        let keywordBonus = [
            "目标", "目的", "结论", "方案", "需求", "问题", "风险", "下一步", "安排", "确认", "落地", "重点", "待办"
        ].reduce(0.0) { partial, keyword in
            partial + (text.contains(keyword) ? 1.0 : 0.0)
        }
        let earlyBonus = segment.start < 900 ? 1.2 : 0
        let middleBonus = text.count > 20 ? 0.8 : 0.3
        return keywordBonus * 2 + earlyBonus + middleBonus + segment.confidence * 2
    }

    private static func isFiller(_ text: String) -> Bool {
        let fillerWords = ["嗯", "啊", "哦", "对", "好", "行", "来", "就是", "然后", "不是"]
        let compact = text.replacingOccurrences(of: " ", with: "")
        return compact.count < 16 || fillerWords.allSatisfy { compact.hasPrefix($0) }
    }

    private static func isLowQuality(_ text: String) -> Bool {
        let compact = text.replacingOccurrences(of: " ", with: "")
        let fillerWords = ["那个", "就是", "然后", "呃", "嗯", "啊", "这个", "对吧"]
        let fillerCount = fillerWords.reduce(0) { count, word in
            count + compact.components(separatedBy: word).count - 1
        }
        let punctuationCount = compact.filter { "，,；;。！？?!".contains($0) }.count
        let repeatedCharacterCount = Dictionary(grouping: compact, by: { $0 })
            .values
            .map(\.count)
            .max() ?? 0
        return fillerCount >= 3 &&
            punctuationCount >= 3 ||
            repeatedCharacterCount >= max(7, compact.count / 3)
    }

    private static func hasRepeatedClause(_ text: String) -> Bool {
        let clauses = text
            .split(whereSeparator: { "，,；;。".contains($0) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 4 }
        return Set(clauses).count < clauses.count
    }

    private static func looksLikeQuestion(_ text: String) -> Bool {
        let questionMarkers = [
            "？", "?", "吗", "啥", "什么", "哪", "怎么", "为什么",
            "能不能", "是不是", "有没有", "是否"
        ]
        return questionMarkers.contains(where: text.contains)
    }

    private static func isReliableSummarySegment(
        _ segment: TranscriptSegment,
        minimumConfidence: Double
    ) -> Bool {
        let text = segment.text
        let compact = text.replacingOccurrences(of: " ", with: "")
        guard segment.confidence >= minimumConfidence,
              compact.count >= 18,
              !looksLikeQuestion(text),
              !isLowQuality(text),
              !hasRepeatedClause(text) else {
            return false
        }

        let punctuationCount = text.filter { "，,；;。！？?!".contains($0) }.count
        let repeatedCharacterCount = Dictionary(grouping: compact, by: { $0 })
            .values
            .map(\.count)
            .max() ?? 0
        return punctuationCount <= 8 &&
            repeatedCharacterCount < max(6, compact.count / 3) &&
            !["对吧", "好不好", "行不行", "是不是"].contains(where: text.contains)
    }

    private static func containsActionStructure(_ text: String) -> Bool {
        let explicitVerbs = [
            "跟进", "整理", "补充", "发给", "提交给", "排期",
            "同步", "准备", "创建", "改成", "完成", "发起", "处理", "负责"
        ]
        guard !text.contains("有两种"),
              !text.contains("有一个"),
              !text.contains("有多个"),
              explicitVerbs.contains(where: text.contains) else {
            return false
        }
        let assignmentMarkers = [
            "你来", "你负责", "我来", "我负责", "由你", "由我",
            "请你", "请负责", "需要你", "需要我", "安排你",
            "后续请", "下一步由", "负责跟进", "负责人"
        ]
        return assignmentMarkers.contains(where: text.contains)
    }

    private static func containsDecisionStructure(_ text: String) -> Bool {
        let markers = [
            "决定", "确定为", "定为", "结论是", "最终采用",
            "最终选择", "就这样", "先这样", "不再使用", "取消", "统一采用"
        ]
        return markers.contains(where: text.contains) &&
            !looksLikeQuestion(text) &&
            !["可能", "考虑一下", "建议", "待定", "再看看"].contains(where: text.contains)
    }

    private static func hasSummarySignal(_ text: String) -> Bool {
        [
            "目标", "目的", "主要", "围绕", "方案", "需求", "问题",
            "风险", "下一步", "安排", "确认", "落地", "重点",
            "评审", "计划", "版本", "结果"
        ].contains(where: text.contains)
    }

    private static func shorten(_ text: String, limit: Int) -> String {
        let clean = text
            .replacingOccurrences(of: "。", with: "")
            .replacingOccurrences(of: "！", with: "")
            .replacingOccurrences(of: "？", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)) + "…"
    }
}
