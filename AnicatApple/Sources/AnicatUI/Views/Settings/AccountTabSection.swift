import SwiftUI

struct AccountTabSection: View {
    let isSignedIn: Bool
    let username: String?
    let avatarUrl: String?
    let onSaveToken: (String) -> Void
    let onDisconnectAniList: () -> Void

    @State private var anilistTokenInput: String = ""
    @State private var showsDisconnectDialog: Bool = false
    /// A viewer's own TMDB key, which wins over the one the app carries.
    /// `TmdbCredential` is the reader; `@AppStorage` needs a literal here, so
    /// the two spellings have to agree.
    @AppStorage("anicat_tmdb_key") private var tmdbKeyInput: String = ""

    var body: some View {
    VStack(alignment: .leading, spacing: 28) {
        SettingsCard(title: "AniList") {
            if isSignedIn {
                // Profile Header with Avatar & Disconnect
                HStack(spacing: 16) {
                    // Avatar
                    AsyncImage(url: avatarUrl.flatMap(URL.init(string:))) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else {
                            ZStack {
                                SumiTheme.card
                                Image(systemName: "person.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )

                    VStack(alignment: .leading, spacing: 4) {
                        Text(username ?? "AniList user")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)

                        HStack(spacing: 6) {
                            Circle()
                                .fill(SumiTheme.successLight)
                                .frame(width: 7, height: 7)

                            Text("Connected to AniList")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(SumiTheme.successLight)
                        }
                    }

                    Spacer()

                    Button("Disconnect", role: .destructive) {
                        showsDisconnectDialog = true
                    }
                    .sumiSecondaryButton()
                    .controlSize(.large)
                    .confirmationDialog("Disconnect from AniList?", isPresented: $showsDisconnectDialog) {
                        Button("Disconnect", role: .destructive, action: onDisconnectAniList)
                    } message: {
                        Text("Anicat forgets its AniList token and stops syncing progress. Your list on AniList is not changed.")
                    }
                }
                .padding(14)
                .overlay(
                    RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )

                // API Token
                SettingField(
                    label: "API token",
                    description: "Your authorization token. Keep this private."
                ) {
                    Text("••••••••••••••••••••••••••••••••")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(SumiTheme.background)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                                .stroke(SumiTheme.border, lineWidth: 1)
                        )
                }
            } else {
                // Not signed in: Login
                SettingField(
                    label: "Login",
                    description: "Authorize Anicat to access your AniList account."
                ) {
                    Button {
                        // Must match the client id the web build registers
                        // in web/src-tauri/src/commands/auth.rs — this one
                        // was wrong (20822 belongs to a third-party app,
                        // "Airin," not this one) and sent users through
                        // someone else's OAuth client instead of Anicat's own.
                        if let url = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token") {
                            Platform.openExternal(url)
                        }
                    } label: {
                        // Secondary: Save and connect below is this card's
                        // prominent button.
                        Text("Connect AniList")
                    }
                    .sumiSecondaryButton()
                    .controlSize(.large)
                }

                // API Token Input
                SettingField(
                    label: "API token",
                    description: "After authorizing, paste the full URL you were redirected to (or just the token)."
                ) {
                    HStack(spacing: 8) {
                        SecureField("Paste redirect URL or token…", text: $anilistTokenInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundColor(SumiTheme.foreground)

                        Button {
                            let trimmed = anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !trimmed.isEmpty {
                                onSaveToken(trimmed)
                                anilistTokenInput = ""
                            }
                        } label: {
                            Text("Save and connect").fontWeight(.semibold)
                        }
                        .sumiPrimaryButton()
                        .disabled(anilistTokenInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: 340)
                }
            }
        }

        // Cinema mode reads TMDB with a key the app carries, so this is
        // an override and not a requirement -- the field says so, because
        // an empty credential box otherwise reads as a thing to go and
        // fill in before films will work. Takes effect on the next
        // launch: the engine is handed its key when it is constructed.
        SettingsCard(title: "Cinema (TMDB)") {
            SettingField(
                label: "Your own TMDB key",
                description: "Optional. Films and series already work without one. Paste a v3 key or a v4 read token to send requests on your own account instead. It takes effect as you type it."
            ) {
                SecureField("Leave empty to use the built-in key", text: $tmdbKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.foreground)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(SumiTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                    .overlay(
                        RoundedRectangle(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    .frame(maxWidth: 340)
                    // The engine holds the key in memory, so a paste has
                    // to be handed over; before this it reached nothing
                    // until the next launch and cinema mode stayed
                    // hidden with the key sitting right there.
                    .onChange(of: tmdbKeyInput) { _, _ in AppModel.shared?.applyTmdbKey() }
            }

            // Required by TMDB's API terms wherever their data is used,
            // not a courtesy line: the mark and the wording are both
            // theirs. See `TMDBAttribution`.
            TMDBAttribution()
                .padding(.top, 4)
        }
    }
}

}
