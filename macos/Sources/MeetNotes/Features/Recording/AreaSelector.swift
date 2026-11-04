import AppKit

/// Full-screen transparent panel to drag a rectangle; release or Enter captures, Esc cancels.
/// It's a non-activating panel so it takes keyboard focus even while the call app stays frontmost
/// (the overlay button that opens it doesn't activate Keepword), and it's drawn with layers in AppKit
/// so dragging doesn't re-render a full-screen SwiftUI view on every mouse move.
@MainActor
final class AreaSelector {
    private static var window: NSPanel?
    private static var continuation: CheckedContinuation<CGRect?, Never>?

    static func select(on screen: NSScreen) async -> CGRect? {
        finish(nil)  // a second request while one is open cancels the first instead of orphaning its window
        return await withCheckedContinuation { cont in
            continuation = cont
            let p = KeyPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .screenSaver
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = SelectionView(frame: NSRect(origin: .zero, size: screen.frame.size))
            view.done = { finish($0) }
            p.contentView = view
            p.setFrame(screen.frame, display: true)
            p.makeKeyAndOrderFront(nil)
            p.makeFirstResponder(view)
            window = p
        }
    }

    fileprivate static func finish(_ rect: CGRect?) {
        window?.orderOut(nil)
        window = nil
        continuation?.resume(returning: rect.flatMap { $0.width > 4 && $0.height > 4 ? $0 : nil })
        continuation = nil
    }

    private final class KeyPanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override func cancelOperation(_ sender: Any?) { AreaSelector.finish(nil) }
    }

    /// Rect is reported in view coordinates flipped to a top-left origin, which is what `SCStreamConfiguration.sourceRect` expects.
    private final class SelectionView: NSView {
        var done: ((CGRect?) -> Void)?
        private var start: CGPoint?
        private var current: CGPoint?
        private let dim = CAShapeLayer()
        private let border = CAShapeLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            dim.fillColor = NSColor.black.withAlphaComponent(0.25).cgColor
            dim.fillRule = .evenOdd
            border.fillColor = NSColor.white.withAlphaComponent(0.08).cgColor
            border.strokeColor = NSColor.white.cgColor
            border.lineWidth = 1.5
            layer?.addSublayer(dim)
            layer?.addSublayer(border)
            addSubview(hint())
            redraw()
        }
        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { true }
        // Without this the first click only focuses the panel and the drag starts on the second try.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

        private var rect: CGRect? {
            guard let start, let current else { return nil }
            return CGRect(x: min(start.x, current.x), y: min(start.y, current.y), width: abs(start.x - current.x), height: abs(start.y - current.y))
        }

        override func mouseDown(with event: NSEvent) {
            start = convert(event.locationInWindow, from: nil)
            current = start
            redraw()
        }
        override func mouseDragged(with event: NSEvent) {
            guard start != nil else { return }
            current = convert(event.locationInWindow, from: nil)
            redraw()
        }
        override func mouseUp(with event: NSEvent) {
            guard start != nil else { return }
            current = convert(event.locationInWindow, from: nil)
            done?(rect)
        }
        override func rightMouseDown(with event: NSEvent) { done?(nil) }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 53: done?(nil)  // Esc
            case 36, 76: done?(rect)  // Return, keypad Enter: capture what's selected so far
            default: super.keyDown(with: event)
            }
        }

        private func redraw() {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            let full = CGPath(rect: bounds, transform: nil)
            if let r = rect {
                let hole = CGMutablePath()
                hole.addPath(full)
                hole.addRect(r)
                dim.path = hole
                border.path = CGPath(rect: r, transform: nil)
            } else {
                dim.path = full
                border.path = nil
            }
            CATransaction.commit()
        }

        private func hint() -> NSView {
            let label = NSTextField(labelWithString: String(localized: "Drag to select an area · Press Esc to cancel"))
            label.font = .preferredFont(forTextStyle: .callout)
            label.textColor = .white
            label.sizeToFit()
            let pill = NSView(frame: NSRect(x: 20, y: 20, width: label.frame.width + 16, height: label.frame.height + 16))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.6).cgColor
            pill.layer?.cornerRadius = pill.frame.height / 2
            label.frame.origin = NSPoint(x: 8, y: 8)
            pill.addSubview(label)
            return pill
        }
    }
}
