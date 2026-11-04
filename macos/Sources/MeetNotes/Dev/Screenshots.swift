import AppKit
import SwiftUI

/// `MeetNotes --demo --screenshots <dir>`: renders the README screenshots from the demo library into
/// `<name>-light.png` and `<name>-dark.png`, at 2x, framed like macOS windows on a transparent background.
/// Rendering happens in-process, so no Screen Recording permission is needed.
///
/// `cacheDisplay` can't see into Liquid Glass (macOS 26): the sidebar and the toolbar's search capsule come out
/// as blank white panes. Those are painted here instead: the sidebar is rendered on its own outside the glass,
/// the toolbar items and window buttons are drawn again on top.
@MainActor
enum Screenshots {
    static let windowSize = NSSize(width: 1280, height: 800)

    static func run(_ model: AppModel, to dir: String) {
        Task {
            guard let main = await mainWindow() else {
                log("The main window did not open; windows: \(NSApp.windows.map { "\(type(of: $0)) \($0.frame) \($0.isVisible)" })")
                exit(1)
            }
            if main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
            main.setFrame(main.frameRect(forContentRect: NSRect(origin: .zero, size: windowSize)), display: true)
            main.center()
            let newest = (try? model.store.meetings(.all))?.first?.id
            let chat = (try? model.store.chatSessions(meetingID: nil))?.first { $0.title == Demo.chatTitle }?.id
            model.briefs[Demo.budgetEventID] = Demo.budgetBrief

            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                /// Captures the main window (plus extra layers) once the change has been drawn.
                @MainActor func shot(_ name: String, extra: [Layer] = [], _ change: () -> Void) async {
                    change()
                    await settle()
                    let pane = sidebarSize(main)
                    let sidebar = await standalone(SidebarView().environment(\.controlActiveState, .key),
                                                   size: NSSize(width: pane.width, height: pane.height - sidebarTop), model)
                    let url = URL(filePath: dir).appending(path: "\(name)-\(dark ? "dark" : "light").png")
                    do { try compose([Layer(main, sidebar: sidebar)] + extra, dark: dark).write(to: url) } catch { log("\(name): \(error)") }
                }

                await shot("summary") { model.section = .documents(.all); model.selectedMeeting = newest; model.documentTab = .summary }
                await shot("transcript") { model.documentTab = .transcript }
                await shot("chat") { model.section = .chat; model.selectedChat = chat }
                await shot("search") { model.section = .documents(.all); model.searchText = "load testing" }
                await shot("calendar") { model.searchText = ""; model.section = .calendar }

                // Home with the brief for the next meeting open, where its popover would be.
                model.section = .home
                if let event = model.calendar.upcoming.first(where: { $0.id == Demo.budgetEventID }) {
                    let view = MeetingBriefView(event: event, brief: MeetingBrief.build(for: event, store: model.store))
                    let brief = await standalone(view.background(Color(nsColor: .windowBackgroundColor)), size: NSSize(width: 440, height: 460), model)
                    await shot("home", extra: [Layer(brief, at: .topRight(dx: 110, dy: 222), radius: 12)]) {}
                }

                // A meeting in progress: live transcript in the window, the floating overlay beside it.
                var live = Meeting.new(title: "Atlas Launch: Go/No-Go")
                live.folderId = "product"
                live.duration = 754
                live.notes = "- Load test passed at 2x traffic\n- Duplicate-note bug: fix in review, merge tomorrow\n- Go for Nov 18?"
                try? model.store.save(live)
                model.recordingID = live.id
                model.meter.elapsed = 754
                (model.meter.mic, model.meter.system) = (0.45, 0.6)
                model.live.lines = Demo.liveLines.map { LiveTranscript.Line(isMic: $0.0, text: $0.2, time: $0.1) }
                model.live.volatile = [false: "And the release notes are"]
                MeetingOverlay.shared.show(model)
                model.section = .documents(.all)
                model.selectedMeeting = live.id
                model.documentTab = .transcript
                await settle()
                if let panel = NSApp.windows.first(where: { $0 is NSPanel && $0.isVisible }) {
                    let overlay = render(panel.contentView!.superview ?? panel.contentView!)
                    await shot("recording", extra: [Layer(overlay, at: .topRight(dx: -385, dy: 120), radius: 16)]) {}
                }
                MeetingOverlay.shared.close()
                model.recordingID = nil
                model.meter.elapsed = 0
                model.live.lines = []
                model.live.volatile = [:]
                try? model.store.deletePermanently(live)
            }
            exit(0)
        }
    }

    // MARK: - Capture

    struct Layer {
        enum Place { case origin, topRight(dx: CGFloat, dy: CGFloat) }
        let image: NSBitmapImageRep
        let place: Place
        let radius: CGFloat

        /// The whole window, title bar and toolbar included, with the glass panes painted in.
        @MainActor init(_ window: NSWindow, sidebar: NSBitmapImageRep) {
            let root = window.contentView!.superview ?? window.contentView!
            image = Screenshots.paintGlass(of: root, Screenshots.render(root), sidebar: sidebar)
            (place, radius) = (.origin, 16)
        }

        init(_ image: NSBitmapImageRep, at place: Place, radius: CGFloat) {
            (self.image, self.place, self.radius) = (image, place, radius)
        }
    }

    /// Renders a view at 2x, whatever the screen's scale.
    static func render(_ view: NSView, scale: CGFloat = 2) -> NSBitmapImageRep {
        let rep = bitmap(view.bounds.size, scale: scale)
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    private static func bitmap(_ size: NSSize, scale: CGFloat = 2) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = size
        return rep
    }

    /// Draws into a new bitmap of the given size (points, 2x pixels).
    private static func draw(_ size: NSSize, _ body: () -> Void) -> NSBitmapImageRep {
        let rep = bitmap(size)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        body()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    static func paintGlass(of root: NSView, _ image: NSBitmapImageRep, sidebar: NSBitmapImageRep) -> NSBitmapImageRep {
        let dark = root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let all = descendants(of: root)
        func rect(_ v: NSView) -> NSRect {
            var r = v.convert(v.bounds, to: root)
            if root.isFlipped { r.origin.y = root.bounds.height - r.maxY }
            return r
        }
        func named(_ s: String) -> [NSView] { all.filter { String(describing: type(of: $0)).contains(s) && !$0.isHidden } }
        var out: NSBitmapImageRep!
        root.effectiveAppearance.performAsCurrentDrawingAppearance { out = draw(image.size) {
            (dark ? NSColor(white: 0.12, alpha: 1) : NSColor(white: 0.9, alpha: 1)).setFill()
            NSRect(origin: .zero, size: image.size).fill()
            image.draw(in: NSRect(origin: .zero, size: image.size))
            // The window background around the sidebar (the glass leaves streaks there).
            for glass in named("ConcentricGlassEffectView") {
                if let around = glass.superview { NSColor.textBackgroundColor.setFill(); rect(around).fill() }
            }
            // The sidebar: a rounded pane with its own shadow.
            for glass in named("ConcentricGlassEffectView") {
                let r = rect(glass)
                let pane = NSBezierPath(roundedRect: r, xRadius: 18, yRadius: 18)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 8
                shadow.shadowColor = .black.withAlphaComponent(dark ? 0.5 : 0.14)
                shadow.set()
                (dark ? NSColor(white: 0.17, alpha: 1) : NSColor(white: 0.965, alpha: 1)).setFill()
                pane.fill()
                NSGraphicsContext.restoreGraphicsState()
                (dark ? NSColor.white.withAlphaComponent(0.1) : NSColor.black.withAlphaComponent(0.07)).setStroke()
                pane.stroke()
                NSGraphicsContext.saveGraphicsState()
                pane.addClip()
                sidebar.draw(in: NSRect(x: r.minX, y: r.minY, width: r.width, height: r.height - sidebarTop))
                NSGraphicsContext.restoreGraphicsState()
            }
            // Toolbar capsules (the search field), then the toolbar items on top of them.
            for glass in named("NSGlassEffectView") {
                let r = rect(glass)
                (dark ? NSColor(white: 0.22, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
                NSBezierPath(roundedRect: r, xRadius: r.height / 2, yRadius: r.height / 2).fill()
            }
            // The search field's text: drawn, since the field itself renders blank in dark mode.
            for field in named("ToolbarItemHostingView").flatMap(descendants).compactMap({ $0 as? NSTextField }) where field.isEditable {
                let r = rect(field)
                let font = NSFont.systemFont(ofSize: 13)
                let text = field.stringValue.isEmpty ? field.placeholderString ?? "" : field.stringValue
                let color: NSColor = field.stringValue.isEmpty ? .secondaryLabelColor : .labelColor
                (text as NSString).draw(at: NSPoint(x: r.minX + 2, y: r.midY - font.capHeight / 2 - 3), withAttributes: [.font: font, .foregroundColor: color])
                if let glass = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: 13, weight: .medium).applying(.init(hierarchicalColor: .secondaryLabelColor))) {
                    glass.draw(in: NSRect(x: r.minX - 24, y: r.midY - glass.size.height / 2, width: glass.size.width, height: glass.size.height))
                }
            }
            // Traffic lights in their active colors.
            for (button, hex) in [(NSWindow.ButtonType.closeButton, 0xFF5F57), (.miniaturizeButton, 0xFEBC2E), (.zoomButton, 0x28C840)] {
                guard let b = root.window?.standardWindowButton(button), !b.isHidden else { continue }
                let r = rect(b)
                let d: CGFloat = 12
                NSColor(red: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1).setFill()
                NSBezierPath(ovalIn: NSRect(x: r.midX - d / 2, y: r.midY - d / 2, width: d, height: d)).fill()
            }
        } }
        return out
    }

    /// Height of the sidebar pane's title-bar part (traffic lights), above the list.
    private static let sidebarTop: CGFloat = 44

    /// Lays the layers out (the first one is the base window, the canvas grows for layers hanging over its edge),
    /// rounds their corners and adds window shadows.
    static func compose(_ layers: [Layer], dark: Bool, margin: CGFloat = 48) throws -> Data {
        let base = layers[0].image.size
        var rects = [NSRect(origin: .zero, size: base)]
        for l in layers.dropFirst() {
            if case let .topRight(dx, dy) = l.place {
                let s = l.image.size
                rects.append(NSRect(x: base.width - s.width - dx, y: base.height - s.height - dy, width: s.width, height: s.height))
            }
        }
        let bounds = rects.reduce(rects[0]) { $0.union($1) }
        let out = draw(NSSize(width: bounds.width + margin * 2, height: bounds.height + margin * 2)) {
            for (l, r0) in zip(layers, rects) {
                let r = r0.offsetBy(dx: margin - bounds.minX, dy: margin - bounds.minY)
                let path = NSBezierPath(roundedRect: r, xRadius: l.radius, yRadius: l.radius)
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowBlurRadius = 30
                shadow.shadowOffset = NSSize(width: 0, height: -10)
                shadow.shadowColor = .black.withAlphaComponent(dark ? 0.55 : 0.25)
                shadow.set()
                NSColor.black.setFill()
                path.fill()
                NSGraphicsContext.restoreGraphicsState()
                NSGraphicsContext.saveGraphicsState()
                path.addClip()
                l.image.draw(in: r)
                NSGraphicsContext.restoreGraphicsState()
                (dark ? NSColor.white.withAlphaComponent(0.18) : NSColor.black.withAlphaComponent(0.14)).setStroke()
                path.lineWidth = 1
                path.stroke()
            }
        }
        guard let png = out.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    // MARK: - Helpers

    private static func mainWindow() async -> NSWindow? {
        // Started from a shell (not through Launch Services) SwiftUI doesn't present the main window by itself;
        // its item in the Window menu does.
        NSApp.activate()
        try? await Task.sleep(for: .seconds(1))
        if !NSApp.windows.contains(where: { $0.canBecomeMain }),
           let item = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items).first(where: { $0.title == "Keepword" && $0.action != nil }),
           let action = item.action {
            NSApp.sendAction(action, to: item.target, from: item)
        }
        for _ in 0..<80 {
            if let w = NSApp.windows.first(where: { !($0 is NSPanel) && $0.canBecomeMain && $0.frame.width >= 1000 }) {
                await settle()
                return w
            }
            try? await Task.sleep(for: .milliseconds(250))
        }
        return nil
    }

    private static func sidebarSize(_ window: NSWindow) -> NSSize {
        let root = window.contentView!.superview ?? window.contentView!
        return descendants(of: root).first { String(describing: type(of: $0)).contains("ConcentricGlassEffectView") }?.bounds.size
            ?? NSSize(width: 235, height: windowSize.height - 16)
    }

    /// Renders a SwiftUI view in a plain offscreen window (no glass, so `cacheDisplay` sees all of it).
    private static func standalone(_ content: some View, size: NSSize, _ model: AppModel) async -> NSBitmapImageRep {
        let w = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10_000, y: 0), size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.backgroundColor = .clear
        w.isOpaque = false
        w.contentView = NSHostingView(rootView: content.environmentObject(model).frame(width: size.width, height: size.height))
        w.orderFrontRegardless()
        try? await Task.sleep(for: .seconds(0.8))
        let rep = render(w.contentView!)
        w.close()
        return rep
    }

    private static func descendants(of v: NSView) -> [NSView] { v.subviews + v.subviews.flatMap(descendants) }

    private static func settle() async { try? await Task.sleep(for: .seconds(1.5)) }

    private static func log(_ s: String) { FileHandle.standardError.write(Data("screenshots: \(s)\n".utf8)) }
}
