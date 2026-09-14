import Foundation
import os

/// 双声道链路（P2-2a）的可观察性。
///
/// ## 为什么需要它
///
/// 双声道的**降级是静默的**：某一路没挂上、挂上了但一个样本都没来、或者全程静音，
/// 表现**完全一样** —— 逐字稿照常出来，只是没有说话人标签。而"没有说话人标签"
/// 在界面上看不出任何异常。
///
/// 于是这条链路上**任何一环断掉都等于白做**，而且断在哪里完全无从判断。
/// 2026-09-14 就真断过一次：录音会话的构造漏传了两路 URL（吃了 `nil` 默认值），
/// 整条链路静默退回单路 —— 编译通过、171 条测试全绿、录音与转写一切正常，
/// 用户唯一能看到的只有"逐字稿里没有 `[我方]` / `[对方]`"。
///
/// 所以链路每一步都往统一日志写一行。排查时：
///
/// ```
/// log show --last 30m --predicate 'subsystem == "com.qingmeng.meetingscribe"' --info
/// ```
///
/// 一场正常录音应该按顺序看到：
///
/// 1. `录音会话接线`（两路的文件名）
/// 2. `挂上采样输出` ×2（我方 / 对方）
/// 3. `两路收尾`（各路写了多少帧，或为什么废了）
/// 4. `归一化` ×2
/// 5. `转写计划`（哪几路有声、合并后带说话人的段数）
///
/// **少了哪一行，就是断在哪一环。** 少了第 1 行意味着调用方没接线；
/// 第 2 行报错意味着系统不接受 `.microphone` 这个 output 类型；
/// 第 3 行写着 0 帧意味着挂上了但系统没往这一路投递样本。
enum Diagnostics {
    private static let subsystem = "com.qingmeng.meetingscribe"

    /// 录音 / 双声道链路。
    static let audio = Logger(subsystem: subsystem, category: "dual-track")

    /// 转写与整理。
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
}
