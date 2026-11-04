import SwiftUI

struct TextEditSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: LocalizedStringKey
    @Binding var text: String
    let onSave: () -> Void
    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            TextEditor(text: $text).font(.body).frame(minHeight: 140)
            HStack { Spacer(); Button("Cancel") { dismiss() }; Button("Save") { onSave(); dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding().frame(width: 480)
    }
}
