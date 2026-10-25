import AppKit

/// Shared native window policy for the app's utility windows. No global input
/// hooks, private APIs, or window-manager dependencies are involved.
enum DesktopWindowBehavior {
    static func configure(_ window: NSWindow, minimumContentSize: NSSize) {
        window.styleMask.insert(.resizable)
        window.contentMinSize = minimumContentSize
        window.collectionBehavior.remove([.fullScreenPrimary, .fullScreenAuxiliary, .fullScreenAllowsTiling])
        window.collectionBehavior.insert([.fullScreenNone, .fullScreenDisallowsTiling])
        window.standardWindowButton(.zoomButton)?.toolTip = L("放大至当前桌面；再次点击恢复原大小", "Fill the current desktop; click again to restore")
        // Keep AppKit's native target/action: zoom stores/restores the user frame.
    }

    static func standardFrame(for window: NSWindow, defaultFrame: NSRect) -> NSRect {
        (window.screen ?? NSScreen.main)?.visibleFrame ?? defaultFrame
    }

    /// Also shrink an oversized window after removing/changing displays.
    static func constrainedFrame(_ frame: NSRect, visibleFrame: NSRect) -> NSRect {
        guard visibleFrame.width > 0, visibleFrame.height > 0 else { return frame }
        let width = min(frame.width, visibleFrame.width)
        let height = min(frame.height, visibleFrame.height)
        return NSRect(x: min(max(frame.minX, visibleFrame.minX), visibleFrame.maxX - width),
                      y: min(max(frame.minY, visibleFrame.minY), visibleFrame.maxY - height),
                      width: width, height: height)
    }
}
