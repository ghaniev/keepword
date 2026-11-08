import Foundation

extension Date {
    /// "Today", "Yesterday", a weekday within the last week, then "Tue, 4 Nov" (with the year when it isn't this year).
    var dayHeader: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return String(localized: "Today") }
        if cal.isDateInYesterday(self) { return String(localized: "Yesterday") }
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: self), to: cal.startOfDay(for: .now)).day ?? 0
        if (0..<7).contains(days) { return formatted(.dateTime.weekday(.wide)) }
        if cal.isDate(self, equalTo: .now, toGranularity: .year) { return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) }
        return formatted(.dateTime.day().month(.abbreviated).year())
    }
    var hhmm: String { formatted(date: .omitted, time: .shortened) }
}

/// "3 meetings"; translations come from Localizable.stringsdict ("%lld meetings"), English falls back to adding "s".
func plural(_ n: Int, _ word: String) -> String {
    let key = "%lld \(word)s"
    let format = Bundle.main.localizedString(forKey: key, value: "", table: nil)
    return format == key ? "\(n) \(word)\(n == 1 ? "" : "s")" : String.localizedStringWithFormat(format, n)
}

func timestamp(_ seconds: Double) -> String {
    let s = Int(max(0, seconds))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
}

/// "mm:ss" / "h:mm:ss" → seconds.
func parseTimestamp(_ s: String?) -> Double? {
    guard let parts = s?.split(separator: ":").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
          (2...3).contains(parts.count) else { return nil }
    return parts.reduce(0) { $0 * 60 + $1 }
}

/// "2m 5s" / "1h 20m", in the app's language ("2 мин 5 с").
func durationLabel(_ seconds: Double) -> String {
    let f = DateComponentsFormatter()
    f.unitsStyle = .abbreviated
    f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
    return f.string(from: seconds.rounded(.down)) ?? ""
}

/// "23 min" / "1 hr, 20 min", rounded to whole minutes ("23 мин").
func minutesLabel(_ seconds: Double) -> String {
    let f = DateComponentsFormatter()
    f.unitsStyle = .short
    f.allowedUnits = [.hour, .minute]
    return f.string(from: max(60, (seconds / 60).rounded() * 60)) ?? ""
}

extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}
