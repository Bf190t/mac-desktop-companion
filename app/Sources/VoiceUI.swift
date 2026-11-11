import AppKit

/// Click once to start recording, click again to stop and transcribe. Replaces the old
/// hold-to-talk button: holding a trackpad or mouse button while speaking was awkward.
/// The voice controls now live in the merged chat window (ChatInspector); the separate
/// voice-experiment window is gone.
final class RecordToggleButton: NSButton {
    var onToggle:(()->Void)?
    override init(frame:NSRect){super.init(frame:frame);target=self;action=#selector(fire)}
    required init?(coder:NSCoder){fatalError()}
    @objc private func fire(){onToggle?()}
}
