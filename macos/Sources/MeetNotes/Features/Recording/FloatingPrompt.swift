import SwiftUI

/// Small always-on-top panel in the screen corner that offers to record.
@MainActor
final class FloatingPrompt {
    static let shared = FloatingPrompt()
    private var panel: NSPanel?

    func show(title: String, message: String, primary: (String, () -> Void), secondary: (String, () -> Void)) {
        close()
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 96), styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isMovableByWindowBackground = true
        p.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "record.circle").foregroundStyle(.red).font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            HStack {
                Spacer()
                Button(secondary.0) { secondary.1(); self.close() }
                Button(primary.0) { primary.1(); self.close() }.keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: 340))
        if let screen = NSScreen.main?.visibleFrame {
            p.setFrameOrigin(NSPoint(x: screen.maxX - 360, y: screen.maxY - 120))
        }
        p.orderFrontRegardless()
        panel = p
        // Dismiss by itself after a minute.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak p] in if self.panel === p { self.close() } }
    }

    func close() { panel?.close(); panel = nil }
}
