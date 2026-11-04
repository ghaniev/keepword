import AppKit
import ScreenCaptureKit

/// Screenshots during a call: the whole screen under the mouse, or a dragged area.
/// MeetNotes' own windows (overlay, main window) are excluded from the image.
@MainActor
enum ScreenCapture {
    static func capture(area: Bool) async throws -> URL {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main else {
            throw LLMError(message: "No screen found")
        }
        var rect: CGRect? = nil  // in screen-local points, top-left origin
        if area {
            guard let r = await AreaSelector.select(on: screen) else { throw CancellationError() }
            rect = r
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw LLMError(message: "No display available for capture")
        }
        let me = content.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = screen.backingScaleFactor
        let source = rect ?? CGRect(origin: .zero, size: screen.frame.size)
        config.sourceRect = source
        config.width = Int(source.width * scale)
        config.height = Int(source.height * scale)
        config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw LLMError(message: "Could not encode the screenshot") }
        let url = FileManager.default.temporaryDirectory.appending(path: "Screenshot \(Date.now.formatted(.iso8601.time(includingFractionalSeconds: false)).replacingOccurrences(of: ":", with: ".")).png")
        try png.write(to: url)
        return url
    }
}
