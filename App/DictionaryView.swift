import Store
import SwiftUI

/// Dictionary (spec §5, DESIGN.md): SUGGESTIONS (when pending) on top, then
/// TERMS and REPLACEMENTS. Each row carries its source badge and hit count;
/// entries feed the ASR prompt, the cleanup `{terms}` line, and the
/// deterministic replacement engine.
struct DictionaryView: View {
    @ObservedObject var model: AppModel
    @State private var newTerm = ""
    @State private var newFrom = ""
    @State private var newTo = ""

    private var terms: [DictionaryEntry] {
        model.dictEntries.filter { $0.kind == "term" }
    }
    private var replacements: [DictionaryEntry] {
        model.dictEntries.filter { $0.kind == "replacement" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.l) {
                PageHeader("Dictionary")

                if !model.pendingSuggestions.isEmpty {
                    suggestionsTile
                }
                termsTile
                replacementsTile
            }
            .padding(Theme.Space.contentPadding)
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.window)
    }

    // MARK: - suggestions (§6 — edits the watcher observed)

    private var suggestionsTile: some View {
        Tile("SUGGESTIONS") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text("Edits you made after pasting. Approve to make them permanent; the same edit twice approves itself.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(Theme.Color.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, Theme.Space.xs)
                ForEach(model.pendingSuggestions) { suggestion in
                    suggestionRow(suggestion)
                }
            }
        }
    }

    private func suggestionRow(_ s: Suggestion) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text("\(s.fromText) → \(s.toText)")
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            Text("seen ×\(s.seenCount)")
                .font(Theme.Font.data(12))
                .foregroundStyle(Theme.Color.textTertiary)
            Spacer()
            Button("Approve") { model.approveSuggestion(id: s.id) }
                .buttonStyle(.hushSecondary)
            Button("Reject") { model.rejectSuggestion(id: s.id) }
                .buttonStyle(.hushGhost)
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.vertical, 6)
    }

    // MARK: - terms

    private var termsTile: some View {
        Tile("TERMS") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if terms.isEmpty {
                    Text("No terms yet — names and jargon feed the transcriber so they come out right.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .padding(.bottom, Theme.Space.xs)
                }
                ForEach(terms) { entry in
                    entryRow(text: entry.toText, entry: entry)
                }
                addField(placeholder: "Add a term (e.g. Supabase)", text: $newTerm) {
                    model.addDictionaryTerm(newTerm)
                    newTerm = ""
                }
            }
        }
    }

    // MARK: - replacements

    private var replacementsTile: some View {
        Tile("REPLACEMENTS") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if replacements.isEmpty {
                    Text("No replacements yet — deterministic `from → to` fixes applied before and after cleanup.")
                        .font(Theme.Font.caption)
                        .foregroundStyle(Theme.Color.textTertiary)
                        .padding(.bottom, Theme.Space.xs)
                }
                ForEach(replacements) { entry in
                    entryRow(text: "\(entry.fromText ?? "") → \(entry.toText)",
                             entry: entry)
                }
                HStack(spacing: Theme.Space.s) {
                    field(placeholder: "from", text: $newFrom)
                    Text("→").foregroundStyle(Theme.Color.textTertiary)
                    field(placeholder: "to", text: $newTo) {
                        submitReplacement()
                    }
                    Button("Add") { submitReplacement() }
                        .buttonStyle(.hushSecondary)
                        .disabled(newFrom.trimmingCharacters(in: .whitespaces).isEmpty
                                  || newTo.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func submitReplacement() {
        model.addDictionaryReplacement(from: newFrom, to: newTo)
        newFrom = ""
        newTo = ""
    }

    // MARK: - rows

    private func entryRow(text: String, entry: DictionaryEntry) -> some View {
        HStack(spacing: Theme.Space.m) {
            Text(text)
                .font(Theme.Font.body)
                .foregroundStyle(Theme.Color.textPrimary)
                .lineLimit(1)
            badge(entry.source)
            Spacer()
            Text("\(entry.hitCount)×")
                .font(Theme.Font.data(12))
                .foregroundStyle(Theme.Color.textTertiary)
            Button {
                model.deleteDictionaryEntry(id: entry.id)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.hushGhost)
            .accessibilityLabel("Delete")
        }
        .padding(.vertical, 4)
    }

    /// MANUAL / LEARNED / HISTORY provenance chip.
    private func badge(_ source: String) -> some View {
        Text(source)
            .font(Theme.Font.label(9))
            .tracking(0.06 * 9)
            .textCase(.uppercase)
            .foregroundStyle(source == "learned" ? Theme.Color.signal
                             : Theme.Color.textTertiary)
            .padding(.horizontal, Theme.Space.s)
            .padding(.vertical, 2)
            .overlay(Capsule().stroke(Theme.Color.hairline, lineWidth: 1))
    }

    private func addField(placeholder: String, text: Binding<String>,
                          onSubmit: @escaping () -> Void) -> some View {
        HStack(spacing: Theme.Space.s) {
            field(placeholder: placeholder, text: text, onSubmit: onSubmit)
            Button("Add") { onSubmit() }
                .buttonStyle(.hushSecondary)
                .disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func field(placeholder: String, text: Binding<String>,
                       onSubmit: (() -> Void)? = nil) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(Theme.Font.body)
            .foregroundStyle(Theme.Color.textPrimary)
            .padding(.horizontal, Theme.Space.m)
            .frame(height: 32)
            .background(Theme.Color.raised,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .onSubmit { onSubmit?() }
    }
}
