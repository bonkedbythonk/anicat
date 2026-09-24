import SwiftUI
import AnicatCoreKit

/// Reorder and hide the home page's configurable rows. Changes apply as they
/// are made, so the sheet has Done and no Cancel.
struct HomeCustomizeSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Customize home")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(SumiTheme.foreground)
                .padding(.bottom, 4)

            Text("Drag to reorder.")
                .font(.system(size: 11))
                .foregroundColor(SumiTheme.muted)
                .padding(.bottom, 12)

            List {
                ForEach(model.homeRowConfig) { row in
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(row.visible ? SumiTheme.foreground : SumiTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        SumiSwitch(isOn: Binding(
                            get: { row.visible },
                            set: { _ in model.toggleHomeRow(id: row.id) }
                        ))
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

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .sumiPrimaryButton()
                    .sumiKeyboardShortcut(.escape, modifiers: [])
            }
            .padding(.top, 16)
        }
        .padding(20)
        .frame(width: 380)
        .background(SumiTheme.background)
    }
}
