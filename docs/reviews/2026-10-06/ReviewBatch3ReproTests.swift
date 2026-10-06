import XCTest
import AVFoundation
@testable import MeetingScribe

final class ReviewBatch3ReproTests: XCTestCase {
    @MainActor
    func testEditedTranscriptExportStillPresentsContradictoryOldMinutesWithoutWarning() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-batch3-edit-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        for i in 0..<6 {
            let text = i == 0 ? "审查甲下周一交付报价单。" : String(repeating: "这是用于隔离验证的完整合成会议背景材料。", count: 3)
            let start = Double(i * 10)
            session.transcriptSegments.append(TranscriptSegment(start: start, end: start + 10, text: text, confidence: 0.9))
        }
        session.transcriptText = session.transcriptSegments.map(\.text).joined(separator: "\n")
        session.analysis = MeetingAnalysis(overview: [], timeline: [], decisions: [], actions: [], confidence: 0.9, minutesText: "审查甲下周一交付报价单。", summaryModel: "审查模型", headline: "下周一交付")
        try storage.save(session)
        let store = MeetingStore(storage: storage)
        guard case .saved = store.updateTranscriptSegment(sessionID: session.id, segmentID: session.transcriptSegments[0].id, text: "审查甲改为下周三交付报价单。") else { return XCTFail("fixture edit must succeed") }
        let edited = try storage.session(with: session.id)
        XCTAssertNotNil(edited.transcriptEditedAt)
        XCTAssertEqual(edited.analysis, session.analysis)
        XCTAssertNil(edited.analysis.noticeMessage)
        let exported = MeetingExporter.markdown(for: edited)
        XCTAssertTrue(exported.contains("## 会议纪要\n\n审查甲下周一交付报价单。"))
        XCTAssertTrue(exported.contains("审查甲改为下周三交付报价单。"))
        XCTAssertFalse(exported.contains("过期"))
        print("BATCH3 stale-export: old Monday minutes + edited Wednesday transcript, no stale notice")
    }

    func testEmojiTitleExceedsFilesystemByteLimitDespiteCharacterLimit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-batch3-name-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var session = MeetingSession.makeDraft(createdAt: Date(), captureMode: .imported, folderName: "fixture")
        session.title = String(repeating: "👨‍👩‍👧‍👦", count: 60)
        let name = MeetingExporter.fileName(for: session)
        XCTAssertGreaterThan(name.utf8.count, 255)
        XCTAssertThrowsError(try "synthetic export".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8))
        print("BATCH3 filename bytes: \(name.utf8.count), Swift characters: \(name.count), write rejected")
    }

    @MainActor
    func testLegacyTextSurvivesButMaterialGateTreatsItAsNoSpeech() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-batch3-legacy-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = SessionStorage(rootURL: root)
        var session = storage.createDraftSession(captureMode: .imported)
        session.status = .ready
        session.transcriptText = String(repeating: "这份旧版全文已经存在且可以导出，不应该被原文页面说成没有内容。", count: 20)
        session.analysis = .empty
        try storage.save(session)
        let store = MeetingStore(storage: storage)
        let loaded = try XCTUnwrap(store.sessions.first)
        XCTAssertEqual(loaded.transcriptText, session.transcriptText)
        XCTAssertTrue(loaded.transcriptSegments.isEmpty)
        XCTAssertNotNil(loaded.analysis.insufficientMaterial)
        XCTAssertTrue(MeetingExporter.markdown(for: loaded).contains(session.transcriptText))
        print("BATCH3 legacy: preserved \(loaded.transcriptText.count) characters, no-speech summary state, exporter includes text")
    }

    @MainActor
    func testPlaybackTimerRetainsOwnerUntilExplicitStop() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ms-batch3-player-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("silence.wav")
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160_000))
        buffer.frameLength = 160_000
        buffer.floatChannelData![0].initialize(repeating: 0, count: 160_000)
        do { let file = try AVAudioFile(forWriting: url, settings: format.settings); try file.write(from: buffer) }
        var strong: MeetingAudioPlayer? = MeetingAudioPlayer()
        strong!.load(url: url)
        XCTAssertTrue(strong!.isAvailable)
        strong!.togglePlayback()
        defer { strong?.stop() }
        weak var weakOwner = strong
        strong = nil
        do {
            let retained = try XCTUnwrap(weakOwner, "scheduled target timer retains the player")
            defer { retained.stop() }
            print("BATCH3 playback: owner remains retained after releasing external reference; isPlaying=\(retained.isPlaying)")
        }
        XCTAssertNil(weakOwner, "explicit stop releases timer ownership")
        weakOwner = nil
    }
}
