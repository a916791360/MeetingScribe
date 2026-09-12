import SwiftUI
import AppKit

/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4 · genre: modern-minimal · macrostructure: Workbench · theme: Cobalt · motion: cut
 * chrome: 原生分段控件 —— 结果页控制条不再铺液态玻璃。
 *         玻璃的质感来自折射「背后有变化的内容」，而这条控制条背后是纯色纸面，
 *         没有东西可折射，玻璃只剩一块发灰的底，比不做更脏（第五轮用户原话「不精致、没质感」）。
 *         现在回到 macOS 原生的纪律：容器只包住真正需要边界的东西（三个 Tab），
 *         右侧图标不要底板，质感交给排印、2pt 内衬和 1pt 发丝线。
 *
 * theme: Cobalt · 双外观（浅色 / 深色）。
 *
 * **这次改动的判据只有一条：色板必须跟着系统外观走。** 原来 15 个颜色全是写死的浅色值，
 * 系统切到深夜模式后，窗口标题栏、sheet 页头这些由 macOS 自己画的 chrome 变深了，
 * 而应用自己画的纸面、文字、线还停在浅色 —— 于是一屏里两套语言打架：
 * sheet 页头是深底配深墨字（几乎看不见），标题栏是深底配浅色按钮。这就是「没适配」的真身。
 *
 * 做法：每个 token 用 `NSColor(name:dynamicProvider:)` 包成**随外观解析**的动态色，
 * SwiftUI 在绘制时按当前 `NSAppearance` 取值，运行时切换外观也会自动跟上。
 *
 * **浅色档的值一个字节都没动** —— 把现有数值原样搬进 `light:` 参数，所以浅色模式
 * 与改动前逐像素一致（唯一的例外是三处调用点，见 WorkbenchView 注释）。
 * 新增的 `controlSurface` / `segmentSelected` / `accentFill` / `dangerFill` 四个 token
 * 在浅色档同样取现有值，属于「给已有颜色补个名字」，不产生视觉变化。
 */

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

    /// 页面底。最外层的纸面。
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
    static let accent = dynamic(light: (0.153, 0.420, 0.980), dark: (0.463, 0.663, 1.0))
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
    static let contentColumn: CGFloat = 920
    static let contentInset: CGFloat = 32

    /// 结果页控制条：一个**贴合内容宽度**的分段控件 + 一条发丝线。
    /// 轨道比纸面深一档（paper 是 248,250,253），白色凸起段才立得起来；
    /// 轨道若也用 paper，选中段和轨道会糊成一片，正是「看不出边界」的老毛病。
    /// 分段高度：轨道 2pt 内衬 + 28pt 凸起段 = 32pt，与 controlCompact 同高。
    static let segmentHeight: CGFloat = 28
    static let segmentRadius: CGFloat = 8
    /// 控制条整行高度（发丝线收在它下面）。
    static let segmentRowHeight: CGFloat = 46
    /// 控制条里的图标命中区，比图标本身大一圈，才够好点。
    static let stripIconHit: CGFloat = 30
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
