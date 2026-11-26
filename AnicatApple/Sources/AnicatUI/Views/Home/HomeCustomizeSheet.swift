import SwiftUI
import AnicatCoreKit

/// Reorder and hide the home page's configurable rows. Changes apply as they
/// are made, so the sheet has Done and no Cancel.
struct HomeCustomizeSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Customize Up next")
                    .font(.sumiHeading(size: 19, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(SumiTheme.foreground)
                Text("Drag to reorder. Hidden rows stay one click away here.")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }

            List {
                ForEach(model.homeRowConfig) { row in
                    HStack(spacing: 12) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(row.visible ? SumiTheme.foreground : SumiTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SumiSwitch(isOn: Binding(
                            get: { row.visible },
                            set: { _ in model.toggleHomeRow(id: row.id) }
                        ), label: row.title)
                    }
                    .padding(.vertical, 4)
                    .listRowBackground(Color.clear)
                    #if !os(tvOS)
                    .listRowSeparatorTint(SumiTheme.border)
                    #endif
                }
                .onMove { from, to in
                    model.homeRowConfig.move(fromOffsets: from, toOffset: to)
                    model.persistHomeRowConfig()
                }
            }
            .listStyle(.plain)
            #if !os(tvOS)
            // The plain list otherwise paints the system control background,
            // a grey slab against the Sumi paper and ink palettes.
            .scrollContentBackground(.hidden)
            #endif
            // A List has no intrinsic height and a sheet sizes itself once,
            // so the list gets one: about 38pt a row, from the row count so a
            // new row (Watching joined as the seventh) is not cut off.
            .frame(height: CGFloat(model.homeRowConfig.count) * 38 + 8)

            HStack(spacing: 8) {
                Spacer()
                // A quiet word, not a second boxed button: the sheet's one
                // push button is Done.
                Button {
                    model.homeRowConfig = AppModel.defaultHomeRows
                    model.persistHomeRowConfig()
                } label: {
                    Text("Reset")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .disabled(model.homeRowConfig == AppModel.defaultHomeRows)
                Button("Done") { isPresented = false }
                    .sumiPrimaryButton()
                    .sumiKeyboardShortcut(.escape, modifiers: [])
            }
        }
        .padding(22)
        .frame(width: 460)
        .background(SumiTheme.card)
    }
}
