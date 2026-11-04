import SwiftUI

struct PeopleListColumn: View {
    @EnvironmentObject var model: AppModel
    @State private var people: [(Speaker, Int)] = []
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("People").font(.system(size: 15, weight: .semibold))
                Spacer()
                CountBadge(count: people.count)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 6)
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search people", text: $filter).textFieldStyle(.plain)
            }
            .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
            .padding(.horizontal, 12).padding(.bottom, 8)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(people.filter { filter.isEmpty || $0.0.name.localizedCaseInsensitiveContains(filter) }, id: \.0.id) { p, count in
                        Card(selected: model.selectedPerson == p.id) {
                            HStack(spacing: 10) {
                                Avatar(name: p.name, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(p.name).font(.system(size: 12.5, weight: .medium))
                                    Text([p.company, p.position].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ").ifEmpty(plural(count, "meeting")))
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer()
                                Text("\(count)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .onTapGesture { model.selectedPerson = p.id }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
        .background(Palette.cardFill)
        .task(id: model.revision) {
            people = (try? model.store.people()) ?? []
            if model.selectedPerson == nil { model.selectedPerson = people.first?.0.id }
        }
    }
}
