import SwiftUI
import AnicatCoreKit
#if os(macOS)
import AppKit
#endif

/// Reorder/hide the home page's configurable rows — mirrors the "Customize
/// home" modal in HomeView.tsx: arrows to move, an eye to toggle visibility,
/// order is the list order itself.
struct HomeCustomizeSheet: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "square.grid.2x2")
                        .foregroundColor(SumiTheme.indigo)
                    Text("Customize home")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(SumiTheme.foreground)
                }
                Spacer()
                Button(action: { isPresented = false }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.muted)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
            }
            .padding(.bottom, 4)

            Text("Reorder with the arrows, show or hide with the eye.")
                .font(.system(size: 11))
                .foregroundColor(SumiTheme.muted)
                .padding(.bottom, 12)

            VStack(spacing: 2) {
                ForEach(Array(model.homeRowConfig.enumerated()), id: \.element.id) { index, row in
                    HStack(spacing: 8) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(row.visible ? SumiTheme.foreground : SumiTheme.muted)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Button(action: { withAnimation(.snappy) { model.moveHomeRow(at: index, by: -1) } }) {
                            Image(systemName: "chevron.up")
                                .foregroundColor(index == 0 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .disabled(index == 0)

                        Button(action: { withAnimation(.snappy) { model.moveHomeRow(at: index, by: 1) } }) {
                            Image(systemName: "chevron.down")
                                .foregroundColor(index == model.homeRowConfig.count - 1 ? SumiTheme.muted.opacity(0.3) : SumiTheme.muted)
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .disabled(index == model.homeRowConfig.count - 1)

                        Button(action: { withAnimation(.snappy) { model.toggleHomeRow(id: row.id) } }) {
                            Image(systemName: row.visible ? "eye" : "eye.slash")
                                .foregroundColor(row.visible ? SumiTheme.indigo : SumiTheme.muted.opacity(0.5))
                                .frame(width: 20, height: 20)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.sumiPressable)
                        .animation(.snappy, value: row.visible)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(SumiTheme.card.opacity(0.4))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                }
                .animation(.snappy, value: model.homeRowConfig)
            }
        }
        .padding(20)
        .frame(width: 380)
        .background(SumiTheme.background)
    }
}
