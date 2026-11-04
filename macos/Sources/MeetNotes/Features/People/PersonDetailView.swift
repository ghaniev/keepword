import SwiftUI

struct PersonDetailView: View {
    @EnvironmentObject var model: AppModel
    @State private var person: Speaker?
    @State private var meetings: [Meeting] = []
    @State private var people: [(Speaker, Int)] = []
    @State private var confirmDelete = false

    var body: some View {
        Group {
            if let p = person {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 14) {
                            Avatar(name: p.name, size: 54)
                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Name", text: binding(\.name)).textFieldStyle(.plain).font(.system(size: 21, weight: .semibold))
                                Text(plural(meetings.count, "meeting") + (p.embedding.isEmpty ? "" : String(localized: " · voice profile saved"))).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Menu {
                                Menu("Merge Into…") {
                                    ForEach(people.filter { $0.0.id != p.id }, id: \.0.id) { other, _ in
                                        Button(other.name) {
                                            try? model.store.merge(p.id, into: other.id)
                                            model.selectedPerson = other.id
                                            model.toast = String(localized: "Merged speakers globally")
                                        }
                                    }
                                }
                                Button("Delete Person", role: .destructive) { confirmDelete = true }.disabled(p.id == Speaker.meID)
                            } label: { Image(systemName: "ellipsis.circle").font(.system(size: 15)) }
                                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        }
                        Form {
                            TextField("Email", text: optional(\.email))
                            TextField("Company", text: optional(\.company))
                            TextField("Position", text: optional(\.position))
                            TextField("Notes", text: optional(\.notes), axis: .vertical).lineLimit(2...6)
                        }
                        .formStyle(.grouped).scrollDisabled(true).frame(maxWidth: 560)
                        VStack(alignment: .leading, spacing: 6) {
                            SectionTitle(title: "Meetings", count: "\(meetings.count)")
                            ForEach(meetings) { m in
                                Button { model.open(m.id) } label: {
                                    HStack {
                                        Image(systemName: "doc.text").foregroundStyle(.secondary)
                                        Text(m.title).lineLimit(1)
                                        Spacer()
                                        Text(m.createdAt.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(.secondary)
                                    }
                                    .font(.system(size: 12.5)).padding(.vertical, 3).contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(24).frame(maxWidth: 760, alignment: .leading)
                }
            } else {
                EmptyState(icon: "person.2", title: "No people detected", message: "People appear after speaker identification. Rename them once — their voice is remembered.")
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: "\(model.revision)-\(model.selectedPerson ?? "")") {
            let all = (try? model.store.speakers()) ?? [:]
            person = model.selectedPerson.flatMap { all[$0] }
            meetings = person.flatMap { try? model.store.meetings(.person($0.id)) } ?? []
            people = (try? model.store.people()) ?? []
        }
        .confirmationDialog("Delete Person?", isPresented: $confirmDelete) {
            Button("Delete Person", role: .destructive) {
                if let id = person?.id { try? model.store.deletePerson(id); model.selectedPerson = nil }
            }
        } message: { Text("Their transcript lines become unassigned.") }
    }

    private func binding(_ kp: WritableKeyPath<Speaker, String>) -> Binding<String> {
        Binding(get: { person?[keyPath: kp] ?? "" }, set: { v in
            guard var p = person else { return }
            p[keyPath: kp] = v
            person = p
            try? model.store.saveSpeaker(p)
        })
    }

    private func optional(_ kp: WritableKeyPath<Speaker, String?>) -> Binding<String> {
        Binding(get: { person?[keyPath: kp] ?? "" }, set: { v in
            guard var p = person else { return }
            p[keyPath: kp] = v.isEmpty ? nil : v
            person = p
            try? model.store.saveSpeaker(p)
        })
    }
}
