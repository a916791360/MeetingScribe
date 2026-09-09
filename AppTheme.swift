import SwiftUI
import AppKit

/* Hallmark · pre-emit critique: P5 H5 E4 S5 R5 V4 · genre: modern-minimal · macrostructure: Workbench · theme: Cobalt · motion: cut */

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
    static let space2: CGFloat = 8
    static let space3: CGFloat = 12
    static let space4: CGFloat = 16
    static let space5: CGFloat = 20
    static let space6: CGFloat = 24
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
