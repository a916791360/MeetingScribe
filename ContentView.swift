import SwiftUI
import UniformTypeIdentifiers

enum SessionDetailSection: String, CaseIterable, Identifiable {
    case overview
    case transcript
    case decisions
    case actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "速览"
        case .transcript:
            return "逐字稿"
        case .decisions:
            return "决策点"
        case .actions:
            return "待办"
        }
    }

    var icon: String {
        switch self {
        case .overview:
            return "text.alignleft"
        case .transcript:
            return "doc.text.magnifyingglass"
        case .decisions:
            return "checklist"
        case .actions:
            return "tray.full"
        }
    }
}

struct ContentView: View {
    @EnvironmentObject private var store: MeetingStore

    @State private var selectedSection: SessionDetailSection = .overview
    @State private var showDeleteConfirmation = false

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            VStack(spacing: 0) {
                header
                Divider()
                detailArea
            }
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: 1200, minHeight: 800)
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
            SettingsView()
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

    private var sidebar: some View {
        List(selection: $store.selectedSessionID) {
            if store.sessions.isEmpty {
                ContentUnavailableView(
                    "还没有会议",
                    systemImage: "tray",
                    description: Text("开始录音或导入一段音频，结果会保留在这台 Mac 上。")
                )
                .listRowSeparator(.hidden)
            } else {
                Section("最近会话") {
                    ForEach(store.sessions) { session in
                        SessionRowView(session: session)
                            .tag(session.id)
                    }
                    .onDelete { indexSet in
                        let sessionsToDelete = indexSet.compactMap { index in
                            store.sessions.indices.contains(index) ? store.sessions[index] : nil
                        }
                        sessionsToDelete.forEach(store.deleteSession)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("会议")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(store.selectedSession?.title ?? "会议")
                        .font(.title2.weight(.semibold))
                    HStack(spacing: 10) {
                        StatusBadge(status: store.selectedSession?.status ?? .ready)
                        if let duration = store.selectedSession?.duration {
                            MetaBadge(text: duration.clockLabel, systemImage: "clock")
                        }
                        if let captureMode = store.selectedSession?.captureMode {
                            MetaBadge(text: captureMode.title, systemImage: captureMode.icon)
                        }
                    }
                }

                Spacer(minLength: 12)

                HStack(spacing: 10) {
                    Button(action: primaryAction) {
                        Label(primaryTitle, systemImage: primaryIcon)
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(primaryTint)
                    .disabled(store.isProcessing)

                    Button {
                        store.importAudioPresented = true
                    } label: {
                        Label("导入音频", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isRecording || store.isProcessing)

                    Button {
                        store.openSelectedSessionFolder()
                    } label: {
                        Label("打开文件夹", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.selectedSession == nil)

                    Button {
                        store.showSettings = true
                    } label: {
                        Label("设置", systemImage: "gearshape")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack(spacing: 16) {
                Picker("输入方式", selection: $store.captureMode) {
                    ForEach(CaptureMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.icon).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                Spacer()

                Text(store.statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    @ViewBuilder
    private var detailArea: some View {
        if let session = store.selectedSession {
            SessionDetailView(session: session, selectedSection: $selectedSection)
        } else {
            ContentUnavailableView(
                "选中一场会议",
                systemImage: "doc.text.magnifyingglass",
                description: Text("左侧选一个会话，或者直接开始录音。")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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

    private var primaryTitle: String {
        if store.captureMode == .imported {
            return "导入音频"
        }
        return store.isRecording ? "结束并转写" : "开始录音"
    }

    private var primaryIcon: String {
        if store.captureMode == .imported {
            return "square.and.arrow.down"
        }
        return store.isRecording ? "stop.fill" : "record.circle"
    }

    private var primaryTint: Color {
        if store.isRecording {
            return .red
        }
        return .accentColor
    }

    private func primaryAction() {
        if store.captureMode == .imported {
            store.importAudioPresented = true
        } else if store.isRecording {
            store.stopRecording()
        } else {
            store.startRecording()
        }
    }
}

struct SessionRowView: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Text(session.createdAt, format: .dateTime.month().day().hour().minute())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                Image(systemName: session.status.icon)
                    .foregroundStyle(statusColor)
            }

            HStack(spacing: 8) {
                MetaBadge(text: session.captureMode.title, systemImage: session.captureMode.icon)
                StatusBadge(status: session.status)
                if let duration = session.duration {
                    MetaBadge(text: duration.clockLabel, systemImage: "clock")
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch session.status {
        case .recording:
            return .red
        case .processing:
            return .orange
        case .ready:
            return .green
        case .failed:
            return .red
        }
    }
}

struct SessionDetailView: View {
    let session: MeetingSession
    @Binding var selectedSection: SessionDetailSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                metadataBlock

                Picker("内容", selection: $selectedSection) {
                    ForEach(SessionDetailSection.allCases) { section in
                        Label(section.title, systemImage: section.icon).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 620)

                switch selectedSection {
                case .overview:
                    OverviewSection(session: session)
                case .transcript:
                    TranscriptSection(session: session)
                case .decisions:
                    DecisionSection(session: session)
                case .actions:
                    ActionSection(session: session)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var metadataBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.title)
                        .font(.title3.weight(.semibold))
                        .textSelection(.enabled)
                    Text(session.createdAt, format: .dateTime.year().month().day().hour().minute())
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 12)

                StatusBadge(status: session.status)
            }

            HStack(spacing: 10) {
                MetaBadge(text: session.captureMode.title, systemImage: session.captureMode.icon)
                if let duration = session.duration {
                    MetaBadge(text: "时长 \(duration.clockLabel)", systemImage: "clock")
                }
                MetaBadge(text: "置信度 \(session.analysis.confidence.confidenceLabel)", systemImage: "scope")
            }

            if let errorMessage = session.errorMessage, !errorMessage.isEmpty {
                Text(errorMessage)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
    }
}

struct OverviewSection: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("重点速览", subtitle: "按时间切块展示会议关键片段。")

            if session.analysis.overview.isEmpty {
                emptyHint("还没有提取出足够明确的速览。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.analysis.overview) { item in
                        InsightRow(item: item)
                        if item.id != session.analysis.overview.last?.id {
                            Divider()
                        }
                    }
                }
            }

            sectionTitle("时间切块", subtitle: "每个块都保留原文依据。")

            if session.analysis.timeline.isEmpty {
                emptyHint("没有足够的分段结果。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.analysis.timeline) { chunk in
                        TimelineRow(chunk: chunk)
                        if chunk.id != session.analysis.timeline.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct TranscriptSection: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("逐字稿", subtitle: "保留原汁原味的转写内容。")

            if session.transcriptSegments.isEmpty {
                emptyHint("转写还没出来。")
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.transcriptSegments) { segment in
                        TranscriptRow(segment: segment)
                        if segment.id != session.transcriptSegments.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct DecisionSection: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("决策点", subtitle: "只展示有把握的判断。")

            if session.analysis.decisions.isEmpty {
                emptyHint("没有提取到足够明确的决策。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.analysis.decisions) { item in
                        InsightRow(item: item)
                        if item.id != session.analysis.decisions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct ActionSection: View {
    let session: MeetingSession

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            sectionTitle("待办", subtitle: "优先级、依据和截止时间都保留。")

            if session.analysis.actions.isEmpty {
                emptyHint("没有提取到足够明确的待办。")
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(session.analysis.actions) { item in
                        ActionRow(item: item)
                        if item.id != session.analysis.actions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }
}

struct InsightRow: View {
    let item: InsightItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                ConfidenceBadge(value: item.confidence)
            }

            if let timestamp = item.timestamp {
                Text(timestamp.clockLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(item.evidence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct TimelineRow: View {
    let chunk: TimelineChunk

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(chunk.title)
                    .font(.body.weight(.medium))
                Spacer(minLength: 8)
                ConfidenceBadge(value: chunk.confidence)
            }

            Text(chunk.summary)
                .font(.callout)
                .textSelection(.enabled)

            Text(chunk.evidence)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct TranscriptRow: View {
    let segment: TranscriptSegment

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(segment.timeLabel)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                ConfidenceBadge(value: segment.confidence)
            }

            Text(segment.text)
                .font(.body)
                .textSelection(.enabled)
        }
    }
}

struct ActionRow: View {
    let item: ActionItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(item.label)
                    .font(.body.weight(.medium))
                    .textSelection(.enabled)
                Spacer(minLength: 8)
                if let priority = item.priority {
                    PriorityBadge(priority: priority)
                }
                ConfidenceBadge(value: item.confidence)
            }

            HStack(spacing: 10) {
                if let dueText = item.dueText {
                    MetaBadge(text: "截止 \(dueText)", systemImage: "calendar")
                }
                if let timestamp = item.timestamp {
                    MetaBadge(text: timestamp.clockLabel, systemImage: "clock")
                }
            }

            Text(item.evidence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var store: MeetingStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("本地转写") {
                    TextField("whisper-cli 路径", text: $store.whisperCLIPath)
                    TextField("模型路径", text: $store.whisperModelPath)
                    Text("默认会回落到本机的 whisper.cpp 目录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("默认路径") {
                    let defaults = MeetingStore.defaultRuntimePaths()
                    Text(defaults.cliURL.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Text(defaults.modelURL.path)
                        .font(.footnote)
                        .textSelection(.enabled)
                    Button("恢复默认") {
                        let defaults = MeetingStore.defaultRuntimePaths()
                        store.whisperCLIPath = defaults.cliURL.path
                        store.whisperModelPath = defaults.modelURL.path
                        store.refreshPreferences()
                    }
                }
            }
            .navigationTitle("设置")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") {
                        store.refreshPreferences()
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 620, minHeight: 420)
        .onChange(of: store.whisperCLIPath) { _, _ in
            store.refreshPreferences()
        }
        .onChange(of: store.whisperModelPath) { _, _ in
            store.refreshPreferences()
        }
    }
}

struct StatusBadge: View {
    let status: MeetingStatus

    var body: some View {
        MetaBadge(text: status.title, systemImage: status.icon, tint: tint)
    }

    private var tint: Color {
        switch status {
        case .recording:
            return .red
        case .processing:
            return .orange
        case .ready:
            return .green
        case .failed:
            return .red
        }
    }
}

struct MetaBadge: View {
    let text: String
    let systemImage: String
    var tint: Color = .secondary

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage)
        }
        .font(.caption)
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

struct ConfidenceBadge: View {
    let value: Double

    var body: some View {
        Text(value.confidenceLabel)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }
}

struct PriorityBadge: View {
    let priority: PriorityLevel

    var body: some View {
        Text(priority.label)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
    }

    private var color: Color {
        switch priority {
        case .p1:
            return .red
        case .p2:
            return .orange
        case .p3:
            return .secondary
        }
    }
}

@ViewBuilder
private func sectionTitle(_ title: String, subtitle: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
        Text(title)
            .font(.headline)
        Text(subtitle)
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

@ViewBuilder
private func emptyHint(_ text: String) -> some View {
    Text(text)
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(.vertical, 6)
}
