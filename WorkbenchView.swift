import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showFailedSessions = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: AppTheme.space5) {
                    VStack(alignment: .leading, spacing: AppTheme.space3) {
                        Text("MeetingScribe")
                            .font(.system(size: 22, weight: .semibold, design: .default))
                            .foregroundStyle(AppTheme.ink)

                        Text("本地保存 · 录音结束后生成结果")
                            .font(.callout)
                            .foregroundStyle(AppTheme.muted)

                        Text("录音、转写和会议要点都在这台 Mac 上完成。")
                            .font(.caption)
                            .foregroundStyle(AppTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, AppTheme.space4)
                    .padding(.top, AppTheme.space4)

                    WorkbenchSidebarSection(
                        title: "最近会话",
                        subtitle: "按时间倒序，先看最新。",
                        count: successfulSessions.count
                    ) {
                        VStack(spacing: 10) {
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

                    if !failedSessions.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button {
                                showFailedSessions.toggle()
                            } label: {
                                WorkbenchSidebarDisclosureLabel(
                                    title: "失败会话",
                                    subtitle: "折叠显示，不抢主视线。",
                                    count: failedSessions.count,
                                    isExpanded: showFailedSessions
                                )
                            }
                            .buttonStyle(.plain)

                            if showFailedSessions {
                                VStack(spacing: 10) {
                                    ForEach(failedSessions) { session in
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
                        .padding(.horizontal, AppTheme.space4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, AppTheme.space4)
            }

            Divider()

            VStack(alignment: .leading, spacing: 6) {
                Text(store.statusText)
                    .font(.callout)
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(2)
                Text("结果只保留在这台 Mac 上。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(AppTheme.space4)
            .background(AppTheme.paperSoft)
        }
        .frame(minWidth: 274, idealWidth: 288, maxWidth: 330)
        .background(AppTheme.paper)
    }

    private var successfulSessions: [MeetingSession] {
        store.sessions.filter { $0.status != .failed }
    }

    private var failedSessions: [MeetingSession] {
        store.sessions.filter { $0.status == .failed }
    }
}

struct WorkbenchSessionRowView: View {
    let session: MeetingSession
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
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

                HStack(spacing: 8) {
                    WorkbenchMetaText(text: session.captureMode.shortTitle, inverse: isSelected)
                    if let duration = session.duration {
                        WorkbenchMetaText(text: duration.clockLabel, inverse: isSelected)
                    }
                    WorkbenchMetaText(text: session.status.title, inverse: isSelected)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(backgroundColor, in: RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.radius, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .overlay(alignment: .leading) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(AppTheme.accent)
                        .frame(width: 3)
                        .padding(.vertical, 12)
                        .padding(.leading, 1)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var titleColor: Color {
        isSelected ? .white : AppTheme.ink
    }

    private var subtitleColor: Color {
        isSelected ? .white.opacity(0.72) : AppTheme.muted
    }

    private var backgroundColor: Color {
        isSelected ? AppTheme.graphite : AppTheme.paperSoft
    }

    private var borderColor: Color {
        isSelected ? AppTheme.graphiteSoft.opacity(0.9) : AppTheme.rule
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
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(AppTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
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

struct WorkbenchSidebarDisclosureLabel: View {
    let title: String
    let subtitle: String
    let count: Int
    let isExpanded: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(AppTheme.ink)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(AppTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Text("\(count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(AppTheme.accentSoft, in: Capsule())

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(AppTheme.muted)
        }
    }
}

struct WorkbenchDetailView: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        VStack(spacing: 0) {
            WorkbenchGlobalActionBar()

            Divider()
                .overlay(AppTheme.rule)

            ScrollView {
                Group {
                    if let session = store.workspaceSession {
                        WorkbenchSessionWorkspace(session: session)
                    } else {
                        WorkbenchEmptyState()
                    }
                }
                .frame(maxWidth: 1220, alignment: .leading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .background(AppTheme.paper)
    }
}

struct WorkbenchGlobalActionBar: View {
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            wideLayout
            compactLayout
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .background(AppTheme.paper)
    }

    private var wideLayout: some View {
        HStack(alignment: .center, spacing: 14) {
            titleBlock

            Spacer(minLength: 12)

            WorkbenchCaptureSourceMenu(
                selection: $store.captureMode,
                isDisabled: store.isRecording || store.isProcessing
            )

            utilityButtons
        }
    }

    private var compactLayout: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 12) {
                titleBlock

                Spacer(minLength: 8)

                settingsButton
            }

            HStack(spacing: 10) {
                WorkbenchCaptureSourceMenu(
                    selection: $store.captureMode,
                    isDisabled: store.isRecording || store.isProcessing
                )

                compactUtilityButtons
            }
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("会议工作台")
                .font(.headline.weight(.semibold))
                .foregroundStyle(AppTheme.ink)

            Text(statusLine)
                .font(.caption)
                .foregroundStyle(AppTheme.muted)
                .lineLimit(1)
        }
        .frame(minWidth: 150, alignment: .leading)
    }

    private var utilityButtons: some View {
        HStack(spacing: 8) {
            Button {
                store.importAudioPresented = true
            } label: {
                Label("导入音频", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(WorkbenchLightButtonStyle())
            .disabled(store.isRecording || store.isProcessing)

            Button {
                toggleRecording()
            } label: {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
            .disabled(store.isProcessing)

            settingsButton
        }
    }

    private var compactUtilityButtons: some View {
        HStack(spacing: 8) {
            Button {
                store.importAudioPresented = true
            } label: {
                Label("导入音频", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(WorkbenchLightButtonStyle())
            .disabled(store.isRecording || store.isProcessing)

            Button {
                toggleRecording()
            } label: {
                Label(primaryTitle, systemImage: primaryIcon)
            }
            .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
            .disabled(store.isProcessing)
        }
    }

    private var settingsButton: some View {
        Button {
            store.showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.callout.weight(.semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(WorkbenchLightButtonStyle())
        .help("设置")
        .accessibilityLabel("设置")
        .keyboardShortcut(",", modifiers: .command)
    }

    private var statusLine: String {
        if store.isRecording {
            return "录音进行中 · 结束后生成逐字稿和会议要点"
        }
        if store.isProcessing {
            return "正在处理 · 结果完成后会留在本机"
        }
        return "新录音会沿用上次选择的录音来源"
    }

    private var primaryTitle: String {
        store.isRecording ? "结束并转写" : "开始录音"
    }

    private var primaryIcon: String {
        store.isRecording ? "stop.fill" : "record.circle"
    }

    private func toggleRecording() {
        if store.isRecording {
            store.stopRecording()
        } else {
            store.startRecording()
        }
    }
}

struct WorkbenchCaptureSourceMenu: View {
    @Binding var selection: CaptureMode
    let isDisabled: Bool

    var body: some View {
        Menu {
            Section("选择下一次录音来源") {
                ForEach(CaptureMode.recordingModes) { mode in
                    Button {
                        selection = mode
                    } label: {
                        Label {
                            Text(mode.selectionLabel)
                        } icon: {
                            Image(systemName: mode.icon)
                        }
                    }
                }
            }

            Divider()

            Text("选择后会自动记住，下次继续使用。")
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selection.icon)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)

                Text(selection.selectionLabel)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(1)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppTheme.muted)
            }
            .frame(minWidth: 220, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(AppTheme.paperSoft, in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous)
                    .stroke(AppTheme.rule, lineWidth: 1)
            )
        }
        .menuStyle(.borderlessButton)
        .disabled(isDisabled)
        .accessibilityLabel("录音来源")
        .accessibilityValue(selection.selectionLabel)
        .help(isDisabled ? "录音或处理进行中，暂不能切换来源" : "更改下一次录音来源")
    }
}

struct WorkbenchSessionWorkspace: View {
    let session: MeetingSession
    @EnvironmentObject private var store: MeetingStore

    var body: some View {
        Group {
            if session.status == .failed {
                WorkbenchFailureState(
                    session: session,
                    openFolderAction: store.openSelectedSessionFolder
                )
            } else {
                VStack(alignment: .leading, spacing: 20) {
                    WorkbenchSnapshotBand(
                        session: session,
                        openFolderAction: store.openSelectedSessionFolder
                    )

                    WorkbenchMetricStrip(session: session)

                    WorkbenchSectionStack(session: session)

                    WorkbenchTranscriptPanel(session: session)
                }
            }
        }
    }

}

struct WorkbenchFailureState: View {
    let session: MeetingSession
    let openFolderAction: () -> Void

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
                        openFolderAction()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(WorkbenchDarkButtonStyle())
                }
            }

            Text("失败记录会留在侧栏折叠区，新的录音不会和它们混在一起。")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.72))
        }
        .workbenchDarkPanel()
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
                        WorkbenchDarkChip(text: session.captureMode.selectionLabel, systemImage: session.captureMode.icon)
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
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.and.mic")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(AppTheme.accent)
                    .frame(width: 38, height: 38)
                    .background(AppTheme.accentSoft, in: RoundedRectangle(cornerRadius: AppTheme.radiusSmall, style: .continuous))

                Text("还没有会议")
                    .font(.system(size: 30, weight: .semibold, design: .default))
                    .foregroundStyle(AppTheme.ink)
            }

            Text("从上方开始一次新的录音，或导入已有音频。")
                .font(.callout)
                .foregroundStyle(AppTheme.muted)

            Text("处理完成后，逐字稿、速览、决策点和待办会集中显示在这里。")
                .font(.callout)
                .foregroundStyle(AppTheme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 560, alignment: .leading)
        .workbenchPanel(cornerRadius: AppTheme.radiusLarge)
        .frame(maxWidth: .infinity, minHeight: 400, alignment: .center)
    }
}

struct WorkbenchSettingsPane: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("设置")
                            .font(.system(size: 28, weight: .semibold, design: .default))
                            .foregroundStyle(.white)

                        Text("告诉 MeetingScribe 你的本地 whisper.cpp 命令和模型文件在哪。")
                            .font(.callout)
                            .foregroundStyle(.white.opacity(0.78))
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: 8) {
                            WorkbenchDarkMeta(text: "本地运行")
                            WorkbenchDarkMeta(text: "不上传")
                            WorkbenchDarkMeta(text: "结果只留在本机")
                        }
                    }
                    .workbenchDarkPanel()

                    let defaults = MeetingStore.defaultRuntimePaths()

                    WorkbenchSettingsPathCard(
                        title: "转写命令",
                        subtitle: "whisper-cli 负责把音频交给本地识别引擎。",
                        systemImage: "terminal.fill",
                        path: $store.whisperCLIPath,
                        defaultPath: defaults.cliURL.path,
                        isValid: FileManager.default.fileExists(atPath: store.whisperCLIPath),
                        restoreAction: {
                            store.whisperCLIPath = defaults.cliURL.path
                            store.refreshPreferences()
                        }
                    )

                    WorkbenchSettingsPathCard(
                        title: "模型文件",
                        subtitle: "模型决定中文转写的准确度，也是最关键的一项。",
                        systemImage: "cube.transparent.fill",
                        path: $store.whisperModelPath,
                        defaultPath: defaults.modelURL.path,
                        isValid: FileManager.default.fileExists(atPath: store.whisperModelPath),
                        restoreAction: {
                            store.whisperModelPath = defaults.modelURL.path
                            store.refreshPreferences()
                        }
                    )

                    HStack {
                        Button("恢复默认") {
                            store.whisperCLIPath = defaults.cliURL.path
                            store.whisperModelPath = defaults.modelURL.path
                            store.refreshPreferences()
                        }
                        .buttonStyle(WorkbenchLightButtonStyle())

                        Spacer(minLength: 12)

                        Button("完成") {
                            store.refreshPreferences()
                            dismiss()
                        }
                        .buttonStyle(WorkbenchLightButtonStyle(emphasized: true))
                    }
                }
                .padding(24)
            }
            .navigationTitle("设置")
            .background(AppTheme.paper)
        }
        .frame(minWidth: 760, minHeight: 560)
        .onChange(of: store.whisperCLIPath) { _, _ in
            store.refreshPreferences()
        }
        .onChange(of: store.whisperModelPath) { _, _ in
            store.refreshPreferences()
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

struct WorkbenchConfidenceChip: View {
    let value: Double

    var body: some View {
        Text(value.confidenceLabel)
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
        Text(priority.label)
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
