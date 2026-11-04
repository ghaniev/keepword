import SwiftUI

/// Minimal iCalendar (RFC 5545) reader for calendar feeds: line folding, escaping, time zones, all-day events,
/// recurring events (DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT, UNTIL, BYDAY incl. "2TU"/"-1FR"),
/// EXDATE, RECURRENCE-ID overrides and cancelled events.
enum ICS {
    struct Prop { let name: String; let params: [String: String]; let value: String }

    static func parse(_ text: String, calendarName: String, color: Color, from: Date, to: Date) -> [CalEvent] {
        var blocks: [[Prop]] = []
        var current: [Prop]?
        for line in unfold(text) {
            if line == "BEGIN:VEVENT" { current = []; continue }
            if line == "END:VEVENT" { if let c = current { blocks.append(c) }; current = nil; continue }
            if current != nil, let p = prop(line) { current!.append(p) }
        }
        let overrides = blocks.filter { b in b.contains { $0.name == "RECURRENCE-ID" } }
        let overridden = Set(overrides.compactMap { b -> String? in
            guard let uid = b.first(where: { $0.name == "UID" })?.value,
                  let rid = b.first(where: { $0.name == "RECURRENCE-ID" }).flatMap(date) else { return nil }
            return "\(uid)|\(Int(rid.0.timeIntervalSince1970))"
        })
        var out: [CalEvent] = []
        for b in blocks {
            func v(_ n: String) -> String? { b.first { $0.name == n }.map { unescape($0.value) } }
            guard v("STATUS") != "CANCELLED", let startProp = b.first(where: { $0.name == "DTSTART" }),
                  let (start, allDay) = date(startProp) else { continue }
            let uid = v("UID") ?? UUID().uuidString
            var end = b.first(where: { $0.name == "DTEND" }).flatMap(date)?.0
                ?? v("DURATION").flatMap(duration).map { start.addingTimeInterval($0) }
                ?? start.addingTimeInterval(allDay ? 86400 : 3600)
            if end <= start { end = start.addingTimeInterval(allDay ? 86400 : 1800) }
            let length = end.timeIntervalSince(start)
            let attendees = b.filter { $0.name == "ATTENDEE" }.map { $0.params["CN"] ?? $0.value.replacingOccurrences(of: "mailto:", with: "", options: .caseInsensitive) }
            let link = (v("X-GOOGLE-CONFERENCE") ?? v("URL")).flatMap(URL.init(string:))
            func event(at s: Date) -> CalEvent {
                CalEvent(id: "ics:\(uid)|\(Int(s.timeIntervalSince1970))", title: v("SUMMARY") ?? "Untitled", start: s,
                         end: s.addingTimeInterval(length), isAllDay: allDay, color: color, calendarName: calendarName,
                         location: v("LOCATION"), notes: v("DESCRIPTION"), url: link, attendees: attendees)
            }
            if let rule = v("RRULE"), !b.contains(where: { $0.name == "RECURRENCE-ID" }) {
                let tz = startProp.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current
                let exdates = Set(b.filter { $0.name == "EXDATE" }.flatMap { p in
                    p.value.split(separator: ",").compactMap { date(Prop(name: "EXDATE", params: p.params, value: String($0)))?.0 }
                }.map { Int($0.timeIntervalSince1970) })
                for s in occurrences(rule: rule, start: start, tz: tz, until: to)
                where s.addingTimeInterval(length) > from && !exdates.contains(Int(s.timeIntervalSince1970))
                    && !overridden.contains("\(uid)|\(Int(s.timeIntervalSince1970))") {
                    out.append(event(at: s))
                }
            } else if end > from && start < to {
                out.append(event(at: start))
            }
        }
        return out.sorted { $0.start < $1.start }
    }

    static func unfold(_ text: String) -> [String] {
        var lines: [String] = []
        for raw in text.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
            if (raw.hasPrefix(" ") || raw.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += raw.dropFirst() } else { lines.append(String(raw)) }
        }
        return lines
    }

    static func prop(_ line: String) -> Prop? {
        // The value starts at the first ':' outside double quotes (params like CN="Doe, John" may contain ':').
        var inQuotes = false
        guard let colon = line.firstIndex(where: { c in
            if c == "\"" { inQuotes.toggle() }
            return c == ":" && !inQuotes
        }) else { return nil }
        let head = line[..<colon].split(separator: ";")
        guard let name = head.first else { return nil }
        var params: [String: String] = [:]
        for p in head.dropFirst() {
            let kv = p.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { params[kv[0].uppercased()] = kv[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return Prop(name: name.uppercased(), params: params, value: String(line[line.index(after: colon)...]))
    }

    static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\N", with: "\n")
            .replacingOccurrences(of: "\\,", with: ",").replacingOccurrences(of: "\\;", with: ";").replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// (date, isAllDay). UTC ("Z"), TZID-local and floating times; VALUE=DATE for all-day.
    static func date(_ p: Prop) -> (Date, Bool)? {
        let v = p.value.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        if p.params["VALUE"] == "DATE" || v.count == 8 {
            f.dateFormat = "yyyyMMdd"
            f.timeZone = .current
            return f.date(from: String(v.prefix(8))).map { ($0, true) }
        }
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = v.hasSuffix("Z") ? TimeZone(identifier: "UTC") : (p.params["TZID"].flatMap(TimeZone.init(identifier:)) ?? .current)
        return f.date(from: String(v.prefix(15))).map { ($0, false) }
    }

    /// ISO 8601 duration like PT1H30M or P1D.
    static func duration(_ s: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var inTime = false
        for c in s {
            switch c {
            case "P", "+": continue
            case "-": return nil
            case "T": inTime = true
            case "W": total += (Double(number) ?? 0) * 7 * 86400; number = ""
            case "D": total += (Double(number) ?? 0) * 86400; number = ""
            case "H": total += (Double(number) ?? 0) * 3600; number = ""
            case "M": total += (Double(number) ?? 0) * (inTime ? 60 : 30 * 86400); number = ""
            case "S": total += Double(number) ?? 0; number = ""
            default: number.append(c)
            }
        }
        return total > 0 ? total : nil
    }

    /// Start times of a recurring event up to `until`, computed in the event's time zone so the wall-clock time
    /// survives daylight-saving changes. COUNT counts from the first occurrence, as in RFC 5545.
    static func occurrences(rule: String, start: Date, tz: TimeZone, until: Date) -> [Date] {
        var r: [String: String] = [:]
        for part in rule.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1)
            if kv.count == 2 { r[kv[0].uppercased()] = String(kv[1]) }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2  // WKST=MO, the RFC default
        let interval = max(1, Int(r["INTERVAL"] ?? "1") ?? 1)
        let count = r["COUNT"].flatMap(Int.init)
        let endDate = min(until, r["UNTIL"].flatMap { date(Prop(name: "UNTIL", params: [:], value: $0))?.0 }.map { $0.addingTimeInterval(1) } ?? until)
        let codes = ["SU": 1, "MO": 2, "TU": 3, "WE": 4, "TH": 5, "FR": 6, "SA": 7]
        // BYDAY entries: (ordinal or nil, weekday)
        let byDay: [(Int?, Int)] = (r["BYDAY"] ?? "").split(separator: ",").compactMap { d in
            let code = String(d.suffix(2)), ord = Int(d.dropLast(2))
            return codes[code].map { (ord, $0) }
        }
        let time = cal.dateComponents([.hour, .minute, .second], from: start)
        func at(_ day: Date) -> Date? {
            cal.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: time.second ?? 0, of: day)
        }
        var out: [Date] = []
        func emit(_ d: Date) -> Bool {  // false = stop
            guard d <= endDate, count.map({ out.count < $0 }) ?? true else { return false }
            if d >= start { out.append(d) }
            return true
        }
        var step = 0
        while step < 5000 {
            switch r["FREQ"] {
            case "DAILY":
                guard let d = cal.date(byAdding: .day, value: step * interval, to: start), emit(d) else { return out }
            case "WEEKLY":
                guard let weekStart = cal.dateInterval(of: .weekOfYear, for: start)?.start,
                      let week = cal.date(byAdding: .weekOfYear, value: step * interval, to: weekStart), week <= endDate else { return out }
                let days = byDay.isEmpty ? [cal.component(.weekday, from: start)] : byDay.map(\.1)
                for wd in days.sorted(by: { ($0 + 5) % 7 < ($1 + 5) % 7 }) {  // Monday-first order
                    guard let day = cal.date(byAdding: .day, value: (wd + 5) % 7, to: week), let d = at(day) else { continue }
                    if !emit(d) { return out }
                }
            case "MONTHLY":
                guard let month = cal.date(byAdding: .month, value: step * interval, to: cal.dateInterval(of: .month, for: start)!.start),
                      month <= endDate else { return out }
                if let (ord, wd) = byDay.first, let n = ord {
                    // nth (or nth-from-last) weekday of the month
                    let range = cal.range(of: .day, in: .month, for: month)!
                    let matches = range.compactMap { cal.date(byAdding: .day, value: $0 - 1, to: month) }.filter { cal.component(.weekday, from: $0) == wd }
                    let idx = n > 0 ? n - 1 : matches.count + n
                    if matches.indices.contains(idx), let d = at(matches[idx]), !emit(d) { return out }
                } else {
                    var c = cal.dateComponents([.year, .month], from: month)
                    c.day = cal.component(.day, from: start)
                    (c.hour, c.minute, c.second) = (time.hour, time.minute, time.second)
                    if let d = cal.date(from: c), cal.component(.month, from: d) == c.month, !emit(d) { return out }  // skip Feb 30
                }
            case "YEARLY":
                guard let d = cal.date(byAdding: .year, value: step * interval, to: start), emit(d) else { return out }
            default:
                _ = emit(start)
                return out
            }
            step += 1
        }
        return out
    }

    /// Side-by-side columns for overlapping timed events (like Calendar.app): (event, lane, lanes in its cluster).
    static func lanes(_ events: [CalEvent]) -> [(CalEvent, Int, Int)] {
        var result: [(CalEvent, Int, Int)] = []
        var cluster: [(CalEvent, Int)] = []
        var laneEnds: [Date] = []
        var clusterEnd = Date.distantPast
        func flush() {
            let n = max(1, laneEnds.count)
            result += cluster.map { ($0.0, $0.1, n) }
            cluster = []
            laneEnds = []
        }
        for e in events.sorted(by: { ($0.start, $1.end) < ($1.start, $0.end) }) {
            if e.start >= clusterEnd { flush() }
            if let free = laneEnds.firstIndex(where: { $0 <= e.start }) {
                laneEnds[free] = e.end
                cluster.append((e, free))
            } else {
                laneEnds.append(e.end)
                cluster.append((e, laneEnds.count - 1))
            }
            clusterEnd = max(clusterEnd, e.end)
        }
        flush()
        return result
    }
}
