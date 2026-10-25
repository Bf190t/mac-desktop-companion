import AppKit

// Layout only when AppKit resizes the window. Text and controls retain native
// point sizes; a bounded form width keeps a maximized settings page readable.
final class SettingsLayoutView: NSView {
    private var baseline: [(NSView, NSRect)] = []
    func captureBaseline() {
        baseline = subviews.map { ($0, $0.frame) }
        needsLayout = true; layoutSubtreeIfNeeded()
    }
    override func layout() {
        super.layout()
        let width = min(640, bounds.width), height = min(760, bounds.height)
        let extraWidth = max(0, width - 430), extraHeight = max(0, height - 620)
        let origin = NSPoint(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2)
        for (view, original) in baseline {
            var frame = original
            frame.origin.y += extraHeight * min(1, max(0, (original.midY - 20) / 600))
            if view is NSSlider {
                frame.size.width += extraWidth
            } else if let button = view as? NSButton, original.minY < 20 {
                // Help stays left; status and quit stay together on the right.
                if button.action != #selector(AppDelegate.showHelp) { frame.origin.x += extraWidth }
            } else if original.minX >= 340 {
                frame.origin.x += extraWidth
            } else if original.width >= 370 {
                frame.size.width += extraWidth
            }
            frame.origin.x += origin.x; frame.origin.y += origin.y
            view.frame = frame
        }
    }
}
