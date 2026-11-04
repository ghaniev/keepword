import Foundation

/// Plain-text action items: "Send the deck tomorrow @Anna" files itself with a due date and an assignee.
/// Dates in English and Russian: today / tomorrow / the day after, weekdays ("on friday", "до пятницы"),
/// "in 3 days" / "через 3 дня", "next week", "15.11" (day first) and "Nov 15" / "15 ноября".
/// The first date phrase wins; words the parser doesn't know stay in the text.
enum TaskText {
    struct Parsed: Equatable {
        var text: String
        var dueDate: Date?
        var assignee: String?
    }

    static func parse(_ input: String, now: Date = .now, calendar: Calendar = .current) -> Parsed {
        var text = input
        var assignee: String?
        if let m = first(#"(?<!\S)@([\p{L}\p{N}._-]*[\p{L}\p{N}])"#, in: text) {
            assignee = m.groups[0]
            text = m.removing(from: text)
        }
        let today = calendar.startOfDay(for: now)
        var due: Date?
        for rule in rules {
            guard let m = first(prefix + "(?:" + rule.pattern + ")" + suffix, in: text),
                  let d = rule.date(m.groups, today, calendar) else { continue }
            due = d
            text = m.removing(from: text)
            break
        }
        text = text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet.whitespaces.union(.init(charactersIn: ",;:—-")))
        return text.isEmpty ? Parsed(text: input.trimmingCharacters(in: .whitespaces)) : Parsed(text: text, dueDate: due, assignee: assignee)
    }

    /// "@anna" → "Anna Petrova" when exactly one known name starts with it (by any word).
    static func resolve(_ handle: String, among names: [String]) -> String {
        let h = handle.lowercased()
        let hits = Set(names.filter { n in n.lowercased().split(separator: " ").contains { $0.hasPrefix(h) } })
        return hits.count == 1 ? hits.first! : handle
    }

    // MARK: - Rules

    private struct Rule {
        let pattern: String
        let date: ([String], Date, Calendar) -> Date?
    }

    /// A date phrase may carry its preposition ("by friday", "до пятницы"); it is removed with the date.
    private static let prefix = #"(?<![\p{L}\p{N}])(?:(?:by|on|due|until|before|до|к|ко|в|во|на)\s+)?"#
    private static let suffix = #"(?![\p{L}\p{N}])"#

    private static func days(_ n: Int) -> ([String], Date, Calendar) -> Date? {
        { _, today, cal in cal.date(byAdding: .day, value: n, to: today) }
    }

    /// Next occurrence of a weekday (1 = Sunday), never today.
    private static func next(_ weekday: Int, after today: Date, _ cal: Calendar) -> Date? {
        let diff = (weekday - cal.component(.weekday, from: today) + 7) % 7
        return cal.date(byAdding: .day, value: diff == 0 ? 7 : diff, to: today)
    }

    /// A day and month without a year that already passed this year means next year.
    private static func date(day: Int, month: Int, year: Int?, today: Date, _ cal: Calendar) -> Date? {
        var c = DateComponents(year: year.map { $0 < 100 ? 2000 + $0 : $0 } ?? cal.component(.year, from: today), month: month, day: day)
        guard let d = cal.date(from: c), cal.component(.day, from: d) == day, cal.component(.month, from: d) == month else { return nil }
        guard year == nil, d < today else { return d }
        c.year! += 1
        return cal.date(from: c)
    }

    private static let weekdays: [(String, Int)] = [
        ("monday|понедельник[ау]?", 2), ("tuesday|вторник[ау]?", 3), ("wednesday|сред[аеуы]", 4), ("thursday|четверг[ау]?", 5),
        ("friday|пятниц[аеуы]", 6), ("saturday|суббот[аеуы]", 7), ("sunday|воскресень[еяю]", 1),
    ]

    private static let months: [(String, Int)] = [
        ("january|jan|январ[яь]", 1), ("february|feb|феврал[яь]", 2), ("march|mar|марта?", 3), ("april|apr|апрел[яь]", 4),
        ("may|ма[яй]", 5), ("june|jun|июн[яь]", 6), ("july|jul|июл[яь]", 7), ("august|aug|августа?", 8),
        ("september|sept|sep|сентябр[яь]", 9), ("october|oct|октябр[яь]", 10), ("november|nov|ноябр[яь]", 11), ("december|dec|декабр[яь]", 12),
    ]

    private static func month(_ name: String) -> Int? {
        months.first { name.range(of: "^(?:\($0.0))$", options: [.regularExpression, .caseInsensitive]) != nil }?.1
    }

    private static let rules: [Rule] = {
        let monthNames = months.map(\.0).joined(separator: "|")
        var r: [Rule] = [
            Rule(pattern: "the day after tomorrow|day after tomorrow|послезавтра", date: days(2)),
            Rule(pattern: "tomorrow|завтра", date: days(1)),
            Rule(pattern: "today|tonight|сегодня", date: days(0)),
            Rule(pattern: #"in (\d{1,3}) days?|через (\d{1,3}) (?:день|дня|дней)"#) { g, today, cal in
                (g.first { !$0.isEmpty }).flatMap(Int.init).flatMap { cal.date(byAdding: .day, value: $0, to: today) }
            },
            Rule(pattern: "in a week|через неделю", date: days(7)),
            Rule(pattern: "next week|следующей неделе") { _, today, cal in next(2, after: today, cal) },
            Rule(pattern: #"(\d{1,2})[./](\d{1,2})(?:[./](\d{4}|\d{2}))?"#) { g, today, cal in
                date(day: Int(g[0])!, month: Int(g[1])!, year: Int(g[2]), today: today, cal)
            },
            Rule(pattern: #"(\d{1,2})\s+("# + monthNames + ")") { g, today, cal in
                month(g[1]).flatMap { date(day: Int(g[0])!, month: $0, year: nil, today: today, cal) }
            },
            Rule(pattern: "(" + monthNames + #")\.?\s+(\d{1,2})"#) { g, today, cal in
                month(g[0]).flatMap { date(day: Int(g[1])!, month: $0, year: nil, today: today, cal) }
            },
        ]
        r += weekdays.map { names, wd in
            Rule(pattern: "(?:next |следующ(?:ий|ую|ее|ая|ей) )?(?:" + names + ")") { _, today, cal in next(wd, after: today, cal) }
        }
        return r
    }()

    // MARK: - Regex helpers

    private struct Match {
        let range: Range<String.Index>
        let groups: [String]  // capture groups; "" when a group didn't take part
        func removing(from s: String) -> String { s.replacingCharacters(in: range, with: " ") }
    }

    private static func first(_ pattern: String, in s: String) -> Match? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              let range = Range(m.range, in: s) else { return nil }
        let groups = (1..<max(m.numberOfRanges, 1)).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
        return Match(range: range, groups: groups)
    }
}
