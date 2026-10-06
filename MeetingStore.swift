import AppKit
import Foundation
import UniformTypeIdentifiers

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
    @Published private(set) var storageIssueCount = 0
    @Published private(set) var isLoadingSessions = false
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
    /// 设置页「获取可用模型」的状态。原来是一个 `String` 扛 9 种语义，
    /// 见 `SummaryModelTestState` 的注释。
    @Published var summaryModelState: SummaryModelTestState = .idle

    // 两道录音权限的当前状态。**只 preflight，不请求** ——
    // 目的是在用户点「开始录音」之前就把状态摆在屏幕上，
    // 而不是等他点了、录完了半小时才发现没有对方的声音。
    @Published var screenCapturePermission: ScreenCapturePermission = .denied
    @Published var microphonePermission: MicrophonePermission = .notDetermined
    /// 缺系统音频权限被拦下时，界面上要显示的一条说明（正常为 nil）。
    @Published var captureBlockedNotice: String?
    /// 导出失败时的一条说明（正常为 nil）。
    ///
    /// **只在失败时非 nil**：导出成功不弹任何东西 —— SavePanel 自己关掉就是成功，
    /// 这是 macOS 的惯例，再补一句「导出成功」属于画蛇添足。
    /// 也**不覆盖 `captureBlockedNotice`**：两者语义不同（一个是录音被拦、一个是文件没写成），
    /// 共用一条会让人在权限出错时读到磁盘错误。
    @Published var exportNotice: String?
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
    private var mixedSession: (any RecordingSession)?
    private let recordingFactory: @MainActor (URL, URL, URL) -> any RecordingSession
    private let capturePermissions: @MainActor () -> (ScreenCapturePermission, MicrophonePermission)
    private var recordingStartFailure: String?
    @Published private(set) var isPreparingRecording = false
    @Published private(set) var recordingStartedAt: Date?
    private var recordingStartTask: Task<Void, Never>?
    private var recordingLevelTask: Task<Void, Never>?
    @Published private(set) var microphoneLevel: Double = 0
    @Published private(set) var systemAudioLevel: Double = 0
    @Published var transcriptDrafts: [UUID: String] = [:]
    @Published var editingSegments: [UUID: UUID] = [:]
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
    init(storage: SessionStorage? = nil,
         loadSessionsInBackground: Bool? = nil,
         recordingFactory: @escaping @MainActor (URL, URL, URL) -> any RecordingSession = {
             MixedRecordingSession(movieURL: $0, localTrackURL: $1, remoteTrackURL: $2)
         },
         capturePermissions: @escaping @MainActor () -> (ScreenCapturePermission, MicrophonePermission) = {
             (MixedRecordingSession.screenCapturePreflight, MicrophoneAccess.permission)
         }) {
        self.storage = storage ?? SessionStorage()
        self.recordingFactory = recordingFactory
        self.capturePermissions = capturePermissions
        let defaults = Self.defaultRuntimePaths()
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
        // 引擎与模型路径的迁移判据：**没存过，或存的那个路径在本机不存在**。
        // 刻意不拿具体的旧路径做字面量比对 —— 旧实现正是这么写的，结果把开发机的
        // 私人目录结构编进了二进制，随安装包一起分发了出去。
        // 「文件不存在」这条判据对两类人都成立（老用户：旧路径已随目录变动失效；
        // 陌生人：从未存过），而且不依赖任何人的机器上有什么。
        whisperCLIPath = Self.shouldUseDefaultPath(storedCLIPath)
            ? defaults.cliURL.path
            : storedCLIPath!
        whisperModelPath = Self.shouldUseDefaultPath(storedModelPath)
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
        savePreferences()
        if loadSessionsInBackground ?? (storage == nil) {
            isLoadingSessions = true
            statusText = "正在读取会议记录..."
            Task { [weak self, storage = self.storage] in
                let report = await Task.detached(priority: .userInitiated) {
                    MeetingSessionLoader.load(storage: storage)
                }.value
                guard let self else { return }
                self.applySessionLoad(report)
                self.isLoadingSessions = false
                self.statusText = "准备就绪"
                self.resumePendingProcessing()
            }
        } else {
            reloadSessions()
            Task { @MainActor [weak self] in self?.resumePendingProcessing() }
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
        guard !isLoadingSessions else { return }
        applySessionLoad(MeetingSessionLoader.load(storage: storage, activeID: activeSessionID))
    }

    private func applySessionLoad(_ load: SessionLoadReport) {
        let previousWriteNotice = storageWriteNotice
        storageIssueCount = load.issues.count
        if !load.issues.isEmpty {
            errorMessage = "有 \(load.issues.count) 个会议目录读取或历史诊断清理异常，文件已保留。请打开会议数据目录检查：" + load.issues.joined(separator: "、")
        }
        if load.writeFailed {
            storageWriteNotice = Self.storageFailureMessage
            errorMessage = storageWriteNotice
        } else {
            storageWriteNotice = nil
            if previousWriteNotice != nil && errorMessage == previousWriteNotice { errorMessage = nil }
        }
        sessions = load.sessions
        normalizeSelection()
    }

    func startRecording() {
        guard !isLoadingSessions, !isRecording, !isPreparingRecording, !isProcessing else { return }

        // 录音前先当场看一眼两道权限门（纯 preflight，不弹窗）。
        //
        // 为什么必须**在开录之前**判：缺系统音频权限时 ScreenCaptureKit 不报错、
        // 也不给样本，录出来是一段**没有对方声音**的文件 —— 用户要等听完才发现，
        // 半小时的会就这么白丢。所以这里当场拦下，并给出可执行的下一步。
        refreshCapturePermissions()
        guard captureReadiness.canStartRecording else {
            captureBlockedNotice = captureReadiness.blockingMessage
            statusText = "缺「屏幕与系统音频录制」权限，录音没有开始"
            return
        }

        // A single recording action captures both system audio and the Mac microphone.
        captureMode = .mixed
        let draft: MeetingSession
        do { draft = try storage.createDraftSession(captureMode: .mixed) }
        catch { errorMessage = error.localizedDescription; statusText = error.localizedDescription; return }
        isPreparingRecording = true
        recordingStartedAt = nil
        recordingStartFailure = nil
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
        let recorder = recordingFactory(
            storage.sourceURL(for: draft, preferredFileName: "source.mov"),
            trackURLs.local,
            trackURLs.remote
        )
        recorder.onFailure = { [weak self] message in
            guard let self, self.activeSessionID == draft.id else { return }
            guard self.isRecording || self.isPreparingRecording else { return }
            self.recordingStartFailure = SafeDiagnostics.processing(message)
            self.errorMessage = "录音采集已中断，正在保留已有文件。"
            self.stopRecording()
        }
        mixedSession = recorder
        recordingStartTask = Task {
            do {
                try await recorder.start()
                try Task.checkCancellation()
                guard self.activeSessionID == draft.id else { _ = try? await recorder.stop(); return }
                await MainActor.run {
                    self.isPreparingRecording = false
                    self.isRecording = true
                    self.recordingStartedAt = Date()
                    self.statusText = "正在录音"
                    self.updateSessionStatus(draft.id, status: .recording)
                    self.startRecordingLimit(for: draft.id)
                    self.recordingLevelTask = Task { [weak self] in
                        while !Task.isCancelled {
                            guard let self, self.isRecording, self.activeSessionID == draft.id else { return }
                            let levels = self.mixedSession?.levels
                            self.microphoneLevel = levels?.local ?? 0
                            self.systemAudioLevel = levels?.remote ?? 0
                            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                        }
                    }
                }
            } catch {
                let wasUserCancellation = Task.isCancelled && self.recordingStartFailure == nil
                _ = try? await recorder.stop()
                await MainActor.run {
                    guard self.activeSessionID == draft.id else { return }
                    self.isPreparingRecording = false
                    self.failSession(draft.id,
                        message: wasUserCancellation && self.recordingStartFailure == nil
                            ? SafeDiagnostics.recordingPreparationCancelled
                            : self.recordingStartFailure ?? error.localizedDescription,
                        cancelled: wasUserCancellation && self.recordingStartFailure == nil)
                }
            }
        }
    }

    func stopRecording() {
        if isPreparingRecording {
            recordingStartTask?.cancel()
            statusText = "正在停止录音准备，保留已有文件..."
            return
        }
        guard isRecording, let sessionID = activeSessionID else { return }
        isRecording = false
        recordingStartedAt = nil
        recordingLevelTask?.cancel()
        microphoneLevel = 0
        systemAudioLevel = 0
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
                // Stop capture before reading the manifest: a failed disk/read must never
                // bypass device cleanup and leave a recorder running behind a failed UI.
                let recording = try await mixedSession?.stop()
                mixedSession = nil
                _ = microphoneSession?.stop()
                microphoneSession = nil
                let session = try storage.session(with: sessionID)
                let sourceURL = storage.sourceURL(for: session, preferredFileName: session.sourceFileName)
                let inputURL: URL
                var dualTracks: DualTrackInput?

                switch session.captureMode {
                case .microphone:
                    inputURL = sourceURL
                case .mixed:
                    inputURL = storage.inputURL(for: session, preferredFileName: "input.wav")
                    try await transcoder.convertToWav(inputURL: sourceURL, outputURL: inputURL)
                    // 双声道（P2-2a）：**两路都拿到才算数**。只有一路时宁可不做标注 ——
                    // 麦克风那一路本来就混着外放出来的对方声音，只按它标"我方"，
                    // 会把对方说的话算成我方，而且读起来完全自然、永远没人发现。
                    dualTracks = try await normalizedTracks(from: recording, in: session)
                    if dualTracks == nil {
                        var updated = try storage.session(with: sessionID)
                        updated.captureWarning = "双路音频不完整，本次使用混合原件转写，无法确认说话人归属。若未授予麦克风权限，本机发言可能缺失。"
                        try storage.save(updated)
                        replaceSession(updated)
                    }
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
        guard !isLoadingSessions, !isRecording, !isPreparingRecording, !isProcessing else { return }

        var draftID: UUID?
        do {
            let draft = try storage.createDraftSession(captureMode: .imported)
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

            processingTask = Task { [weak self] in
                guard let self else { return }
                let isSecurityScoped = url.startAccessingSecurityScopedResource()
                defer {
                    if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                }
                do {
                    let copiedSource = try await Task.detached(priority: .utility) { [storage] in
                        try storage.copyImportedAudio(url: url, into: draft)
                    }.value
                    try Task.checkCancellation()
                    var importedSession = try storage.session(with: draft.id)
                    importedSession.status = .processing
                    importedSession.processingStage = "正在转换音频..."
                    importedSession.processingProgress = 0
                    importedSession.processingStartedAt = Date()
                    importedSession.updatedAt = Date()
                    try storage.save(importedSession)
                    replaceSession(importedSession)
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

    func openMeetingDataFolder() { NSWorkspace.shared.open(storage.dataDirectoryURL) }

    func openSelectedSessionFolder() {
        guard let session = selectedSession else { return }
        let folderURL = storage.folderURL(for: session)
        NSWorkspace.shared.activateFileViewerSelecting([folderURL])
    }

    /// 把当前选中的会议导出成一个 Markdown 文件。
    ///
    /// 走 `NSSavePanel` 而不是固定落点：用户可能把它存进项目文件夹、也可能存桌面，
    /// 这是他的决定。
    ///
    /// **取消不是错误** —— SavePanel 返回 `.cancel` 时直接返回，不写日志、不弹提示。
    /// 把「用户主动取消」和「写入失败」混成同一件事，会让人以后不敢点取消。
    func exportSelectedSession() {
        guard let session = selectedSession else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = MeetingExporter.fileName(for: session)
        panel.canCreateDirectories = true
        panel.title = "导出会议纪要"
        panel.message = "导出为 Markdown：粘进飞书文档、腾讯文档、Notion 都能直接识别标题与列表。"
        panel.prompt = "导出"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try MeetingExporter.markdown(for: session)
                .write(to: url, atomically: true, encoding: .utf8)
            exportNotice = nil
        } catch {
            exportNotice = "导出失败：\(error.localizedDescription)"
            Diagnostics.pipeline.error("导出会议失败：\(error.localizedDescription)")
        }
    }

    /// 把当前选中的会议整份复制到剪贴板。
    ///
    /// 导出文件与复制到剪贴板**必须是同一份文本**（都走 `MeetingExporter.markdown`）：
    /// 两条路各写一遍拼接逻辑，就会出现"复制的和导出的不一样"这种没人发现的分叉。
    /// `board` 默认 `.general` —— 调用点不传参就是写系统剪贴板，行为与以前完全一样。
    ///
    /// 留这个参数不是为了"扩展性"，是为了**单测能证明这件事又不碰用户的剪贴板**：
    /// 「按一下复制，粘出来的是不是那份导出文本」只能靠读剪贴板来验，
    /// 而测试进程去动 `.general` 会把用户当下复制的东西冲掉（他可能刚复制了一段重要的内容）。
    /// 注入一个具名粘贴板，同一段逻辑零副作用可验。
    @discardableResult
    func copySelectedSessionToPasteboard(to board: NSPasteboard = .general) -> Bool {
        guard let session = selectedSession else { return false }
        board.clearContents()
        board.setString(MeetingExporter.markdown(for: session), forType: .string)
        return true
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
        summaryModelState = .idle
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
            summaryModelState = .keySaveFailed
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
        summaryModelState = .connecting
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
                    summaryModelState = .loaded(
                        count: models.count,
                        selected: retainedSelection
                    )
                } else {
                    availableSummaryModels = []
                    canEditSummaryModelManually = true
                    let currentModel = selectionCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
                    if currentModel.isEmpty {
                        summaryModelState = .noList
                    } else {
                        summaryModelState = .testing(model: currentModel)
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
                        summaryModelState = .available(model: currentModel)
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
                summaryModelState = .failed(SummaryModelFailure.classify(error))
                // 原始错误串**不再贴给用户**（多半是英文技术串，说了也不知道改什么），
                // 但必须留下来可查：用户报「连不上」时，先看这一行。
                Diagnostics.pipeline.error(
                    "整理模型连接失败，分类：\(String(describing: SummaryModelFailure.classify(error)), privacy: .private)"
                )
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
        summaryModelState = .selected(model: cleanModel)
        savePreferences()
    }

    func updateManualSummaryModel(_ model: String) {
        cancelSummaryModelDiscovery()
        pendingSummaryModelSelection = nil
        summarySettings.modelName = model
        summaryModelState = .idle
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
        summaryModelState = .idle
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
              summaryModelState == .idle,
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
        if isProcessing || isRecording || isPreparingRecording {
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
            updated.analysisStale = true
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

    /// 主窗口常驻的「整理模型到底能不能用」结论。
    ///
    /// 为什么要在主窗口再说一遍：设置页那次连接测试的结论只活在设置面板里，
    /// 主窗口看起来永远配好了。用户点了「重新整理」才发现没 Key，那一下只能失望。
    ///
    /// 注意它**不判真实可达性**（那要发一次网络请求，不适合常驻）；
    /// 它判的是"本地这一侧齐了没有"：要不要 Key、要不要模型名。
    var summaryModelReadiness: SummaryModelReadiness {
        if summarySettings.provider == .localRules {
            return .localRules
        }
        let providerTitle = summarySettings.provider.title
        if summarySettings.provider.requiresAPIKey,
           summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .needsKey(provider: providerTitle)
        }
        let model = summarySettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.isEmpty {
            return .needsModel(provider: providerTitle)
        }
        return .configured(provider: providerTitle, model: model)
    }

    // MARK: - 录音权限（preflight）

    /// 两道录音门现在合起来是什么结论。
    var captureReadiness: CaptureReadiness {
        if !screenCapturePermission.isGranted {
            return .missingSystemAudio(microphone: microphonePermission)
        }
        if !microphonePermission.isGranted {
            return .missingMicrophoneOnly
        }
        return .ready
    }

    /// 刷新两道权限的当前状态。
    ///
    /// **纯 preflight，不弹任何系统窗口**，所以可以放心地在窗口激活、
    /// 进入空闲时调用。用户在系统设置里改完权限切回来，这里就会自动更新。
    func refreshCapturePermissions() {
        (screenCapturePermission, microphonePermission) = capturePermissions()
        // 权限补齐后，之前那条"被拦下"的提示要自己消失，别留在屏幕上。
        if captureReadiness.canStartRecording {
            captureBlockedNotice = nil
        }
    }

    func openScreenCaptureSettings() {
        openPrivacySettings(anchor: "Privacy_ScreenCapture")
    }

    func openMicrophoneSettings() {
        openPrivacySettings(anchor: "Privacy_Microphone")
    }

    private func openPrivacySettings(anchor: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    /// 「现在点重新整理，会不会真的干活」。
    ///
    /// **原实现漏了一格**：云端服务商这一支只判内存里有没有 Key，
    /// 完全没判有没有选模型。于是"有 Key 但一个模型都没选"时它返回 `true`，
    /// 界面照样给出「重新整理」，点下去必然失败——典型的假入口。
    /// （阶段 1-1 补的单测 `testReadinessNeedsModelWhenKeyPresentButModelEmpty` 钉住了这一格。）
    var canRegenerateSummaryNow: Bool {
        if summarySettings.provider == .localRules { return true }
        let model = summarySettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return false }
        if summarySettings.provider.requiresAPIKey {
            return !summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    var summaryRegenerationBlockedMessage: String? {
        if summarySettings.provider.requiresAPIKey,
           summaryAPIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "为了避免后台弹出钥匙串密码框，自动整理不会直接读取已保存的 API Key。请先打开设置页授权/保存一次，或切换成本地保守整理后再重新整理。"
        }
        if summarySettings.provider != .localRules,
           summarySettings.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "请先在设置里选择或填写一个整理模型，再重新整理。"
        }
        return nil
    }

    func regenerateSummary(for session: MeetingSession) {
        guard !isLoadingSessions, session.status == .ready, !isRecording, !isPreparingRecording, !isProcessing else { return }
        guard !session.materialSegments.isEmpty else {
            statusText = "这场会议还没有逐字稿，暂时无法整理纪要。"
            return
        }
        if let blockedMessage = summaryRegenerationBlockedMessage {
            statusText = blockedMessage
            errorMessage = blockedMessage
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
                    current.materialSegments,
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
                let preservedPrevious = analysis.isLocalFallback && (!current.analysis.minutesText.isEmpty || current.analysis.hasStructuredFindings)
                if preservedPrevious {
                    updated.lastRegenerationError = analysis.summaryError
                    if didCorrect { updated.analysisStale = true }
                } else {
                    updated.analysis = analysis
                    updated.analysisStale = nil
                    updated.lastRegenerationError = nil
                }
                updated.updatedAt = Date()
                try storage.save(updated)
                replaceSession(updated)
                if preservedPrevious {
                    statusText = "重新整理未成功，保留上次结果"
                } else if analysis.isLocalFallback {
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
                guard summaryRegenerationID == regenerationID else { return }
                cancelFinishedSummary(sessionID: session.id, regenerationID: regenerationID)
                errorMessage = error.localizedDescription
                statusText = error.localizedDescription
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
        // Cancellation is delivered to this task's process, never a future task's runner.
    }

    func retryProcessing(_ session: MeetingSession) {
        guard !isLoadingSessions, !isRecording, !isPreparingRecording, !isProcessing else { return }
        guard let inputURL = processingInputURL(for: session) else {
            errorMessage = "找不到这场会议的音频文件。"
            statusText = errorMessage ?? ""
            return
        }

        var resetSession: MeetingSession
        do { resetSession = try storage.session(with: session.id) }
        catch { errorMessage = error.localizedDescription; return }
        resetSession.processingRetainsPreviousResults = !resetSession.transcriptText.isEmpty || !resetSession.transcriptSegments.isEmpty
        resetSession.status = .processing
        resetSession.updatedAt = Date()
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
                    var preparedURL = inputURL
                    if preparedURL.pathExtension.lowercased() != "wav" {
                        preparedURL = storage.inputURL(for: resetSession, preferredFileName: "input.wav")
                        try await transcoder.convertToWav(inputURL: inputURL, outputURL: preparedURL)
                    }
                    try Task.checkCancellation()
                    try await process(
                        sessionID: resetSession.id,
                        inputURL: preparedURL,
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
        if activeSessionID == session.id && (isRecording || isPreparingRecording) {
            errorMessage = "请先结束录音，确认文件已保存后再删除这场会议。"
            return
        }
        if activeSessionID == session.id && isProcessing {
            let pending = processingTask
            pending?.cancel()
            statusText = "正在停止处理，完成后删除…"
            Task { [weak self] in
                await pending?.value
                self?.removeSessionFiles(session)
            }
            return
        }
        removeSessionFiles(session)
    }

    private func removeSessionFiles(_ session: MeetingSession) {
        do {
            try storage.delete(session)
            sessions.removeAll { $0.id == session.id }
            editingSegments.removeValue(forKey: session.id)
            for segment in session.transcriptSegments { transcriptDrafts.removeValue(forKey: segment.id) }
            normalizeSelection()
        } catch { errorMessage = error.localizedDescription; statusText = error.localizedDescription }
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
        let canResume = resume && session.processingRetainsPreviousResults != true && dualTracks == nil
        var completedChunks = canResume ? min(session.processingCompletedChunks ?? 0, totalChunks) : 0
        var nextOffset = canResume
            ? min(max(session.processingNextOffset ?? Double(completedChunks) * Self.chunkDuration, 0), duration)
            : 0
        var segments = canResume ? session.transcriptSegments : []

        try Task.checkCancellation()
        guard activeSessionID == sessionID else { throw CancellationError() }
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
        } else if !(try await isAudible(inputURL, probe: AudioLevelProbe(), threshold: 0)) {
            // Imported/mixed fallback audio needs the same guard. For the single track,
            // skip only digital silence; low-volume speech must never be discarded.
            segments = []
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
                try updateProcessingState(
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

                try Task.checkCancellation()
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
                if session.processingRetainsPreviousResults != true {
                    session.transcriptSegments = segments
                    session.transcriptText = segments.map(\.text).joined(separator: "\n")
                }
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

        try updateProcessingState(
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

        guard activeSessionID == sessionID else { throw CancellationError() }
        session = try storage.session(with: sessionID)
        session.status = .ready
        session.updatedAt = Date()
        session.transcriptSegments = cleanedSegments
        session.transcriptText = cleanedSegments.map(\.text).joined(separator: "\n")
        session.analysis = analysis
        session.analysisStale = nil
        session.lastRegenerationError = nil
        session.processingRetainsPreviousResults = nil
        session.transcriptEditedAt = nil
        session.inputAudioFileName = inputURL.lastPathComponent
        session.whisperCLIPath = cliURL.path
        session.whisperModelPath = modelURL.path
        session.duration = duration
        session.errorMessage = nil
        // 标题从**清洗后**的段落里取，与正文同一份材料。
        //
        // 2026-09-17 之前这里传的是 `segments`（清洗前的原始分块）：清洗会把一屏几十条
        // 15 字的碎行合成正常句子，于是标题可能是从一句**用户根本没在界面上见过**的碎句
        // 里截的，而下面正文里找不到那句话。同一屏里两处对不上，用户只会以为软件在乱起名。
        session.title = MeetingAnalysisBuilder.title(for: session, segments: cleanedSegments)
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
        let session = session.sanitizingDiagnostics
        if let index = sessions.firstIndex(where: { $0.id == session.id }),
           sessions[index].createdAt == session.createdAt {
            sessions[index] = session
        } else {
            sessions.removeAll { $0.id == session.id }
            let index = sessions.firstIndex { $0.createdAt < session.createdAt } ?? sessions.endIndex
            sessions.insert(session, at: index)
        }
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
        // 后台整理绝不能读取钥匙串密文：旧 ACL / 签名漂移时，macOS 会弹系统密码框，
        // `LAContext.interactionNotAllowed` 对这种钥匙串访问确认框也挡不住。
        // 自动流程只使用内存里已有的输入框值；没有就让云端整理失败并降级到本地规则。
        let apiKey = enteredKey.isEmpty ? nil : enteredKey

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
            fallback.summaryError = SafeDiagnostics.summary(error.localizedDescription)
            return fallback
        }
    }

    private func failSession(_ sessionID: UUID, message: String, cancelled: Bool = false) {
        guard activeSessionID == sessionID else { return }
        if var session = sessions.first(where: { $0.id == sessionID }) {
            session.status = .failed
            session.errorMessage = message
            session.updatedAt = Date()
            session.processingStage = cancelled ? "已取消录音准备" : "处理失败"
            persistRecoveryState(session)
            replaceSession(session)
        }
        if storageWriteNotice == nil { errorMessage = cancelled ? nil : SafeDiagnostics.processing(message) }
        statusText = errorMessage ?? (cancelled ? "已取消录音准备" : SafeDiagnostics.processing(message) ?? "处理失败")
        isPreparingRecording = false
        recordingStartedAt = nil
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
        guard activeSessionID == sessionID else { return }
        if var session = sessions.first(where: { $0.id == sessionID }) {
            session.status = .failed
            session.errorMessage = message
            session.updatedAt = Date()
            session.processingStage = "处理失败"
            persistRecoveryState(session)
            replaceSession(session)
        }
        if storageWriteNotice == nil { errorMessage = SafeDiagnostics.processing(message) }
        statusText = errorMessage ?? SafeDiagnostics.processing(message) ?? "处理失败"
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
        guard activeSessionID == sessionID else { return }
        if var session = sessions.first(where: { $0.id == sessionID }) {
            session.status = .failed
            session.errorMessage = "已取消转写，已保留已经完成的内容，可以重新处理。"
            session.processingStage = "已取消"
            session.updatedAt = Date()
            persistRecoveryState(session)
            replaceSession(session)
        }
        errorMessage = storageWriteNotice
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
        guard !isLoadingSessions, !isRecording, !isPreparingRecording, !isProcessing else { return }
        guard let session = sessions.first(where: { $0.status == .processing }) else { return }
        activeSessionID = session.id
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
    ) throws {
        try Task.checkCancellation()
        guard activeSessionID == sessionID else { throw CancellationError() }
        var session = try storage.session(with: sessionID)
        session.status = .processing
        session.updatedAt = Date()
        session.processingProgress = progress
        session.processingStage = stage
        session.processingCompletedChunks = completedChunks
        session.processingTotalChunks = totalChunks
        session.processingNextOffset = nextOffset
        session.processingStartedAt = startedAt
        try storage.save(session)
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
            // 保留失败的原始轨道供恢复；完整混合录音用于回退转写。
            Diagnostics.audio.notice("双声道不可用：只有一路，已退回单路且不标说话人")
            return nil
        }
        return DualTrackInput(local: local, remote: remote)
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
                speaker: entry.speaker,
                previousSegments: bySpeaker.values.flatMap { $0 },
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
    private func isAudible(_ url: URL, probe: AudioLevelProbe, threshold: Float = AudioLevelProbe.silenceThreshold) async throws -> Bool {
        do {
            // 扫一遍整段音频是纯计算、可能几百毫秒，扔到主线程外。
            return try await Task.detached(priority: .utility) {
                try probe.hasAudibleSignal(at: url, threshold: threshold)
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
        speaker: TranscriptSpeaker,
        previousSegments: [TranscriptSegment],
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
                        speaker == .local ? "local" : "remote",
                        index + 1
                    )
                )

            let completed = trackIndex * totalChunks + index
            let progress = Double(completed) / Double(overallTotal)
            let stage = "正在转写\(label)第 \(index + 1)/\(totalChunks) 段"
            processingProgress = progress
            processingStage = stage
            statusText = "\(stage) · \(progress.percentLabel)"
            try updateProcessingState(
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
            try Task.checkCancellation()
            let tagged = Self.ownedSegments(chunkTranscript.segments, index: index, in: window).map { segment in
                var copy = segment; copy.speaker = speaker; return copy
            }
            segments = Self.mergeSegments(existing: segments, incoming: tagged)

            var saved = try storage.session(with: sessionID)
            if saved.processingRetainsPreviousResults != true {
                saved.transcriptSegments = (previousSegments + segments).sorted { $0.start < $1.start }
                saved.transcriptText = saved.transcriptSegments.map(\.text).joined(separator: "\n")
            }
            saved.duration = max(saved.duration ?? 0, duration)
            saved.processingChunkStartedAt = Date()
            try storage.save(saved)
            replaceSession(saved)
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

    /// 保留跨越核心区间的完整句，重叠文本在合并时去重。
    static func ownedSegments(
        _ segments: [TranscriptSegment],
        index: Int,
        in window: ChunkWindow
    ) -> [TranscriptSegment] {
        segments.filter { segment in
            if index == 0 {
                return segment.start < window.coreEnd
            }
            return segment.end > window.coreStart && segment.start < window.coreEnd
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
        guard var session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.status = status
        session.updatedAt = Date()
        persistRecoveryState(session)
        replaceSession(session)
    }

    @Published private(set) var storageWriteNotice: String?
    private static let storageFailureMessage = "会议状态未能保存到磁盘。请释放磁盘空间并检查目录权限；已有文件已保留，退出前请导出可见内容。"

    /// Terminal/recovery transitions must still release the recorder when the disk fails.
    /// Keep their in-memory state visible, but never claim it was durably saved.
    private func persistRecoveryState(_ session: MeetingSession) {
        do {
            try storage.save(session)
            storageWriteNotice = nil
        } catch {
            storageWriteNotice = Self.storageFailureMessage
            errorMessage = storageWriteNotice
        }
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

    /// 「这个存下来的路径该不该被默认值取代」。
    ///
    /// 只有两条判据：没存过，或存的那个路径在本机**不存在**。
    /// 刻意不做字面量比对 —— 那需要把某个具体路径写死在源码里，而它会被编进二进制、
    /// 随安装包一起分发。旧实现就是这么写的，把开发机的私人目录结构泄了出去。
    private static func shouldUseDefaultPath(_ stored: String?) -> Bool {
        guard let stored, !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return true
        }
        return !FileManager.default.fileExists(atPath: stored)
    }

    /// 开发期的外部兜底路径：**只在显式声明时才生效**。
    ///
    /// 打包后的 app 自带引擎与模型（`bundledCLIURL` / `bundledModelURL` 总能命中），
    /// 走不到这里；它存在的意义只是让 `swift run` 不必每次去设置里填路径。
    /// 想用就自己声明，例如：
    /// `MS_DEV_WHISPER_ROOT=/path/to/whisper.cpp swift run`
    /// 默认值 `~/whisper.cpp` 正好是 README 推荐的安装位置，是个中性路径，
    /// 不含任何人的项目名。
    private static func legacyRuntimePaths() -> (cliURL: URL, modelURL: URL) {
        let declared = ProcessInfo.processInfo.environment["MS_DEV_WHISPER_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let root: URL
        if let declared, !declared.isEmpty {
            root = URL(
                fileURLWithPath: (declared as NSString).expandingTildeInPath,
                isDirectory: true
            )
        } else {
            root = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("whisper.cpp", isDirectory: true)
        }
        return (
            root.appendingPathComponent("build/bin/whisper-cli"),
            root.appendingPathComponent("models/ggml-small.bin")
        )
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
