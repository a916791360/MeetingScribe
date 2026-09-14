import AppKit
import Foundation

/// 一个转写分块在整段音频里的位置（秒）。
///
/// 抽出来是因为**双声道两路**（`transcribeTrack`）与原来那条单路循环都要算它。
/// 两处各写一遍，就会出现"同一场会议里两路的分块边界差 2 秒"这种没人看得出来的不一致。
struct ChunkWindow: Equatable {
    /// 分块的核心区间：只有起点落在这里的段才算这一块转写的结果。
    let coreStart: TimeInterval
    let coreEnd: TimeInterval
    /// 真正送进 whisper 的区间：核心区间两侧各多给一段重叠，免得在切点上把半句话切掉。
    let start: TimeInterval
    let end: TimeInterval

    /// 送给 whisper 的时长。**不许是 0 或负数**（whisper 会当成"整段"或直接报错）。
    var length: TimeInterval { max(0.1, end - start) }
}

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
    /// 设置页「识别术语表」的原始文本。**存原文、不存解析结果**：
    /// 解析规则以后可能会改（分隔符、长度门槛），存文本的话用户下次启动自动受益；
    /// 存解析结果就等于把老规则冻结进 UserDefaults 了。
    @Published var glossaryText: String {
        didSet {
            guard oldValue != glossaryText else { return }
            UserDefaults.standard.set(glossaryText, forKey: Preferences.glossaryText)
            // 同步刷新派生结果 —— whisper 的 `--prompt`、后处理替换表、整理 prompt
            // 三处读的都是 `glossary`，只有这一个写入点。
            glossary = Glossary.parse(glossaryText)
        }
    }
    /// `glossaryText` 的解析结果。三处消费点都读它，见 `Glossary`。
    @Published private(set) var glossary: Glossary = .empty
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

    private let storage: SessionStorage
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
        static let glossaryText = "meetingScribe.glossaryText"
        static let summaryProvider = "meetingScribe.summaryProvider"
        static let summaryModel = "meetingScribe.summaryModel"
        static let summaryEndpoint = "meetingScribe.summaryEndpoint"
    }

    /// `storage` 参数只为**测试**存在：要验「改一句逐字稿真的落到盘上」，
    /// 就得让 store 把数据写进一个临时目录。不给这个入口的话，那条测试只能
    /// 靠环境变量把整个进程的数据根改掉 —— 一旦哪天变量没生效，它就会写进
    /// **用户真实的数据根**（这条已经被证明过一次，见 `SessionStorage.defaultRootURL`）。
    /// 显式传进来的目录不存在"忘设就落到真实根"的可能。
    init(storage: SessionStorage? = nil) {
        self.storage = storage ?? SessionStorage()
        let defaults = Self.defaultRuntimePaths()
        let legacyDefaults = Self.legacyRuntimePaths()
        let storedCLIPath = UserDefaults.standard.string(forKey: Preferences.whisperCLIPath)
        let storedModelPath = UserDefaults.standard.string(forKey: Preferences.whisperModelPath)
        let summaryProvider = SummaryModelProvider(
            rawValue: UserDefaults.standard.string(forKey: Preferences.summaryProvider) ?? ""
        ) ?? .localRules
        let storedGlossaryText = UserDefaults.standard.string(forKey: Preferences.glossaryText)
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
        // 没存过就给出厂词表（就是 1D 实测用过的那一版），用户改过就一个字不动。
        // 派生结果要在 init 里**显式**算一次：`glossaryText` 的 didSet 在 init 赋值时不触发。
        let initialGlossaryText = storedGlossaryText ?? Glossary.factoryDefaultText
        glossaryText = initialGlossaryText
        glossary = Glossary.parse(initialGlossaryText)
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

        // 2C 的历史数据修补。
        //
        // 门禁只对**新产出**生效，而升级前那条"25 秒误录"的记录里存的还是模型写的
        // 元评论（「本次材料仅包含一句栏目推广语……」），它的 `summaryModel` 是一个
        // 真实模型名 —— 上面那个循环只认"本地整理"档，压根不会碰它。于是修复在
        // 用户已有的那条记录上**根本看不见**（这正是方案 O5 的现场，也是本条存在的全部理由）。
        //
        // 条件刻意收得很紧，两把锁缺一不可：**材料确实不够** 且 **这条结果里没有任何
        // 结构化发现**。材料够的不动（那是真结果）；有决策 / 待办 / 一句话结论的也不动
        // （哪怕材料少，那也是用户真正拿到过的东西，不能替他清掉）。
        // **逐字稿任何时候都不删** —— 被替换的只有那份"对着材料自我介绍"的整理结果。
        for index in loadedSessions.indices
            where MeetingAnalysisBuilder.needsMaterialGateRepair(loadedSessions[index]) {
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

        // 两路的落盘位置必须**在这里**交给录音会话（`local.caf` / `remote.caf`）。
        // 2026-09-14 这里漏过：构造时只传了 `movieURL`，另外两个参数吃默认值 nil，
        // 于是双声道整条链路静默退化成单路 —— 录出来一切正常，就是永远没有说话人标签。
        let trackURLs = DualTrackPaths.captureURLs(in: storage.folderURL(for: draft))
        Diagnostics.audio.notice(
            """
            录音会话接线：我方 \(trackURLs.local.lastPathComponent, privacy: .public)、\
            对方 \(trackURLs.remote.lastPathComponent, privacy: .public)
            """
        )
        let recorder = MixedRecordingSession(
            movieURL: storage.sourceURL(for: draft, preferredFileName: "source.mov"),
            localTrackURL: trackURLs.local,
            remoteTrackURL: trackURLs.remote
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
                var dualTracks: DualTrackInput?

                switch session.captureMode {
                case .microphone:
                    inputURL = sourceURL
                    _ = microphoneSession?.stop()
                    microphoneSession = nil
                case .mixed:
                    let recording = try await mixedSession?.stop()
                    mixedSession = nil
                    inputURL = storage.inputURL(for: session, preferredFileName: "input.wav")
                    try await transcoder.convertToWav(inputURL: sourceURL, outputURL: inputURL)
                    // 双声道（P2-2a）：**两路都拿到才算数**。只有一路时宁可不做标注 ——
                    // 麦克风那一路本来就混着外放出来的对方声音，只按它标"我方"，
                    // 会把对方说的话算成我方，而且读起来完全自然、永远没人发现。
                    dualTracks = try await normalizedTracks(from: recording, in: session)
                case .imported:
                    inputURL = processingInputURL(for: session) ?? sourceURL
                }

                try await process(
                    sessionID: session.id,
                    inputURL: inputURL,
                    resume: false,
                    dualTracks: dualTracks
                )
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

    /// 逐字稿就地编辑（方案 P1-4）：把某一段改成用户输入的文本，**立即落盘**。
    ///
    /// 为什么立即落盘、不给"保存全部"：用户改的是一句具体的转写，没有第二个动作
    /// 会替他覆盖住它；而只要它攒在内存里，关窗 / 退出就没了 ——
    /// 那时用户以为自己改过了（他确实点了保存），下次打开却发现白改。
    ///
    /// 为什么正在整理时**拒绝**：这一句正是整理模型这次要读的材料。放它进来会得到
    /// 「模型整理的是旧文本、用户看着的是新文本」这种谁也解释不清的结果 ——
    /// 与其这样，不如让用户等几秒（见"点了结果会变吗"那条判据）。
    @discardableResult
    func updateTranscriptSegment(
        sessionID: UUID,
        segmentID: UUID,
        text: String
    ) -> TranscriptEditor.Outcome {
        if isProcessing || isRecording {
            return .rejected("正在整理纪要，等它结束再改这一句。")
        }

        do {
            var updated = try storage.session(with: sessionID)
            let outcome = TranscriptEditor.apply(
                text: text,
                to: updated.transcriptSegments,
                segmentID: segmentID
            )
            guard case let .saved(segments) = outcome else { return outcome }

            updated.transcriptSegments = segments
            // 全文是**派生**的，必须跟着一起走。落下一处不改，同一个会话里就有了
            // 两份不一致的逐字稿（一份是段数组、一份是拼好的全文），
            // 而哪一份被用到取决于走的是哪条路 —— 这种不一致只能靠"改就一起改"避免。
            updated.transcriptText = segments.map(\.text).joined(separator: "\n")
            updated.transcriptEditedAt = Date()
            updated.updatedAt = Date()
            try storage.save(updated)
            replaceSession(updated)
            selectedSessionID = updated.id
            statusText = "已保存这句修改，可以重新整理纪要了"
            errorMessage = nil
            return .saved(segments)
        } catch {
            errorMessage = error.localizedDescription
            statusText = error.localizedDescription
            return .rejected(error.localizedDescription)
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
                // 用户很可能**刚刚**才在设置里补了术语（"这个名字一直听错"），而完整清洗
                // 只在转写那一刻跑一次 —— 那条已存盘的逐字稿不会自己变好。这里是唯一
                // 一次能补上的机会：只做纯替换（不动段结构、不动时间戳），改到了才写回，
                // 没改到就一个字都不碰盘。
                //
                // **以盘上的那份为准，不用调用方传进来的快照**：用户可能刚刚才在原文页
                // 改过一句（`updateTranscriptSegment` 已落盘、也刷新了列表），但视图层
                // 手里那份 `session` 是它自己构造时抓的 —— 拿它当输入，就是把用户刚改的
                // 那句丢掉，而且丢得毫无声响（覆盖它的正是"看起来很正常"的旧文本）。
                let current = try storage.session(with: session.id)
                // 表替换会**跳过人工改过的段**（见 `applyingTerminology`）：用户改过的
                // 那句是他确认过的事实，不能被"猜出来的纠错"再动一次。
                let corrected = TranscriptCleaner.applyingTerminology(
                    current.transcriptSegments,
                    table: glossary.replacementTable
                )
                let correctedText = corrected.map(\.text).joined(separator: "\n")
                let didCorrect = corrected.map(\.text) != current.transcriptSegments.map(\.text)

                let analysis = try await buildAnalysis(from: corrected)
                try Task.checkCancellation()
                guard summaryRegenerationID == regenerationID else { return }

                var updated = try storage.session(with: session.id)
                if didCorrect {
                    updated.transcriptSegments = corrected
                    updated.transcriptText = correctedText
                }
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
                    statusText = didCorrect ? "纪要已更新，并应用了术语表" : "纪要已更新"
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
                    try await process(
                        sessionID: resetSession.id,
                        inputURL: inputURL,
                        resume: false,
                        dualTracks: resolvedDualTracks(for: resetSession)
                    )
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

    /// 处理一场会议：转写 → 清洗 → 整理。
    ///
    /// - Parameter dualTracks: 双声道（P2-2a）的两路音频。给了它就走"两路各转一次再合并
    ///   打说话人"，没有它走原来那条单路（导入的音频、老会话、以及任何一条路没录上的情况）。
    private func process(
        sessionID: UUID,
        inputURL: URL,
        resume: Bool,
        dualTracks: DualTrackInput? = nil
    ) async throws {
        guard let cliURL = resolvedWhisperCLIURL(), let modelURL = resolvedModelURL() else {
            throw PipelineError.missingBinary
        }

        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw PipelineError.transcriptionFailed("找不到待处理的音频文件。")
        }

        let duration = try durationReader.duration(for: inputURL)
        let totalChunks = Self.chunkCount(for: duration)
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
        // 两路文件名要存下来：**重新处理 / 崩溃恢复**不经过录音，只能靠这两个名字
        // 把说话人找回来（不存的话，那两条路会静默丢掉全部说话人标注 —— 其他都对，
        // 就是标签没了，没人看得出是这里出的问题）。
        session.localAudioFileName = dualTracks?.local.lastPathComponent
        session.remoteAudioFileName = dualTracks?.remote.lastPathComponent
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

        // 术语表在这**一次转写开始时取一次快照**：中途用户改了设置，也不该让同一场会议
        // 前半段和后半段用两份不同的提示词（whisper 的偏置本来就有"越往后越弱"的问题，
        // 再叠一层变化就更没法解释了）。下一次转写自然用新词表。
        let initialPrompt = glossary.whisperInitialPrompt()

        if let dualTracks {
            // 双声道：两路各转一遍，再合并打说话人。分块窗口与"哪一段归谁"的算法
            // 与下面那条单路循环**共用同一份实现**（`chunkWindow` / `ownedSegments`）。
            segments = try await transcribeDualTracks(
                dualTracks,
                sessionID: sessionID,
                session: session,
                cliURL: cliURL,
                modelURL: modelURL,
                initialPrompt: initialPrompt,
                startedAt: startedAt
            )
            completedChunks = totalChunks
            nextOffset = duration
        } else {
            while completedChunks < totalChunks {
                try Task.checkCancellation()

                let window = Self.chunkWindow(index: completedChunks, duration: duration)
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
                    offset: window.start,
                    duration: window.length,
                    initialPrompt: initialPrompt
                )

                let ownedSegments = Self.ownedSegments(
                    chunkTranscript.segments,
                    index: completedChunks,
                    in: window
                )
                segments = Self.mergeSegments(existing: segments, incoming: ownedSegments)
                completedChunks += 1
                nextOffset = window.coreEnd

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
        }

        processingStage = "正在整理会议结果..."
        statusText = processingStage

        // 逐字稿后处理（P0-1C）。放在**所有分块都转完之后、整理之前**，一次过：
        // 复读是跨块的（whisper 在长静音上会自重复），逐块清洗看不见。
        // 清洗结果会写回会话，所以「逐字稿」页里也是清洗后的样子 ——
        // 原来一屏几十条 15 字的碎行，读起来像电报。
        //
        // 替换表来自设置页的术语表（P1-3 / 2D），**显式传入**：用户清空术语表就是
        // "什么都别替我改"，不能悄悄回落到出厂词表。
        let cleanedSegments = TranscriptCleaner.clean(
            segments,
            options: TranscriptCleaner.Options(terminology: glossary.replacementTable)
        )

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
            ? keychain.string(for: settings.provider, allowAuthenticationUI: false)
            : enteredKey

        do {
            let analysis = try await summaryEngine.analyze(
                segments: segments,
                settings: settings,
                apiKey: apiKey,
                glossary: glossary
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
                // 双声道会话在恢复时也要把两路带上：不带的话，靠续跑救回来的那场会议
                // 会**静默**丢掉全部说话人标注（别的地方都对，就是标签没了）。
                try await process(
                    sessionID: session.id,
                    inputURL: preparedURL,
                    resume: true,
                    dualTracks: resolvedDualTracks(for: session)
                )
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
        duration: TimeInterval,
        initialPrompt: String
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
                    language: "zh",
                    initialPrompt: initialPrompt
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

    // MARK: - 双声道（P2-2a）

    /// 从会话记录里把双声道两路找回来（**重新处理**与**崩溃恢复**走这条路 ——
    /// 它们不经过录音，只能靠存下来的两个文件名）。
    /// 两个文件都要在才算数，理由同 `stopRecording`。
    private func resolvedDualTracks(for session: MeetingSession) -> DualTrackInput? {
        guard let localName = session.localAudioFileName,
              let remoteName = session.remoteAudioFileName else { return nil }
        let local = storage.inputURL(for: session, preferredFileName: localName)
        let remote = storage.inputURL(for: session, preferredFileName: remoteName)
        guard FileManager.default.fileExists(atPath: local.path),
              FileManager.default.fileExists(atPath: remote.path) else { return nil }
        return DualTrackInput(local: local, remote: remote)
    }

    /// 把刚录下来的两路 `.caf` 归一化成 whisper 能直接吃的 16 kHz 单声道 wav。
    ///
    /// 换算成功后**删掉原始 `.caf`**：16 kHz 浮点单声道一小时约 230 MB，两路就是 460 MB，
    /// 而原始录音已经完整地留在 `.mov` 里了，再留一份没有意义。
    private func normalizedTracks(
        from recording: MixedRecordingResult?,
        in session: MeetingSession
    ) async throws -> DualTrackInput? {
        guard let recording else { return nil }
        guard let local = try await normalizedTrack(
            recording.localTrackURL,
            name: DualTrackPaths.localNormalizedName,
            in: session
        ), let remote = try await normalizedTrack(
            recording.remoteTrackURL,
            name: DualTrackPaths.remoteNormalizedName,
            in: session
        ) else {
            // 只有一路 → 不做说话人标注（"两路都拿到才算数"，见 DualTrackInput）。
            // 但**必须把没用上的中间文件删掉**：`local.caf` / `remote.caf` 是中间产物，
            // 留在会话目录里既占地方，又长得像"其实录到了两路"的证据。
            // 2026-09-14 实测就留下过一个 1.9 MB 的 `remote.caf`（本地路缺失时提前返回，
            // 系统声那一路还没来得及归一化）。
            discardCaptureFiles(in: session)
            Diagnostics.audio.notice("双声道不可用：只有一路，已退回单路且不标说话人")
            return nil
        }
        return DualTrackInput(local: local, remote: remote)
    }

    /// 兜底删掉双声道的中间文件（`.caf`）。正常路径上它们在归一化后就删了。
    private func discardCaptureFiles(in session: MeetingSession) {
        let urls = DualTrackPaths.captureURLs(in: storage.folderURL(for: session))
        for url in [urls.local, urls.remote] where FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.removeItem(at: url)
            Diagnostics.audio.notice("清掉没用上的中间文件 \(url.lastPathComponent, privacy: .public)")
        }
    }

    private func normalizedTrack(
        _ source: URL?,
        name: String,
        in session: MeetingSession
    ) async throws -> URL? {
        guard let source, FileManager.default.fileExists(atPath: source.path) else {
            Diagnostics.audio.notice("归一化跳过 \(name, privacy: .public)：原始录音文件不存在")
            return nil
        }
        let target = storage.inputURL(for: session, preferredFileName: name)
        try await transcoder.convertToWav(inputURL: source, outputURL: target)
        try? FileManager.default.removeItem(at: source)
        Diagnostics.audio.notice("归一化完成 \(name, privacy: .public)")
        return target
    }

    /// 双声道两路各转一遍，再合并打说话人。
    private func transcribeDualTracks(
        _ tracks: DualTrackInput,
        sessionID: UUID,
        session: MeetingSession,
        cliURL: URL,
        modelURL: URL,
        initialPrompt: String,
        startedAt: Date
    ) async throws -> [TranscriptSegment] {
        let probe = AudioLevelProbe()
        var plan: [(speaker: TranscriptSpeaker, url: URL)] = []
        if try await isAudible(tracks.local, probe: probe) {
            plan.append((.local, tracks.local))
        }
        if try await isAudible(tracks.remote, probe: probe) {
            plan.append((.remote, tracks.remote))
        }

        // 两路都没声音 = 整场就是一段静音。返回空数组，让上层按「材料不足」处理
        // （根本不调模型），而不是把一段静音交给 whisper 让它编出一整场会。
        guard !plan.isEmpty else {
            Diagnostics.audio.notice("转写计划为空：两路都没有可听信号，按「材料不足」处理")
            return []
        }
        Diagnostics.audio.notice(
            "转写计划：\(plan.map(\.speaker.displayName).joined(separator: "、"), privacy: .public)"
        )

        var bySpeaker: [TranscriptSpeaker: [TranscriptSegment]] = [:]
        for (index, entry) in plan.enumerated() {
            bySpeaker[entry.speaker] = try await transcribeTrack(
                audioURL: entry.url,
                sessionID: sessionID,
                session: session,
                cliURL: cliURL,
                modelURL: modelURL,
                initialPrompt: initialPrompt,
                startedAt: startedAt,
                label: entry.speaker.displayName,
                trackIndex: index,
                trackCount: plan.count
            )
        }

        let merged = TranscriptMerger.merge(
            local: bySpeaker[.local] ?? [],
            remote: bySpeaker[.remote] ?? []
        )
        Diagnostics.audio.notice(
            "合并结果：\(merged.count) 段，其中带说话人 \(merged.filter { $0.speaker != nil }.count) 段"
        )
        return merged
    }

    /// 这一路有没有声音。
    ///
    /// 探针**读不动时按"有声音"处理**：一个文件读不出来，不该被当成"对方没说话"，
    /// 那会把整整一半的发言静默丢掉。宁可让 whisper 去转一段静音。
    private func isAudible(_ url: URL, probe: AudioLevelProbe) async throws -> Bool {
        do {
            // 扫一遍整段音频是纯计算、可能几百毫秒，扔到主线程外。
            return try await Task.detached(priority: .utility) {
                try probe.hasAudibleSignal(at: url)
            }.value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return true
        }
    }

    /// 把**一路**音频从头转完。
    ///
    /// 不支持"续跑"：双声道只出现在刚录完的会话上，中途失败就整场重来
    /// （`retryProcessing` 也是从头跑），而两路的续跑计数混在一起没法解释。
    ///
    /// 分块窗口与"哪一段归谁"用的是与单路循环**同一份**实现（`chunkWindow` /
    /// `ownedSegments`）—— 两处各写一遍，就会出现"两路的分块边界差 2 秒"这种
    /// 没人看得出来的不一致。
    private func transcribeTrack(
        audioURL: URL,
        sessionID: UUID,
        session: MeetingSession,
        cliURL: URL,
        modelURL: URL,
        initialPrompt: String,
        startedAt: Date,
        label: String,
        trackIndex: Int,
        trackCount: Int
    ) async throws -> [TranscriptSegment] {
        let duration = try durationReader.duration(for: audioURL)
        let totalChunks = Self.chunkCount(for: duration)
        // 进度按"两路合起来算一段"报：总段数是两路之和，所以进度条从头到尾单调 ——
        // 第二路接着第一路走，不会退回去。
        let overallTotal = totalChunks * trackCount
        var segments: [TranscriptSegment] = []

        for index in 0..<totalChunks {
            try Task.checkCancellation()

            let window = Self.chunkWindow(index: index, duration: duration)
            let prefix = storage.folderURL(for: session)
                .appendingPathComponent("chunks", isDirectory: true)
                .appendingPathComponent(
                    String(
                        format: "chunk-%@-%04d",
                        trackIndex == 0 ? "local" : "remote",
                        index + 1
                    )
                )

            let completed = trackIndex * totalChunks + index
            let progress = Double(completed) / Double(overallTotal)
            let stage = "正在转写\(label)第 \(index + 1)/\(totalChunks) 段"
            processingProgress = progress
            processingStage = stage
            statusText = "\(stage) · \(progress.percentLabel)"
            updateProcessingState(
                sessionID: sessionID,
                progress: progress,
                stage: stage,
                completedChunks: completed,
                totalChunks: overallTotal,
                nextOffset: window.coreEnd,
                startedAt: startedAt
            )

            let chunkTranscript = try await transcribeChunkWithTimeout(
                audioURL: audioURL,
                cliURL: cliURL,
                modelURL: modelURL,
                outputPrefix: prefix,
                offset: window.start,
                duration: window.length,
                initialPrompt: initialPrompt
            )
            segments = Self.mergeSegments(
                existing: segments,
                incoming: Self.ownedSegments(chunkTranscript.segments, index: index, in: window)
            )

            // 每块落地一次（与单路循环同样的理由：中途崩了不该整场重来）。
            if var saved = try? storage.session(with: sessionID) {
                saved.transcriptSegments = segments
                saved.transcriptText = segments.map(\.text).joined(separator: "\n")
                saved.duration = duration
                saved.processingChunkStartedAt = Date()
                try? storage.save(saved)
                replaceSession(saved)
            }
        }
        return segments
    }

    // MARK: - 分块

    static func chunkCount(for duration: TimeInterval) -> Int {
        max(1, Int(ceil(duration / chunkDuration)))
    }

    /// 分块窗口。
    ///
    /// **迁移不变式**：这段算法原来内联在 `process` 的循环里。抽出来的时候把它
    /// 在小样本上的**具体取值**钉进了 `ProcessingChunkWindowTests` ——
    /// 合并/搬迁是**静默**改变（不崩、不报错），只有断言值相等才能证明行为没变。
    static func chunkWindow(index: Int, duration: TimeInterval) -> ChunkWindow {
        let coreStart = Double(index) * chunkDuration
        let coreEnd = min(duration, coreStart + chunkDuration)
        let start = max(0, coreStart - (index == 0 ? 0 : chunkOverlap))
        let end = min(duration, coreEnd + (coreEnd < duration ? chunkOverlap : 0))
        return ChunkWindow(coreStart: coreStart, coreEnd: coreEnd, start: start, end: end)
    }

    /// 这一块「拥有」哪些段：只有起点落在核心区间里的才算。
    ///
    /// 重叠区里被前后两块重复转出来的部分归**前一块**（第一块例外 —— 它没有前一块，
    /// 拿的是 `start` 到 `coreEnd` 之间的全部）。
    static func ownedSegments(
        _ segments: [TranscriptSegment],
        index: Int,
        in window: ChunkWindow
    ) -> [TranscriptSegment] {
        segments.filter { segment in
            if index == 0 {
                return segment.start < window.coreEnd
            }
            return segment.start >= window.coreStart && segment.start < window.coreEnd
        }
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
            let sameText = TranscriptMerger.normalized(segment.text) == TranscriptMerger.normalized(previous.text)
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
        // 这里再写一次是**给新装用户补初值**：`init` 里的赋值不触发 `glossaryText` 的 didSet，
        // 第一次启动不会落盘。之后用户每次编辑都由 didSet 负责，不依赖这个函数。
        UserDefaults.standard.set(glossaryText, forKey: Preferences.glossaryText)
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
        // **门禁在这里**，而不是只在上层调用点 —— 这样三条路都会经过它：
        // ① 录音 / 导入后的正式整理（`MeetingSummaryEngine.analyze` 会先问一次，
        //    不足就直接回到这里）；② 选「本地保守整理」的用户；③ `reloadSessions`
        //    里那段"重算本地整理结果"的修补循环。少任何一条，短录音都会在重启后
        //    换个样子出现。
        if let shortfall = TranscriptMaterial.measure(segments).shortfall {
            return buildInsufficient(shortfall: shortfall)
        }

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

    /// 2C 的历史修补判据：这条会话要不要拿门禁结果覆盖一次。
    ///
    /// 抽成静态函数，是因为它决定**要不要动用户已经存盘的数据** ——
    /// 这种判据不能靠审阅代码来保证正确，必须有单测钉住（`TranscriptMaterialTests`）。
    ///
    /// 两把锁缺一不可：
    /// 1. **材料确实不够**（门禁会拦），
    /// 2. **结果里没有任何结构化发现**（`hasStructuredFindings`）。
    ///
    /// 材料够的不动（那是真结果）；有决策 / 待办 / 结论的也不动 ——
    /// 哪怕材料少，那也是用户真正拿到过的东西。已经标过 `insufficientMaterial`
    /// 的更不用动（否则每次启动都要重写一遍）。
    static func needsMaterialGateRepair(_ session: MeetingSession) -> Bool {
        guard session.status == .ready else { return false }
        guard session.analysis.insufficientMaterial == nil else { return false }
        guard !session.analysis.hasStructuredFindings else { return false }
        return TranscriptMaterial.measure(session.transcriptSegments).shortfall != nil
    }

    /// 材料不足时的产物：**一屏空态，而不是一段元评论**。
    ///
    /// 刻意留空的几处，每一处都有理由：
    /// - `summaryError` 保持 nil —— 这里没有失败，写进去会让界面弹出
    ///   「已保留逐字稿；下面仅显示本地保守结果」，并且给出一个点了也没用的「重试」。
    /// - `summaryModel` 保持 nil —— **没有模型参与**，这是字面事实。填上「本地保守整理」
    ///   会让窗口副标题挂出一个档位名，读起来像"用本地规则整理过一场会"，其实
    ///   本地规则这次也只做了一件事：判定材料不够。
    ///   （nil 会让 `reloadSessions` 的第一个修补循环重算一次，但算出来与存盘结果
    ///   逐字段相等，所以不会写盘 —— 这条不变式由 `testRepairLoopSeesAStableResult` 钉住。）
    static func buildInsufficient(shortfall: MaterialShortfall) -> MeetingAnalysis {
        MeetingAnalysis(
            overview: [],
            timeline: [],
            decisions: [],
            actions: [],
            confidence: 0,
            overviewText: "",
            minutesText: "",
            summaryModel: nil,
            summaryError: nil,
            partialNotice: nil,
            diagnostics: nil,
            headline: nil,
            overviewBullets: nil,
            openQuestions: nil,
            insufficientMaterial: shortfall
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
