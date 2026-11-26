#if os(macOS)
import SwiftUI

struct AccountTabSection: View {
    let isSignedIn: Bool
    let username: String?
    let avatarUrl: String?
    let onSaveToken: (String) -> Void
    let onDisconnectAniList: () -> Void

    @State private var anilistTokenInput: String = ""
    @State private var showsDisconnectDialog: Bool = false
    // `@AppStorage` needs a literal key, so the spelling and the default
    // must agree with `AppModel`, which owns the reader.
    @AppStorage("anicat_discord_presence") private var discordPresence: Bool = false
    // Same literal-key constraint; `AppModel.discordPresenceDetail` reads it.
    @AppStorage("anicat_discord_presence_detail") private var discordPresenceDetail: String = "full"

    var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "AniList") {
            if isSignedIn {
                HStack(spacing: 12) {
                    AsyncImage(url: avatarUrl.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                SumiTheme.card
                                Image(anicat: "person.fill")
                                    .font(.system(size: 15))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                    }
                    .frame(width: 36, height: 36)
                    .clipShape(SumiRect(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        SumiRect(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(username ?? "AniList user")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                        Text("Signed in")
                            .sumiTabularMono()
                            .foregroundColor(SumiTheme.muted)
                    }

                    Spacer(minLength: 12)

                    Button("Sign out", role: .destructive) {
                        showsDisconnectDialog = true
                    }
                    .sumiSecondaryButton()
                    .confirmationDialog("Sign out of AniList?", isPresented: $showsDisconnectDialog) {
                        Button("Sign out", role: .destructive, action: onDisconnectAniList)
                    } message: {
                        Text("Anicat forgets its AniList token and stops syncing progress. Your list on AniList is not changed.")
                    }
                }
            } else {
                SettingField(
                    label: "Sign in",
                    description: "Authorize Anicat on AniList, then paste where it sent you below"
                ) {
                    Button("Connect AniList") {
                        Platform.openExternal(AppModel.aniListAuthorizeURL)
                    }
                    .sumiSecondaryButton()
                }

                SettingField(
                    label: "Token",
                    description: "The full redirect URL, or just the token"
                ) {
                    HStack(spacing: 8) {
                        SecureField("Paste redirect URL or token", text: $anilistTokenInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12))
                            .foregroundColor(SumiTheme.foreground)
                            .padding(.horizontal, 10)
                            .frame(height: 28)
                            .overlay(
                                SumiRect(cornerRadius: SumiTheme.radiusSm)
                                    .stroke(SumiTheme.border, lineWidth: 1)
                            )
                            .frame(maxWidth: 240)

                        Button("Save and connect") {
                            let trimmed = anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onSaveToken(trimmed)
                                anilistTokenInput = ""
                            }
                        }
                        .sumiPrimaryButton()
                        .disabled(anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }

        SettingsCard(title: "Discord") {
            SettingField(
                label: "Show what you're watching on your Discord profile",
                description: "Also what you are reading; picks Discord up whenever it runs"
            ) {
                SumiSwitch(isOn: $discordPresence, label: "Discord presence")
            }

            // "Private" leaves only "Watching anime" and the time: no title,
            // cover or link. The switch reads the stored "full" / "private"
            // rather than adding a key, so the presence code needs no change.
            SettingField(
                label: "Show the title, not just that you're watching",
                description: "With its episode or chapter, cover and AniList or TMDB link"
            ) {
                SumiSwitch(isOn: Binding(
                    get: { discordPresenceDetail != "private" },
                    set: { discordPresenceDetail = $0 ? "full" : "private" }
                ), label: "Show the title on Discord")
                .disabled(!discordPresence)
                .opacity(discordPresence ? 1 : 0.5)
            }
        }
    }
    }
}
#endif
