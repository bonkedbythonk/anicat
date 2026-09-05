import SwiftUI

public struct StatusBadge: View {
    public enum BadgeStyle {
        case neutral(String)
        case score(Int)
        case status(String)
        case format(String)
    }

    public let style: BadgeStyle

    public init(_ style: BadgeStyle) {
        self.style = style
    }

    public var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .neutral(let text):
                Text(text.uppercased())
                    .foregroundColor(SumiTheme.muted)
            case .score(let score):
                Image(systemName: "star.fill")
                    .font(.system(size: 9))
                    .foregroundColor(SumiTheme.indigo)
                Text("\(score)%")
                    .foregroundColor(SumiTheme.foreground)
            case .status(let status):
                Circle()
                    .fill(statusColor(status))
                    .frame(width: 5, height: 5)
                Text(status.replacingOccurrences(of: "_", with: " ").uppercased())
                    .foregroundColor(SumiTheme.foreground)
            case .format(let format):
                Text(format.uppercased())
                    .foregroundColor(SumiTheme.indigo)
            }
        }
        .sumiTabularMono(size: 10, weight: .medium)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
        .overlay(
            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                .stroke(SumiTheme.border, lineWidth: 1)
        )
    }

    private func statusColor(_ status: String) -> Color {
        switch status.uppercased() {
        case "RELEASING", "CURRENT", "AIRING":
            return SumiTheme.success
        case "NOT_YET_RELEASED", "PLANNING":
            return SumiTheme.warning
        case "CANCELLED":
            return SumiTheme.danger
        default:
            return SumiTheme.muted
        }
    }
}
