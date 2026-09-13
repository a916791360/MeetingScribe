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
        // 只挂模型名，不挂服务商。存下来的 `summaryModel` 是「服务商 · 模型」，
        // 前半截在这条一行的副标题里是噪音（见 `MeetingAnalysis.modelLabel`）。
        if let model = analysis.modelLabel { parts.append(model) }
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
    // 三个动作按角色分层，而不是三个同样轻重的裸字形（**顺序即此**）：
    //   主操作 → 开始录音 / 结束并转写 / 停止处理 / 重新处理（实底主色，排在最左）
    //   次要 → 导入音频（无填充底盘）
    //   全局 → 设置（方形图标钮，齿轮是通用符号，不给文字）
    //
    // 为什么没有会话时整条撤掉：空态正文里已经有一对很大的「开始录音 / 导入音频」，
    // 标题栏再摆一遍同样的两个动作，同一屏就有四处入口在做两件事；而且此刻选中的
    // 是"什么都没有"，工具栏却在喊"开始录音"，权重给错了对象。
    // 设置是 app 级动作、不针对某场会议，跟着一起收走，改由 app 菜单的「设置…（⌘,）」
    // 承担——那本来就是 macOS 上设置该在的地方。
    @ToolbarContentBuilder
    private var workbenchToolbar: some ToolbarContent {
        if let session = store.workspaceSession {
            // ⚠️ 三个动作装在**同一个** ToolbarItem 里，而不是三个并列的 ToolbarItem。
            //
            // 为什么：macOS 会把同一 placement 的相邻 toolbar item 收成「一组」，组内间距
            // 由系统拍板。实测这组间距只有 **1pt** —— 像素核验：导入音频胶囊右沿 x=2430、
            // 开始录音左沿 x=2433，中间只隔 2px@2x（1pt）；开始录音与齿轮之间同样 1pt。
            // 三颗胶囊因此糊成一条，深色下更像同一个控件被切了三刀（用户原话：
            // 「很怪，不规范，贴一起了，尤其深夜模式下，还有重叠的地方」）。
            // 装进一个间距自控的 HStack 之后，间距不再受工具栏分组启发式摆布。
            //
            // 8pt 是 macOS 工具栏项目之间的标准间距，三颗因此既分开、又仍读成一排。
            //
            // **顺序：主操作在左、导入在右（v0.6.2 按用户要求调换）**。
            // 原来是「导入音频 · 开始录音 · 设置」，主操作被夹在中间；
            // 现在主操作紧挨窗口左侧一侧，视线从侧边栏扫过来第一眼就是它，
            // 低频的「导入音频」退到靠设置那一侧。主次仍由填充色区分，不由左右区分。
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: AppTheme.space2) {
                    Button {
                        performPrimaryAction(for: session)
                    } label: {
                        Label(primaryTitle(for: session), systemImage: primaryIcon(for: session))
                    }
                    .labelStyle(.titleAndIcon)
                    // 实底 + 着色：整条里唯一的高权重，录制/处理中整体转为危险色。
                    .buttonStyle(WorkbenchToolbarButtonStyle(tint: primaryTint))
                    .help(primaryTitle(for: session))

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
        // 这里的颜色是**当底色**用的（上面压白字），所以走 `*Fill` 那一支：
        // 它们钉在浅色档的数值上，深色模式下不会跟着提亮，白字才保得住 4.6:1。
        if store.isRecording || store.isProcessing {
            return AppTheme.dangerFill
        }
        return AppTheme.accentFill
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
                        WorkbenchResultDocument(
                            session: session,
                            tab: selectedTab,
                            onSelectTab: { selectedTab = $0 }
                        )
                        // 速览页的要点要能点时间锚跳播放，而播放器是这一层的
                        // `@StateObject`（播放条也在这一层）。注入到文档子树里，
                        // 免得把播放器一路当参数传到最底下的那一行。
                        .environmentObject(audioPlayer)
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
            // 11pt，与时间轨同一档：都是"行内元信息"，不该有两种字号。
            .font(.system(size: 11, weight: .medium))
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
/// 分段控件的**唯一一套画法**：浅底轨道 + 纸色凸起段 + 1pt 描边。
///
/// 抽出来是为了不让应用里长出第二种分段语言 —— 结果页的 Tab 和设置里的
/// 「跟随系统 / 浅色 / 深色」必须长得一模一样，只是选项不同。
/// 选中段靠「纸色填充 + 1pt 描边」立起来，不用主色实底：三档并列时色块面积
/// 越大越吵，权重已经在字体粗细上补过一档。
struct WorkbenchSegmentStrip<Item: Hashable>: View {
    let items: [Item]
    let label: (Item) -> String
    @Binding var selection: Item

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.self) { item in
                Button {
                    selection = item
                } label: {
                    // 选中段换字重（regular → semibold），字重一变**字宽就变**，
                    // 而三个格子是贴合内容排的 → 整个控件会随选中项呼吸，
                    // 相邻两格跟着左右挪零点几到一点几 pt。切 Tab 时看得见抖。
                    //
                    // 解决办法不是"别换字重"（字重是这个控件唯一的强选中信号），
                    // 而是**先把格子撑到上限**：底下垫一份透明的 semibold 同文案，
                    // 它不显示、但参与布局 → 每格恒等于 semibold 的字宽，
                    // 选中谁都不再改宽度。（只垫字重，不垫字号/内衬，视觉零变化。）
                    ZStack {
                        Text(label(item))
                            .font(.system(size: 13, weight: .semibold))
                            .opacity(0)
                            .accessibilityHidden(true)

                        Text(label(item))
                            .font(.system(size: 13, weight: isCurrent(item) ? .semibold : .regular))
                            .foregroundStyle(isCurrent(item) ? AppTheme.ink : AppTheme.muted)
                    }
                    .padding(.horizontal, AppTheme.space4)
                    .frame(height: AppTheme.segmentHeight)
                    .background(
                        isCurrent(item) ? AppTheme.segmentSelected : Color.clear,
                        in: RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous)
                            .stroke(isCurrent(item) ? AppTheme.rule : Color.clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: AppTheme.segmentRadius - 2, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCurrent(item) ? .isSelected : [])
            }
        }
        .padding(2)
        .background(
            AppTheme.segmentTrack,
            in: RoundedRectangle(cornerRadius: AppTheme.segmentRadius, style: .continuous)
        )
        // 贴合内容宽度（不拉通栏），且因为上面垫了 semibold 占位，这个宽度是恒定的。
        .fixedSize()
    }

    private func isCurrent(_ item: Item) -> Bool {
        selection == item
    }
}

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

    /// 轨道只比三个 Tab 宽一点点（**不拉通栏**）。
    /// 画法交给 `WorkbenchSegmentStrip`，与设置里的外观三选一共用。
    private var segmentedControl: some View {
        WorkbenchSegmentStrip(
            items: MeetingResultTab.allCases,
            label: \.title,
            selection: $selection
        )
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
    /// 换页的回调。速览页的「查看全部」要跳到纪要页 —— 只在那里摊得开。
    let onSelectTab: (MeetingResultTab) -> Void

    var body: some View {
        switch tab {
        case .original:
            WorkbenchOriginalDocument(session: session)
        case .overview:
            WorkbenchOverviewDocument(session: session, onSelectTab: onSelectTab)
        case .minutes:
            WorkbenchMinutesDocument(session: session, onSelectTab: onSelectTab)
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

struct WorkbenchDocumentSectionHeading<Trailing: View>: View {
    let title: String
    let count: Int?
    /// 标题行右端的东西（速览页用来放「查看全部」）。
    ///
    /// 有它才能保证尾部动作和标题**同处一条基线**：把按钮摆在标题下面或
    /// 单独开一行，它会读成另一个区块，而不是"这个区块的延伸"。
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space2) {
            Text(title)
                .font(AppType.sectionTitle)
                .foregroundStyle(AppTheme.ink)
            if let count {
                // 「4 条」比孤零零一个「4」有用：后者要靠上下文才猜得出是数量。
                Text("\(count) 条")
                    .font(AppType.documentMeta)
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.muted)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension WorkbenchDocumentSectionHeading where Trailing == EmptyView {
    /// 不带尾部动作的写法（纪要页两处沿用）。
    ///
    /// 有了这个 init，既有调用点一行都不用改 —— 加泛型参数不会变成一次全局改写。
    init(title: String, count: Int?) {
        self.init(title: title, count: count, trailing: { EmptyView() })
    }
}

/// 速览页：**先给结论，再给抓手，最后给全文**。
///
/// 页面顺序是刻意排成一条下滑的漏斗，而不是"把有的东西都摞上来"：
///
/// | 位置 | 区块 | 回答的问题 |
/// |---|---|---|
/// | 1 | 一句话结论 | 这场会最后定了什么？（读完这行就能走） |
/// | 2 | 要点（带时间锚） | 有哪几件事？（锚可点，直接跳去听） |
/// | 3 | 决策摘要 | 决定了什么？ |
/// | 4 | 待办摘要（含 owner） | 谁要做什么？ |
/// | 5 | 待确认 | 还有什么没定？ |
/// | 6 | 会议概述 | 完整脉络（200~400 字） |
/// | 7 | 时间轨 | 每一段都聊了什么 |
///
/// **为什么「概述」排在第 6 位、而不是像以前那样霸着第一位**：验收标准是
/// 「一屏内看到结论 + 要点 + 谁做什么」，而概述是 200~400 字的一段话 ——
/// 它摆在最前面，会把下面四块全部推到折线以下。它不是不重要，
/// 是**不紧急**：前五块是索引，它和第七块是正文。
///
/// 老会话没有 `headline` / `overviewBullets` / `openQuestions`（2A 之前存盘的），
/// 那几块直接消失，页面退化回"导语 + 时间轨"—— 和升级前一模一样，
/// 而不是一屏空白。见 `MeetingAnalysis` 的 decodeIfPresent。
struct WorkbenchOverviewDocument: View {
    let session: MeetingSession
    /// 跳到别的结果页。摘要行尾的「查看全部」用它。
    let onSelectTab: (MeetingResultTab) -> Void
    @EnvironmentObject private var store: MeetingStore
    /// 时间锚要能跳播放，所以这一页要拿到播放器。
    /// 走 `environmentObject` 而不是逐层传参：`WorkbenchResultDocument` 只是
    /// 一个 switch，不该为了传一个播放器而被改造成转发管道。
    @EnvironmentObject private var player: MeetingAudioPlayer

    /// 速览页最多列几条决策 / 待办。超出的走行尾「查看全部」。
    ///
    /// 3 是"一屏内"倒推出来的：三段小标题 + 三行摘要 ≈ 200pt，
    /// 加上结论和要点仍在一屏之内。列全（长会 16 条）这一页就只能当纪要读了。
    private static let summaryLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space6) {
            // 提醒横幅只在「下面真的有本地保守结果」时才给。
            //
            // 它那句话是「下面仅显示本地保守结果」——下面空着的时候，这句话就是在
            // 替空态重复一遍「没生成出东西」：同一屏里两处说同一件事，而空态那个
            // 说得更完整（还带原因和出路）。所以让空态独家承担，横幅撤走。
            if let notice = session.analysis.noticeMessage, hasVisibleContent {
                WorkbenchSummaryFallbackNotice(
                    message: notice,
                    headline: session.analysis.isLocalFallback
                        ? "整理模型未返回，已保留逐字稿；下面仅显示本地保守结果。"
                        : "整理模型这次的结果不完整，下面可能缺少部分内容。"
                )
            }

            if let headline {
                WorkbenchOverviewHeadline(text: headline)
            }

            if !bullets.isEmpty {
                WorkbenchOverviewBulletsSection(
                    bullets: bullets,
                    // 播放器没加载出音频时不给跳转 —— 点了没反应比不可点更糟。
                    onJump: player.isAvailable ? { jump(to: $0) } : nil
                )
            }

            summarySection(
                title: "决策与结论",
                items: session.analysis.decisions.map {
                    WorkbenchOverviewSummaryRow.Item(
                        time: $0.timestamp?.clockLabel,
                        label: $0.label,
                        owner: nil
                    )
                }
            )

            summarySection(
                title: "待办",
                items: session.analysis.actions.map {
                    WorkbenchOverviewSummaryRow.Item(
                        time: $0.timestamp?.clockLabel,
                        label: $0.label,
                        owner: $0.owner
                    )
                }
            )

            if !openQuestions.isEmpty {
                WorkbenchOverviewOpenQuestionsSection(questions: openQuestions)
            }

            // 概述：老会话（没有 headline / 要点）时它是**第一块**，这时候不该给它
            // 小标题 —— 它就是导语本身，顶上再加一个「会议概述」纯属自我说明。
            // 新会话里它排在摘要后面，才需要一个标题说明"下面是全文"。
            if !overviewText.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.space3) {
                    if hasQuickRead {
                        WorkbenchDocumentSectionHeading(title: "会议概述", count: nil)
                    }
                    // 导语是「整场概览」，比条目正文大一档（16.5 vs 15）就够。
                    // 原来给到 20pt 又铺满 920pt：它和条目正文只差 2pt、却都很大，
                    // 层级没拉开，整页还显得松垮。
                    //
                    // 外面这层容器只圈**这段话**：它是"一整段话"，与下面"一条一条"的
                    // 时间线是不同的东西，给它一个面才立得住（下面那些靠轨和线立住）。
                    // 宽度（行宽 + 内衬 = 结构列）全部由容器自己负责，调用方不要再套
                    // `.frame` —— 上一版就是调用方套了两层，外沿漏了 79.5pt。
                    Text(overviewText)
                        .font(AppType.documentLead)
                        .foregroundStyle(AppTheme.ink)
                        .lineSpacing(AppType.leadLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .workbenchProsePanel()
                }
            }

            if !session.analysis.timeline.isEmpty {
                VStack(alignment: .leading, spacing: AppTheme.space3) {
                    if hasQuickRead {
                        WorkbenchDocumentSectionHeading(title: "会议经过", count: nil)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(session.analysis.timeline.enumerated()), id: \.element.id) { index, item in
                            WorkbenchTimelineDocumentRow(item: item)
                            if index != session.analysis.timeline.count - 1 {
                                WorkbenchDocumentRowDivider()
                            }
                        }
                    }
                }
            } else if let shortfall = session.analysis.insufficientMaterial {
                // 材料不足：这一屏要说的是「这段录音里没有会议」，而不是「模型没跑成功」。
                // 所以既没有失败横幅（`hasVisibleContent` 是 false，横幅上面就不会画），
                // 也**不给「重试」**——材料还是那么少，点几次都一样；给的出路是
                // 「查看原文」，因为唯一还有信息量的东西就在那儿。
                WorkbenchSummaryEmptyState(
                    title: shortfall.title,
                    message: shortfall.message,
                    actionTitle: "查看原文",
                    action: { onSelectTab(.original) },
                    actionIcon: "text.alignleft"
                )
            } else if !hasVisibleContent {
                WorkbenchSummaryEmptyState(
                    title: "还没有生成速览",
                    message: emptyMessage,
                    retry: retryAction,
                    actionTitle: "打开设置选择模型",
                    action: { store.showSettings = true }
                )
            }
        }
    }

    /// 摘要区块：小标题 + 前 N 条 + 行尾「查看全部」。
    ///
    /// 抽成一个函数而不是两个 `if`：决策和待办的排版必须**逐点一致**，
    /// 否则两条摘要一上一下会错开（上一次"元素对不齐"就是这么来的）。
    @ViewBuilder
    private func summarySection(title: String, items: [WorkbenchOverviewSummaryRow.Item]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                WorkbenchDocumentSectionHeading(title: title, count: items.count) {
                    if items.count > Self.summaryLimit {
                        WorkbenchSectionMoreButton { onSelectTab(.minutes) }
                    }
                }
                .padding(.bottom, AppTheme.space2)

                ForEach(Array(items.prefix(Self.summaryLimit).enumerated()), id: \.offset) { index, item in
                    WorkbenchOverviewSummaryRow(item: item)
                    if index != min(items.count, Self.summaryLimit) - 1 {
                        WorkbenchDocumentRowDivider()
                    }
                }
            }
        }
    }

    /// 点时间锚：**先定位再播**。
    ///
    /// 只定位不播的话，用户点了之后还要再去按一次播放键 —— 而点一个时间锚的
    /// 全部意图就是"我要听这一段"。已经在播的就不打断（只挪位置）。
    private func jump(to seconds: TimeInterval) {
        player.seek(to: seconds)
        if !player.isPlaying {
            player.togglePlayback()
        }
    }

    /// 这场会议在「速览」页里有没有可看的东西（用来和空态互补）。
    private var hasVisibleContent: Bool {
        !overviewText.isEmpty
            || !session.analysis.timeline.isEmpty
            || hasQuickRead
            || !session.analysis.decisions.isEmpty
            || !session.analysis.actions.isEmpty
    }

    /// 有没有「索引层」（结论 / 要点 / 摘要 / 待确认）。
    /// 有才给概述和时间轨加小标题 —— 否则它们在页首，标题是多余的。
    private var hasQuickRead: Bool {
        headline != nil
            || !bullets.isEmpty
            || !openQuestions.isEmpty
            || !session.analysis.decisions.isEmpty
            || !session.analysis.actions.isEmpty
    }

    /// 只有失败过（或结果不完整）才给「重试」。没配置模型时点重试是白点。
    private var retryAction: (() -> Void)? {
        guard session.analysis.noticeMessage != nil else { return nil }
        return { store.regenerateSummary(for: session) }
    }

    private var headline: String? {
        guard let raw = session.analysis.headline?
            .trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty
        else { return nil }
        return raw
    }

    /// 要点。**丢弃只有时间锚、没有正文的条目** —— 那种行渲染出来就是
    /// 一个孤零零的时刻，不如不画（同 `WorkbenchDocumentItemRow` 里
    /// "空着的那一行会把噪音放大"的判断）。
    private var bullets: [OverviewBullet] {
        session.analysis.parsedOverviewBullets.filter { !$0.text.isEmpty }
    }

    private var openQuestions: [String] {
        (session.analysis.openQuestions ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private var overviewText: String {
        session.analysis.overviewText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var emptyMessage: String {
        if session.analysis.isLocalFallback {
            return "整理模型这次没有返回可靠结果，原文仍然保留。可以直接重试，或者更换本机 / 云端整理模型后重新整理。"
        }
        if session.analysis.partialNotice != nil {
            return "这次只拿到了结果的一部分（速览没生成出来）。原文仍然保留，可以直接重试。"
        }
        return "当前没有启用会后整理模型。逐字稿仍然由本机中文 Whisper 完成；选择一个整理模型后，这里会生成整场会议的快速概览。"
    }
}

/// 速览页顶部的一句话结论。
///
/// 它是这一页**唯一** 22pt 的东西，也是整页唯一不带小标题的区块 ——
/// 因为它就是"标题该说的话"：这场会最后是个什么结果。
struct WorkbenchOverviewHeadline: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space2) {
            Text("一句话结论")
                .font(AppType.documentMeta)
                .foregroundStyle(AppTheme.muted)
            Text(text)
                .font(AppType.documentHeadline)
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(6)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 行宽 = 结构列：与下面的章节标题、摘要行落在同一条左边线上。
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
    }
}

/// 速览「要点」：每条一行「时间锚 + 摘要」，锚可点跳播放。
struct WorkbenchOverviewBulletsSection: View {
    let bullets: [OverviewBullet]
    /// 点时间锚的回调。**为 nil 表示不可跳**（没加载出音频）——
    /// 这时锚退化成纯文字，而不是一颗点了没反应的按钮。
    let onJump: ((TimeInterval) -> Void)?

    /// 锚列的固定宽。
    ///
    /// 为什么要定宽：`[0:53]` 与 `[17:00]` 差一个字符，正文就会左右错一位，
    /// 一列要点读起来像锯齿。逐字稿那一页靠"同一场会的时间戳等长"天然对齐，
    /// 这里不能靠它 —— 要点的时间锚可能是模型从整场里挑的，会跨过 1 小时线
    /// （`00:53` 与 `01:02:30` 不是一个长度），所以按"本场有没有超过 1 小时"选宽度。
    private var anchorWidth: CGFloat {
        bullets.contains { ($0.seconds ?? 0) >= 3600 } ? 62 : 42
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchDocumentSectionHeading(title: "要点", count: bullets.count)
                .padding(.bottom, AppTheme.space3)

            ForEach(Array(bullets.enumerated()), id: \.element.id) { index, bullet in
                row(for: bullet)
                if index != bullets.count - 1 {
                    WorkbenchDocumentRowDivider()
                }
            }
        }
    }

    @ViewBuilder
    private func row(for bullet: OverviewBullet) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
            anchor(for: bullet)
                .frame(width: anchorWidth, alignment: .leading)

            Text(bullet.text)
                .font(AppType.documentBody)
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(AppType.bodyLineSpacing)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
        .padding(.vertical, AppTheme.space3)
    }

    @ViewBuilder
    private func anchor(for bullet: OverviewBullet) -> some View {
        if let seconds = bullet.seconds, let onJump {
            Button {
                onJump(seconds)
            } label: {
                Text(seconds.clockLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.accent)
                    // 不给交互元素换行 —— 宽度提案一紧它就折成两行。
                    .lineLimit(1)
                    .fixedSize()
            }
            .buttonStyle(.plain)
            .help("从 \(seconds.clockLabel) 开始播放")
        } else if let seconds = bullet.seconds {
            Text(seconds.clockLabel)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
        }
    }
}

/// 速览页的**摘要行**：一行放下一条决策或待办。
///
/// 它和纪要页的 `WorkbenchDocumentItemRow` 差在"要不要读依据"：
/// 纪要页是终稿，每条都要能溯源，所以带「依据：…」和把握度徽标；
/// 速览页是**索引**，一行一条、扫完就走，画上依据只会把一屏撑成两屏。
struct WorkbenchOverviewSummaryRow: View {
    struct Item: Hashable {
        var time: String?
        var label: String
        /// 待办才有；决策为 nil。
        var owner: String?
    }

    let item: Item

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
            if let time = item.time {
                Text(time)
                    .font(AppType.documentMeta)
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            Text(item.label)
                .font(AppType.documentBody)
                .foregroundStyle(AppTheme.ink)
                // 摘要行只占一行：整句在「纪要」页里。截断掉的那半句靠 `.help` 兜底，
                // 让"想知道但不想跳页"的人悬停就能读完。
                .lineLimit(1)
                .truncationMode(.tail)

            // 这一颗 Spacer 是**必须**的（同 `WorkbenchDocumentItemRow`）：把负责人
            // 推到行尾，全页的负责人排成一列。
            Spacer(minLength: AppTheme.space3)

            if let owner = item.owner {
                WorkbenchSessionMeta(text: owner, systemImage: "person")
            }
        }
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
        .padding(.vertical, AppTheme.space2)
        .help(item.label)
    }
}

/// 速览页的「待确认」栏：会上**提过但没定下来**的事。
///
/// 单独立栏的理由：跟"已决定"混在同一张表里，读者会把悬案读成结论 ——
/// 而这两者对未来动作的指引正好相反（一个可以直接执行，一个必须先去问）。
struct WorkbenchOverviewOpenQuestionsSection: View {
    let questions: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            WorkbenchDocumentSectionHeading(title: "待确认", count: questions.count)
                .padding(.bottom, AppTheme.space3)

            ForEach(Array(questions.enumerated()), id: \.offset) { index, question in
                HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                    Image(systemName: "questionmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.muted)
                    Text(question)
                        .font(AppType.documentBody)
                        .foregroundStyle(AppTheme.ink)
                        .lineSpacing(AppType.bodyLineSpacing)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
                .padding(.vertical, AppTheme.space3)

                if index != questions.count - 1 {
                    WorkbenchDocumentRowDivider()
                }
            }
        }
    }
}

/// 章节标题行尾的「查看全部 ›」。
///
/// 用 `AppType.documentMeta`（11pt）而不是正文档：它是**索引的延伸**，不是内容；
/// 和标题同一行时字号必须小于标题，否则会读成并列的两个标题。
/// 颜色给 `accent` 是唯一一处提示"这里可以点"的信号 —— 剥掉下划线和边框之后，
/// 颜色是这颗按钮最后的可交互痕迹。
struct WorkbenchSectionMoreButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("查看全部")
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(AppType.documentMeta)
            .foregroundStyle(AppTheme.accent)
            // `ButtonStyle` 是自定义的 `.plain`，不吃 `.disabled()`；
            // 而标题栏里那条"`Text` 是唯一可伸缩视图"的教训在这里同样成立 ——
            // 宽度一紧，`查看全部` 就会折成两行。
            .fixedSize()
        }
        .buttonStyle(.plain)
        .help("到「纪要」页看全部")
    }
}

struct WorkbenchMinutesDocument: View {
    let session: MeetingSession
    /// 空态里「查看原文」要用它。这一页平时是终点（不给"下一站"），
    /// 只有材料不足那一种空态需要一个出口，而出口通向原文页。
    let onSelectTab: (MeetingResultTab) -> Void
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space6) {
            // 「纪要」页只说结果，不做任何自我说明。
            //
            // 这里先后撤掉过两样东西：先是失败提醒横幅（"下面仅显示本地保守结果"），
            // 然后是本地说明（"本地保守整理只保留…"）。两次都是同一个判断：
            // 这一页存在的意义是**给出结论和待办**，不是解释这些结论是怎么来的；
            // 一屏之内连续两段"因为模型没成功所以…"，读起来像在反复道歉。
            //
            // 失败信息没有被丢掉：它在唯一该出现的地方 —— 「速览」页的空态
            // （"还没有生成速览" + 原因 + 重试按钮）。跨 Tab 去看一眼，比在每个 Tab
            // 都贴一遍要干净。
            if !minutesText.isEmpty {
                // 同速览：只给"这一段话"一个容器，下面的决策 / 待办是条目，靠轨和线立住。
                // 限宽的理由在下面那条注释里 —— 这一页最容易变成"一屏 60 字的墙"。
                // 宽度交给容器（= 结构列整宽），调用方不再套 frame。
                Text(minutesText)
                    .font(AppType.documentBody)
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(AppType.bodyLineSpacing)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .workbenchProsePanel()
            } else if let shortfall = session.analysis.insufficientMaterial {
                // 同速览页：材料不足是一种**结论**，不是一次失败。文案与速览页逐字一致
                // （同一句在 `MaterialShortfall.message` 里，两处共用），
                // 出路也一样是「查看原文」，没有「重试」。
                WorkbenchSummaryEmptyState(
                    title: shortfall.title,
                    message: shortfall.message,
                    actionTitle: "查看原文",
                    action: { onSelectTab(.original) },
                    actionIcon: "text.alignleft"
                )
            } else if session.analysis.decisions.isEmpty && session.analysis.actions.isEmpty {
                // 什么都没整理出来时另说：空态不是"提醒"，它是这一屏唯一的内容，
                // 而且要给出路（重试 / 去设置选模型）。
                WorkbenchSummaryEmptyState(
                    title: "还没有生成完整纪要",
                    message: emptyMessage,
                    retry: retryAction,
                    actionTitle: "打开设置选择模型",
                    action: { store.showSettings = true }
                )
            }

            if !session.analysis.decisions.isEmpty {
                // 分隔线是**分界**，不是页首装饰：正文在上面时才画。
                // 本地保守整理那条路 minutesText 是空的，原来会在内容顶部留一条悬空的线。
                if !minutesText.isEmpty {
                    Divider()
                        .overlay(AppTheme.rule)
                }
                WorkbenchDocumentSectionHeading(
                    title: "决策与结论",
                    count: session.analysis.decisions.count
                )
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.analysis.decisions.enumerated()), id: \.element.id) { index, item in
                        WorkbenchDecisionDocumentRow(item: item)
                        if index != session.analysis.decisions.count - 1 {
                            WorkbenchDocumentRowDivider()
                        }
                    }
                }
            }

            if !session.analysis.actions.isEmpty {
                // 同上：上面真有东西（正文或决策）才画这条分界线。
                if !minutesText.isEmpty || !session.analysis.decisions.isEmpty {
                    Divider()
                        .overlay(AppTheme.rule)
                }
                WorkbenchDocumentSectionHeading(
                    title: "待办",
                    count: session.analysis.actions.count
                )
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.analysis.actions.enumerated()), id: \.element.id) { index, item in
                        WorkbenchActionDocumentRow(item: item)
                        if index != session.analysis.actions.count - 1 {
                            WorkbenchDocumentRowDivider()
                        }
                    }
                }
            }
        }
    }

    private var minutesText: String {
        session.analysis.minutesText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 只有失败过（或结果不完整）才给「重试」。没配置模型时点重试是白点。
    private var retryAction: (() -> Void)? {
        guard session.analysis.noticeMessage != nil else { return nil }
        return { store.regenerateSummary(for: session) }
    }

    /// 空态文案要认得出「为什么空」。
    ///
    /// 原来这里写死一句「当前没有使用会后整理模型」—— 但撤掉提醒横幅之后，
    /// 这句就成了这一屏唯一的解释，而模型**用过却失败**的时候它是错的
    /// （用户被告知"没配模型"，于是去设置里翻半天，其实模型配得好好的）。
    private var emptyMessage: String {
        if session.analysis.isLocalFallback {
            return "整理模型这次没有返回可靠结果，原文仍然保留。可以直接重试，或者更换本机 / 云端整理模型后重新整理。"
        }
        if session.analysis.partialNotice != nil {
            return "这次只拿到了结果的一部分（纪要正文没生成出来）。原文仍然保留，可以直接重试。"
        }
        return "本地转写已经完成，但当前没有使用会后整理模型。选择一个模型后重新整理，可以生成会议叙述、决策和待办。"
    }
}

struct WorkbenchOriginalDocument: View {
    let session: MeetingSession
    /// 就地编辑要**写回盘**（`updateTranscriptSegment`），所以这一页需要 store；
    /// 注入链和纪要页一样，由上层给。
    @EnvironmentObject private var store: MeetingStore
    /// 正在编辑哪一段。**同一时刻只允许一段**：两段同时编辑时「保存」的语义是模糊的
    /// （谁先落盘？后落盘的那份会不会把前一段的改动覆盖掉？），而这种模糊不会报错，
    /// 只会让某一处的修改静默消失。
    @State private var editingSegmentID: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if session.transcriptSegments.isEmpty {
                WorkbenchEmptyHint(text: "转写还没有内容。")
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(session.transcriptSegments.enumerated()), id: \.element.id) { index, segment in
                        WorkbenchTranscriptDocumentRow(
                            segment: segment,
                            isEditing: editingSegmentID == segment.id,
                            canEdit: canEdit,
                            onBeginEditing: { editingSegmentID = segment.id },
                            onCancel: { editingSegmentID = nil },
                            onCommit: { text in commit(text, for: segment) }
                        )
                        if index != session.transcriptSegments.count - 1 {
                            // 三页共用同一条分隔线画法（`WorkbenchDocumentRowDivider`），
                            // 起笔线也同一个 —— 原来这里是手写的一份,现在收归一处。
                            WorkbenchDocumentRowDivider()
                        }
                    }
                }
            }
        }
    }

    /// 页眉：一行「日期 · 这一页是什么」的眉标，不是标题 ——
    /// 页面主角是下面成百上千行逐字稿，眉标不该跟它抢字号。
    ///
    /// **被人改过之后那句话必须换掉。**「原汁原味保留转写」在有人手工校正过之后
    /// 就不是事实了，而它看上去毫无异常（同 2C 的 `summaryModel`：留 nil 才是字面事实）。
    /// 换成的这句同时解释了为什么被改过的段尾不再有机器置信度。
    private var header: some View {
        HStack(spacing: 7) {
            Text(session.createdAt.formatted(date: .numeric, time: .shortened))
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
            Text(editedCount > 0 ? "已人工校正 \(editedCount) 处" : "原汁原味保留转写")
                .foregroundStyle(AppTheme.ink)
        }
        .font(.system(size: 12, weight: .medium))
    }

    /// 这一场**此刻**能不能改。
    ///
    /// 转写没完成时改不了（还没写完的逐字稿没有稳定内容）；正在整理纪要时也改不了 ——
    /// 那一句正是模型这次要读的材料，放它进来会得到"模型整理旧文本、用户看着新文本"。
    private var canEdit: Bool {
        session.status == .ready && !store.isProcessing && !store.isRecording
    }

    private var editedCount: Int {
        TranscriptEditor.editedCount(in: session.transcriptSegments)
    }

    /// 提交一次编辑。返回**拒绝理由**（nil = 通过，此时父层已经退出编辑态）。
    ///
    /// 校验放在 `TranscriptEditor` 里而不是这里：它要判的是"这次改动该不该落盘"，
    /// 而落盘与否决定用户明天打开还看不看得到自己的修改 —— 必须由单测钉住。
    private func commit(_ text: String, for segment: TranscriptSegment) -> String? {
        switch store.updateTranscriptSegment(
            sessionID: session.id,
            segmentID: segment.id,
            text: text
        ) {
        case .saved, .unchanged:
            editingSegmentID = nil
            return nil
        case let .rejected(reason):
            return reason
        }
    }
}

/// 文档条目的行间分隔线。
///
/// 它曾经**从正文列起笔**而不是从行首起笔 —— 因为左边那一栏当时是留给时间轨的，
/// 横线穿过去会把「时间」和「正文」重新粘成一堆。
/// v0.6.2 撤掉时间轨之后，条目本身就是从结构列左沿起笔的（见
/// `AppTheme.contentColumn`），这条线跟着回到左沿：与章节分隔线、Tab 发丝线、
/// 散文块左右边框**同宽同起点**，整页只剩一条竖线。
struct WorkbenchDocumentRowDivider: View {
    var body: some View {
        Divider()
            .overlay(AppTheme.rule)
    }
}

/// 速览时间线的一行。
///
/// **起笔线回到结构列左沿（v0.6.2 对齐修正）**：这一行原来和纪要、原文共用一条
/// 96pt 的时间轨，正文因此要在结构列左沿再往右 112pt 才起笔 —— 用户看到的
/// 「内容非常往右」就是这条轨。轨撤掉之后，区间标签退成**主句上面那一行元信息**，
/// 正文于是和「决策与结论」这类章节标题落在同一条竖线上（x=421）。
///
/// 时间**不是标题**。原来它是 `.headline.weight(.semibold)`：一个机械字符串拿到了
/// 主句的字重，真正有内容的那句话反而只有 18pt 常规 —— 层级整个是反的。
/// 现在它是元信息档（11pt semibold / muted），排在段落上方只为给这一段定位；
/// 主角是下面那句话，拿正文档（15pt 常规）。
struct WorkbenchTimelineDocumentRow: View {
    let item: TimelineChunk

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space2) {
            Text(item.rangeLabel)
                .font(AppType.documentMeta)
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
                .lineLimit(1)

            Text(item.summary)
                .font(AppType.documentBody)
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(AppType.bodyLineSpacing)
                .fixedSize(horizontal: false, vertical: true)
        }
        // 行宽 = 结构列：正文右边界、行间分隔线、章节分隔线落在同一条竖线上。
        // 行尾不要再加 `Spacer()` —— 它是弹性的，会跟正文抢宽度
        // （同 `WorkbenchDocumentItemRow` 里那条注释）。
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
        .padding(.vertical, AppType.documentItemPadding)
    }
}

/// 决策 / 待办**共用**的一行。
///
/// 这一行专门解决用户说的「信息太分散」：原来时间戳孤零零飘在左上角、
/// 「把握 96%」飘在 900pt 之外的最右边、中间那句结论夹在二者之间 ——
/// 三样东西横跨一整屏，眼睛要来回扫三次才拼得出一条完整的话。
/// 现在收进**同一个信息簇**：
///   · 时间退成主句上方的一行元信息（11pt / muted），不再另开一栏；
///   · 主句与徽标同处一条行，徽标贴这条行的**右端** —— 于是全页徽标排成一列；
///   · 依据 12pt / muted 紧随其下，与主句同一个左边线。
///
/// **起笔线回到结构列左沿（v0.6.2 对齐修正）**：原来时间落在一条 96pt 的左轨上，
/// 主句因此要在结构列左沿再往右 112pt 才起笔 —— 用户原话「内容是非常往右的」。
/// 轨撤掉、时间改成上方元信息之后，**主句与「决策与结论」这类章节标题落在同一条
/// 竖线上**（x=421）；时间行也在同一条线上，整块条目再没有内缩。
struct WorkbenchDocumentItemRow<Trailing: View>: View {
    let time: String?
    let label: String
    let evidence: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: AppTheme.space2) {
            // 没有时间就不画这一行：在行首印一个孤零零的「—」比不给还糟，
            // 而且空着的那一行会把「这条没定位」放大成视觉噪音。
            if let time {
                Text(time)
                    .font(AppType.documentMeta)
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                Text(label)
                    .font(AppType.documentItemLabel)
                    .foregroundStyle(AppTheme.ink)
                    .fixedSize(horizontal: false, vertical: true)

                // 这一颗 Spacer 是**必须**的：它把徽标推到行尾，全页徽标才排成一列。
                // 别和行尾那颗混为一谈（见下）。
                Spacer(minLength: AppTheme.space3)

                trailing()
            }

            // 依据为空时不画这一行 —— 否则屏幕上只剩一个孤零零的「依据：」，
            // 比不给还糟。
            if !trimmedEvidence.isEmpty {
                Text("依据：\(trimmedEvidence)")
                    .font(AppType.documentEvidence)
                    .foregroundStyle(AppTheme.muted)
                    .lineSpacing(AppType.evidenceLineSpacing)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // 行宽 = **结构列本身**。徽标因此贴在 1221，与它上下的行间分隔线、
        // 章节分隔线、Tab 发丝线落在同一条竖线上。
        //
        // ⚠️ 行尾**不能**再跟一个 `Spacer(minLength: 0)`。
        // 行尾那个 Spacer 也是弹性的，它会分走 20~26pt —— 实测徽标右端只到 1194.5，
        // 而分隔线铺到 1221：**徽标那一列比线短了 26.5pt**，正是"元素对不齐"。
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
        .padding(.vertical, AppType.documentItemPadding)
    }

    private var trimmedEvidence: String {
        evidence.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

struct WorkbenchDecisionDocumentRow: View {
    let item: InsightItem

    var body: some View {
        WorkbenchDocumentItemRow(
            time: item.timestamp?.clockLabel,
            label: item.label,
            evidence: item.evidence
        ) {
            WorkbenchConfidenceChip(value: item.confidence)
        }
    }
}

struct WorkbenchActionDocumentRow: View {
    let item: ActionItem

    var body: some View {
        WorkbenchDocumentItemRow(
            time: item.timestamp?.clockLabel,
            label: item.label,
            evidence: item.evidence
        ) {
            HStack(spacing: AppTheme.space2) {
                // 截止日期并进这一簇：它和「高优先」是同一层的判断依据。
                // 原来它和「时间戳」并排挤在主句下面那一行，而那个时间戳又和左轨
                // 说的是同一件事 —— 一条待办里同一个信息出现两遍。
                if let dueText = item.dueText {
                    WorkbenchSessionMeta(text: "截止 \(dueText)", systemImage: "calendar")
                }
                if let priority = item.priority {
                    WorkbenchPriorityChip(priority: priority)
                }
                WorkbenchConfidenceChip(value: item.confidence)
            }
        }
    }
}

struct WorkbenchTranscriptDocumentRow: View {
    let segment: TranscriptSegment
    /// 这一行正在被编辑。
    let isEditing: Bool
    /// 是否允许进入编辑态（转写没完 / 正在整理时为 false）。
    let canEdit: Bool
    let onBeginEditing: () -> Void
    let onCancel: () -> Void
    /// 返回拒绝理由；nil = 通过。
    let onCommit: (String) -> String?

    @State private var draft = ""
    /// 就地拒绝的理由（比如"不能改成空"）。它必须显示在**这一行**上 ——
    /// 只往底栏状态里塞一句的话，用户的眼睛在段落这里，等于没告诉他。
    @State private var rejection: String?
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if isEditing {
                editor
            } else {
                reader
            }
        }
        // 行宽 = 结构列：编辑态也不改，否则一进编辑整页会横向跳一下。
        .frame(maxWidth: AppTheme.documentRowWidth, alignment: .leading)
        .padding(.vertical, 12)
        .onChange(of: isEditing) { _, editing in
            guard editing else { return }
            draft = segment.text
            rejection = nil
            // 让输入框立刻拿到键盘。同一次更新里设 `isFocused` 通常是白设的
            // （那时输入框还没进视图层级），下一次 runloop 才是稳的。
            DispatchQueue.main.async { isFocused = true }
        }
    }

    // MARK: - 只读态

    /// 基线对齐：11pt 的时间戳和置信度要落在正文**第一行的基线**上。
    /// 用 `.top` 对齐时小的那两串字会浮在行顶（视觉上比正文高半行），
    /// 这正是此前这一页"看着不齐"的来源之一。
    ///
    /// 逐字稿这一页特意**不**把时间挪到上一行（速览 / 纪要那样做）：
    /// 一场会议有上百段，每段再占一行会让这一页长出一倍。而且同一场会议里
    /// 时间戳等长（1 小时内都是 `MM:SS`、超过 1 小时都是 `HH:MM:SS`），
    /// 正文的左边界仍然自然对齐。
    private var reader: some View {
        HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
            Text(segment.start.clockLabel)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AppTheme.muted)
                .monospacedDigit()
                .lineLimit(1)

            Text(segment.text)
                .font(.system(size: 14.5, weight: .regular, design: .default))
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(4.5)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: AppTheme.space4)

            trailing
        }
        // 双击整行也能进编辑（与行尾那颗铅笔等价）。**不把它当成唯一入口**：
        // 正文开了文本选择，双击在文本上会变成"选中一个词" ——
        // 这正是必须有铅笔按钮的原因（一个可能被系统抢走的手势不能是唯一的路）。
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if canEdit { onBeginEditing() }
        }
    }

    private var trailing: some View {
        HStack(spacing: AppTheme.space2) {
            if let editedAt = segment.manuallyEditedAt {
                // 人工改过的段**不再显示置信度**：那个数字是机器对原文的把握，
                // 而这段已经被人一字一句看过了。继续摆一个「62%」只会让人怀疑
                // 自己刚改过的东西，而它想表达的其实已经过期了。
                // 用 `help` 把时间点留着（不占版面，但问得出来）。
                Text("已校正")
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.muted)
                    .frame(width: 40, alignment: .trailing)
                    .help("这一句由人工校正于 \(editedAt.formatted(date: .abbreviated, time: .shortened))")
            } else {
                // 置信度是「机器给的参考值」，比时间戳更次要：同样的字级与颜色，
                // 但字重更轻，右对齐在一列里，好让人扫一眼又不会跟正文抢。
                Text(segment.confidence.confidenceLabel)
                    .font(.system(size: 11, weight: .regular))
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                    .frame(width: 40, alignment: .trailing)
            }

            // 编辑入口。**常驻**（怕它变成"藏起来的功能"：用户根本不知道能改），
            // 颜色就用 `muted` —— 与同一行的置信度、时间戳**同一档**，
            // 所以整行右端仍是"一列元信息"，铅笔只是其中一件。
            //
            // 为什么不再乘一个 opacity：`muted` 对纸面本来只有 4.86:1（像素实测 3.71:1），
            // 乘 0.8 之后实测只剩 **2.71:1** —— 而这是**功能入口**（不是装饰），
            // 非文字图形要 3:1（WCAG 1.4.11）。它看上去只是"淡了一点"，不会有任何人报 bug。
            Button {
                onBeginEditing()
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(WorkbenchStripIconButtonStyle())
            .disabled(!canEdit)
            .help("修改这一句（也可以双击这一段）")
            .accessibilityLabel("修改这一句")
        }
    }

    // MARK: - 编辑态

    private var editor: some View {
        VStack(alignment: .leading, spacing: AppTheme.space2) {
            HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                Text(segment.start.clockLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
                    .lineLimit(1)

                TextField("", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14.5, weight: .regular, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .lineSpacing(4.5)
                    // 折行显示但**不许无限长**：一段改成一整页会把这一页的节奏毁掉，
                    // 而且这种输入几乎没有正当用途。
                    .lineLimit(1...12)
                    .focused($isFocused)
                    .onExitCommand { onCancel() }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(
                        AppTheme.paperSoft,
                        in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                            .stroke(isFocused ? AppTheme.accent : AppTheme.ruleStrong, lineWidth: isFocused ? 1.5 : 1)
                    )

                Button {
                    submit()
                } label: {
                    Image(systemName: "checkmark")
                }
                .buttonStyle(WorkbenchStripIconButtonStyle())
                .keyboardShortcut(.return, modifiers: [.command])
                .disabled(!canSubmit)
                .help("保存这一句（⌘↩）")
                .accessibilityLabel("保存这一句")

                Button {
                    onCancel()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(WorkbenchStripIconButtonStyle())
                .help("放弃这次修改（Esc）")
                .accessibilityLabel("放弃这次修改")
            }

            if let rejection {
                // **语义给图标、可读性给文字**（同 2D 的状态行）：`danger` 那一档是按
                // "图标 / 描边 / 底盘"的量级调出来的，直接当 11pt 正文用，浅色下实测
                // 只有 4.42:1（AA 要 4.5:1），而且看上去"只是红了一点"，
                // 谁也不会为此报个 bug。措辞本身已经说清了这是拒绝，颜色只是提示。
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.danger)
                    Text(rejection)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.ink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// 归一化之后没变 / 是空的，都不给保存 —— 一颗点了什么都不发生的按钮不如不给。
    ///
    /// 判据来自 `TranscriptEditor.verdict`，**不在这里重写一遍**：重写的那一份迟早
    /// 会与 `apply` 走岔，而走岔的表现是"按钮亮着但点不动"（或反过来），不报错。
    private var canSubmit: Bool {
        if case .effective = TranscriptEditor.verdict(for: draft, against: segment.text) {
            return true
        }
        return false
    }

    private func submit() {
        rejection = onCommit(draft)
    }
}

struct WorkbenchSummaryFallbackNotice: View {
    let message: String
    /// 标题要分得清「模型整个没返回（本地兜底）」和「模型返回了但不完整」。
    /// 这两种情况的出路不一样：前者多半要换模型/查配置，后者直接重试通常就好。
    var headline: String = "整理模型未返回，已保留逐字稿；下面仅显示本地保守结果。"

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "info.circle")
                .foregroundStyle(AppTheme.warning)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
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
    /// 「重试」入口。**只有真的失败过**（`summaryError` 非空）才传进来。
    ///
    /// 为什么不是常驻：没配置整理模型时，再点一次「重试」还是同一个结果 ——
    /// 那种情况该做的是去设置里挑个模型，多一颗按钮只会让人白点一下。
    /// 所以由调用方按失败与否决定给不给。
    var retry: (() -> Void)?
    let actionTitle: String
    let action: () -> Void
    /// 主按钮的图标。默认那颗是「打开设置选择模型」；材料不足时空态要去的是
    /// 「原文」页（换模型解决不了材料少的问题），齿轮在那里是错的暗示。
    var actionIcon: String = "gearshape"

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

            HStack(spacing: AppTheme.space2) {
                if let retry {
                    // 重试是这颗空态里最省事的一步（很多失败是预算/网络这类一次性的），
                    // 所以给它实底主色；「打开设置选择模型」是退一步的做法，留描边。
                    // 顺序按用户要求：重试在左。
                    Button(action: retry) {
                        Label("重试", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
                    .help("用当前模型再整理一次")
                }

                Button(action: action) {
                    Label(actionTitle, systemImage: actionIcon)
                }
                .buttonStyle(WorkbenchLightButtonStyle())
            }
            .padding(.top, 4)
        }
        // 限宽：空态那段话是要读完的，铺到 560pt 以上就不成句了。
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, minHeight: 240)
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
        // 这里**不再**压一条 1pt `rule` 发丝线。
        // 原来 bar 是 paperSoft 底 + 顶部一条线，等于把「换个底色」和「画条边界」
        // 两件事都做了，底部就多出一道横杠。现在只留底色这一档信号：
        // paperSoft 对纸面本身就有反差，分区已经够了，边界交给色差而不是线条
        // （Finder / Music 的底部条也是这个口径）。用户明确要求去掉这条线。
        .background(AppTheme.paperSoft)
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

    /// 这张卡片其实横跨三个真实阶段，原来的界面把它们揉成了同一句话：
    ///
    /// - `preparing`：拿到了音频但还没算出总段数（导入 / 转码），进度无从谈起；
    /// - `transcribing`：正在跑第 n 段的 whisper；
    /// - `analyzing`：**所有段都转完了**，正在调模型做结构化整理。
    ///
    /// 第三段是原来漏掉的一页：转写循环一结束，`processingStage` 就写成了
    /// "正在整理会议结果..."，可卡片上还挂着"第 4/4 段"、进度条停在 100%、
    /// 逐字稿尾部还在闪打字点——读起来像"卡死了"，其实它正在干活。
    private enum ProcessingPhase {
        case preparing
        case transcribing
        case analyzing
    }

    private var phase: ProcessingPhase {
        if isRecordingPhase { return .preparing }
        guard let total = session.processingTotalChunks, total > 0 else { return .preparing }
        return completedChunks >= total ? .analyzing : .transcribing
    }

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
                Image(systemName: phase == .analyzing ? "sparkles" : "waveform")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
            }

            Text(statusTitle)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(AppTheme.ink)

            Text(session.captureMode.subtitle)
                .font(.subheadline)
                .foregroundStyle(AppTheme.muted)

            Spacer(minLength: AppTheme.space4)

            if let counter = chunkCounterText {
                Text(counter)
                    .font(.caption.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(AppTheme.muted)
            }
        }
        .padding(.horizontal, AppTheme.space5)
        .padding(.vertical, AppTheme.space4)
    }

    private var statusTitle: String {
        switch phase {
        case .preparing: return isRecordingPhase ? "录音中" : "正在准备"
        case .transcribing: return "正在转写"
        case .analyzing: return "正在整理"
        }
    }

    /// 右上角的段计数。整理阶段不再显示"第 n/n 段"——那是**转写**的坐标，
    /// 在一个已经转完、正在调模型的界面上它读起来像"卡在最后一段了"。
    private var chunkCounterText: String? {
        guard let total = session.processingTotalChunks, total > 0 else { return nil }
        switch phase {
        case .preparing: return nil
        case .transcribing: return "第 \(min(completedChunks + 1, total))/\(total) 段"
        case .analyzing: return "\(total)/\(total) 段 · 转写完成"
        }
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

                Text(transcriptCountText)
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

    private var transcriptCountText: String {
        if segments.isEmpty {
            return phase == .analyzing ? "这一段没有识别到内容" : "正在识别第一段…"
        }
        return phase == .analyzing ? "共 \(segments.count) 句" : "已识别 \(segments.count) 句"
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

                    HStack(alignment: .firstTextBaseline, spacing: AppTheme.space3) {
                        Color.clear.frame(width: 46, height: 1)

                        if phase == .analyzing {
                            // 全转完了就别再假装还在"打字"——闪动的点会让用户
                            // 以为转写卡在这一段。明说"转完了、在整理"。
                            Text("逐字稿已全部转完，正在整理会议结果…")
                                .font(.caption)
                                .foregroundStyle(AppTheme.muted)
                        } else {
                            WorkbenchTypingDots()
                        }
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let shown = smoothProgress(now: context.date)

                    HStack(spacing: AppTheme.space4) {
                        ProgressView(value: shown)
                            .progressViewStyle(.linear)
                            .tint(AppTheme.accent)

                        Text(shown.percentLabel)
                            .font(.caption.weight(.medium))
                            .monospacedDigit()
                            .foregroundStyle(AppTheme.ink)
                            .fixedSize()
                    }
                    // 每秒钟只是往上挪零点几个百分点；不补一个同时长的线性动画，
                    // 线条会一格一格地"跳"。补上之后观感才是连续地爬。
                    .animation(.linear(duration: 1), value: shown)
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
        if isRecordingPhase { return recordingFooterNote(now: now) }
        if phase == .analyzing {
            return "逐字稿已经全部转完，正在梳理结构、提炼决策与待办。"
        }
        return "每段完成后立即保存，重开应用会从未完成的段继续。"
    }

    private func recordingFooterNote(now: Date) -> String {
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

    /// 段内平滑的**显示用**进度。规则与纪律全在
    /// `ProcessingProgressEstimator` 里（纯函数，有回归护栏），
    /// 这里只负责把当前会话的字段喂进去。
    private func smoothProgress(now: Date) -> Double {
        guard !isRecordingPhase, phase == .transcribing else { return progress }
        return ProcessingProgressEstimator.displayProgress(
            base: progress,
            completedChunks: completedChunks,
            totalChunks: session.processingTotalChunks ?? 0,
            startedAt: session.processingStartedAt,
            chunkStartedAt: session.processingChunkStartedAt,
            now: now
        )
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
                    // 空态这颗和标题栏那颗（`workbenchToolbar`）说同一件事，文案必须**逐字一致**：
                    // 同一屏里两个入口一个叫「导入已有音频」、一个叫「导入音频」，
                    // 读起来像两个不同功能。侧栏空态那行「开始录音或导入音频」也是这个词。
                    Label("导入音频", systemImage: "square.and.arrow.down")
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
                    Text("转写始终在本机完成；下面配置术语表、外观与会后整理使用的模型。")
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
            // 页头原来没有自己的底，露出来的是 sheet 的原生底色 —— 深夜模式下
            // 那是深色，于是「设置」两个字（墨色）直接消失在深底上。
            // 补一层纸底，页头与表体成为同一张纸。
            .background(AppTheme.paper)

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

                    WorkbenchSettingsGroup(
                        title: "识别术语表",
                        subtitle: "一行一个词，逗号后面的写法会被换成前面的。例如「多模态, 多摩泰」"
                            + "表示把听到的「多摩泰」改成「多模态」。转写、逐字稿纠错、整理三处都用它。"
                    ) {
                        VStack(alignment: .leading, spacing: 10) {
                            TextEditor(text: $store.glossaryText)
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(AppTheme.ink)
                                .scrollContentBackground(.hidden)
                                .frame(minHeight: 132)
                                .padding(8)
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
                                .accessibilityLabel("识别术语表")

                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                // **颜色只管图标，文字一律走 muted / ink。**
                                // 这里踩过一个坑：`success` / `warning` 这类语义色是给图标
                                // 和底盘用的，直接拿去当 11pt 正文色，浅色下只有 2.7:1 ——
                                // 低于 AA 的 4.5:1（`muted` 是 4.96:1，`ink` 是 15:1）。
                                // 语义由图标承担，可读性由文字色承担，两件事分开。
                                Image(systemName: glossarySummaryIcon)
                                    .font(.caption)
                                    .foregroundStyle(
                                        store.glossary.entries.isEmpty
                                            ? AppTheme.muted
                                            : AppTheme.success
                                    )
                                Text(glossarySummary)
                                    .font(.caption)
                                    .foregroundStyle(AppTheme.muted)
                                    .fixedSize(horizontal: false, vertical: true)

                                Spacer(minLength: 10)

                                Button("恢复默认") {
                                    store.glossaryText = Glossary.factoryDefaultText
                                }
                                .buttonStyle(.plain)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.accent)
                            }

                            if let warning = glossaryBudgetWarning {
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Image(systemName: "exclamationmark.triangle")
                                        .font(.caption)
                                        .foregroundStyle(AppTheme.warning)
                                    Text(warning)
                                        .font(.caption)
                                        // 警告用 ink 而不是 warning 色：同样是不达标的问题，
                                        // 而且这条是"你真的需要知道"的信息，配得上主文字色。
                                        .foregroundStyle(AppTheme.ink)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }

                    WorkbenchSettingsGroup(
                        title: "外观",
                        subtitle: "只改 MeetingScribe 自己的配色，不动系统的外观偏好。"
                    ) {
                        WorkbenchAppearanceSettingRow()
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

    // MARK: - 术语表状态（设置页那一组下面的几行小字）

    /// 「我写了几条，到底生效了几条」—— 这个数必须能对得上，否则用户只会怀疑功能坏了。
    /// 被忽略的条目单独说一句原因，别让人自己猜（多半是把正确写法那一栏空着了）。
    private var glossarySummary: String {
        let entries = store.glossary.entries
        var text: String
        if entries.isEmpty {
            text = "术语表是空的，转写和逐字稿都不会做任何替换。"
        } else if glossaryAliasCount == 0 {
            text = "已启用 \(entries.count) 个词。没有写误听写法，所以只用于转写和整理的偏置。"
        } else {
            text = "已启用 \(entries.count) 个词，其中 \(glossaryAliasCount) 条误听写法会被替换。"
        }
        if store.glossary.ignoredAliasCount > 0 {
            text += "另有 \(store.glossary.ignoredAliasCount) 条被忽略（重复、与正确写法相同，或不足 2 个字）。"
        }
        return text
    }

    private var glossaryAliasCount: Int {
        store.glossary.entries.reduce(0) { $0 + $1.aliases.count }
    }

    private var glossarySummaryIcon: String {
        store.glossary.entries.isEmpty ? "text.badge.xmark" : "checkmark.circle.fill"
    }

    /// Whisper 的起始提示词有长度上限（方案 P0-2：`n_text_ctx/2 ≈ 224 token`），
    /// 词表按 120 字截断。**截断只发生在这里**：整理侧上下文是万级字符，不跟着限。
    /// 不说出来的话，用户会觉得"我明明加了这么多词，怎么一个都没进转写"。
    private var glossaryBudgetWarning: String? {
        let budget = store.glossary.promptTerms()
        guard budget.isTruncated else { return nil }
        return "转写提示词只装得下前 \(budget.terms.count) 个词，另外 \(budget.droppedCount) 个"
            + "不参与转写偏置（Whisper 的提示词有长度上限）。整理不受这个限制。"
    }
}

/// 设置里的「外观」一行：图标 + 当前档位的说明 + 三档分段控件。
/// 结构与上面「接入方式」那一行一致（32pt 图标底盘 / 主副两行文字 / 右侧控件）。
struct WorkbenchAppearanceSettingRow: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: iconName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 32, height: 32)
                .background(
                    AppTheme.accentSoft,
                    in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text(store.appearance.title)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                Text(store.appearance.summary)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 12)

            WorkbenchSegmentStrip(
                items: AppAppearance.allCases,
                label: \.title,
                selection: $store.appearance
            )
        }
    }

    /// 图标跟着当前档位走，一眼能看出现在是哪一档。
    private var iconName: String {
        switch store.appearance {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
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
                    .background(AppTheme.accentFill, in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))

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
                    // 与标题栏按钮共用「控件底盘 / 凹陷轨道」两个 token：
                    // 按下时沉进轨道色。浅色下 rule 本来就够浅，深色下只有
                    // 明显下沉才看得出按到了。
                    configuration.isPressed ? AppTheme.segmentTrack : AppTheme.controlSurface,
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
                // 强调键是 `ink` 实底 + 反白字形。深色模式下 `ink` 本身是近白色，
                // 这里若继续用纯白，字就消失在底里 —— 所以反白取 `paper`：
                // 浅色下 ink 底配浅纸字，深色下浅纸底配 ink 字，两种外观都读得清。
                .foregroundStyle(emphasized ? AppTheme.paper : AppTheme.ink)
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
                .background(emphasized ? AppTheme.accentFill : AppTheme.paperSoft)
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                        .stroke(emphasized ? AppTheme.accentFill : AppTheme.rule, lineWidth: 1)
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
                .background(emphasized ? AppTheme.accentFill : Color.white.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                        .stroke(emphasized ? AppTheme.accentFill : Color.white.opacity(0.12), lineWidth: 1)
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
            let fill = tint ?? AppTheme.controlSurface
            configuration.label
                .font(.system(size: 13, weight: tint == nil ? .medium : .semibold))
                .foregroundStyle(tint == nil ? AppTheme.ink : Color.white)
                // ⚠️ 文案**绝不允许折行**。`Text` 在标题栏里是唯一可伸缩的子视图，
                // 系统给整个 `ToolbarItem` 的宽度提案只要略紧一点，它就自己折成两行——
                // 实测「开始录音」被压成「开始」/「录音」上下两行，胶囊缩到 73pt
                // （= 图标 17 + 间隙 5 + **2 个汉字** 27.7 + 内边距 24），还被钉在
                // `controlRegular` 的 34pt 高里，两行挤成一团；同一排的「导入音频」
                // 拿到的是自然宽度 99pt、一行。主操作反而比次级动作先垮，
                // 缺的就是这一道「不可折行」的约束。
                //
                // 钉住后：标签按**理想宽度**取尺寸、不再听宽度提案的摆布，按钮因此
                // 拿到它真正需要的宽度（4~5 个汉字 + 图标），横向富余由工具栏左移消化。
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, iconOnly ? 0 : AppTheme.space3)
                .frame(
                    width: iconOnly ? AppTheme.controlRegular : nil,
                    height: AppTheme.controlRegular
                )
                .background(fill, in: Capsule(style: .continuous))
                // 次级按钮补一条边。`controlEdge` 在浅色档等于底盘本色（看不见），
                // 深色档才浮出一条 1pt 的边 —— 深色下光靠明度差立不住，这条边是
                // 「这是个按钮」的最后一道保险。主操作是实底主色，不需要边。
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(tint == nil ? AppTheme.controlEdge : Color.clear, lineWidth: 1)
                )
                .opacity(configuration.isPressed ? 0.72 : 1)
                .contentShape(Capsule(style: .continuous))
        }
    }
}
