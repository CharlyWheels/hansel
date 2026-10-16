import SwiftUI

/// A todo's or customer's dossier: read it as written, or edit it. The next rewrite
/// starts from the edited text, so a correction made here is kept.
struct DossierSection: View {
    @Binding var dossier: String
    let updatedAt: Date?
    /// Called after the user saved an edit.
    let onSave: () -> Void

    @State private var editing = false
    @State private var draft = ""

    var body: some View {
        Section {
            if editing {
                TextEditor(text: $draft)
                    .font(.system(.callout, design: .monospaced))
                    .frame(minHeight: 260)
                HStack {
                    Spacer()
                    Button("Cancel") { editing = false }
                    Button("Save") {
                        dossier = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                        editing = false
                        onSave()
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else if dossier.isEmpty {
                Text("No dossier yet. It is written from this item's meetings, messages, emails and pages on the next context collection.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(Self.blocks(dossier).enumerated()), id: \.offset) { _, block in
                        switch block {
                        case let .heading(text):
                            Text(text).font(.headline).padding(.top, 6)
                        case let .line(text):
                            Text(Self.inline(text)).font(.callout).textSelection(.enabled)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text("Dossier")
                Spacer()
                if let updatedAt, !editing {
                    Text("Updated \(updatedAt.formatted(.relative(presentation: .named)))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !editing {
                    Button(dossier.isEmpty ? "Write" : "Edit") {
                        draft = dossier.isEmpty ? Self.emptyTemplate : dossier
                        editing = true
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
            }
        }
    }

    enum Block { case heading(String), line(String) }

    static func blocks(_ markdown: String) -> [Block] {
        markdown.components(separatedBy: .newlines).compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { return nil }
            if line.hasPrefix("#") {
                return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces))
            }
            return .line(line.hasPrefix("- ") ? "•  " + line.dropFirst(2) : line)
        }
    }

    /// Bold, italics, code and links inside a line; the text as is if it does not parse.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static var emptyTemplate: String {
        DossierService.sections.map { "\($0)\n" }.joined(separator: "\n")
    }
}
