import SwiftUI

struct SettingsCard<Content: View>: View {
    let title: String
    var badge: String? = nil
    var description: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header Bar
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)

                    if let badge {
                        Text(badge)
                            .font(.system(size: 11).smallCaps())
                            .foregroundColor(SumiTheme.muted)
                    }
                }

                if let description {
                    Text(description)
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(Color.white.opacity(0.02))

            Rectangle()
                .fill(SumiTheme.border)
                .frame(height: 1)

            // Body
            VStack(alignment: .leading, spacing: 14) {
                content()
            }
            .padding(20)
        }
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }
}

struct SettingField<Trailing: View>: View {
    let label: String
    var badge: String? = nil
    var description: String? = nil
    var isStacked: Bool = false
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        if isStacked {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 11).smallCaps())
                                .foregroundColor(SumiTheme.muted)
                        }
                    }

                    if let description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                trailing()
            }
            .padding(.vertical, 2)
        } else {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(label)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.foreground)

                        if let badge {
                            Text(badge)
                                .font(.system(size: 11).smallCaps())
                                .foregroundColor(SumiTheme.muted)
                        }
                    }

                    if let description {
                        Text(description)
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 16)

                trailing()
            }
            .padding(.vertical, 2)
        }
    }
}

/// The theme row: one swatch per skin, drawn in that skin's own colours.
///
/// Reads `ThemeStore.shared` rather than keeping `@AppStorage` copies of its
/// own. The store already writes both keys, and a second writer for one
/// setting is how a picker ends up showing a theme the app is not using.
struct ThemePicker: View {
    @State private var store = ThemeStore.shared

    // Three swatches fit a row; the grid is kept from when the flat list had
    // six, so a fourth skin needs no revisit. `maximum` is pinned to the
    // swatch width on purpose: left open it defaults to `.infinity`, the grid
    // divides the whole pane between the columns it chose, and each 72pt
    // swatch floats in the middle of an oversized cell.
    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 72), spacing: 12, alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(SumiSkin.allCases) { skin in
                let isSelected = store.skin == skin
                Button {
                    guard !isSelected else { return }
                    SumiHaptics.selection()
                    store.select(skin)
                } label: {
                    VStack(spacing: 7) {
                        ThemeSwatch(
                            palette: store.previewPalette(for: skin),
                            isSelected: isSelected
                        )

                        Text(skin.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(skin.caption)
            }
        }
    }
}

/// A palette in miniature: its ground, one card on it, its accent. Drawn from
/// the palette handed in rather than from `SumiTheme`, which is the whole
/// point — the OLED swatch has to look like OLED while Paper is in force.
struct ThemeSwatch: View {
    let palette: SumiPalette
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background)

            VStack(alignment: .leading, spacing: 5) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(palette.card)
                    .frame(width: 44, height: 12)
                    .overlay(
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(palette.border, lineWidth: 1)
                    )

                HStack(spacing: 4) {
                    Capsule()
                        .fill(palette.indigo)
                        .frame(width: 20, height: 5)

                    Capsule()
                        .fill(palette.muted)
                        .frame(width: 12, height: 5)
                }
            }
            .padding(9)
        }
        .frame(width: 72, height: 44)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? SumiTheme.indigo : SumiTheme.border, lineWidth: isSelected ? 2 : 1)
        )
    }
}

struct SumiSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button {
            withAnimation(.snappy) {
                isOn.toggle()
            }
        } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                RoundedRectangle(cornerRadius: 11)
                    .fill(isOn ? SumiTheme.indigo : SumiTheme.foreground.opacity(0.20))
                    .frame(width: 38, height: 22)

                Circle()
                    .fill(SumiTheme.foreground)
                    .frame(width: 18, height: 18)
                    .padding(2)
                    .shadow(color: Color.black.opacity(0.15), radius: 1, x: 0, y: 1)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.sumiPressable)
    }
}

struct SumiDropdown: View {
    let options: [String]
    @Binding var selected: String
    var minWidth: CGFloat = 160

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { opt in
                Button {
                    selected = opt
                } label: {
                    HStack {
                        Text(opt)
                        if opt == selected {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selected)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)

                Spacer(minLength: 4)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SumiTheme.muted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minWidth: minWidth)
            .background(SumiTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .sumiMenuPressable()
        }
        .menuStyle(.borderlessButton)
    }
}
