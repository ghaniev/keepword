import Foundation

/// Detects calls: a known conferencing app (or browser) is capturing the microphone.
@MainActor
final class CallDetector: ObservableObject {
    static let conferencing: [String: String] = [
        "us.zoom.xos": "Zoom", "com.microsoft.teams": "Microsoft Teams", "com.microsoft.teams2": "Microsoft Teams",
        "com.tinyspeck.slackmacgap": "Slack", "com.apple.FaceTime": "FaceTime", "com.cisco.webexmeetingsapp": "Webex",
        "Cisco-Systems.Spark": "Webex", "com.hnc.Discord": "Discord", "ru.keepcoder.Telegram": "Telegram",
        "com.skype.skype": "Skype", "net.whatsapp.WhatsApp": "WhatsApp", "com.google.Chrome": "Google Chrome",
        "com.apple.Safari": "Safari", "company.thebrowser.Browser": "Arc", "org.mozilla.firefox": "Firefox",
        "com.microsoft.edgemac": "Microsoft Edge", "com.brave.Browser": "Brave", "ru.yandex.desktop.yandex-browser": "Yandex Browser",
    ]

    @Published var activeApp: String?  // app name while a call is detected
    var onCallStarted: ((String) -> Void)?
    var onCallEnded: (() -> Void)?
    private var timer: Timer?
    private var quietTicks = 0

    func start() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil; activeApp = nil }

    private func tick() {
        let ignored = Set(UserDefaults.standard.stringArray(forKey: "ignoredCallApps") ?? [])
        let app = AudioDevices.appsUsingMicrophone().first { Self.conferencing[$0] != nil && !ignored.contains($0) }
        if let app {
            quietTicks = 0
            if activeApp == nil {
                activeApp = Self.conferencing[app]
                onCallStarted?(app)
            }
        } else if activeApp != nil {
            quietTicks += 1
            if quietTicks >= 4 {  // ~12 s without anyone else on the mic
                activeApp = nil
                onCallEnded?()
            }
        }
    }
}
