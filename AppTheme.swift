import SwiftUI
import AppKit

// 窗口底层承载导航；统一内容面承载标题、正文和播放器。
// 所有表面随 NSAppearance 切换，深色模式保持同样的层级关系。

/// 界面外观。三档，与 macOS「外观」偏好一一对应。
///
/// **为什么设 `NSApplication.appearance` 而不是 SwiftUI 的 `.preferredColorScheme`。**
/// 色板是 `NSColor(name:dynamicProvider:)`，它读的就是 `NSAppearance`，两者天生同源；
/// 而 `preferredColorScheme` 只覆盖 SwiftUI 的内容层，窗口标题栏与 sheet 页头这些
/// 由 AppKit 自己画的 chrome 不一定跟着翻 —— 那正是这次要修的「一屏两套语言」。
/// 设进程级 appearance，SwiftUI 与 AppKit 一起翻，也不会漏掉后开的 sheet。
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var summary: String {
        switch self {
        case .system: return "跟着 macOS 的「外观」偏好自动切换。"
        case .light: return "始终使用浅色，不跟随系统。"
        case .dark: return "始终使用深色，不跟随系统。"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    /// 应用到整个进程。`nil` 表示交还给系统。
    ///
    /// 标 `@MainActor`：`NSApplication.appearance` 与 `NSWindow.appearance` 都是
    /// 主 actor 隔离的属性，Swift 6 严格并发下必须在主 actor 上改。
    @MainActor
    static func apply(_ appearance: AppAppearance) {
        let target = appearance.nsAppearance
        NSApplication.shared.appearance = target
        for window in NSApplication.shared.windows {
            window.appearance = target
        }
    }
}

enum AppTheme {
    // MARK: - 表面阶梯
    //
    // 浅色与深色的**抬升方向是相反的**：浅色下越浅越靠前，深色下越亮越靠前。
    // 所以 `paperSoft` 在浅色档比 `paper` 亮一点、在深色档也比 `paper` 亮一点 ——
    // 一样的方向，两种外观下都读成「抬起来的一层」。

    /// 窗口底层：侧栏与内容卡片外侧的中性灰。
    static let windowCanvas = dynamic(light: (0.945, 0.949, 0.957), dark: (0.078, 0.086, 0.102))
    /// 主内容面：浅色为白色，深色为比底层明亮一档的表面。
    static let contentSurface = dynamic(light: (1, 1, 1), dark: (0.125, 0.137, 0.161))
    /// 内容面边缘，仅用发丝线定界，不给导航添加阴影或外框。
    static let contentEdge = dynamic(light: (0.882, 0.890, 0.906), dark: (0.216, 0.235, 0.278))
    static let sidebarWidth: CGFloat = 280
    /// 原生窗口按钮与内容面之间的连续底层，兼作空白拖动区。
    static let windowChromeHeight: CGFloat = 28

    /// 局部辅助区域的底色（设置、提示与控件）。
    static let paper = dynamic(light: (0.972, 0.979, 0.993), dark: (0.086, 0.094, 0.114))
    /// 抬升面：面板、分组卡、卡片。
    static let paperSoft = dynamic(light: (0.988, 0.991, 0.997), dark: (0.153, 0.168, 0.204))
    /// 控件底盘：标题栏次级按钮这类「贴在 chrome 上、需要自己立起来」的小面。
    /// 比 `paper` 高一档；浅色档取 `paper`，与改动前一致。
    static let controlSurface = dynamic(light: (0.972, 0.979, 0.993), dark: (0.217, 0.235, 0.284))
    /// 凹陷轨道：分段控件的槽。**比 `paper` 低一档**，凸起段才立得起来。
    static let segmentTrack = dynamic(light: (0.929, 0.941, 0.965), dark: (0.039, 0.043, 0.055))
    /// 选中段 / 凸起胶囊的面。浅色档取 `paper`，与改动前一致。
    static let segmentSelected = dynamic(light: (0.972, 0.979, 0.993), dark: (0.153, 0.168, 0.204))
    /// 控件底盘的描边。**浅色档等于底盘本身**（等于不描边）—— 浅色下近白实底
    /// 贴在浅色标题栏上已经分得清，多一条边只会变脏；深色下明度差天然难做，
    /// 不给一条边就真的读不出「这是个按钮」（用户实测反馈）。深色档对底盘 1.53:1。
    static let controlEdge = dynamic(light: (0.972, 0.979, 0.993), dark: (0.322, 0.353, 0.416))

    /// 强调面板（失败卡片、结果页大标题卡、设置页头）。
    ///
    /// **这个 token 在两种外观下是「角色互换」的**：浅色模式下它是一块压在浅纸上的深色板
    /// （比纸面暗得多，靠明度反差立起来）；深色模式下页面本身就是深的，此时再压一块更黑的板
    /// 就只剩一团煤 —— 所以深色档让它变成**比纸面亮的抬升面**，靠「更亮」立起来。
    ///
    /// 面板上的墨是纯白（`Color.white` 系列，写在各视图里），两种方向下都读得清，
    /// 因此这一处角色互换不需要改任何调用点。
    static let graphite = dynamic(light: (0.122, 0.140, 0.169), dark: (0.187, 0.201, 0.238))
    /// 强调面板的描边 / 次一级底色。
    static let graphiteSoft = dynamic(light: (0.156, 0.176, 0.208), dark: (0.234, 0.250, 0.290))

    // MARK: - 墨与线

    /// 主文字。
    static let ink = dynamic(light: (0.102, 0.121, 0.146), dark: (0.937, 0.949, 0.969))
    /// 次级文字。深色档提亮到 8.0:1，浅色档维持 4.8:1。
    static let muted = dynamic(light: (0.387, 0.439, 0.510), dark: (0.647, 0.686, 0.749))
    /// 发丝线（1pt 分隔线、描边）。
    static let rule = dynamic(light: (0.842, 0.866, 0.901), dark: (0.216, 0.235, 0.278))
    /// 加重描边（悬停态等）。
    static let ruleStrong = dynamic(light: (0.742, 0.788, 0.855), dark: (0.322, 0.353, 0.416))

    // MARK: - 品牌色（Cobalt）

    /// 交互墨色：**当文字、图标、小色块用**。深色档提亮到 #76A9FF，对深纸 7.5:1。
    ///
    /// **浅色档 2026-09-15 调深（阶段 3-1）**：(0.153, 0.420, 0.980) → (0.1412, 0.3877, 0.9045)。
    ///
    /// 为什么动它：原来那一档对 `paper` 只有 **4.38:1**，而它实实在在当**按钮标签**在用
    /// （设置页「更换会后整理接入方式」、空态「去授权」、结果页提示条的「打开设置」…），
    /// AA 对正文的门槛是 4.5:1 —— 差 0.12，属于「贴线不达标」，谁也不会为它报个 bug。
    ///
    /// 这正是本项目「护栏冻结了基线里的缺陷」那条教训的一次具体落地：旧注释写着
    /// 「浅色档是已验基线、不准动」，于是一个不达标的色被合规地锁了很多轮。
    /// 现在按**保色相、保饱和度、等比压暗**（k = 0.923）取到
    /// **对 paper 5.00:1 / 对 paperSoft 5.14:1**，一次改掉全部「accent 当文字」的站点，
    /// 且不引入第二个蓝。图标（门槛 3:1）、描边、填充、`tint` 都不受影响。
    ///
    /// `accentFill` **不动** —— 它是「当底 + 压白字」的那一支，白字对它 4.59:1，
    /// 跟着调深会让白字掉下去。浅色档这两个 token 从此不再同值，正是它们该分开的理由。
    static let accent = dynamic(light: (0.1412, 0.3877, 0.9045), dark: (0.463, 0.663, 1.0))
    /// 实底填充：**当底色用，上面压白字**。两档都保持 #276BFA —— 白字对它是 4.59:1，
    /// 深色档若跟着提亮，白字立刻掉到 2.6:1，所以这一支必须钉住不动。
    /// 浅色档与 `accent` 同值，改动前也是同一个色，拆开只是为了深色档能分开走。
    static let accentFill = Color(nsColor: NSColor(calibratedRed: 0.153, green: 0.420, blue: 0.980, alpha: 1))
    /// 品牌色的浅底：选中行、小徽标。深色档是一层低饱和的蓝，压在上面的 `muted` 仍有 5.3:1。
    static let accentSoft = dynamic(light: (0.878, 0.925, 1.0), dark: (0.145, 0.212, 0.376))

    // MARK: - 语义色
    //
    // 每一支都按「当墨用」提亮（深色档对深纸 ≥ 4.5:1）。
    // 需要「当底 + 白字」的那两支另有 `*Fill` 版本，钉在浅色档的数值上。

    static let success = dynamic(light: (0.132, 0.635, 0.341), dark: (0.290, 0.788, 0.478))
    static let warning = dynamic(light: (0.945, 0.596, 0.149), dark: (0.976, 0.694, 0.278))
    static let danger = dynamic(light: (0.854, 0.204, 0.239), dark: (0.949, 0.404, 0.435))
    /// 危险色的实底版（录制中的标题栏主按钮）。同上，白字需要它保持在 4.6:1。
    static let dangerFill = Color(nsColor: NSColor(calibratedRed: 0.854, green: 0.204, blue: 0.239, alpha: 1))

    /// 把一个颜色对包成随系统外观解析的动态色。
    ///
    /// 用 `calibratedRed` 而不是 `sRGBRed`：现有色板就是按 calibrated RGB 定的，
    /// 换成 sRGB 会让浅色模式整体偏一点点，属于无谓的回归。
    private static func dynamic(
        light: (CGFloat, CGFloat, CGFloat),
        dark: (CGFloat, CGFloat, CGFloat)
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let value = isDark ? dark : light
            return NSColor(
                calibratedRed: value.0,
                green: value.1,
                blue: value.2,
                alpha: 1
            )
        })
    }

    static let radiusLarge: CGFloat = 16
    static let radius: CGFloat = 12
    static let radiusSmall: CGFloat = 10
    static let radiusTiny: CGFloat = 8

    /// 4pt 间距刻度。新代码只从这几档里取值，
    /// 不要再写 5 / 7 / 9 / 11 / 14 / 18 / 22 / 26 / 28 这类散值。
    static let space1: CGFloat = 4
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
    static let space7: CGFloat = 32

    /// 控件尺寸只留三档：紧凑图标按钮 / 常规图标按钮 / 强调圆形按钮。
    static let controlCompact: CGFloat = 32
    static let controlRegular: CGFloat = 34
    static let controlEmphasis: CGFloat = 38

    /// 会议头、结果页 Tab、正文文档共用同一条居中列，三者左边界必须齐平。
    ///
    /// **920 → 800（v0.6.2）**：原来这一列是给"工作台"定的宽度，但结果页三张页签
    /// 全都是**文档**，铺到 920pt 之后 15pt 的中文一行能排到 60 字开外 ——
    /// 眼睛要横扫一整个屏幕才换行，读起来非常累（用户原话「信息不易阅读」）。
    /// 收窄到 800 之后左右各留 139pt 余白，视线一次能兜住整行。
    /// Tab 条、章节标题、正文左边界**三者仍然共用这一条列**，所以它们还是齐平的。
    ///
    /// **条目行不再内缩（v0.6.2 第二轮）**：这一列同时是**条目行的行宽**。
    /// 原来速览 / 纪要 / 原文三页的条目左边还有一条 96pt 的时间轨（正文要
    /// 再往右 112pt 才起笔），于是「决策与结论」这类章节标题在 421、而条目正文在
    /// 533 —— 用户原话「内容是非常往右的」。现在轨撤掉、时间改成条目内的元信息，
    /// **条目正文与章节标题共用结构列左沿**，右端也仍然齐平：
    /// 正文右边界、徽标右端、行间分隔线、章节分隔线落在同一条竖线上。
    static let contentColumn: CGFloat = 800
    static let contentInset: CGFloat = 32

    /// **条目行**的行宽。它必须**等于**结构列（v0.6.2 第二轮）。
    ///
    /// 单独起这个名字有两个用处：调用处读得出"这一行属于文档列"；
    /// 而 `LayoutTokenTests` 有一条算式可以守 —— 这个数一旦被改小，
    /// 就意味着有人又把条目往右推了，那正是用户报的「内容是非常往右的」。
    /// 上一版三页的条目左边各有一条 96pt 的时间轨，正文要再往右 112pt 才起笔，
    /// 而章节标题在结构列左沿：两者错开 112pt。
    ///
    /// 名字的区别：`contentColumn` 说的是"这一列有多宽"（容器用它），
    /// `documentRowWidth` 说的是"这一行铺满这一列"（条目用它）。两者必须相等。
    static var documentRowWidth: CGFloat { contentColumn }

    /// 散文块（速览导语 / 纪要正文）在容器里的**行宽**。
    ///
    /// 容器是**结构列的一个整宽盒子**：外沿 800 = 行宽 760 + 两侧内衬 40。
    /// 这条等式是"盒子的左右边框跟章节分隔线同宽"的全部依据 ——
    /// 改任一边而另一边没跟上，盒子的边就飘到结构线之外，整页立刻显毛。
    ///
    /// 上一版容器是 720（= 680 + 40），左沿虽然在结构线上，
    /// 右沿却落在 1141.5 —— 比结构列的 1221 短 79.5pt，比正文列短 71.5pt，
    /// 是那页上第三条右边界（用户原话「各种元素对不齐」）。
    /// 现在右沿归位：**盒子 = 结构列**。
    ///
    /// 为什么盒子的字是 760 而不是整 800：这是一个**带内衬的面** ——
    /// 有背景、有 1pt 边框，字贴着框线站会把框读成"挤"。所以两侧各让 20pt。
    /// 条目行（时间线 / 决策 / 待办 / 逐字稿）**没有面、也没有框**，
    /// 因此不设内衬，字直接排在 800 上 —— 它们靠行间分隔线立住，不靠边框。
    static let proseLineWidth: CGFloat = 760

    /// 结果页控制条：一个**贴合内容宽度**的分段控件 + 右侧页内动作。
    /// 轨道比纸面深一档（paper 是 248,250,253），白色凸起段才立得起来；
    /// 轨道若也用 paper，选中段和轨道会糊成一片，正是「看不出边界」的老毛病。
    /// 分段高度：轨道 2pt 内衬 + 28pt 凸起段 = 32pt，与 controlCompact 同高。
    static let segmentHeight: CGFloat = 28
    static let segmentRadius: CGFloat = 8
    /// 控制条整行高度。
    static let segmentRowHeight: CGFloat = 46
    /// 控制条里的图标命中区，比图标本身大一圈，才够好点。
    static let stripIconHit: CGFloat = 30
}

/// 排印阶梯。
///
/// **文档页面只从这几档里取值。** 上一版的毛病是 20 / 18 / callout 三档挤在一起：
/// 导语和条目正文只差 2pt，既谈不上层级，又每一段都偏大，整页读起来松垮；
/// 而"依据"这种注脚却跟主句只差一档，主次分不开。
/// 现在把六档拉开：**章节标题 17** / 导语 16.5 / 正文 15 / 主句 14.5 semibold /
/// 依据 12 / 元信息 11，**行距也按字号分档**（大字的行距要更大，否则行与行太挤）。
///
/// ⚠️ **章节标题必须站在整条阶梯的最上面**：条目主句是 14.5 semibold，
/// 章节标题原来只有 13 —— 同一页里标题反而比条目里那句话还小，两块就糊成一片，
/// 章节读不出来（用户原话「标题应该稍大一些，不然和内容融一起了」）。
/// 标题不只是"比正文大"，它要压过主句那一档，所以直接跳到导语之上。
enum AppType {
    /// 速览页顶部的**一句话结论**。整页唯一一处 22pt，
    /// 因为它是"读完这一行就可以走了"的那一行，必须一眼压过下面所有区块。
    ///
    /// 与 `sectionTitle`(17) 拉开 5pt 是刻意的：两者一上一下挨着，
    /// 只差一两档就会被读成"同一级的另一个标题"。
    static let documentHeadline = Font.system(size: 22, weight: .semibold)
    /// 速览导语。它是"整场概览"，角色与条目正文不同，所以大一档。
    static let documentLead = Font.system(size: 16.5, weight: .regular)
    /// 文档正文：纪要认真叙述、速览时间线的条目正文。
    static let documentBody = Font.system(size: 15, weight: .regular)
    /// 纪要正文里的小标题（`## 一、…`）。
    ///
    /// **必须低于 `sectionTitle`(17)**：速览页的「决策与结论 / 待办」是整页最高一档，
    /// 而纪要正文是**面板里的一篇文章**，它的小标题不该跟页面章节标题抢层级 ——
    /// 抢过去之后，读者分不清"这一节是文章的一部分"还是"这是页面上的新一栏"。
    ///
    /// **又必须与 `documentBody`(15) 拉开字重**：只差 1pt 时，靠字号根本看不出这是标题，
    /// 读完标题会不知道正文从哪开始。所以层级由**字重**承担（regular → semibold），
    /// 字号只提 1pt 配合。
    static let documentSubheading = Font.system(size: 16, weight: .semibold)
    /// 条目主句：决策 / 待办的那一句话。同字号里唯一的 semibold，靠字重立起来。
    static let documentItemLabel = Font.system(size: 14.5, weight: .semibold)
    /// 条目依据。注脚，不是内容 —— 小两档 + 退到 `muted`。
    static let documentEvidence = Font.system(size: 12, weight: .regular)
    /// 时间轨、计数这类元信息。
    static let documentMeta = Font.system(size: 11, weight: .semibold)
    /// 章节标题（速览页的决策与结论 / 待办 / 风险与阻塞）。**整条阶梯的最高一档**，
    /// 必须压过 `documentItemLabel`，否则标题和条目里的句子糊成一片（见上）。
    static let sectionTitle = Font.system(size: 17, weight: .semibold)

    static let leadLineSpacing: CGFloat = 7
    static let bodyLineSpacing: CGFloat = 6.5
    static let evidenceLineSpacing: CGFloat = 4

    /// 文档条目的上下留白。速览与纪要共用同一个值，两页的节奏才一致。
    static let documentItemPadding: CGFloat = 14
}

extension View {
    func workbenchPanel(cornerRadius: CGFloat = AppTheme.radius) -> some View {
        self
            .padding(AppTheme.space5)
            .background(AppTheme.paperSoft)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.rule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    /// 散文块容器：把**那一段话**（速览导语 / 纪要正文）圈起来。
    ///
    /// 为什么只圈这一段：整页内容原来直接铺在页面底上，导语读起来"漂"着没有归属
    /// （用户原话「内容还是直接铺在上面，加个容器把这些内容包起来」）。
    /// 但**不该给整页套一层**——下面的时间线、决策、待办本来就是结构化条目，
    /// 它们靠时间轨和分隔线立住；再罩一层大纸，等于在纸上又画一个框，
    /// 是 Hallmark 说的 card-on-card slop。
    ///
    /// 所以边界画在**散文与条目之间**：散文是"一整段话"，给它一个面；
    /// 条目是"一条一条"，给它们轨和线。两者各得其所。
    ///
    /// 用法：调用方**什么都别加**，容器自己负责宽度。
    /// ```swift
    /// Text(lead)
    ///     .fixedSize(horizontal: false, vertical: true)
    ///     .workbenchProsePanel()
    /// ```
    ///
    /// 为什么宽度必须收进容器里：上一版是调用方套两层 `.frame(maxWidth:)`
    /// （行宽一层、外框一层），两层都要跟 token 对上才不错位，结果就是
    /// 外层 frame 没撑满、盒子比结构列短 79.5pt。宽度这类**约束**一旦散在调用方，
    /// 就总有一处会忘；收进一个 modifier，改错只会错一处。
    func workbenchProsePanel(cornerRadius: CGFloat = AppTheme.radiusLarge) -> some View {
        self
            .frame(maxWidth: AppTheme.proseLineWidth, alignment: .leading)
            .padding(.horizontal, AppTheme.space5)
            .padding(.vertical, AppTheme.space5)
            // 盒子撑满结构列：`maxWidth: .infinity` 拿满父级给的 800，
            // 而非"由内容撑"——内容的理想宽度是 760，撑出来的盒子会是 800 还是 720
            // 取决于提议链，正是上一版错位的来源。
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.paperSoft)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.rule, lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func workbenchDarkPanel(cornerRadius: CGFloat = AppTheme.radiusLarge) -> some View {
        self
            .padding(AppTheme.space5)
            .background(AppTheme.graphite)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(AppTheme.graphiteSoft.opacity(0.75), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}
