import AppKit
import SwiftUI

/// Visual language: light-blue tag chips, orange time chips and folder chips,
/// colored initials avatars, soft rounded cards with a blue selected state.
enum Palette {
    static let keys = ["blue", "green", "orange", "red", "purple", "pink", "teal", "yellow", "gray"]

    static func color(_ key: String) -> Color {
        switch key {
        case "green": .green
        case "orange": .orange
        case "red": .red
        case "purple": .purple
        case "pink": .pink
        case "teal": .teal
        case "yellow": .yellow
        case "gray": .gray
        default: .blue
        }
    }

    /// Stable color per name for avatars (each person keeps one color).
    static func avatar(_ name: String) -> Color {
        let colors: [Color] = [.orange, .red, .pink, .purple, .blue, .teal, .green, .indigo, .brown]
        let h = name.unicodeScalars.reduce(5381) { ($0 << 5) &+ $0 &+ Int($1.value) }
        return colors[abs(h) % colors.count]
    }

    static let tagFill = Color.blue.opacity(0.10)
    static let tagText = Color(nsColor: .systemBlue).opacity(0.95)
    static let timeFill = Color.orange.opacity(0.14)
    static let timeText = Color.orange
    static let cardFill = Color(nsColor: .controlBackgroundColor)
    static let sidebarFill = Color(nsColor: .windowBackgroundColor)
}

func initials(_ name: String) -> String {
    let parts = name.split(separator: " ").prefix(2)
    let s = parts.compactMap(\.first).map(String.init).joined()
    return (s.isEmpty ? "?" : s).uppercased()
}

struct Avatar: View {
    let name: String
    var size: CGFloat = 16
    var body: some View {
        Text(initials(name))
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Circle().fill(Palette.avatar(name)))
    }
}

struct PersonChip: View {
    let name: String
    var body: some View {
        HStack(spacing: 5) {
            Avatar(name: name)
            Text(name).font(.system(size: 11)).lineLimit(1)
        }
        .fixedSize()
        .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.08)))
    }
}

struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)? = nil
    var body: some View {
        HStack(spacing: 3) {
            Text(name).font(.system(size: 10.5))
            if let onRemove {
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 7, weight: .bold)) }.buttonStyle(.plain)
            }
        }
        .lineLimit(1).fixedSize()
        .foregroundStyle(Palette.tagText)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: 5).fill(Palette.tagFill))
    }
}

struct TimeChip: View {
    let seconds: Double
    var action: (() -> Void)? = nil
    var body: some View {
        Button { action?() } label: {
            Text(timestamp(seconds)).font(.system(size: 10, weight: .medium)).monospacedDigit()
                .foregroundStyle(Palette.timeText)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Palette.timeFill))
        }
        .buttonStyle(.plain)
        .help("Play from this timestamp")
    }
}

struct CountBadge: View {
    let count: Int
    var body: some View {
        Text("\(count)").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(Color.primary.opacity(0.07)))
    }
}

struct BetaBadge: View {
    var body: some View {
        Text("Beta").font(.system(size: 9, weight: .medium)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
    }
}

struct SectionTitle: View {
    let title: LocalizedStringKey
    var count: String? = nil
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(.system(size: 14, weight: .semibold))
            if let count { Text(count).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
    }
}

/// Folder glyph: an emoji, or an SF Symbol tinted with the folder color.
struct FolderIcon: View {
    let icon: String
    let color: String
    var size: CGFloat = 13
    var body: some View {
        if icon.unicodeScalars.first?.properties.isEmojiPresentation == true || icon.count == 1 && !icon.allSatisfy(\.isASCII) {
            Text(icon).font(.system(size: size))
        } else {
            Image(systemName: icon).font(.system(size: size)).foregroundStyle(Palette.color(color))
        }
    }
}

struct Card<Content: View>: View {
    var selected = false
    @ViewBuilder let content: Content
    var body: some View {
        content
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(selected ? Color.accentColor.opacity(0.13) : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.accentColor.opacity(0.55) : Color.clear, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

extension View {
    /// Caps document content at a readable width and centers it in wide windows.
    func readableColumn() -> some View {
        frame(maxWidth: 860, alignment: .leading).frame(maxWidth: .infinity)
    }
}

/// Text tabs with a grey capsule on the selected one (Summary / Transcript / Chat).
struct TextTabs<T: Hashable>: View {
    let tabs: [(T, LocalizedStringKey)]
    @Binding var selection: T
    var body: some View {
        HStack(spacing: 4) {
            ForEach(tabs, id: \.0) { tab in
                Button { selection = tab.0 } label: {
                    Text(tab.1).font(.system(size: 13.5))
                        .foregroundStyle(selection == tab.0 ? .primary : .secondary)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(selection == tab.0 ? Color.primary.opacity(0.07) : .clear))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct PulsingDot: View {
    @State private var on = false
    var color: Color = .red
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8).opacity(on ? 0.35 : 1)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on = true } }
    }
}

struct EmptyState: View {
    let icon: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey? = nil
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 30)).foregroundStyle(.tertiary)
            Text(title).font(.headline).foregroundStyle(.secondary)
            if let message { Text(message).font(.callout).foregroundStyle(.tertiary).multilineTextAlignment(.center) }
        }
        .frame(maxWidth: 320).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Renders simple markdown blocks: headings, bullets, paragraphs, with inline formatting.
struct MarkdownText: View {
    let text: String
    var onLink: ((URL) -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(text.components(separatedBy: "\n").enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("#") {
                    inline(line.trimmingCharacters(in: CharacterSet(charactersIn: "# "))).font(.system(size: 13, weight: .semibold)).padding(.top, 4)
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        inline(String(line.dropFirst(2)))
                    }
                } else if !line.isEmpty {
                    inline(line)
                }
            }
        }
        .textSelection(.enabled)
        .environment(\.openURL, OpenURLAction { url in
            if let onLink { onLink(url); return .handled }
            return .systemAction
        })
    }

    private func inline(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s))
            .font(.system(size: 13))
    }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}
