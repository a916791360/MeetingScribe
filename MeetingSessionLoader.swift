import Foundation

struct SessionLoadReport: Sendable {
    var sessions: [MeetingSession]
    var issues: [String]
    var writeFailed: Bool
}

/// Startup decoding and conservative recovery are pure file work, independent of UI state.
enum MeetingSessionLoader {
    static func load(storage: SessionStorage, activeID: UUID? = nil) -> SessionLoadReport {
        let load = storage.loadSessionsReport()
        var loadedSessions = load.sessions
        var writeFailed = false
        func persist(_ session: MeetingSession) {
            do { try storage.save(session) }
            catch { writeFailed = true }
        }
        for index in loadedSessions.indices
            where loadedSessions[index].id != activeID && loadedSessions[index].status == .ready &&
                (
                    loadedSessions[index].analysis.summaryModel == nil ||
                        loadedSessions[index].analysis.summaryModel == "本地整理" ||
                        loadedSessions[index].analysis.summaryModel == SummaryModelProvider.localRules.title
                ) {
            let analysis = MeetingAnalysisBuilder.build(from: loadedSessions[index].materialSegments)
            if analysis != loadedSessions[index].analysis {
                loadedSessions[index].analysis = analysis
                loadedSessions[index].updatedAt = Date()
                persist(loadedSessions[index])
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
            where loadedSessions[index].id != activeID && !loadedSessions[index].transcriptSegments.isEmpty && MeetingAnalysisBuilder.needsMaterialGateRepair(loadedSessions[index]) {
            let analysis = MeetingAnalysisBuilder.build(from: loadedSessions[index].materialSegments)
            if analysis != loadedSessions[index].analysis {
                loadedSessions[index].analysis = analysis
                loadedSessions[index].updatedAt = Date()
                persist(loadedSessions[index])
            }
        }

        for index in loadedSessions.indices where loadedSessions[index].status == .recording && loadedSessions[index].id != activeID {
            loadedSessions[index].status = .failed
            loadedSessions[index].errorMessage = "应用退出时录音未完成，原始文件已保留，可以重新处理。"
            loadedSessions[index].updatedAt = Date()
            persist(loadedSessions[index])
        }

        return SessionLoadReport(sessions: loadedSessions, issues: load.issues, writeFailed: writeFailed)
    }
}
