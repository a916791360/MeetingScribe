import Foundation

/// 一场录音的「材料量」：够不够送进整理模型。
///
/// ## 为什么要有这道门禁
///
/// 25 秒的误录也会被送进模型，而模型面对一句话的材料**不会返回空** ——
/// 它会写一段**元评论**：「本次材料仅包含一句栏目推广语，未出现任何会议讨论内容，
/// 因此无法识别会议主题……」。这段话同时做错了三件事：它花了 token、
/// 它挤在「速览」里看着像结论、而它对用户毫无信息量（用户自己刚按了 25 秒的录音键）。
///
/// 所以门禁必须落在**调用模型之前**，而且必须是**纯本地**的 ——
/// 一个要先联网才能判断「要不要联网」的门禁没有意义。
///
/// ## 两条度量怎么定义
///
/// 「有效」= 去掉空白与标点之后还剩的字。这样两件事骗不过门禁：
/// 一段只有「……」的转写、以及一堆换行符。
///
/// - `characters`：所有段落的有效字符数之和
/// - `segments`：**有效字数 ≥ 2** 的段落数（一段「嗯」不算一次发言）
///
/// 两条线是**或**的关系（任一条不足即拦）：只看字数会放过"很长但只有两段"的音频，
/// 只看段数会放过"很多段但每段两个字"的噪音。
///
/// ⚠️ **已知取舍**：段数这条对"少而长"的转写会误伤 —— 一段 2000 字、整场只有 4 段
/// 就会被拦。实测本机 whisper 长会是每分钟 1.7~2.3 段（44 分钟 → 75~90 段），
/// 要到 5 段以下得每 9 分钟才切一段，这个量级不会出现在真实会议里，
/// 所以按计划保留「或」。**如果哪天换了转写引擎、段数密度掉下来，先查这里。**
struct TranscriptMaterial: Equatable, Sendable {
    /// 低于这条线就认为没有会议内容。200 字 ≈ 正常语速不到一分钟。
    static let minimumCharacters = 200
    /// 低于这条线同理。5 段 ≈ 正常会议里两三分钟的发言量。
    static let minimumSegments = 5

    var characters: Int
    var segments: Int

    static let none = TranscriptMaterial(characters: 0, segments: 0)

    /// 材料不足时的判决书；够用就是 nil。
    ///
    /// 三条原因有**优先级**：段数为 0 说明根本没转出内容（另有说法），
    /// 比"字不够"更准确，所以先判它。
    var shortfall: MaterialShortfall? {
        if segments == 0 {
            return MaterialShortfall(reason: .noContent, characters: characters, segments: segments)
        }
        if characters < Self.minimumCharacters {
            return MaterialShortfall(reason: .tooFewCharacters, characters: characters, segments: segments)
        }
        if segments < Self.minimumSegments {
            return MaterialShortfall(reason: .tooFewSegments, characters: characters, segments: segments)
        }
        return nil
    }

    /// 数一份逐字稿。**纯函数**，不碰磁盘也不碰网络 —— 门禁的全部前提。
    static func measure(_ segments: [TranscriptSegment]) -> TranscriptMaterial {
        var characters = 0
        var effectiveSegments = 0
        for segment in segments {
            let count = contentCharacterCount(segment.text)
            characters += count
            if count >= 2 { effectiveSegments += 1 }
        }
        return TranscriptMaterial(characters: characters, segments: effectiveSegments)
    }

    /// 有效字符数：空白、标点、符号都不算。
    ///
    /// 用 `unicodeScalars` 而不是 `count`：中文标点在 `unicodeScalars` 里也是一个
    /// scalar，逐个判不重不漏；而 `.symbols` 一起排掉，是为了 `＋－×÷` 这类
    /// 转写噪音不至于把 200 这条线顶过去。
    static func contentCharacterCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if !ignorableCharacters.contains(scalar) { count += 1 }
        }
    }

    private static let ignorableCharacters: CharacterSet = {
        var set = CharacterSet.whitespacesAndNewlines
        set.formUnion(.punctuationCharacters)
        set.formUnion(.symbols)
        return set
    }()
}

/// 材料不足的判决书：**不是错误**，是一条本地结论。
///
/// 为什么另开一个类型而不复用 `MeetingAnalysis.summaryError`：
/// `summaryError` 的含义是「调了模型、模型没返回，下面是本地保守结果」，
/// 它对应的横幅是「已保留逐字稿；下面仅显示本地保守结果。」——
/// 拿它去描述"我们压根没调模型"是在说谎，而且会把用户骗去设置页换模型
/// （换哪个都一样：材料不够，换模型不解决问题）。
///
/// 存盘（`Codable`）的理由同 `ActionItem.owner`：这个状态要能跨重启活下来，
/// 否则每次打开 App 都会重新判断一次，而判断结果又依赖逐字稿还在不在。
struct MaterialShortfall: Codable, Hashable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// 没转出任何发言（有效段数为 0）。
        case noContent
        /// 有发言，但有效字数不够。
        case tooFewCharacters
        /// 有发言、字数也够，但段数太少。
        case tooFewSegments
    }

    var reason: Reason
    var characters: Int
    var segments: Int

    /// 空态标题。
    var title: String {
        switch reason {
        case .noContent:
            return "这段录音没有会议内容"
        case .tooFewCharacters, .tooFewSegments:
            return "这段录音太短"
        }
    }

    /// 空态正文。
    ///
    /// 两个 View（速览页空态 / 纪要页空态）共用同一份文案 —— 同一件事在两处说，
    /// 就必须逐字一致（这条在本项目里已经栽过一次：空态与横幅各说各的）。
    /// 也正因为要能单测，才把它放在模型层而不是某一个 View 里。
    var message: String {
        switch reason {
        case .noContent:
            return "没有从这段录音里识别到发言内容，因此没有调用整理模型。原文仍然保留，可以在「原文」页确认录音是否正常。"
        case .tooFewCharacters, .tooFewSegments:
            return """
            这段录音只有 \(segments) 段、约 \(characters) 字，没有达到整理一场会议的最低量\
            （\(TranscriptMaterial.minimumSegments) 段 / \(TranscriptMaterial.minimumCharacters) 字），\
            因此没有调用整理模型。原文仍然保留。
            """
        }
    }
}
