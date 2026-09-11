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

                    if successfulSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有可查看的会议")
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
                            count: successfulSessions.count
                        ) {
                            VStack(spacing: 4) {
                                ForEach(successfulSessions) { session in
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

    private var successfulSessions: [MeetingSession] {
        store.sessions.filter { $0.status != .failed }
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
        .navigationSubtitle(store.statusText)
        .toolbar { workbenchToolbar }
    }

    // 全局操作全部注册到原生标题栏，和侧边栏开关同一行，不再自绘第二条横栏。
    @ToolbarContentBuilder
    private var workbenchToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                store.importAudioPresented = true
            } label: {
                Label("导入音频", systemImage: "square.and.arrow.down")
            }
            .labelStyle(.titleAndIcon)
            .help("导入一段已有音频")
            .disabled(store.isRecording || store.isProcessing)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                toggleRecording()
            } label: {
                Label {
                    Text(primaryTitle)
                } icon: {
                    Image(systemName: primaryIcon)
                        .foregroundStyle(primaryTint)
                }
            }
            .labelStyle(.titleAndIcon)
            .help(primaryTitle)
        }

        ToolbarItem(placement: .primaryAction) {
            Button {
                store.showSettings = true
            } label: {
                Label("设置", systemImage: "gearshape")
            }
            .help("设置")
            .accessibilityLabel("设置")
            .keyboardShortcut(",", modifiers: .command)
        }
    }

    private var primaryTitle: String {
        if store.isProcessing {
            return "停止处理"
        }
        return store.isRecording ? "结束并转写" : "开始录音"
    }

    private var primaryIcon: String {
        if store.isProcessing {
            return "stop.fill"
        }
        return store.isRecording ? "stop.fill" : "record.circle"
    }

    private var primaryTint: Color {
        if store.isRecording || store.isProcessing {
            return AppTheme.danger
        }
        return AppTheme.accent
    }

    private func toggleRecording() {
        if store.isProcessing {
            store.cancelProcessing()
        } else if store.isRecording {
            store.stopRecording()
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
                .padding(24)
            case .processing, .recording:
                WorkbenchProcessingState(
                    session: session,
                    cancelAction: store.cancelProcessing,
                    openFolderAction: store.openSelectedSessionFolder
                )
                .padding(24)
            case .ready:
                VStack(spacing: 0) {
                    WorkbenchSessionHeader(
                        session: session,
                        isRefreshing: store.isProcessing,
                        openFolderAction: store.openSelectedSessionFolder,
                        regenerateAction: { store.regenerateSummary(for: session) }
                    )

                    WorkbenchResultTabBar(selection: $selectedTab)

                    ScrollView {
                        WorkbenchResultDocument(session: session, tab: selectedTab)
                            .frame(maxWidth: 920, alignment: .leading)
                            .padding(.horizontal, 32)
                            .padding(.top, 10)
                            .padding(.bottom, 28)
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

struct WorkbenchSessionHeader: View {
    let session: MeetingSession
    let isRefreshing: Bool
    let openFolderAction: () -> Void
    let regenerateAction: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            VStack(alignment: .leading, spacing: 10) {
                Text(session.title)
                    .font(.system(size: 28, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 8) {
                    WorkbenchSessionMeta(
                        text: session.createdAt.formatted(date: .numeric, time: .shortened),
                        systemImage: "calendar"
                    )
                    if let duration = session.duration {
                        WorkbenchSessionMeta(text: duration.clockLabel, systemImage: "clock")
                    }
                    WorkbenchSessionMeta(
                        text: session.status.title,
                        systemImage: session.status.icon
                    )
                    if let summaryModel = session.analysis.summaryModel {
                        WorkbenchSessionMeta(text: summaryModel, systemImage: "wand.and.stars")
                    }
                }
            }

            Spacer(minLength: 12)

            HStack(spacing: 8) {
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
                .buttonStyle(WorkbenchToolbarIconButtonStyle())
                .help("重新整理纪要")
                .accessibilityLabel("重新整理纪要")
                .disabled(isRefreshing)

                Button {
                    openFolderAction()
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(WorkbenchToolbarIconButtonStyle())
                .help("打开录音文件夹")
                .accessibilityLabel("打开录音文件夹")
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 26)
        .padding(.bottom, 20)
        .background(AppTheme.paper)
    }
}

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

struct WorkbenchResultTabBar: View {
    @Binding var selection: MeetingResultTab

    var body: some View {
        HStack(spacing: 28) {
            ForEach(MeetingResultTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 10) {
                        Text(tab.title)
                            .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(selection == tab ? AppTheme.ink : AppTheme.muted)

                        Rectangle()
                            .fill(selection == tab ? AppTheme.ink : Color.clear)
                            .frame(width: 48, height: 3)
                    }
                    .frame(minWidth: 48)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }

            Spacer(minLength: 0)
        }
        // 与下方正文列（maxWidth 920 + 左右 32）左对齐，不再顶着整条分隔线单独成栏。
        .frame(maxWidth: 920, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity, alignment: .center)
        .background(AppTheme.paper)
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
            Text("整理模型未返回，已保留逐字稿；下面仅显示本地保守结果。")
                .font(.callout)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                Button {
                    player.skip(by: -15)
                } label: {
                    Image(systemName: "gobackward.15")
                }
                .buttonStyle(WorkbenchPlayerIconButtonStyle())
                .help("后退 15 秒")
                .disabled(!player.isAvailable)

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 16, weight: .semibold))
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
                .disabled(!player.isAvailable)

                Text(player.isAvailable ? "录音" : "暂无可播放音频")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)

                Spacer(minLength: 12)

                Menu {
                    ForEach([Float(1), Float(1.25), Float(1.5), Float(2)], id: \.self) { rate in
                        Button("\(rate.cleanRateLabel)×") {
                            player.setRate(rate)
                        }
                    }
                } label: {
                    Text("\(player.playbackRate.cleanRateLabel)×")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppTheme.ink)
                }
                .menuStyle(.borderlessButton)
                .disabled(!player.isAvailable)
                .help("播放速度")

                Text("\(player.currentTime.clockLabel) / \(player.duration.clockLabel)")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .monospacedDigit()
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
        .padding(.horizontal, 32)
        .padding(.top, 12)
        .padding(.bottom, 16)
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

                    Text(session.title)
                        .font(.system(size: 30, weight: .semibold, design: .default))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(session.errorMessage ?? "录音未能启动。")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
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

struct WorkbenchProcessingState: View {
    let session: MeetingSession
    let cancelAction: () -> Void
    let openFolderAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    WorkbenchDarkChip(text: "正在处理", systemImage: "waveform")

                    Text(session.title)
                        .font(.system(size: 30, weight: .semibold, design: .default))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(session.processingStage ?? "正在准备转写...")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.82))
                }

                Spacer(minLength: 8)

                HStack(spacing: 8) {
                    Button {
                        cancelAction()
                    } label: {
                        Label("停止处理", systemImage: "stop.fill")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle())

                    Button {
                        openFolderAction()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle())
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(progressLabel)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Spacer(minLength: 12)
                    Text(elapsedLabel)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.68))
                        .monospacedDigit()
                }

                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.white)

                Text("每段完成后会立即保存，应用重新打开后会从未完成的段继续。")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.68))
            }
            .padding(16)
            .background(
                Color.white.opacity(0.07),
                in: RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
            )
        }
        .workbenchDarkPanel()
    }

    private var progress: Double {
        max(0, min(1, session.processingProgress ?? 0))
    }

    private var progressLabel: String {
        let percent = Int((progress * 100).rounded())
        if let completed = session.processingCompletedChunks,
           let total = session.processingTotalChunks,
           total > 0 {
            return "\(percent)% · 第 \(min(completed + 1, total))/\(total) 段"
        }
        return "\(percent)%"
    }

    private var elapsedLabel: String {
        guard let startedAt = session.processingStartedAt else {
            return "刚刚开始"
        }
        return "已用时 \(max(0, Date().timeIntervalSince(startedAt)).clockLabel)"
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

struct WorkbenchToolbarIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(AppTheme.ink)
            .frame(width: 34, height: 34)
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

struct WorkbenchPlayerIconButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(emphasized ? .white : AppTheme.ink)
            .frame(width: emphasized ? 38 : 32, height: emphasized ? 38 : 32)
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
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(emphasized ? .white : AppTheme.ink)
            .padding(.horizontal, 12)
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

struct WorkbenchDarkButtonStyle: ButtonStyle {
    var emphasized: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(emphasized ? .white : .white.opacity(0.90))
            .padding(.horizontal, 12)
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
