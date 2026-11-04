import SwiftUI

struct CalendarWeekView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var calendar: CalendarService
    @State private var weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now
    @State private var selected: String?
    @State private var showConnect = false
    @State private var recorded: Set<String> = []
    @AppStorage("weekViewDays") private var days = 7
    private let hourHeight: CGFloat = 44
    private let gutter: CGFloat = 52

    private var dates: [Date] {
        let week = (0..<7).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: weekStart) }
        return days == 5 ? week.filter { !Calendar.current.isDateInWeekend($0) } : week
    }
    private var interval: DateInterval { DateInterval(start: weekStart, duration: 7 * 86400) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if !calendar.canRead {
                connectState
            } else {
                dayHeader
                allDayRow
                Divider()
                grid
                    .overlay {
                        if calendar.events.isEmpty { emptyWeek }
                    }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: weekStart) { calendar.show(interval) }
        .task(id: model.revision) { recorded = Set(((try? model.store.meetings(.all)) ?? []).compactMap(\.eventId)) }
        .sheet(isPresented: $showConnect) { ConnectGoogleSheet(calendar: calendar) }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Text(weekStart.formatted(.dateTime.month(.wide).year())).font(.system(size: 17, weight: .semibold))
            Spacer()
            Picker("", selection: $days) { Text("Work week").tag(5); Text("Week").tag(7) }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            Button { shift(-7) } label: { Image(systemName: "chevron.left") }.help("Previous week")
            Button("Today") { weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: .now)?.start ?? .now }
            Button { shift(7) } label: { Image(systemName: "chevron.right") }.help("Next week")
            Button { Task { await calendar.refreshFeeds() } } label: { Image(systemName: "arrow.clockwise") }.help("Refresh calendar")
            Button { showConnect = true } label: { Label("Google Calendar", systemImage: "plus") }.help("Import a Google calendar")
        }
        .padding(.horizontal, 18).padding(.vertical, 10)
    }

    private func shift(_ d: Int) { weekStart = Calendar.current.date(byAdding: .day, value: d, to: weekStart) ?? weekStart }

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: gutter)
            ForEach(dates, id: \.self) { d in
                let today = Calendar.current.isDateInToday(d)
                HStack(spacing: 6) {
                    Text(d.formatted(.dateTime.weekday(.abbreviated))).foregroundStyle(.secondary)
                    Text(d.formatted(.dateTime.day())).fontWeight(today ? .bold : .regular)
                        .foregroundStyle(today ? Color.white : .primary)
                        .frame(minWidth: 24, minHeight: 24)
                        .background(Circle().fill(today ? Color.red : .clear))
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var allDayRow: some View {
        let allDay = calendar.events.filter(\.isAllDay)
        if !allDay.isEmpty {
            HStack(alignment: .top, spacing: 0) {
                Text("all-day").font(.system(size: 9.5)).foregroundStyle(.secondary).frame(width: gutter - 6, alignment: .trailing).padding(.trailing, 6)
                ForEach(dates, id: \.self) { d in
                    VStack(spacing: 2) {
                        ForEach(allDay.filter { $0.start <= d && $0.end > d }) { e in
                            eventButton(e) {
                                Text(e.title).font(.system(size: 10.5, weight: .medium)).lineLimit(1)
                                    .padding(.horizontal, 4).padding(.vertical, 2).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangle(cornerRadius: 4).fill(e.color.opacity(0.25)))
                            }
                        }
                    }
                    .padding(.horizontal, 2).frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(.bottom, 4)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var grid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        ForEach(0..<24, id: \.self) { h in
                            Text(String(format: "%02d:00", h)).font(.system(size: 9.5)).foregroundStyle(.secondary)
                                .frame(width: gutter - 6, height: hourHeight, alignment: .topTrailing).padding(.trailing, 6)
                                .offset(y: -6).id(h)
                        }
                    }
                    ForEach(dates, id: \.self) { d in dayColumn(d) }
                }
                .padding(.top, 8)
            }
            .onAppear {
                let h = Calendar.current.component(.hour, from: .now)
                proxy.scrollTo(h < 7 ? 8 : min(h - 1, 15), anchor: .top)  // working hours, or an hour before now
            }
        }
    }

    private func dayColumn(_ day: Date) -> some View {
        let dayEnd = day.addingTimeInterval(86400)
        let timed = calendar.events.filter { !$0.isAllDay && $0.end > day && $0.start < dayEnd }
        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(0..<24, id: \.self) { _ in
                    Rectangle().fill(Color.clear).frame(height: hourHeight).overlay(alignment: .top) { Divider() }
                }
            }
            GeometryReader { geo in
                ForEach(ICS.lanes(timed), id: \.0.id) { e, lane, lanes in
                    let top = offset(max(e.start, day), in: day), bottom = offset(min(e.end, dayEnd), in: day)
                    let width = (geo.size.width - 4) / CGFloat(lanes)
                    eventButton(e) {
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                if recorded.contains(e.id) { Image(systemName: "waveform").font(.system(size: 8)) }
                                Text(e.title).font(.system(size: 10.5, weight: .semibold)).lineLimit(2)
                            }
                            if bottom - top > 28 { Text("\(e.start.hhmm)–\(e.end.hhmm)").font(.system(size: 9.5)).opacity(0.8) }
                        }
                        .padding(4)
                        .frame(width: max(10, width - 2), height: max(18, bottom - top - 1), alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 5).fill(e.color.opacity(0.22)))
                        .overlay(alignment: .leading) { Rectangle().fill(e.color).frame(width: 3) }
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .offset(x: 2 + CGFloat(lane) * width, y: top)
                }
                if Calendar.current.isDateInToday(day) {
                    HStack(spacing: 0) {
                        Circle().fill(Color.red).frame(width: 7, height: 7)
                        Rectangle().fill(Color.red).frame(height: 1.5)
                    }
                    .offset(x: -3, y: offset(.now, in: day) - 3.5)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .leading) { Divider() }
    }

    /// An event chip that opens its details in a popover anchored to itself.
    private func eventButton<L: View>(_ e: CalEvent, @ViewBuilder label: () -> L) -> some View {
        Button { selected = e.id } label: { label() }
            .buttonStyle(.plain)
            .help("\(e.title) · \(e.start.hhmm)–\(e.end.hhmm)")
            .popover(isPresented: Binding(get: { selected == e.id }, set: { if !$0 { selected = nil } }), arrowEdge: .trailing) {
                EventDetail(event: e).environmentObject(model)
            }
    }

    private func offset(_ d: Date, in day: Date) -> CGFloat {
        CGFloat(max(0, min(86400, d.timeIntervalSince(day))) / 3600) * hourHeight
    }

    private var connectState: some View {
        VStack(spacing: 14) {
            Image(systemName: "calendar.badge.exclamationmark").font(.system(size: 34)).foregroundStyle(.tertiary)
            if calendar.status == .denied || calendar.status == .restricted || calendar.status == .writeOnly {
                Text("Calendar access is off").font(.headline)
                Text("MeetNotes can't read your calendars. Turn MeetNotes on in System Settings → Privacy & Security → Calendars.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Open Privacy Settings") { Task { await calendar.requestAccess() } }
            } else {
                Text("Connect your calendar").font(.headline)
                Text("See upcoming meetings, join with one click and record them. Calendar data stays on your Mac.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Allow Calendar Access") { Task { await calendar.requestAccess() } }.buttonStyle(.borderedProminent)
            }
            Button("Import Google Calendar…") { showConnect = true }.buttonStyle(.link)
        }
        .frame(maxWidth: 420).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyWeek: some View {
        VStack(spacing: 8) {
            Text("No events this week").font(.headline)
            Text("Only calendars available to this Mac appear here. Add your work calendar to see your meetings.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("Connect Google Calendar…") { showConnect = true }.buttonStyle(.borderedProminent)
                Button("Calendar Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: 440)
        .background(RoundedRectangle(cornerRadius: 12).fill(.regularMaterial))
        .shadow(radius: 4)
    }
}
