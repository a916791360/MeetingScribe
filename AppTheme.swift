import SwiftUI
import AppKit

/* Hallmark · pre-emit critique: P5 H5 E5 S5 R5 V5 · genre: modern-minimal · macrostructure: Workbench · theme: Cobalt · motion: cut
 * chrome: Liquid Glass —— 只在「结果页控制条」这一处铺玻璃（macOS 26 glassEffect .regular，
 *         macOS 15 回退 ultraThinMaterial）。正文一律不叠玻璃：玻璃叠玻璃会糊成一片，
 *         而且玻璃得有背景内容才显质感，正文本身是纯纸面。
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

    /// 结果页控制条：玻璃底托的高度与圆角。
    /// 44 = 32（选中胶囊）+ 上下各 6pt 内衬，胶囊不会贴到玻璃边上。
    static let stripHeight: CGFloat = 44
    static let radiusBar: CGFloat = 14
    /// 玻璃条里的图标命中区，比图标本身大一圈，才够好点。
    static let stripIconHit: CGFloat = 30
    /// 玻璃条内衬：选中胶囊到玻璃边留 6pt，胶囊的圆角才不和玻璃的圆角打架。
    static let stripInset: CGFloat = 6
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

    /// 液态玻璃底托（Liquid Glass）。
    /// macOS 26 用系统材质 `.glassEffect(.regular, in:)`；macOS 15 没有这套 API，
    /// 回退成 `.ultraThinMaterial` + 一道高光描边，观感尽量靠拢，不做假玻璃渐变。
    ///
    /// 注意：玻璃自带边缘高光与投影，**不要再叠第二道描边**，否则会出现「双层边」。
    /// 只有回退分支才补描边，因为材质本身不画轮廓。
    @ViewBuilder
    func workbenchGlassBar(cornerRadius: CGFloat = AppTheme.radiusBar) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(
                .regular,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        } else {
            self
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .stroke(Color.white.opacity(0.5), lineWidth: 1)
                )
        }
    }
}
