import AppKit
import HushCore
import Store
import SwiftUI
import UniformTypeIdentifiers

/// Styles page (§3.7 / plan T10): what each cleanup style does up top, then
/// one row per app — installed built-in-map apps, overridden apps, and apps
/// seen in dictation history — with a segmented style picker.
struct StylesView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                PageHeader("Styles")

                LazyVGrid(columns: [GridItem](repeating: GridItem(.flexible(), spacing: Theme.Space.gridGap),
                                            count: 4),
                          spacing: Theme.Space.gridGap) {
                    ForEach(Self.styleCards, id: \.style) { card in
                        StyleCard(card)
                    }
                }
                .padding(.bottom, Theme.Space.gridGap)

                Tile("PER APP", accessory: {
                    Button("Add app…") { addApp() }
                        .buttonStyle(.hushSecondary)
                        .controlSize(.small)
                }) {
                    if model.styleRows.isEmpty {
                        Text("Dictate into an app and it shows up here — or add one now.")
                            .font(Theme.Font.caption)
                            .foregroundStyle(Theme.Color.textTertiary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(model.styleRows) { row in
                                styleRow(row)
                            }
                        }
                    }
                }
            }
            .padding(Theme.Space.contentPadding)
        }
        .scrollIndicators(.hidden)
    }

    // MARK: - style cards

    private struct Card: Equatable {
        let style: CleanupStyle
        let title: String
        let blurb: String
        let before: String
        let after: String
    }

    /// One compact tile per style: label, one-line description, tiny
    /// before → after example (a mixed EN/ID sample in Casual).
    private static let styleCards: [Card] = [
        Card(style: .default, title: "Default",
             blurb: "Clear, neutral sentences.",
             before: "um the build is green now",
             after: "The build is green now."),
        Card(style: .casual, title: "Casual",
             blurb: "Chat tone — slang stays, no greetings added.",
             before: "eh jadi besok deploy ya kayak biasa",
             after: "Jadi besok deploy ya, kayak biasa."),
        Card(style: .formal, title: "Formal",
             blurb: "Polished, professional writing for email.",
             before: "uh can you send the report today",
             after: "Could you send the report today?"),
        Card(style: .minimal, title: "Minimal",
             blurb: "Fillers + punctuation only — code and casing untouched.",
             before: "um change maxRetries to three",
             after: "change maxRetries to three"),
    ]

    private struct StyleCard: View {
        let card: Card
        init(_ card: Card) { self.card = card }
        var body: some View {
            Tile(card.title.uppercased()) {
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    Text(card.blurb)
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("“\(card.before)”")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .strikethrough(false)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.Color.textTertiary)
                    Text("“\(card.after)”")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textPrimary)
                }
            }
        }
    }

    // MARK: - app rows

    private func styleRow(_ row: AppModel.StyleAppRow) -> some View {
        HStack(spacing: Theme.Space.m) {
            if let icon = row.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "app.dashed")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.Color.textTertiary)
                    .frame(width: 24, height: 24)
            }
            Text(row.name)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            if row.isBuiltIn {
                Text("DEFAULT").tileLabel()
            }
            Spacer(minLength: Theme.Space.s)
            if row.isOverridden {
                Button {
                    model.resetStyle(bundleID: row.bundleID)
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.hushGhost)
                .controlSize(.small)
                .help("Reset to \(StyleResolver.builtInDefaults[row.bundleID]?.rawValue.capitalized ?? "Default")")
            }
            Picker("", selection: Binding(
                get: { row.effective },
                set: { model.setStyle(bundleID: row.bundleID, name: row.name, style: $0) }
            )) {
                Text("Default").tag(CleanupStyle.default)
                Text("Casual").tag(CleanupStyle.casual)
                Text("Formal").tag(CleanupStyle.formal)
                Text("Minimal").tag(CleanupStyle.minimal)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 300)
        }
        .padding(.vertical, Theme.Space.s)
        .overlay(alignment: .top) {
            if row.id != model.styleRows.first?.id {
                Rectangle().fill(Theme.Color.hairline).frame(height: 1)
            }
        }
    }

    /// "Add app…" — an NSOpenPanel restricted to `.app` in /Applications.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Add"
        panel.message = "Choose an app to give it a cleanup style"
        guard panel.runModal() == .OK, let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }
        model.setStyle(bundleID: bundleID,
                       name: url.deletingPathExtension().lastPathComponent,
                       style: .default)
    }
}
