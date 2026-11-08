import SwiftUI

struct SearchField: View {
    @EnvironmentObject var model: AppModel
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(Palette.brand)
            TextField("Ask or search your meetings", text: $model.searchText)
                .textFieldStyle(.plain).focused($focused)
                .onExitCommand { model.searchText = "" }
            if !model.searchText.isEmpty {
                Button { model.searchText = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .frame(width: 380)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12)))
        .onChange(of: model.focusSearch) { focused = true }
    }
}
