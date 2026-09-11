import SwiftUI
import UniformTypeIdentifiers

enum MeetingResultTab: String, CaseIterable, Identifiable {
    case original
    case overview
    case minutes

    var id: String { rawValue }

    var title: String {
        switch self {
        case .original:
            return "原文"
        case .overview:
            return "速览"
        case .minutes:
            return "纪要"
        }
    }

}

extension MeetingSession {
    /// 会议元信息压成一行**纯文本**。
    ///
    /// 为什么是纯文本：窗口副标题（`navigationSubtitle`）只吃 `Text`，
    /// 渲染不了自定义视图，所以那一行不能再摆 Label + SF Symbol。
    /// 反过来说，这刚好让「会议头」整块从正文里消失——
    /// 它原本占掉正文顶部一整行，只为了重复标题栏里已经有的信息。
    var metaLine: String { metaLine(includingStatus: true) }

    /// `includingStatus: false` 专给「进行中」的副标题用。
    ///
    /// 那时副标题前面已经顶着 `statusText`（「正在录音」/「正在转写第 1/2 段 · 0%」），
    /// 末尾再挂一个状态词（「录音中」/「转写中」）就是同一句话说两遍。
    func metaLine(includingStatus: Bool) -> String {
        var parts = [createdAt.formatted(date: .numeric, time: .shortened)]
        if let duration { parts.append(duration.clockLabel) }
        if includingStatus { parts.append(status.title) }
        if let model = analysis.summaryModel, !model.isEmpty { parts.append(model) }
        return parts.joined(separator: "  ·  ")
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        NavigationSplitView {
            WorkbenchSidebarView()
        } detail: {
            WorkbenchDetailView()
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1060, minHeight: 660)
        .background(AppTheme.paper)
        .fileImporter(
            isPresented: $store.importAudioPresented,
            allowedContentTypes: [.audio],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                store.importAudio(url: url)
            case .failure(let error):
                store.errorMessage = error.localizedDescription
                store.statusText = error.localizedDescription
            }
        }
        .sheet(isPresented: $store.showSettings) {
            WorkbenchSettingsPane()
                .environmentObject(store)
        }
        .alert("发生问题", isPresented: errorBinding) {
            Button("好", role: .cancel) {
                store.errorMessage = nil
            }
        } message: {
            Text(store.errorMessage ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { store.errorMessage != nil },
            set: { shown in
                if !shown {
                    store.errorMessage = nil
                }
            }
        )
    }
}

struct WorkbenchSidebarView: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(spacing: 0) {
            // 交通灯区域由原生 NavigationSplitView + 标题栏统一让位，这里不再手写占位。
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.space5) {
                    VStack(alignment: .leading, spacing: AppTheme.space3) {
                        Text("MeetingScribe")
                            .font(.system(size: 22, weight: .semibold, design: .default))
                            .foregroundStyle(AppTheme.ink)

                        Text("把会议录下来，结束后直接得到可读的结果。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.space4)
                    .padding(.top, AppTheme.space4)

                    if store.sessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有会议记录")
                                .font(.headline)
                                .foregroundStyle(AppTheme.ink)
                            Text("开始录音或导入音频，结果会显示在这里。")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, AppTheme.space4)
                    } else {
                        WorkbenchSidebarSection(
                            title: "最近会议",
                            subtitle: "",
                            count: store.sessions.count
                        ) {
                            VStack(spacing: 4) {
                                // 失败 / 中断的会话也留在列表里（原来被 filter 掉了）。
                                // 它们的录音还在磁盘上，藏起来用户就既看不到、也没法重新处理。
                                ForEach(store.sessions) { session in
                                    WorkbenchSessionRowView(
                                        session: session,
                                        isSelected: store.selectedSessionID == session.id
                                    ) {
                                        store.selectedSessionID = session.id
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, AppTheme.space4)
            }
        }
        .frame(minWidth: 274, idealWidth: 288, maxWidth: 330)
        .background(AppTheme.paper)
    }

}

struct WorkbenchSessionRowView: View {
    let session: MeetingSession
    let isSelected: Bool
    let action: () -> Void
    @EnvironmentObject private var store: MeetingStore
    @State private var isHovering = false
    @State private var isRenamePresented = false
    @State private var isDeleteConfirmationPresented = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    WorkbenchStatusDot(status: session.status)
                }

                Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                    .font(.caption)
                    .foregroundStyle(subtitleColor)

                HStack(spacing: 6) {
                    if let duration = session.duration {
                        Text(duration.clockLabel)
                        Text("·")
                    }
                    Text(session.status.title)
                }
                .font(.caption)
                .foregroundStyle(subtitleColor)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule()
                        .fill(AppTheme.accent)
                        .frame(width: 3, height: 28)
                        .padding(.leading, 4)
                }
            }
        }
        .buttonStyle(.plain)
        .contentShape(RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
        .onHover { hovering in
            isHovering = hovering
        }
        .contextMenu {
            Button {
                isRenamePresented = true
            } label: {
                Label("重命名", systemImage: "pencil")
            }

            Button(role: .destructive) {
                isDeleteConfirmationPresented = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .sheet(isPresented: $isRenamePresented) {
            WorkbenchRenameSessionSheet(initialTitle: session.title) { title in
                store.renameSession(session, to: title)
            }
        }
        .alert("删除这场会议？", isPresented: $isDeleteConfirmationPresented) {
            Button("删除", role: .destructive) {
                store.deleteSession(session)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("录音、逐字稿和纪要会一并从这台 Mac 删除，且无法恢复。")
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleColor: Color {
        isSelected ? AppTheme.accent : AppTheme.ink
    }

    private var subtitleColor: Color {
        isSelected ? AppTheme.ink.opacity(0.62) : AppTheme.muted
    }

    private var backgroundColor: Color {
        if isSelected {
            return AppTheme.accentSoft
        }
        return isHovering ? AppTheme.paperSoft : Color.clear
    }
}

struct WorkbenchRenameSessionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isTitleFocused: Bool
    @State private var title: String
    let onSave: (String) -> Void

    init(initialTitle: String, onSave: @escaping (String) -> Void) {
        _title = State(initialValue: initialTitle)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("重命名会议")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text("名称只用于左侧会话列表和会议页标题。")
                    .font(.callout)
                    .foregroundStyle(AppTheme.muted)
            }

            TextField("会议名称", text: $title)
                .textFieldStyle(.roundedBorder)
                .focused($isTitleFocused)
                .onSubmit(save)

            HStack {
                Spacer(minLength: 0)

                Button("取消", role: .cancel) {
                    dismiss()
                }
                .buttonStyle(.plain)
                .foregroundStyle(AppTheme.muted)

                Button("保存") {
                    save()
                }
                .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 380)
        .background(AppTheme.paper)
        .onAppear {
            isTitleFocused = true
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty else { return }
        onSave(cleanTitle)
        dismiss()
    }
}

struct WorkbenchSidebarSection<Content: View>: View {
    let title: String
    let subtitle: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.accentSoft, in: Capsule())
            }

            content()
        }
        .padding(.horizontal, AppTheme.space4)
    }
}

struct WorkbenchDetailView: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        Group {
            if let session = store.workspaceSession {
                WorkbenchSessionWorkspace(session: session)
            } else {
                WorkbenchEmptyState()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.paper)
        .navigationTitle(store.workspaceSession?.title ?? "会议")
        .navigationSubtitle(navigationSubtitleText)
        .toolbar { workbenchToolbar }
    }

    /// 副标题原来只放一句「准备就绪」，一整条宽度只承载四个字，信息密度太低。
    /// 现在由会议元信息接管（日期 · 时长 · 状态 · 整理模型），也就是原来正文顶部那一行，
    /// 所以正文少了一整行、标题栏的副标题位才真正被用起来。
    ///
    /// 录音 / 转写 / 整理进行中时把实时状态顶到最前——这时候进度比元信息更该被看见；
    /// 终态（已完成 / 失败）本来就写在元信息里，不会丢。
    private var navigationSubtitleText: Text {
        guard let session = store.workspaceSession else {
            return Text(store.statusText)
        }
        if store.isRecording || store.isProcessing {
            // 进行中：`statusText` 本身已经说明了状态（「正在录音」/「正在转写第 1/2 段 · 0%」），
            // 所以元信息里不再重复那个状态词，否则副标题末尾会再挂一个「转写中」。
            return Text("\(store.statusText)  ·  \(session.metaLine(includingStatus: false))")
        }
        return Text(session.metaLine)
    }

    // 全局操作注册到原生标题栏，和侧边栏开关同一行，不再自绘第二条横栏。
    // 三个动作按角色分层，而不是三个同样轻重的裸字形：
    //   次要 → 导入音频（.bordered 底盘）
    //   主操作 → 开始录音 / 结束并转写 / 停止处理 / 重新处理（.borderedProminent 实底）
    //   全局 → 设置（.bordered 方形图标钮，齿轮是通用符号，不给文字）
    //
    // 为什么没有会话时整条撤掉：空态正文里已经有一对很大的「开始录音 / 导入已有音频」，
    // 标题栏再摆一遍同样的两个动作，同一屏就有四处入口在做两件事；而且此刻选中的
    // 是"什么都没有"，工具栏却在喊"开始录音"，权重给错了对象。
    // 设置是 app 级动作、不针对某场会议，跟着一起收走，改由 app 菜单的「设置…（⌘,）」
    // 承担——那本来就是 macOS 上设置该在的地方。
    @ToolbarContentBuilder
    private var workbenchToolbar: some ToolbarContent {
        if let session = store.workspaceSession {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.importAudioPresented = true
                } label: {
                    Label("导入音频", systemImage: "square.and.arrow.down")
                }
                .labelStyle(.titleAndIcon)
                // 与主操作共用一套底盘（实底 / 无描边 / 胶囊），主次只由填充色区分。
                .buttonStyle(WorkbenchToolbarButtonStyle())
                .help("导入一段已有音频")
                .disabled(store.isRecording || store.isProcessing)
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    performPrimaryAction(for: session)
                } label: {
                    Label(primaryTitle(for: session), systemImage: primaryIcon(for: session))
                }
                .labelStyle(.titleAndIcon)
                // 实底 + 着色：整条里唯一的高权重，录制/处理中整体转为危险色。
                .buttonStyle(WorkbenchToolbarButtonStyle(tint: primaryTint))
                .help(primaryTitle(for: session))
            }

            ToolbarItem(placement: .primaryAction) {
                Button {
                    store.showSettings = true
                } label: {
                    Image(systemName: "gearshape")
                }
                .buttonStyle(WorkbenchToolbarButtonStyle(iconOnly: true))
                .help("设置")
                .accessibilityLabel("设置")
            }
        }
    }

    /// 一场会议在标题栏上只能有**一个**状态迁移动作，且必须和当前状态对得上：
    /// 转写中 → 停止处理；录音中 → 结束并转写；失败 → 重新处理；其余 → 开始录音。
    ///
    /// 原来它只看 isRecording / isProcessing（都是全局开关，不看选中的是哪场会议），
    /// 于是在一条**失败**的会议记录上，主按钮显示的是「开始录音」——
    /// 用户正对着一条出错的记录，主按钮却在招呼他开一场新录音。
    private func primaryTitle(for session: MeetingSession) -> String {
        if store.isProcessing { return "停止处理" }
        if store.isRecording { return "结束并转写" }
        if session.status == .failed { return "重新处理" }
        return "开始录音"
    }

    private func primaryIcon(for session: MeetingSession) -> String {
        if store.isProcessing || store.isRecording { return "stop.fill" }
        if session.status == .failed { return "arrow.clockwise" }
        return "record.circle"
    }

    private var primaryTint: Color {
        if store.isRecording || store.isProcessing {
            return AppTheme.danger
        }
        return AppTheme.accent
    }

    private func performPrimaryAction(for session: MeetingSession) {
        if store.isProcessing {
            store.cancelProcessing()
        } else if store.isRecording {
            store.stopRecording()
        } else if session.status == .failed {
            store.retryProcessing(session)
        } else {
            store.startRecording()
        }
    }
}

struct WorkbenchSessionWorkspace: View {
    let session: MeetingSession
    @EnvironmentObject private var store: MeetingStore
    @State private var selectedTab: MeetingResultTab = .overview
    @StateObject private var audioPlayer = MeetingAudioPlayer()

    var body: some View {
        Group {
            switch session.status {
            case .failed:
                WorkbenchFailureState(
                    session: session,
                    openFolderAction: store.openSelectedSessionFolder,
                    retryAction: { store.retryProcessing(session) }
                )
                .padding(AppTheme.space6)
            case .processing, .recording:
                // 卡片只负责说明"现在在干什么"，不再摆按钮：
                // 状态迁移统一由标题栏那**一个**主按钮承担，一处唯一，
                // 不会再出现「卡片里停止处理 / 导航上结束并转写」两个按钮打架的局面。
                WorkbenchProcessingState(session: session)
                .padding(AppTheme.space6)
            case .ready:
                VStack(spacing: 0) {
                    // 原来这里有两行：会议头（元信息 + 两个图标按钮）、结果页 Tab。
                    // 现在元信息上移到窗口副标题，两个图标并进 Tab 同一行，
                    // 整条包在一片液态玻璃底托里，正文少了一整行、多了一件有体积的控制件。
                    WorkbenchResultTabBar(
                        selection: $selectedTab,
                        isRefreshing: store.isProcessing,
                        openFolderAction: store.openSelectedSessionFolder,
                        regenerateAction: { store.regenerateSummary(for: session) }
                    )

                    ScrollView {
                        WorkbenchResultDocument(session: session, tab: selectedTab)
                            .frame(maxWidth: AppTheme.contentColumn, alignment: .leading)
                            .padding(.horizontal, AppTheme.contentInset)
                            .padding(.top, AppTheme.space3)
                            .padding(.bottom, AppTheme.space6)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    WorkbenchAudioPlayerBar(
                        player: audioPlayer,
                        audioURL: store.audioURL(for: session)
                    )
                }
            }
        }
        .background(AppTheme.paper)
        .onAppear {
            audioPlayer.load(url: store.audioURL(for: session))
        }
        .onChange(of: session.id) { _, _ in
            selectedTab = .overview
            audioPlayer.load(url: store.audioURL(for: session))
        }
    }

}

/// 会议元信息的一「格」：图标 + 文字。
/// 正文文档里（行动项截止日、逐字稿时间戳）还在用它，所以保留；
/// 会议头那一行已经上移到窗口副标题，不再走这个视图。
struct WorkbenchSessionMeta: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(AppTheme.muted)
            .lineLimit(1)
    }
}

/// 结果页控制条：左边是一个**贴合内容宽度**的分段控件（原文 / 速览 / 纪要），
/// 右边是本场会议的两个页内动作，整行下面收一条发丝线。
///
/// 为什么不再铺液态玻璃：玻璃的质感来自折射「背后有变化的内容」。这条控制条背后是
/// 纯色纸面，没有东西可折射，玻璃就只剩一块发灰的底——用户的原话是「不精致、没质感」。
/// 现在的做法回到 macOS 原生的纪律：容器只包住真正需要边界的东西（三个 Tab，
/// 而且是贴合内容而不是拉通栏），右侧两个图标干脆不要底板，
/// 质感交给排印、2pt 内衬和 1pt 发丝线。
///
/// 为什么把两个图标和 Tab 放在同一行：它们和 Tab 一样都是「针对这一场会议的动作」，
/// 分两行放既白占一整行高度，也让右上角飘着两个孤立的小方块。
struct WorkbenchResultTabBar: View {
    @Binding var selection: MeetingResultTab
    let isRefreshing: Bool
    let openFolderAction: () -> Void
    let regenerateAction: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: AppTheme.space4) {
                segmentedControl
                Spacer(minLength: AppTheme.space4)
                pageActions
            }
            .frame(height: AppTheme.segmentRowHeight)

            // 发丝线把控制条和正文分开。它是这一行唯一的"边界"，
            // 所以只有 1pt，且不参与任何圆角——一旦带圆角就又变成"容器"了。
            Rectangle()
                .fill(AppTheme.rule)
                .frame(height: 1)
        }
        .frame(maxWidth: AppTheme.contentColumn)
        .padding(.horizontal, AppTheme.contentInset)
        // 会议头撤掉后，这条就是正文顶部第一件东西，上方留一档气口即可。
        .padding(.top, AppTheme.space4)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    /// 分段控件：轨道只比三个 Tab 宽一点点（**不拉通栏**）。
    /// 选中段靠「纸色填充 + 1pt 描边」立起来——三档并列时色块面积越大越吵，
    /// 所以不用主色实底，只在字体粗细上再补一档。
    private var segmentedControl: some View {
        HStack(spacing: 2) {
            ForEach(MeetingResultTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Text(tab.title)
                        .font(.system(size: 13, weight: isCurrent(tab) ? .semibold : .regular))
                        .foregroundStyle(isCurrent(tab) ? AppTheme.ink : AppTheme.muted)
                        .padding(.horizontal, AppTheme.space4)
                        .frame(height: AppTheme.segmentHeight)
                        .background(
                            isCurrent(tab) ? AppTheme.paper : Color.clear,
                            in: RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous)
                                .stroke(isCurrent(tab) ? AppTheme.rule : Color.clear, lineWidth: 1)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent(tab) ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            AppTheme.segmentTrack,
            in: RoundedRectangle(cornerRadius: AppTheme.segmentRadius, style: .continuous)
        )
        .fixedSize()
    }

    private func isCurrent(_ tab: MeetingResultTab) -> Bool {
        selection == tab
    }

    private var pageActions: some View {
        HStack(spacing: AppTheme.space1) {
            Button {
                regenerateAction()
            } label: {
                if isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(WorkbenchStripIconButtonStyle())
            .help("重新整理纪要")
            .accessibilityLabel("重新整理纪要")
            .disabled(isRefreshing)

            Button {
                openFolderAction()
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(WorkbenchStripIconButtonStyle())
            .help("打开录音文件夹")
            .accessibilityLabel("打开录音文件夹")
        }
    }
}

struct WorkbenchResultDocument: View {
    let session: MeetingSession
    let tab: MeetingResultTab

    var body: some View {
        switch tab {
        case .original:
            WorkbenchOriginalDocument(session: session)
        case .overview:
            WorkbenchOverviewDocument(session: session)
        case .minutes:
            WorkbenchMinutesDocument(session: session)
        }
    }
}

struct WorkbenchDocumentHeading: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
        }
    }
}

struct WorkbenchDocumentSectionHeading: View {
    let title: String
    let count: Int?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
            if let count {
                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 0)
        }
    }
}

struct WorkbenchOverviewDocument: View {
    let session: MeetingSession
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let summaryError = session.analysis.summaryError, !summaryError.isEmpty {
                WorkbenchSummaryFallbackNotice(message: summaryError)
            }

            if !overviewText.isEmpty {
                Text(overviewText)
                    .font(.system(size: 20, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !session.analysis.timeline.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.analysis.timeline.enumerated()), id: \.element.id) { index, item in
                        WorkbenchTimelineDocumentRow(item: item)
                        if index != session.analysis.timeline.count - 1 {
                            Divider()
                                .overlay(AppTheme.rule)
                        }
                    }
                }
            } else if overviewText.isEmpty {
                WorkbenchSummaryEmptyState(
                    title: "还没有生成速览",
                    message: emptyMessage,
                    actionTitle: "打开设置选择模型",
                    action: { store.showSettings = true }
                )
            }
        }
    }

    private var overviewText: String {
        session.analysis.overviewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyMessage: String {
        if session.analysis.summaryError != nil {
            return "整理模型这次没有返回可靠结果，原文仍然保留。可以更换本机或云端整理模型后重新整理。"
        }
        return "当前没有启用会后整理模型。逐字稿仍然由本机中文 Whisper 完成；选择一个整理模型后，这里会生成整场会议的快速概览。"
    }
}

struct WorkbenchMinutesDocument: View {
    let session: MeetingSession
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: 30) {
            if let summaryError = session.analysis.summaryError, !summaryError.isEmpty {
                WorkbenchSummaryFallbackNotice(message: summaryError)
            }

            if !minutesText.isEmpty {
                Text(minutesText)
                    .font(.system(size: 18, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(7)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if session.analysis.decisions.isEmpty && session.analysis.actions.isEmpty {
                WorkbenchSummaryEmptyState(
                    title: "还没有生成完整纪要",
                    message: "本地转写已经完成，但当前没有使用会后整理模型。选择一个模型后重新整理，可以生成会议叙述、决策和待办。",
                    actionTitle: "打开设置选择模型",
                    action: { store.showSettings = true }
                )
            } else {
                WorkbenchLocalSummaryNote()
            }

            if !session.analysis.decisions.isEmpty {
                Divider()
                    .overlay(AppTheme.rule)
                WorkbenchDocumentSectionHeading(
                    title: "决策与结论",
                    count: session.analysis.decisions.count
                )
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.analysis.decisions.enumerated()), id: \.element.id) { index, item in
                        WorkbenchDecisionDocumentRow(item: item)
                        if index != session.analysis.decisions.count - 1 {
                            Divider()
                                .overlay(AppTheme.rule)
                        }
                    }
                }
            }

            if !session.analysis.actions.isEmpty {
                Divider()
                    .overlay(AppTheme.rule)
                WorkbenchDocumentSectionHeading(
                    title: "待办",
                    count: session.analysis.actions.count
                )
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.analysis.actions.enumerated()), id: \.element.id) { index, item in
                        WorkbenchActionDocumentRow(item: item)
                        if index != session.analysis.actions.count - 1 {
                            Divider()
                                .overlay(AppTheme.rule)
                        }
                    }
                }
            }
        }
    }

    private var minutesText: String {
        session.analysis.minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WorkbenchOriginalDocument: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("\(session.createdAt.formatted(date: .numeric, time: .shortened)) · 原汁原味保留转写")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(AppTheme.muted)

            if session.transcriptSegments.isEmpty {
                WorkbenchEmptyHint(text: "转写还没有内容。")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.transcriptSegments.enumerated()), id: \.element.id) { index, segment in
                        WorkbenchTranscriptDocumentRow(segment: segment)
                        if index != session.transcriptSegments.count - 1 {
                            Divider()
                                .overlay(AppTheme.rule)
                        }
                    }
                }
            }
        }
    }
}

struct WorkbenchTimelineDocumentRow: View {
    let item: TimelineChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()

            Text(item.summary)
                .font(.system(size: 18, weight: .regular, design: .default))
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 16)
    }
}

struct WorkbenchDecisionDocumentRow: View {
    let item: InsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.timestamp?.clockLabel ?? "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                Spacer(minLength: 8)
                WorkbenchConfidenceChip(value: item.confidence)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(item.label)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text("依据：\(item.evidence)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 16)
    }
}

struct WorkbenchActionDocumentRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.timestamp?.clockLabel ?? "—")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                Spacer(minLength: 8)
                WorkbenchConfidenceChip(value: item.confidence)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.label)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if let priority = item.priority {
                        WorkbenchPriorityChip(priority: priority)
                    }
                }

                HStack(spacing: 12) {
                    if let dueText = item.dueText {
                        WorkbenchSessionMeta(text: "截止 \(dueText)", systemImage: "calendar")
                    }
                    if let timestamp = item.timestamp {
                        WorkbenchSessionMeta(text: timestamp.clockLabel, systemImage: "clock")
                    }
                }

                Text("依据：\(item.evidence)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 16)
    }
}

struct WorkbenchTranscriptDocumentRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 22) {
            Text(segment.start.clockLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
                .frame(width: 92, alignment: .leading)

            Text(segment.text)
                .font(.system(size: 17, weight: .regular, design: .default))
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
            Text(segment.confidence.confidenceLabel)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
        }
        .padding(.vertical, 16)
    }
}

struct WorkbenchSummaryFallbackNotice: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(AppTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text("整理模型未返回，已保留逐字稿；下面仅显示本地保守结果。")
                    .font(.callout)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                // 真实原因要看得见。原来它只喂给了 `.help`（鼠标悬停才出），
                // 于是界面上永远只有一句"未返回"，用户根本不知道为什么。
                Text(message)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .background(AppTheme.warning.opacity(0.10), in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                .stroke(AppTheme.warning.opacity(0.22), lineWidth: 1)
        )
        .help(message)
    }
}

struct WorkbenchSummaryEmptyState: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.text")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(AppTheme.muted)

            Text(title)
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            Text(message)
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: action) {
                Label(actionTitle, systemImage: "gearshape")
            }
            .buttonStyle(WorkbenchLightButtonStyle())
            .padding(.top, 4)
        }
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, minHeight: 260)
    }
}

struct WorkbenchLocalSummaryNote: View {
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal")
                .foregroundStyle(AppTheme.success)
            Text("本地保守整理只保留逐字稿中明确命中的决策和待办，不把普通讨论拼成纪要。")
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 4)
    }
}

struct WorkbenchAudioPlayerBar: View {
    @ObservedObject var player: MeetingAudioPlayer
    let audioURL: URL?

    private static let rateOptions: [Float] = [1, 1.25, 1.5, 2]

    @State private var isRateHovering = false
    @State private var isRatePopoverPresented = false

    var body: some View {
        VStack(spacing: AppTheme.space2) {
            // 左 / 中 / 右三区叠放：中区的传输键因此落在**整条播放器的水平中点**，
            // 而不是「跟着左边界排」。原来它贴在左侧、右半条全空，播放器看着像没做完。
            // 左右两区各自只占需要的宽度，不参与中区定位，所以中区永远是真居中。
            ZStack {
                // 左区：只在没有音频时占位，用来交代「为什么按钮是灰的」。
                HStack(spacing: AppTheme.space2) {
                    if !player.isAvailable {
                        Text("暂无可播放音频")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)

                // 中区：后退 15 / 播放暂停 / 前进 15
                transportGroup

                // 右区：倍速 + 时间
                HStack(spacing: AppTheme.space3) {
                    Spacer(minLength: 0)
                    rateMenu
                    timeReadout
                }
                .frame(maxWidth: .infinity)
            }

            Slider(
                value: Binding(
                    get: { player.currentTime },
                    set: { player.seek(to: $0) }
                ),
                in: 0...max(player.duration, 0.1)
            )
            .tint(AppTheme.accent)
            .disabled(!player.isAvailable)
            .accessibilityLabel("录音进度")
        }
        .padding(.horizontal, AppTheme.contentInset)
        .padding(.top, AppTheme.space3)
        .padding(.bottom, AppTheme.space4)
        .background(AppTheme.paperSoft)
        .overlay(alignment: .top) {
            Divider()
                .overlay(AppTheme.rule)
        }
        .onAppear {
            player.load(url: audioURL)
        }
        .onChange(of: audioURL) { _, newValue in
            player.load(url: newValue)
        }
    }

    /// 后退 / 播放 / 前进 属于同一个功能组，用 8pt 抱在一起。
    /// 原来 18pt 的间距把三个按钮摊成三块，反而看不出它们是一组。
    private var transportGroup: some View {
        HStack(spacing: AppTheme.space2) {
            Button {
                player.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
            }
            .buttonStyle(WorkbenchPlayerIconButtonStyle())
            .help("后退 15 秒")
            .accessibilityLabel("后退 15 秒")
            .disabled(!player.isAvailable)

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .semibold))
            }
            .buttonStyle(WorkbenchPlayerIconButtonStyle(emphasized: true))
            .help(player.isPlaying ? "暂停" : "播放")
            .accessibilityLabel(player.isPlaying ? "暂停" : "播放")
            .disabled(!player.isAvailable)

            Button {
                player.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
            }
            .buttonStyle(WorkbenchPlayerIconButtonStyle())
            .help("前进 15 秒")
            .accessibilityLabel("前进 15 秒")
            .disabled(!player.isAvailable)
        }
    }

    /// 倍速控件。走到现在这一步踩过四个坑，一并记下来：
    /// 1. `Menu` 不加 `.fixedSize()` 会吃掉横栏里的全部剩余宽度 →「1×」留在最左边、
    ///    系统下拉箭头被推到最右边，也就是「分开两地」。
    /// 2. `.borderlessButton` 会丢掉 label 自带的 background / overlay，而且会给 label
    ///    额外内缩约 4pt、**只缩左边**——实测左 6pt / 右 12pt，也就是「底色贴着倍速文字」。
    /// 3. 改成「自绘胶囊 + 透明 Menu 命中层」后外观对了，但**不好点**：透明层用
    ///    `Color.clear` + `maxWidth/maxHeight: .infinity` 铺在 ZStack 里，尺寸是由兄弟视图
    ///    间接推出来的，命中区和看得见的胶囊并不严格重合，点边缘会落空，
    ///    表现就是用户说的「有时候要点好几下才出来」。
    /// 4. 现在换成最直白的一件东西：**一个真按钮**，它的 label 就是那颗胶囊，
    ///    命中区 = 画出来的形状，不可能错位；点开是一个 popover 列表。
    ///    顺带除掉了「hover 状态变化触发菜单重绘」这类隐患（按钮重绘没有副作用）。
    private var rateMenu: some View {
        Button {
            isRatePopoverPresented = true
        } label: {
            HStack(spacing: AppTheme.space1) {
                Text("\(player.playbackRate.cleanRateLabel)×")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.ink)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, AppTheme.space3)   // 左右各 12pt，对称气口
            .frame(height: AppTheme.controlCompact)
            // paper 铺在 paperSoft 上对比度只有 1.02，等于一个看不出边界的脏底；
            // 悬停时整颗胶囊浮到 accentSoft，用来确认"这是一个可点的控件"。
            .background(isRateHovering ? AppTheme.accentSoft : AppTheme.paper, in: Capsule())
            .overlay(
                Capsule().stroke(isRateHovering ? AppTheme.ruleStrong : AppTheme.rule, lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        // `.plain` 不会像 `.borderlessButton` 那样剥掉 label 的底，也不会给 label 加内缩，
        // 所以胶囊的外形和命中区是同一个矩形，点哪儿都算。
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovering in
            guard player.isAvailable else { return }
            isRateHovering = hovering
        }
        .popover(isPresented: $isRatePopoverPresented) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Self.rateOptions, id: \.self) { rate in
                    Button {
                        player.setRate(rate)
                        isRatePopoverPresented = false
                    } label: {
                        HStack(spacing: AppTheme.space2) {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .opacity(isCurrentRate(rate) ? 1 : 0)
                            Text("\(rate.cleanRateLabel)×")
                                .font(.system(size: 12, weight: .medium))
                                .monospacedDigit()
                            Spacer(minLength: 0)
                        }
                        .foregroundStyle(AppTheme.ink)
                        .padding(.horizontal, AppTheme.space2)
                        .frame(height: 26)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppTheme.space1)
            .frame(width: 118)
        }
        .disabled(!player.isAvailable)
        .help("播放速度")
        .accessibilityLabel("播放速度")
    }

    private func isCurrentRate(_ rate: Float) -> Bool {
        abs(player.playbackRate - rate) < 0.001
    }

    private var timeReadout: some View {
        Text("\(player.currentTime.clockLabel) / \(player.duration.clockLabel)")
            .font(.caption)
            .foregroundStyle(AppTheme.muted)
            .monospacedDigit()
            .lineLimit(1)
            .fixedSize()
    }
}

struct WorkbenchFailureState: View {
    let session: MeetingSession
    let openFolderAction: () -> Void
    let retryAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchDarkChip(text: session.status.title, systemImage: session.status.icon)

                    // 会议名不在这里重复——窗口标题栏已经有它（第四轮已确立的规矩）。
                    Text(session.errorMessage ?? "录音未能启动。")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.86))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        retryAction()
                    } label: {
                        Label("重新处理", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle(emphasized: true))

                    Button {
                        openFolderAction()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle())
                }
            }

            Text("原始录音仍然保留在这台 Mac 上。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
        .workbenchDarkPanel()
    }
}

/// 录音 / 转写中的状态卡片。
///
/// 三处结构性修正：
///
/// 1. **卡片里不再放按钮。** 原来这里有个「停止处理」，但在录音阶段它调的是
///    `cancelProcessing()`，而那个方法第一行就是 `guard isProcessing else { return }`——
///    录音时 isProcessing 是 false，所以那颗按钮**点了完全没反应**，是颗死按钮。
///    同一个界面里标题栏还挂着「结束并转写」，于是出现两个"停止"，一个有效一个无效，
///    这正是「看不懂该点哪个」的来源。现在卡片回归只读，状态迁移只由标题栏
///    **一个**主按钮承担。顺带「打开文件夹」也撤了：录音刚开始，去翻文件夹没有意义。
///
/// 2. **不再重复一遍会议名。** 它已经在窗口标题栏，这里再来一遍 30pt 大白字，
///    就是第四轮刚消掉的那类重复。
///
/// 3. **录音阶段不再显示进度条。** 转写还没开始，`processingProgress` 恒为 0、
///    `processingStartedAt` 为 nil，所以原来整个录音过程都停在「0% / 刚刚开始」，
///    看着像卡死。现在录音阶段改走每秒一格的已用时长，进度条只在转写阶段出现。
///
/// 4. **进度区不再重复右上角的已用时长，也不再重复段号。** 详见 `progressBox` 的注释。
/// 录音 / 转写进行中的界面。
///
/// **为什么从深色改成浅色。** 第七轮把它做成了占满内容区的深色面板，但整个应用是
/// Cobalt 浅色工作台——纸面、墨字、一条品牌蓝。深色面板是全应用唯一的例外，
/// 读起来像在浅色纸上贴了一块黑板，正是「太土」「黑色部分」的来源。这里回到
/// 纸面 + 墨字，彩色只留给真正"活着"的信号：录音红点、音源波形、进度条。
///
/// **为什么信息变多了。** 原来只有：状态胶囊、计时、一段波形、一句话、一条进度。
/// 参考通义听悟的「实时记录」和钉钉 AI 听记的会中界面，两者都把**实时逐字稿**当主体
/// ——文字一行行滚出来、时间戳挂在左侧，用户随时能看到"它到底听清了什么"，
/// 这才是有信息量的等待。本项目管线本来就是分段转写、每段完成即写回
/// `session.transcriptSegments`（见 `MeetingStore` 的分段循环），所以直接把它们
/// 实时列出来即可，不必改管线。
///
/// 两阶段共用同一骨架（状态条 / 主体 / 页脚），只换主体：
/// - **录音中**：大号计时器当主角 + 两路音源在采集
/// - **转写中**：实时逐字稿当主角 + 段进度与预计剩余
struct WorkbenchProcessingState: View {
    let session: MeetingSession

    private var isRecordingPhase: Bool { session.status == .recording }

    private var segments: [TranscriptSegment] {
        session.transcriptSegments.sorted { $0.start < $1.start }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
            hairline
            content
            hairline
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(AppTheme.paperSoft)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous)
                .stroke(AppTheme.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusLarge, style: .continuous))
    }

    private var hairline: some View {
        Rectangle()
            .fill(AppTheme.rule)
            .frame(height: 1)
    }

    // MARK: - 状态条

    private var statusBar: some View {
        HStack(spacing: AppTheme.space3) {
            if isRecordingPhase {
                WorkbenchLiveDot()
            } else {
                Image(systemName: "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            Text(isRecordingPhase ? "录音中" : "正在转写")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.ink)

            Text(session.captureMode.subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)

            Spacer(minLength: AppTheme.space4)

            if !isRecordingPhase, let total = session.processingTotalChunks, total > 0 {
                Text("第 \(min(completedChunks + 1, total))/\(total) 段")
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(.horizontal, AppTheme.space5)
        .padding(.vertical, AppTheme.space4)
    }

    // MARK: - 主体

    @ViewBuilder
    private var content: some View {
        if isRecordingPhase {
            recordingBody
        } else {
            transcriptionBody
        }
    }

    /// 录音中：计时器是主角，两路音源各给一张卡。
    private var recordingBody: some View {
        VStack(spacing: AppTheme.space5) {
            Spacer(minLength: AppTheme.space4)

            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: AppTheme.space3) {
                    Text(elapsedClock(now: context.date))
                        .font(.system(size: 52, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.ink)

                    Text("正在采集，结束后自动在本地转写")
                        .font(.subheadline)
                        .foregroundStyle(AppTheme.muted)
                }
            }

            HStack(spacing: AppTheme.space3) {
                WorkbenchCaptureSourceCard(
                    title: "麦克风",
                    systemImage: "mic.fill",
                    detail: "这台 Mac 的输入设备"
                )
                WorkbenchCaptureSourceCard(
                    title: "系统声音",
                    systemImage: "speaker.wave.2.fill",
                    detail: "应用里播放的声音"
                )
            }
            .frame(maxWidth: 560)

            Spacer(minLength: AppTheme.space4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, AppTheme.space5)
    }

    /// 转写中：实时逐字稿是主角。
    private var transcriptionBody: some View {
        VStack(alignment: .leading, spacing: AppTheme.space2) {
            HStack(spacing: AppTheme.space3) {
                Text("实时逐字稿")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)

                Spacer(minLength: AppTheme.space3)

                Text(segments.isEmpty ? "正在识别第一段…" : "已识别 \(segments.count) 句")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.muted)
            }
            .padding(.horizontal, AppTheme.space5)
            .padding(.top, AppTheme.space4)

            liveTranscript
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var liveTranscript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: AppTheme.space3) {
                    if segments.isEmpty {
                        Text("它一边听一边转，第一批句子很快就会出现。")
                            .font(.callout)
                            .foregroundStyle(AppTheme.muted)
                    }

                    ForEach(segments) { segment in
                        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                            Text(segment.start.clockLabel)
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(AppTheme.muted)
                                .frame(width: 46, alignment: .leading)

                            Text(segment.text)
                                .font(.callout)
                                .foregroundStyle(AppTheme.ink)
                                .multilineTextAlignment(.leading)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(segment.id)
                    }

                    HStack(spacing: AppTheme.space3) {
                        Color.clear.frame(width: 46, height: 1)
                        WorkbenchTypingDots()
                    }
                    .id(Self.transcriptTailID)
                }
                .padding(.horizontal, AppTheme.space5)
                .padding(.bottom, AppTheme.space4)
            }
            .onChange(of: segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.22)) {
                    proxy.scrollTo(Self.transcriptTailID, anchor: .bottom)
                }
            }
        }
    }

    private static let transcriptTailID = "workbench-transcript-tail"

    // MARK: - 页脚

    private var footer: some View {
        VStack(alignment: .leading, spacing: AppTheme.space3) {
            if isRecordingPhase {
                // 录音没有"进度"可言，用不确定进度条表达"在跑"，不假装一个百分比。
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(AppTheme.danger)
            } else {
                HStack(spacing: AppTheme.space4) {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .tint(AppTheme.accent)

                    Text(percentText)
                        .font(.caption.weight(.medium))
                        .monospacedDigit()
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize()
                }
            }

            TimelineView(.periodic(from: .now, by: 15)) { context in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                    Text(footerNote(now: context.date))
                        .font(.caption)
                        .foregroundStyle(isNearRecordingLimit(now: context.date) ? AppTheme.danger : AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: AppTheme.space3)

                    if !isRecordingPhase, let eta = etaText(now: context.date) {
                        Text(eta)
                            .font(.caption)
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize()
                    }
                }
            }
        }
        .padding(.horizontal, AppTheme.space5)
        .padding(.vertical, AppTheme.space4)
    }

    /// 页脚一句话。录音阶段在临近上限时改报倒计时——
    /// 录音到点是**直接 `stopRecording()`**、没有任何预告的（原来的 B6），
    /// 主计时器旁边随时能看到"还剩多久"是这里唯一能做的补救。
    private func footerNote(now: Date) -> String {
        guard isRecordingPhase else {
            return "每段完成后立即保存，重开应用会从未完成的段继续。"
        }
        let remaining = MeetingStore.maxRecordingSeconds - max(0, now.timeIntervalSince(session.createdAt))
        if remaining <= Self.recordingLimitWarningWindow {
            let minutes = max(1, Int((remaining / 60).rounded(.up)))
            return "录音会在约 \(minutes) 分钟后自动停止，请及时结束并保存。"
        }
        return "原始录音实时写入本机，不会上传。"
    }

    private static let recordingLimitWarningWindow: TimeInterval = 15 * 60

    private func isNearRecordingLimit(now: Date) -> Bool {
        guard isRecordingPhase else { return false }
        let elapsed = max(0, now.timeIntervalSince(session.createdAt))
        return MeetingStore.maxRecordingSeconds - elapsed <= Self.recordingLimitWarningWindow
    }

    // MARK: - 取值

    private var completedChunks: Int {
        max(0, session.processingCompletedChunks ?? 0)
    }

    private var progress: Double {
        max(0, min(1, session.processingProgress ?? 0))
    }

    private var percentText: String {
        "\(Int((progress * 100).rounded()))%"
    }

    private func elapsedClock(now: Date) -> String {
        let startedAt = isRecordingPhase ? session.createdAt : session.processingStartedAt
        guard let startedAt else { return "00:00" }
        return max(0, now.timeIntervalSince(startedAt)).clockLabel
    }

    /// 预计剩余：按「已完成段的平均耗时」外推。
    /// 一段都还没完成时不报数——宁可不说，也不要给一个每次都乱跳的假数。
    private func etaText(now: Date) -> String? {
        let done = Double(completedChunks)
        let total = Double(session.processingTotalChunks ?? 0)
        guard done >= 1, total > done, let startedAt = session.processingStartedAt else {
            return nil
        }
        let perChunk = now.timeIntervalSince(startedAt) / done
        let remaining = perChunk * (total - done)
        guard remaining.isFinite, remaining > 0 else { return nil }
        return "约剩 \(remaining.clockLabel)"
    }
}

/// 录音中的呼吸红点。用 `TimelineView` 驱动而不是 `repeatForever` 动画：
/// 后者在视图被复用/重建时容易停在半透明那一帧，读起来像"坏了"。
struct WorkbenchLiveDot: View {
    var color: Color = AppTheme.danger

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            let bright = Int(context.date.timeIntervalSinceReferenceDate / 0.5) % 2 == 0
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .opacity(bright ? 1 : 0.32)
        }
    }
}

/// 一路音源（麦克风 / 系统声音）的采集卡片。
struct WorkbenchCaptureSourceCard: View {
    let title: String
    let systemImage: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space3) {
            HStack(spacing: AppTheme.space2) {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)

                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
            }

            WorkbenchLevelBars()

            Text(detail)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
        }
        .padding(AppTheme.space4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            AppTheme.paper,
            in: RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
                .stroke(AppTheme.rule, lineWidth: 1)
        )
    }
}

/// 采集电平柱。**这是装饰性的活动指示，不是真实电平表**——
/// 真正的电平需要从录音引擎拉 tap，本轮没动引擎，所以这里不谎报数值，
/// 只表达"有信号在进来"。
struct WorkbenchLevelBars: View {
    private let barCount = 22

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20.0)) { context in
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(AppTheme.accent.opacity(0.78))
                        .frame(width: 3, height: barHeight(for: index, at: context.date))
                }
            }
            .frame(height: 26, alignment: .center)
        }
    }

    private func barHeight(for index: Int, at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let slow = sin(t * 1.7 + Double(index) * 0.9) * 0.5 + 0.5
        let fast = sin(t * 3.1 + Double(index) * 0.55) * 0.5 + 0.5
        return 5 + (slow * 0.4 + fast * 0.6) * 21
    }
}

/// 「还在继续」的三个点，替代光标。
struct WorkbenchTypingDots: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.4)) { context in
            let step = Int(context.date.timeIntervalSinceReferenceDate / 0.4) % 3
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(AppTheme.accent.opacity(index == step ? 0.95 : 0.28))
                        .frame(width: 5, height: 5)
                }
            }
        }
    }
}

struct WorkbenchSnapshotBand: View {
    let session: MeetingSession
    let openFolderAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        WorkbenchDarkChip(text: session.status.title, systemImage: session.status.icon)
                        if let duration = session.duration {
                            WorkbenchDarkChip(text: duration.clockLabel, systemImage: "clock")
                        }
                        WorkbenchDarkChip(text: "置信度 \(session.analysis.confidence.confidenceLabel)", systemImage: "scope")
                    }

                    Text(session.title)
                        .font(.system(size: 30, weight: .semibold, design: .default))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(summaryLine)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        openFolderAction()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle())
                }
            }

            HStack(spacing: 10) {
                WorkbenchDarkMeta(text: "更新 \(session.updatedAt.formatted(date: .omitted, time: .shortened))")
                WorkbenchDarkMeta(text: session.inputAudioFileName ?? session.sourceFileName)
                if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                    WorkbenchDarkMeta(text: errorMessage, tint: AppTheme.danger)
                }
            }
        }
        .workbenchDarkPanel()
    }

    private var summaryLine: String {
        if let first = session.analysis.overview.first {
            return first.label
        }
        if let firstTranscript = session.transcriptSegments.first {
            return firstTranscript.text.trimmedForPreview(limit: 120)
        }
        if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
            return errorMessage
        }
        return "转写完成后，速览、决策点和待办会出现在这里。"
    }

}

struct WorkbenchMetricStrip: View {
    let session: MeetingSession

    struct Item {
        let title: String
        let value: String
        let note: String?
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                ForEach(items.indices, id: \.self) { index in
                    WorkbenchMetricCard(item: items[index])
                }
            }
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    WorkbenchMetricCard(item: items[0])
                    WorkbenchMetricCard(item: items[1])
                }
                HStack(spacing: 12) {
                    WorkbenchMetricCard(item: items[2])
                    WorkbenchMetricCard(item: items[3])
                }
            }
        }
    }

    private var items: [Item] {
        [
            Item(title: "时长", value: session.duration?.clockLabel ?? "—", note: "本场会议"),
            Item(title: "片段", value: "\(session.transcriptSegments.count)", note: "转写分段"),
            Item(title: "决策", value: "\(session.analysis.decisions.count)", note: "明确收录"),
            Item(title: "待办", value: "\(session.analysis.actions.count)", note: "可执行项")
        ]
    }
}

struct WorkbenchMetricCard: View {
    let item: WorkbenchMetricStrip.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(item.title.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.08)
                .foregroundStyle(AppTheme.muted)

            Text(item.value)
                .font(.system(size: 24, weight: .semibold, design: .default))
                .foregroundStyle(AppTheme.ink)
                .monospacedDigit()

            if let note = item.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppTheme.space4)
        .background(AppTheme.paperSoft)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
                .stroke(AppTheme.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous))
    }
}

struct WorkbenchSectionStack: View {
    let session: MeetingSession

    var body: some View {
        VStack(spacing: 20) {
            WorkbenchSectionPanel(
                title: "速览",
                subtitle: "最先读的东西。",
                count: session.analysis.overview.count
            ) {
                sectionBody(for: session.analysis.overview, emptyText: "还没有足够明确的速览。") { item in
                    WorkbenchInsightRow(item: item)
                }
            }

            WorkbenchSectionPanel(
                title: "待办",
                subtitle: "优先级、依据和截止时间。",
                count: session.analysis.actions.count
            ) {
                sectionBody(for: session.analysis.actions, emptyText: "暂时没有提取到待办。") { item in
                    WorkbenchActionRow(item: item)
                }
            }

            WorkbenchSectionPanel(
                title: "时间切块",
                subtitle: "按时间切开看会议节奏。",
                count: session.analysis.timeline.count
            ) {
                sectionBody(for: session.analysis.timeline, emptyText: "没有足够的时间块。") { item in
                    WorkbenchTimelineRow(item: item)
                }
            }

            WorkbenchSectionPanel(
                title: "决策点",
                subtitle: "只收录有把握的结论。",
                count: session.analysis.decisions.count
            ) {
                sectionBody(for: session.analysis.decisions, emptyText: "没有提取到明确决策。") { item in
                    WorkbenchInsightRow(item: item)
                }
            }
        }
    }

    @ViewBuilder
    private func sectionBody<Item: Identifiable, Row: View>(
        for items: [Item],
        emptyText: String,
        @ViewBuilder row: @escaping (Item) -> Row
    ) -> some View {
        if items.isEmpty {
            WorkbenchEmptyHint(text: emptyText)
        } else {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    row(item)
                    if index != items.count - 1 {
                        Divider()
                            .overlay(AppTheme.rule)
                    }
                }
            }
        }
    }
}

struct WorkbenchSectionPanel<Content: View>: View {
    let title: String
    let subtitle: String
    let count: Int
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(AppTheme.muted)
                }

                Spacer(minLength: 8)

                Text("\(count)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(AppTheme.accentSoft, in: Capsule())
            }

            Divider()
                .overlay(AppTheme.rule)

            content()
        }
        .workbenchPanel()
    }
}

struct WorkbenchTranscriptPanel: View {
    let session: MeetingSession

    var body: some View {
        WorkbenchSectionPanel(
            title: "逐字稿",
            subtitle: "原汁原味保留原文。",
            count: session.transcriptSegments.count
        ) {
            if session.transcriptSegments.isEmpty {
                WorkbenchEmptyHint(text: "转写完成后，这里会出现逐字稿。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(session.transcriptSegments.enumerated()), id: \.element.id) { index, segment in
                        WorkbenchTranscriptRow(segment: segment)
                        if index != session.transcriptSegments.count - 1 {
                            Divider()
                                .overlay(AppTheme.rule)
                        }
                    }
                }
            }
        }
    }
}

struct WorkbenchInsightRow: View {
    let item: InsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                WorkbenchConfidenceChip(value: item.confidence)
            }

            if let timestamp = item.timestamp {
                WorkbenchMetaText(text: timestamp.clockLabel)
            }

            Text(item.evidence)
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkbenchTimelineRow: View {
    let item: TimelineChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                WorkbenchConfidenceChip(value: item.confidence)
            }

            Text(item.summary)
                .font(.callout)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)

            Text(item.evidence)
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkbenchActionRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 8)

                if let priority = item.priority {
                    WorkbenchPriorityChip(priority: priority)
                }

                WorkbenchConfidenceChip(value: item.confidence)
            }

            HStack(spacing: 10) {
                if let dueText = item.dueText {
                    WorkbenchMetaText(text: "截止 \(dueText)")
                }
                if let timestamp = item.timestamp {
                    WorkbenchMetaText(text: timestamp.clockLabel)
                }
            }

            Text(item.evidence)
                .font(.callout)
                .foregroundStyle(AppTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct WorkbenchTranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(segment.timeLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
                .frame(width: 78, alignment: .leading)

            VStack(alignment: .leading, spacing: 8) {
                Text(segment.text)
                    .font(.body)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                WorkbenchConfidenceChip(value: segment.confidence)
            }

            Spacer(minLength: 0)
        }
    }
}

struct WorkbenchEmptyHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(AppTheme.muted)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct WorkbenchEmptyState: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "waveform.and.mic")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 72, height: 72)
                .background(AppTheme.accentSoft, in: Circle())
                .accessibilityHidden(true)

            VStack(spacing: 9) {
                Text("开始记录第一场会议")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(AppTheme.ink)

                Text("录音结束后，会在本机转成文字，并把速览、纪要、决策和待办集中放在这里。")
                    .font(.callout)
                    .foregroundStyle(AppTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    store.startRecording()
                } label: {
                    Label("开始录音", systemImage: "record.circle")
                }
                .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
                .disabled(store.isRecording || store.isProcessing)

                Button {
                    store.importAudioPresented = true
                } label: {
                    Label("导入已有音频", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(WorkbenchLightButtonStyle())
                .disabled(store.isRecording || store.isProcessing)
            }

        }
        .frame(maxWidth: 620)
        .padding(.horizontal, 48)
        .padding(.vertical, 56)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}

struct WorkbenchSettingsPane: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var showTranscriptionDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("设置")
                        .font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text("转写始终在本机完成；下面只配置会后整理使用的模型。")
                        .font(.callout)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 12)

                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(WorkbenchToolbarIconButtonStyle())
                .help("关闭设置")
                .accessibilityLabel("关闭设置")
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 18)

            Divider()
                .overlay(AppTheme.rule)

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    WorkbenchSettingsGroup(
                        title: "会议整理模型",
                        subtitle: "只负责会后生成速览、纪要、决策和待办。中文逐字稿始终由本机 Whisper 完成。"
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: store.summarySettings.provider.icon)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(AppTheme.accent)
                                    .frame(width: 32, height: 32)
                                    .background(AppTheme.accentSoft, in: RoundedRectangle(
                                        cornerRadius: AppTheme.radiusSmall,
                                        style: .continuous
                                    ))

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(store.summarySettings.displayName)
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(store.summarySettings.provider.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.muted)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)

                                Menu {
                                    Section("本机") {
                                        ForEach(SummaryModelProvider.allCases.filter { $0.isLocal }) { provider in
                                            Button {
                                                store.updateSummaryProvider(provider)
                                            } label: {
                                                Label(provider.title, systemImage: provider.icon)
                                            }
                                        }
                                    }

                                    Section("云端") {
                                        ForEach(SummaryModelProvider.allCases.filter {
                                            !$0.isLocal && $0 != .custom
                                        }) { provider in
                                            Button {
                                                store.updateSummaryProvider(provider)
                                            } label: {
                                                Label(provider.title, systemImage: provider.icon)
                                            }
                                        }
                                    }

                                    Section("其他") {
                                        Button {
                                            store.updateSummaryProvider(.custom)
                                        } label: {
                                            Label(
                                                SummaryModelProvider.custom.title,
                                                systemImage: SummaryModelProvider.custom.icon
                                            )
                                        }
                                    }
                                } label: {
                                    HStack(spacing: 7) {
                                        Text("接入方式")
                                        Image(systemName: "chevron.up.chevron.down")
                                            .font(.caption2.weight(.semibold))
                                    }
                                }
                                .buttonStyle(WorkbenchLightButtonStyle())
                                .accessibilityLabel("更换会后整理接入方式")
                            }

                            Divider()
                                .overlay(AppTheme.rule)

                            if store.summarySettings.provider == .localRules {
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: "lock.shield")
                                        .foregroundStyle(AppTheme.success)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("当前不使用总结模型")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                        Text("完全离线，只保留逐字稿中明确的决策和待办。没有足够把握时，速览和纪要会留空而不是猜测。")
                                            .font(.callout)
                                            .foregroundStyle(AppTheme.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            } else {
                                VStack(alignment: .leading, spacing: 16) {
                                    VStack(alignment: .leading, spacing: 6) {
                                        Text("服务地址")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)
                                        TextField(
                                            "https://服务商域名/v1",
                                            text: $store.summarySettings.endpoint
                                        )
                                        .textFieldStyle(.roundedBorder)
                                        .font(.system(.body, design: .monospaced))
                                        Text("可填写 API 根地址或完整的聊天接口地址，应用会自动定位模型列表。")
                                            .font(.caption)
                                            .foregroundStyle(AppTheme.muted)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }

                                    if store.summarySettings.provider.requiresAPIKey {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text("API Key")
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(AppTheme.ink)
                                            SecureField(
                                                "只保存在 macOS 钥匙串",
                                                text: $store.summaryAPIKeyInput
                                            )
                                            .textFieldStyle(.roundedBorder)

                                            HStack(spacing: 10) {
                                                Button("保存到钥匙串") {
                                                    store.saveSummaryAPIKey()
                                                }
                                                .buttonStyle(WorkbenchLightButtonStyle())

                                                Button("清除") {
                                                    store.clearSummaryAPIKey()
                                                }
                                                .buttonStyle(.plain)
                                                .foregroundStyle(AppTheme.muted)

                                                Text(store.summaryAPIKeyStatus)
                                                    .font(.caption)
                                                    .foregroundStyle(AppTheme.muted)
                                            }
                                        }
                                    }

                                    HStack(alignment: .center, spacing: 12) {
                                        Button {
                                            store.testSummaryModel()
                                        } label: {
                                            if store.isLoadingSummaryModels {
                                                HStack(spacing: 7) {
                                                    ProgressView()
                                                        .controlSize(.small)
                                                    Text("正在获取模型…")
                                                }
                                            } else {
                                                Label("获取可用模型", systemImage: "arrow.triangle.2.circlepath")
                                            }
                                        }
                                        .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
                                        .disabled(
                                            store.summarySettings.endpoint
                                                .trimmingCharacters(in: .whitespacesAndNewlines)
                                                .isEmpty ||
                                                (store.summarySettings.provider.requiresAPIKey &&
                                                    store.summaryAPIKeyInput
                                                        .trimmingCharacters(in: .whitespacesAndNewlines)
                                                        .isEmpty) ||
                                                store.isLoadingSummaryModels
                                        )

                                        if !store.summaryTestStatus.isEmpty {
                                            Text(store.summaryTestStatus)
                                                .font(.caption)
                                                .foregroundStyle(
                                                    store.summaryTestStatus.hasPrefix("连接正常") ||
                                                        store.summaryTestStatus.hasPrefix("已获取") ||
                                                        store.summaryTestStatus.hasPrefix("已选择")
                                                        ? AppTheme.success
                                                        : store.summaryTestStatus.hasPrefix("正在")
                                                            ? AppTheme.muted
                                                            : AppTheme.danger
                                                )
                                                .lineLimit(3)
                                        }
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        Text(store.canEditSummaryModelManually ? "模型 ID" : "选择服务商模型")
                                            .font(.callout.weight(.semibold))
                                            .foregroundStyle(AppTheme.ink)

                                        if !store.availableSummaryModels.isEmpty {
                                            Menu {
                                                ForEach(store.availableSummaryModels, id: \.self) { model in
                                                    Button {
                                                        store.selectSummaryModel(model)
                                                    } label: {
                                                        if model == store.summarySettings.modelName {
                                                            Label(model, systemImage: "checkmark")
                                                        } else {
                                                            Text(model)
                                                        }
                                                    }
                                                }
                                            } label: {
                                                HStack(spacing: 8) {
                                                    Text(
                                                        store.summarySettings.modelName.isEmpty
                                                            ? "请选择一个模型"
                                                            : store.summarySettings.modelName
                                                    )
                                                    .lineLimit(1)
                                                    .truncationMode(.middle)
                                                    Spacer(minLength: 8)
                                                    Image(systemName: "chevron.up.chevron.down")
                                                        .font(.caption2.weight(.semibold))
                                                }
                                                .foregroundStyle(
                                                    store.summarySettings.modelName.isEmpty
                                                        ? AppTheme.muted
                                                        : AppTheme.ink
                                                )
                                                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                                                .padding(.horizontal, 12)
                                                .padding(.vertical, 9)
                                                .background(
                                                    AppTheme.paper,
                                                    in: RoundedRectangle(
                                                        cornerRadius: AppTheme.radiusSmall,
                                                        style: .continuous
                                                    )
                                                )
                                                .overlay(
                                                    RoundedRectangle(
                                                        cornerRadius: AppTheme.radiusSmall,
                                                        style: .continuous
                                                    )
                                                    .stroke(AppTheme.rule, lineWidth: 1)
                                                )
                                            }
                                            .menuStyle(.borderlessButton)
                                            .disabled(store.isLoadingSummaryModels)
                                            .help("选择服务商接口返回的总结模型")
                                            .accessibilityLabel("选择服务商模型")
                                            .accessibilityValue(store.summarySettings.modelName)
                                        } else if store.canEditSummaryModelManually {
                                            TextField(
                                                "服务商提供的模型 ID",
                                                text: Binding(
                                                    get: { store.summarySettings.modelName },
                                                    set: { store.updateManualSummaryModel($0) }
                                                )
                                            )
                                            .textFieldStyle(.roundedBorder)
                                            Text("接口没有返回模型列表时，才需要手动填写。")
                                                .font(.caption)
                                                .foregroundStyle(AppTheme.muted)
                                        } else {
                                            Label(
                                                store.isLoadingSummaryModels
                                                    ? "正在读取服务商的模型列表"
                                                    : "填写服务地址和密钥后，点击“获取可用模型”",
                                                systemImage: "list.bullet.rectangle"
                                            )
                                            .font(.callout)
                                            .foregroundStyle(AppTheme.muted)
                                        }
                                    }
                                }
                            }
                        }
                    }

                    let defaults = MeetingStore.defaultRuntimePaths()

                    WorkbenchSettingsGroup(
                        title: "本地转写",
                        subtitle: "录音结束后，Whisper 在这台 Mac 上生成原汁原味的逐字稿。"
                    ) {
                        VStack(alignment: .leading, spacing: 16) {
                            HStack(alignment: .center, spacing: 12) {
                                Image(systemName: transcriptionReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                                    .font(.system(size: 17, weight: .semibold))
                                    .foregroundStyle(transcriptionReady ? AppTheme.success : AppTheme.warning)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        (transcriptionReady ? AppTheme.success : AppTheme.warning).opacity(0.12),
                                        in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                                    )

                                VStack(alignment: .leading, spacing: 4) {
                                    Text("中文 Whisper")
                                        .font(.body.weight(.semibold))
                                        .foregroundStyle(AppTheme.ink)
                                    Text(
                                        transcriptionReady
                                            ? "本机组件已就绪，转写不受会后整理模型影响。"
                                            : "组件路径未找到，录音结束后无法开始转写。"
                                    )
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                                }

                                Spacer(minLength: 12)
                                WorkbenchPathState(isValid: transcriptionReady)
                            }

                            DisclosureGroup(
                                "高级：转写组件路径",
                                isExpanded: $showTranscriptionDetails
                            ) {
                                VStack(alignment: .leading, spacing: 16) {
                                    WorkbenchSettingsPathRow(
                                        title: "转写命令",
                                        subtitle: "本机 whisper-cli 的可执行文件。",
                                        path: $store.whisperCLIPath,
                                        defaultPath: defaults.cliURL.path,
                                        isValid: FileManager.default.isExecutableFile(atPath: store.whisperCLIPath),
                                        restoreAction: {
                                            store.whisperCLIPath = defaults.cliURL.path
                                            store.refreshPreferences()
                                        }
                                    )

                                    Divider()
                                        .overlay(AppTheme.rule)

                                    WorkbenchSettingsPathRow(
                                        title: "中文模型",
                                        subtitle: "模型越大通常越准，但处理时间和内存占用也会增加。",
                                        path: $store.whisperModelPath,
                                        defaultPath: defaults.modelURL.path,
                                        isValid: FileManager.default.fileExists(atPath: store.whisperModelPath),
                                        restoreAction: {
                                            store.whisperModelPath = defaults.modelURL.path
                                            store.refreshPreferences()
                                        }
                                    )
                                }
                                .padding(.top, 8)
                            }
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(AppTheme.ink)
                        }
                    }
                }
                .padding(24)
            }
            .background(AppTheme.paper)
        }
        .frame(minWidth: 700, minHeight: 620)
        .onAppear {
            store.loadSummaryModelsIfNeeded()
        }
        .onChange(of: store.whisperCLIPath) { _, _ in
            store.refreshPreferences()
        }
        .onChange(of: store.whisperModelPath) { _, _ in
            store.refreshPreferences()
        }
        .onChange(of: store.summarySettings.modelName) { _, _ in
            store.refreshPreferences()
        }
        .onChange(of: store.summarySettings.endpoint) { _, _ in
            store.invalidateSummaryModels()
            store.refreshPreferences()
        }
        .onChange(of: store.summaryAPIKeyInput) { _, _ in
            store.summaryAPIKeyInputDidChange()
        }
    }

    private var transcriptionReady: Bool {
        FileManager.default.isExecutableFile(atPath: store.whisperCLIPath) &&
            FileManager.default.fileExists(atPath: store.whisperModelPath)
    }
}

struct WorkbenchSettingsGroup<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            content()
        }
        .padding(20)
        .background(AppTheme.paperSoft)
        .overlay(
            RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
                .stroke(AppTheme.rule, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous))
    }
}

struct WorkbenchSettingsPathRow: View {
    let title: String
    let subtitle: String
    @Binding var path: String
    let defaultPath: String
    let isValid: Bool
    let restoreAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                }
                Spacer(minLength: 10)
                WorkbenchPathState(isValid: isValid)
            }

            TextField("本机路径", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("默认：\(defaultPath)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .textSelection(.enabled)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Button("恢复默认") {
                    restoreAction()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.accent)
            }
        }
    }
}

struct WorkbenchSettingsPathCard: View {
    let title: String
    let subtitle: String
    let systemImage: String
    @Binding var path: String
    let defaultPath: String
    let isValid: Bool
    let restoreAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(AppTheme.accent, in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                        .foregroundStyle(AppTheme.ink)

                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                WorkbenchPathState(isValid: isValid)
            }

            TextField("请输入本机路径", text: $path)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("默认值：\(defaultPath)")
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .textSelection(.enabled)

            HStack {
                Button("恢复默认") {
                    restoreAction()
                }
                .buttonStyle(WorkbenchLightButtonStyle())

                Spacer(minLength: 8)

                Text(isValid ? "路径已找到" : "当前路径未找到，会在运行时回落到默认路径。")
                    .font(.caption)
                    .foregroundStyle(isValid ? AppTheme.success : AppTheme.warning)
            }
        }
        .workbenchPanel()
    }
}

struct WorkbenchPathState: View {
    let isValid: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isValid ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.caption2.weight(.semibold))
            Text(isValid ? "已找到" : "未找到")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(isValid ? AppTheme.success : AppTheme.warning)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(AppTheme.accentSoft, in: Capsule())
    }
}

struct WorkbenchStatusDot: View {
    let status: MeetingStatus

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }

    private var color: Color {
        switch status {
        case .recording:
            return AppTheme.danger
        case .processing:
            return AppTheme.warning
        case .ready:
            return AppTheme.success
        case .failed:
            return AppTheme.danger
        }
    }
}

struct WorkbenchStatusChip: View {
    let status: MeetingStatus

    var body: some View {
        WorkbenchDarkChip(text: status.title, systemImage: status.icon)
    }
}

struct WorkbenchDarkChip: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption2.weight(.semibold))
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.09), in: Capsule())
        .overlay(
            Capsule()
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        )
    }
}

struct WorkbenchDarkMeta: View {
    let text: String
    var tint: Color = .white.opacity(0.72)

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color.white.opacity(0.06), in: Capsule())
            .overlay(
                Capsule()
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            )
    }
}

struct WorkbenchMetaText: View {
    let text: String
    var inverse: Bool = false

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(inverse ? .white.opacity(0.78) : AppTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(inverse ? Color.white.opacity(0.08) : AppTheme.accentSoft, in: Capsule())
            .overlay(
                Capsule()
                    .stroke(inverse ? Color.white.opacity(0.12) : Color.clear, lineWidth: 1)
            )
    }
}

/// 自定义 ButtonStyle 不会自动响应 `.disabled()`，这里统一读环境开关降透明度，
/// 保证「没有音频可播 / 正在重新整理」这类不可用状态看得出来。
struct WorkbenchDisabledDim<Content: View>: View {
    @Environment(\.isEnabled) private var isEnabled
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content.opacity(isEnabled ? 1 : 0.35)
    }
}

struct WorkbenchToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(AppTheme.ink)
                .frame(width: AppTheme.controlRegular, height: AppTheme.controlRegular)
                .background(
                    configuration.isPressed ? AppTheme.rule : AppTheme.paperSoft,
                    in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                        .stroke(AppTheme.rule, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.96 : 1)
                .opacity(configuration.isPressed ? 0.88 : 1)
        }
    }
}

/// 玻璃条里的图标按钮：**不自绘底盘**。
/// 玻璃条本身已经是一件有体积的容器，再给里面的每个图标各套一个方底，
/// 就成了「按钮里套按钮」——右上角那两颗孤立小方块的毛病会在新容器里复发。
/// 所以这里只留字形，悬停 / 按下时才浮出一层很浅的圆底，也就是 macOS 工具栏的惯用做法。
struct WorkbenchStripIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            WorkbenchStripGlyph(configuration: configuration)
        }
    }
}

private struct WorkbenchStripGlyph: View {
    let configuration: ButtonStyleConfiguration
    @State private var isHovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(isHovering || configuration.isPressed ? AppTheme.ink : AppTheme.muted)
            .frame(width: AppTheme.stripIconHit, height: AppTheme.stripIconHit)
            .background(hoverSurface, in: Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }

    private var hoverSurface: Color {
        (isHovering || configuration.isPressed) ? AppTheme.rule.opacity(0.55) : .clear
    }
}

struct WorkbenchPlayerIconButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(emphasized ? .white : AppTheme.ink)
                .frame(
                    width: emphasized ? AppTheme.controlEmphasis : AppTheme.controlCompact,
                    height: emphasized ? AppTheme.controlEmphasis : AppTheme.controlCompact
                )
                .background(
                    emphasized ? AppTheme.ink : AppTheme.paper,
                    in: Circle()
                )
                .overlay(
                    Circle()
                        .stroke(emphasized ? AppTheme.ink : AppTheme.rule, lineWidth: 1)
                )
                .scaleEffect(configuration.isPressed ? 0.95 : 1)
                .opacity(configuration.isPressed ? 0.88 : 1)
        }
    }
}

struct WorkbenchConfidenceChip: View {
    let value: Double

    var body: some View {
        Text("把握 \(value.confidenceLabel)")
            .font(.caption.weight(.semibold))
            .foregroundStyle(AppTheme.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(AppTheme.accentSoft, in: Capsule())
    }
}

struct WorkbenchPriorityChip: View {
    let priority: PriorityLevel

    var body: some View {
        Text("\(priority.friendlyLabel)优先")
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(background, in: Capsule())
    }

    private var color: Color {
        switch priority {
        case .p1:
            return AppTheme.danger
        case .p2:
            return AppTheme.warning
        case .p3:
            return AppTheme.muted
        }
    }

    private var background: Color {
        AppTheme.accentSoft
    }
}

struct WorkbenchLightButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(emphasized ? .white : AppTheme.ink)
                .padding(.horizontal, AppTheme.space3)
                .padding(.vertical, 10)
                .background(emphasized ? AppTheme.accent : AppTheme.paperSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                        .stroke(emphasized ? AppTheme.accent : AppTheme.rule, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
                .opacity(configuration.isPressed ? 0.88 : 1)
        }
    }
}

struct WorkbenchDarkButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            configuration.label
                .font(.callout.weight(.semibold))
                .foregroundStyle(emphasized ? .white : .white.opacity(0.90))
                .padding(.horizontal, AppTheme.space3)
                .padding(.vertical, 10)
                .background(emphasized ? AppTheme.accent : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                        .stroke(emphasized ? AppTheme.accent : Color.white.opacity(0.12), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
                .opacity(configuration.isPressed ? 0.88 : 1)
        }
    }
}

private extension String {
    func trimmedForPreview(limit: Int) -> String {
        let clean = trimmingCharacters(in: .whitespacesAndNewlines)
        if clean.count <= limit { return clean }
        return String(clean.prefix(limit)) + "…"
    }
}

private extension Float {
    var cleanRateLabel: String {
        if rounded() == self {
            return String(Int(self))
        }
        return String(format: "%.2f", self)
            .replacingOccurrences(of: "0", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
    }
}


/// 标题栏动作按钮的**统一底盘**：实底、无描边、胶囊。
///
/// **为什么三个动作必须共用一套底盘。** 原来只给主操作铺底、另外两个用 `.bordered`
/// 的发丝描边，标题栏上就成了「一个真按钮 + 两个空心框」——空心框挂在灰底上读起来
/// 像占位符、不像能点的东西，整条也就没了质感（用户第九轮原话「没质感了」）。
/// 统一成实底后，主次只由**填充色**一档表达（纸白 → 品牌蓝），不再混用「有底 / 没底」。
///
/// **为什么都用胶囊。** `.bordered` 的圆角约 6pt，自绘胶囊是 17pt，两种圆角并排
/// 就是两套语言。统一取胶囊，与 macOS 26 强调按钮的口径一致；方形图标钮也因此
/// 自然收成一个正圆，和两颗胶囊同属一族。
///
/// **为什么不用 `.borderedProminent` + `.tint`。** 系统只在「窗口是最前面那个」时
/// 才给它上色，窗口一失活就被抹成灰描边——实测那一版标题栏的蓝色像素是 **0**。
/// 这里自己画底，颜色不看窗口活跃状态。
///
/// 自定义 `ButtonStyle` 不会自动响应 `.disabled()`，所以外面包 `WorkbenchDisabledDim`。
struct WorkbenchToolbarButtonStyle: ButtonStyle {
    /// 底盘填充色。传 `nil` 表示次级动作：铺纸白底、配墨色字。
    var tint: Color?
    /// 纯图标按钮（设置）：收成正方形，不横向撑开。
    var iconOnly: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        WorkbenchDisabledDim {
            let fill = tint ?? AppTheme.paper
            configuration.label
                .font(.system(size: 13, weight: tint == nil ? .medium : .semibold))
                .foregroundStyle(tint == nil ? AppTheme.ink : Color.white)
                .padding(.horizontal, iconOnly ? 0 : AppTheme.space3)
                .frame(
                    width: iconOnly ? AppTheme.controlRegular : nil,
                    height: AppTheme.controlRegular
                )
                .background(fill, in: Capsule(style: .continuous))
                .opacity(configuration.isPressed ? 0.72 : 1)
                .contentShape(Capsule(style: .continuous))
        }
    }
}
