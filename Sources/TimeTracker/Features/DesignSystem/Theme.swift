import SwiftUI

/// Hansel's small design system: the same card, header, chip and stat tile everywhere,
/// on system materials so it follows light and dark mode and the user's accent colour.
enum Theme {
    static let cornerRadius: CGFloat = 12
    static let smallRadius: CGFloat = 8
    static let spacing: CGFloat = 12
    static let cardPadding: CGFloat = 12
}

/// A rounded panel on the window's material. `tint` colours it lightly for notices.
struct Card<Content: View>: View {
    var tint: Color? = nil
    var padding: CGFloat = Theme.cardPadding
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .fill(tint.map { AnyShapeStyle($0.opacity(0.12)) } ?? AnyShapeStyle(.background.secondary))
            }
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .strokeBorder(tint?.opacity(0.35) ?? Color.primary.opacity(0.06), lineWidth: 1)
            }
    }
}

/// Small caps-style title over a group, with an optional trailing accessory.
struct SectionHeader<Accessory: View>: View {
    let title: String
    var systemImage: String? = nil
    var accessory: Accessory

    init(_ title: String, systemImage: String? = nil, @ViewBuilder accessory: () -> Accessory) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.5)
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension SectionHeader where Accessory == EmptyView {
    init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.accessory = EmptyView()
    }
}

/// A coloured capsule label: project, customer, source…
struct Chip: View {
    let text: String
    var systemImage: String? = nil
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption)
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .foregroundStyle(color == .secondary ? Color.secondary : color)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

/// A big number with a label: "5h 12m · tracked today".
struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String? = nil
    var tint: Color = .accentColor

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if let systemImage { Image(systemName: systemImage).foregroundStyle(tint) }
                    Text(label).font(.caption).foregroundStyle(.secondary)
                }
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
    }
}

/// A borderless icon button with a tooltip, for toolbars and footers.
struct IconButton: View {
    let systemImage: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
    }
}

extension TimeEntry {
    /// The colour an entry is drawn in: its project's, else neutral.
    var displayColor: Color {
        project?.displayColor ?? Color.gray.opacity(0.55)
    }
}

/// The top of every page: a large title, a line of context, and the page's actions.
struct PageHeader<Actions: View>: View {
    let title: String
    var subtitle: String? = nil
    var actions: Actions

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(.largeTitle.weight(.semibold))
            if let subtitle {
                Text(subtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            actions
        }
    }
}

extension PageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

/// "+ Add a …" field, the same on every page that creates things. Extra controls (a
/// customer picker, a billable toggle) go in `accessory`.
struct AddField<Accessory: View>: View {
    let placeholder: String
    @Binding var text: String
    let onAdd: () -> Void
    var accessory: Accessory

    init(_ placeholder: String, text: Binding<String>, onAdd: @escaping () -> Void,
         @ViewBuilder accessory: () -> Accessory) {
        self.placeholder = placeholder
        self._text = text
        self.onAdd = onAdd
        self.accessory = accessory()
    }

    private var canAdd: Bool { !text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle.fill")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .onSubmit { if canAdd { onAdd() } }
            accessory
            if canAdd {
                Button("Add", action: onAdd).buttonStyle(.borderedProminent).controlSize(.small)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).fill(.background.secondary))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
            .strokeBorder(Color.primary.opacity(0.06)))
    }
}

extension AddField where Accessory == EmptyView {
    init(_ placeholder: String, text: Binding<String>, onAdd: @escaping () -> Void) {
        self.init(placeholder, text: text, onAdd: onAdd) { EmptyView() }
    }
}

struct BillableChip: View {
    let billable: Bool
    var body: some View {
        Chip(text: billable ? "Billable" : "Non-billable",
             systemImage: billable ? "dollarsign.circle.fill" : "dollarsign.circle",
             color: billable ? .green : .secondary)
    }
}

enum CatalogStats {
    /// Time tracked on these entries in the last 30 days.
    static func last30Days(_ entries: [TimeEntry], now: Date = Date()) -> TimeInterval {
        let since = now.addingTimeInterval(-30 * 86_400)
        return entries.reduce(0) { total, e in
            guard let end = e.endAt, end > since else { return total }
            return total + end.timeIntervalSince(max(e.startAt, since))
        }
    }
}
