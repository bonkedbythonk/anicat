import SwiftUI

public struct StatusBadge: View {
    public enum BadgeStyle {
        case neutral(String)
        case score(Int)
        case status(String)
        case format(String)
    }

    public let style: BadgeStyle
    /// Off, the badge drops the forced capitals and the medium weight and
    /// takes the same sentence-case regular register as a card's metadata
    /// row. The poster hover badges sat 40pt above "83% Ep 8 out" in caps,
    /// tracked and medium at 10pt, and the owner read them as a different
    /// typeface altogether; the face was IBM Plex Mono both times.
    public let caps: Bool

    public init(_ style: BadgeStyle, caps: Bool = true) {
        self.style = style
        self.caps = caps
    }

    private func cased(_ text: String) -> String {
        caps ? text.uppercased() : text
    }

    public var body: some View {
        HStack(spacing: 4) {
            switch style {
            case .neutral(let text):
                Text(cased(text))
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
                Text(cased(status.replacingOccurrences(of: "_", with: " ")))
                    .foregroundColor(SumiTheme.foreground)
            case .format(let format):
                Text(cased(format))
                    .foregroundColor(SumiTheme.indigo)
            }
        }
        .sumiTabularMono(size: 10, weight: caps ? .medium : .regular)
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
