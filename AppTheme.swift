import SwiftUI
import AppKit

/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V4 · genre: modern-minimal · macrostructure: Workbench · theme: Cobalt · motion: cut
 * chrome: 原生分段控件 —— 结果页控制条不再铺液态玻璃。
 *         玻璃的质感来自折射「背后有变化的内容」，而这条控制条背后是纯色纸面，
 *         没有东西可折射，玻璃只剩一块发灰的底，比不做更脏（第五轮用户原话「不精致、没质感」）。
 *         现在回到 macOS 原生的纪律：容器只包住真正需要边界的东西（三个 Tab），
 *         右侧图标不要底板，质感交给排印、2pt 内衬和 1pt 发丝线。
 */

enum AppTheme {
    static let paper = Color(nsColor: NSColor(calibratedRed: 0.972, green: 0.979, blue: 0.993, alpha: 1))
    static let paperSoft = Color(nsColor: NSColor(calibratedRed: 0.988, green: 0.991, blue: 0.997, alpha: 1))
    static let graphite = Color(nsColor: NSColor(calibratedRed: 0.122, green: 0.140, blue: 0.169, alpha: 1))
    static let graphiteSoft = Color(nsColor: NSColor(calibratedRed: 0.156, green: 0.176, blue: 0.208, alpha: 1))
    static let ink = Color(nsColor: NSColor(calibratedRed: 0.102, green: 0.121, blue: 0.146, alpha: 1))
    static let muted = Color(nsColor: NSColor(calibratedRed: 0.387, green: 0.439, blue: 0.510, alpha: 1))
    static let rule = Color(nsColor: NSColor(calibratedRed: 0.842, green: 0.866, blue: 0.901, alpha: 1))
    static let ruleStrong = Color(nsColor: NSColor(calibratedRed: 0.742, green: 0.788, blue: 0.855, alpha: 1))
    static let accent = Color(nsColor: NSColor(calibratedRed: 0.153, green: 0.420, blue: 0.980, alpha: 1))
    static let accentSoft = Color(nsColor: NSColor(calibratedRed: 0.878, green: 0.925, blue: 1.0, alpha: 1))
    static let success = Color(nsColor: NSColor(calibratedRed: 0.132, green: 0.635, blue: 0.341, alpha: 1))
    static let warning = Color(nsColor: NSColor(calibratedRed: 0.945, green: 0.596, blue: 0.149, alpha: 1))
    static let danger = Color(nsColor: NSColor(calibratedRed: 0.854, green: 0.204, blue: 0.239, alpha: 1))

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
    static let segmentTrack = Color(nsColor: NSColor(calibratedRed: 0.929, green: 0.941, blue: 0.965, alpha: 1))
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
