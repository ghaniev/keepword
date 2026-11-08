import SwiftUI

enum DateFilter: String, CaseIterable, Identifiable {
    case any = "Any time", today = "Today", week = "This week", month = "This month"
    var id: String { rawValue }
    func contains(_ d: Date) -> Bool {
        let cal = Calendar.current
        switch self {
        case .any: return true
        case .today: return cal.isDateInToday(d)
        case .week: return cal.isDate(d, equalTo: .now, toGranularity: .weekOfYear)
        case .month: return cal.isDate(d, equalTo: .now, toGranularity: .month)
        }
    }
}

struct DocumentListColumn: View {
    @EnvironmentObject var model: AppModel
    let scope: Store.Scope
    @State private var meetings: [Meeting] = []
    @State private var people: [String: [Speaker]] = [:]
    @State private var folders: [String: Folder] = [:]
    @State private var title = String(localized: "Meetings")
    @AppStorage("dateFilter") private var dateFilter: DateFilter = .any

    private var groups: [(Date, [Meeting])] {
        Dictionary(grouping: meetings.filter { dateFilter.contains($0.createdAt) }) { Calendar.current.startOfDay(for: $0.createdAt) }
            .sorted { $0.key > $1.key }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text("\(meetings.count)").font(.system(size: 13)).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Menu {
                    Picker("Date", selection: $dateFilter) { ForEach(DateFilter.allCases) { Text(LocalizedStringKey($0.rawValue)).tag($0) } }
                } label: { Image(systemName: dateFilter == .any ? "calendar" : "calendar.badge.clock") }
                    .menuStyle(.borderlessButton).fixedSize().help("Filter by date")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            Divider()
            if meetings.isEmpty {
                EmptyState(icon: scope == .deleted ? "trash" : "doc.text", title: scope == .deleted ? "Trash is empty" : "No meetings yet",
                           message: scope == .deleted ? "Deleted meetings stay here for 30 days." : "Record a call or import an audio file.")
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2, pinnedViews: .sectionHeaders) {
                        ForEach(groups, id: \.0) { day, items in
                            Section {
                                ForEach(items) { m in
                                    DocumentCard(meeting: m, people: people[m.id] ?? [],
                                                 selected: model.selectedMeeting == m.id)
                                        .onTapGesture { model.selectedMeeting = m.id }
                                        .draggable(m.id)
                                        .contextMenu { DocumentMenu(meeting: m) }
                                }
                            } header: {
                                Text(day.dayHeader).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
                                    .background(Palette.cardFill.opacity(0.95))
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 12)
                }
            }
        }
        .background(Palette.cardFill)
        .task(id: "\(model.revision)-\(scope)") {
            meetings = (try? model.store.meetings(scope)) ?? []
            people = (try? model.store.participantsByMeeting()) ?? [:]
            let fs = (try? model.store.folders()) ?? []
            folders = Dictionary(uniqueKeysWithValues: fs.map { ($0.id, $0) })
            title = switch scope {
            case .all: String(localized: "Meetings")
            case .unsorted: String(localized: "Inbox")
            case .folder(let id): folders[id]?.name ?? String(localized: "Folder")
            case .tag(let id): "#" + ((try? model.store.allTags())?.first { $0.0.id == id }?.0.name ?? "")
            case .person: String(localized: "Person")
            case .deleted: String(localized: "Trash")
            }
            if model.selectedMeeting == nil || !meetings.contains(where: { $0.id == model.selectedMeeting }) {
                if scope != .deleted || model.selectedMeeting != nil { model.selectedMeeting = meetings.first?.id }
            }
        }
    }
}

struct DocumentCard: View {
    @EnvironmentObject var model: AppModel
    let meeting: Meeting
    let people: [Speaker]
    let selected: Bool

    var body: some View {
        Card(selected: selected) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    if meeting.id == model.recordingID { PulsingDot() }
                    else if meeting.isProcessing || meeting.status == "queued" { ProgressView().controlSize(.mini) }
                    else if meeting.status.hasPrefix("error") { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption) }
                    Text(meeting.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                }
                Text("\(meeting.createdAt.hhmm) · \(minutesLabel(meeting.duration))").font(.system(size: 11)).foregroundStyle(.secondary)
                if !people.isEmpty { AvatarStack(names: people.map(\.name), limit: 3).padding(.vertical, 1) }
                let preview = meeting.status == "done" ? meeting.summary : meeting.statusLabel
                if !preview.isEmpty {
                    Text(preview).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}
