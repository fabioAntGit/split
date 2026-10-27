import SwiftUI

/// Settings › Formats: choose a format to see what Split turns it into and what it makes it from.
/// A format that waits for a free program reads dimmed, with the program's name.
struct FormatSettings: View {
    @State private var chosen: Format? = .jpg
    @State private var query = ""

    private func matching(_ kind: SourceKind) -> [Format] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return kind.formats.filter { words.isEmpty || $0.label.lowercased().contains(words) || $0.ext.contains(words) }
    }

    var body: some View {
        ScrollViewReader { proxy in
            HStack(alignment: .top, spacing: 18) {
                VStack(spacing: 8) {
                    TextField(L("Search Formats"), text: $query)
                        .textFieldStyle(.roundedBorder)
                    List(selection: $chosen) {
                        ForEach(SourceKind.allCases.filter { !matching($0).isEmpty }) { kind in
                            Section(kind.title) {
                                ForEach(matching(kind), id: \.self) { format in
                                    HStack {
                                        Text(format.label)
                                        Spacer()
                                        Text(".\(format.ext)").font(.system(size: 11)).foregroundColor(.secondary)
                                    }
                                    .tag(format)
                                    .id(format)
                                }
                            }
                        }
                    }
                    .listStyle(.bordered(alternatesRowBackgrounds: false))
                }
                .frame(width: 220)
                if let chosen {
                    FormatDetail(format: chosen) { format in
                        query = ""
                        self.chosen = format
                        withAnimation(Motion.standard) { proxy.scrollTo(format, anchor: .center) }
                    }
                } else {
                    Text(L("Choose a format to see what Split makes from it."))
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

private struct FormatDetail: View {
    let format: Format
    let choose: (Format) -> Void

    private var targets: [Format] { Conversions.targets(for: format) }
    private var sources: [Format] { Format.allCases.filter { $0 != format && Conversions.targets(for: $0).contains(format) } }

    var body: some View {
        let targets = self.targets
        let sources = self.sources
        let waiting = targets.contains { Conversions.missingProgram(from: format, to: $0) != nil }
            || sources.contains { Conversions.missingProgram(from: $0, to: format) != nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    Text(".\(format.ext)")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 4)
                        .frame(width: 52, height: 52)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.08)))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(format.label).font(.system(size: 20, weight: .bold))
                        Text(SourceKind(format).title).font(.system(size: 12)).foregroundColor(.secondary)
                    }
                }
                Text(format.summary)
                    .fixedSize(horizontal: false, vertical: true)
                part(L("Turns into"), targets, missing: { Conversions.missingProgram(from: format, to: $0) },
                     empty: L("Nothing on this Mac opens %@ files for Split yet. Settings › Engines lists the apps that help.", format.label))
                part(L("Made from"), sources, missing: { Conversions.missingProgram(from: $0, to: format) },
                     empty: L("Split reads %@ files but doesn’t make them.", format.label))
                if waiting {
                    Label(L("Dimmed formats need a free program first. Settings › Engines has the command that installs it."), systemImage: "shippingbox")
                        .font(.system(size: 11)).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, 4)
        }
        .id(format)
    }

    /// One side of the conversions, in families, each format a button that shows that format.
    @ViewBuilder
    private func part(_ title: String, _ formats: [Format], missing: @escaping (Format) -> String?, empty: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                if !formats.isEmpty {
                    Text(String(formats.count)).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary).monospacedDigit()
                }
            }
            if formats.isEmpty {
                Text(empty).font(.system(size: 12)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(SourceKind.allCases.filter { kind in formats.contains { SourceKind($0) == kind } }) { kind in
                VStack(alignment: .leading, spacing: 6) {
                    Text(kind.title).font(.system(size: 11)).foregroundColor(.secondary)
                    Flow(spacing: 6) {
                        ForEach(formats.filter { SourceKind($0) == kind }, id: \.self) { other in
                            FormatChip(format: other, missing: missing(other)) { choose(other) }
                        }
                    }
                }
            }
        }
    }
}

private struct FormatChip: View {
    let format: Format
    let missing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(format.label)
                if let missing {
                    Text(missing).font(.system(size: 10)).foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(SecondaryButtonStyle(compact: true))
        .opacity(missing == nil ? 1 : 0.55)
        .help(missing.map { L("Needs %@, which Settings › Engines installs.", $0) } ?? format.summary)
        .accessibilityHint(missing.map { L("Needs %@, which Settings › Engines installs.", $0) } ?? format.summary)
    }
}

/// Lays its views out in rows, wrapping to the next row when one is full, like words.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let width = rows.map { $0.reduce(0) { $0 + $1.width } + spacing * CGFloat(max($0.count - 1, 0)) }.max() ?? 0
        let height = rows.map { $0.map(\.height).max() ?? 0 }.reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var index = 0
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            let height = row.map(\.height).max() ?? 0
            for size in row {
                subviews[index].place(at: CGPoint(x: x, y: y + (height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
                index += 1
            }
            y += height + spacing
        }
    }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [[CGSize]] {
        var rows: [[CGSize]] = [[]]
        var used: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].isEmpty, used + spacing + size.width > width {
                rows.append([])
                used = 0
            }
            used += (rows[rows.count - 1].isEmpty ? 0 : spacing) + size.width
            rows[rows.count - 1].append(size)
        }
        return rows
    }
}
