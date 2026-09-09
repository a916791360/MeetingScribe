import AppKit
import SwiftUI

struct WindowConfigurationView: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(nsView.window)
        }
    }

    private func configure(_ window: NSWindow?) {
        guard let window else { return }

        window.title = "MeetingScribe"
        window.setFrameAutosaveName("MeetingScribeMainWindow")
        window.styleMask.insert([.titled, .closable, .miniaturizable, .resizable])
        window.standardWindowButton(.zoomButton)?.isHidden = false
        window.standardWindowButton(.zoomButton)?.isEnabled = true
        window.contentMinSize = NSSize(width: 1060, height: 660)
        window.isRestorable = true
        window.collectionBehavior.insert(.fullScreenPrimary)

        guard !window.isZoomed,
              let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return
        }

        var frame = window.frame
        let maxWidth = visibleFrame.width
        let maxHeight = visibleFrame.height
        frame.size.width = min(frame.size.width, maxWidth)
        frame.size.height = min(frame.size.height, maxHeight)

        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
        }
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
        }

        if !visibleFrame.intersects(frame) {
            frame.origin.x = visibleFrame.midX - frame.width / 2
            frame.origin.y = visibleFrame.midY - frame.height / 2
        }

        if frame != window.frame {
            window.setFrame(frame, display: false)
        }
    }
}
