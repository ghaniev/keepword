import AVFoundation
import AppKit
import EventKit

/// macOS privacy permissions MeetNotes uses: current status and how to ask for each.
enum Permission: String, CaseIterable, Identifiable {
    case microphone, systemAudio, screenRecording, calendar, reminders
    var id: Self { self }

    enum Status { case granted, denied, notDetermined, unknown }

    /// Recording can't work without these; the permissions window opens at launch while one is missing.
    var isRequired: Bool { self == .microphone || self == .systemAudio }

    static var missingRequired: Bool { allCases.contains { $0.isRequired && $0.status != .granted } }

    var status: Status {
        switch self {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: .granted
            case .notDetermined: .notDetermined
            default: .denied
            }
        case .systemAudio: SystemAudioPermission.status
        // macOS only tells whether access is granted; a refusal looks the same as "not asked yet".
        case .screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .calendar: Self.eventKit(.event)
        case .reminders: Self.eventKit(.reminder)
        }
    }

    private static func eventKit(_ type: EKEntityType) -> Status {
        switch EKEventStore.authorizationStatus(for: type) {
        case .fullAccess: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Shows the macOS prompt. macOS asks only once per app, so after a refusal this opens the Privacy pane.
    func request() async {
        if status == .denied || status == .unknown { openSettings(); return }
        switch self {
        case .microphone: _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .systemAudio: await SystemAudioPermission.request()
        case .screenRecording:
            let asked = "screenRecordingAsked"
            if UserDefaults.standard.bool(forKey: asked) { openSettings() } else {
                UserDefaults.standard.set(true, forKey: asked)
                CGRequestScreenCaptureAccess()
            }
        case .calendar: _ = try? await EKEventStore().requestFullAccessToEvents()
        case .reminders: _ = try? await EKEventStore().requestFullAccessToReminders()
        }
    }

    func openSettings() {
        let pane = switch self {
        case .microphone: "Privacy_Microphone"
        case .systemAudio, .screenRecording: "Privacy_ScreenCapture"  // "Screen & System Audio Recording"
        case .calendar: "Privacy_Calendars"
        case .reminders: "Privacy_Reminders"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}

/// System audio recording (kTCCServiceAudioCapture) has no public status or request API. These are the
/// private TCC calls, the same approach as the open-source AudioCap sample.
// ponytail: private API, may change between macOS versions; missing symbols degrade to "unknown" + Open Settings.
enum SystemAudioPermission {
    private static let service = "kTCCServiceAudioCapture" as CFString
    private static let tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @convention(block) (Bool) -> Void) -> Void

    static var status: Permission.Status {
        guard let symbol = dlsym(tcc, "TCCAccessPreflight") else { return .unknown }
        switch unsafeBitCast(symbol, to: Preflight.self)(service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .notDetermined
        }
    }

    static func request() async {
        guard let symbol = dlsym(tcc, "TCCAccessRequest") else { return }
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            unsafeBitCast(symbol, to: Request.self)(service, nil) { _ in done.resume() }
        }
    }
}
