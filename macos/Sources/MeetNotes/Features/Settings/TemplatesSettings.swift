import SwiftUI

struct TemplatesSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var templates: [Template] = []
    @State private var selection: String?
    @State private var draft: Template?

    var body: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 0) {
                List(templates, selection: $selection) { t in
                    HStack {
                        Text(t.name)
                        Spacer()
                        if t.isDefault { Text("Default").font(.caption).foregroundStyle(.secondary) }
                    }
                    .tag(t.id)
                }
                HStack {
                    Button { newTemplate() } label: { Image(systemName: "plus") }
                    Button { if let id = selection { try? model.store.deleteTemplate(id); selection = nil } } label: { Image(systemName: "minus") }
                        .disabled(draft?.builtin ?? true)
                }
                .buttonStyle(.borderless).padding(6)
            }
            .frame(minWidth: 180, maxWidth: 220)
            if let d = draft {
                Form {
                    TextField("Template Name", text: Binding(get: { d.name }, set: { draft?.name = $0 }))
                    VStack(alignment: .leading) {
                        Text("Highlights — what to pay attention to")
                        TextEditor(text: Binding(get: { d.insightsPrompt }, set: { draft?.insightsPrompt = $0 })).font(.system(size: 12)).frame(height: 120)
                    }
                    VStack(alignment: .leading) {
                        Text("Follow-ups — what counts as one")
                        TextEditor(text: Binding(get: { d.actionsPrompt }, set: { draft?.actionsPrompt = $0 })).font(.system(size: 12)).frame(height: 100)
                    }
                    HStack {
                        Button("Set as Default") { draft?.isDefault = true; save() }.disabled(d.isDefault)
                        Spacer()
                        Button("Save Changes") { save() }.keyboardShortcut("s")
                    }
                    Text("Order of use: meeting template → folder template → default template.").font(.caption).foregroundStyle(.secondary)
                }
                .formStyle(.grouped)
            } else {
                EmptyState(icon: "doc.text", title: "Select Template")
            }
        }
        .task(id: model.revision) { templates = (try? model.store.templates()) ?? [] }
        .onChange(of: selection) { _, id in draft = templates.first { $0.id == id } }
    }

    private func save() {
        guard let d = draft else { return }
        try? model.store.saveTemplate(d)
        model.toast = String(localized: "Saved")
    }

    private func newTemplate() {
        let t = Template(id: UUID().uuidString, name: String(localized: "New Template"), insightsPrompt: BuiltinTemplates.all[0].text("insights"),
                         actionsPrompt: BuiltinTemplates.all[0].text("actions"))
        try? model.store.saveTemplate(t)
        selection = t.id
        draft = t
    }
}
