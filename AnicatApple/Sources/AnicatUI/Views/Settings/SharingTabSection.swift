import SwiftUI

/// Everything Anicat tells something outside itself.
///
/// New-episode alerts sat in General and Discord presence on the end of the
/// playback list, two tabs apart, though they answer the same question.
struct SharingTabSection: View {
    // `SystemNotifications` owns the reader and the default; `@AppStorage`
    // needs a literal here, so the two spellings and the two defaults must
    // agree.
    @AppStorage("anicat_notify_new_episodes") private var notifyNewEpisodes: Bool = true
    // Same literal-key constraint. `AppModel` owns the reader and default.
    @AppStorage("anicat_discord_presence") private var discordPresence: Bool = false
    // Same literal-key constraint; `AppModel.isLanSharingEnabled` reads it
    // and its defaults observer starts or stops the Bonjour listener.
    @AppStorage("anicat_lan_sharing") private var lanSharing: Bool = false
    // Same literal-key constraint; `AppModel.discordPresenceDetail` reads it.
    @AppStorage("anicat_discord_presence_detail") private var discordPresenceDetail: String = "full"
    // Read once into state rather than off `UserDefaults` in the body: the
    // paired list is written by `RemoteHost` from a socket callback, which
    // no `@AppStorage` array binding observes.
    @State private var pairedCount = RemoteHost.pairedDevices().count

    var body: some View {
    VStack(alignment: .leading, spacing: 28) {
        SettingsCard(title: "Notifications") {
            SettingField(
                label: "New episode alerts",
                description: "A local notification when an episode of something you are watching airs, and, if you watch dubbed, when its English dub is out. Each episode is announced once, whether or not the app was running when it aired."
            ) {
                SumiSwitch(isOn: $notifyNewEpisodes)
            }
        }

        SettingsCard(title: "Presence") {
            SettingField(
                label: "Discord presence",
                description: "Show what you are watching or reading on your Discord profile. Picks Discord up whenever it is running, including when it starts after Anicat."
            ) {
                SumiSwitch(isOn: $discordPresence)
            }

            SettingField(
                label: "Show on profile",
                description: discordPresenceDetail == "private"
                    ? "Only \"Watching anime\" or \"Reading manga\" and the time. No title, cover or link."
                    : "The title, episode or chapter, cover art, and a link to its AniList or TMDB page. Everyone who can see your Discord profile sees it."
            ) {
                SumiSegmentedControl(
                    options: [("full", "Title"), ("private", "Private")],
                    selection: $discordPresenceDetail
                )
                .disabled(!discordPresence)
                .opacity(discordPresence ? 1 : 0.5)
            }
        }

        SettingsCard(title: "Devices") {
            SettingField(
                label: "Allow other devices",
                description: "Announce this Mac on the local network so Anicat on an iPhone can find it, control playback and stream through it. Off, nothing on the network can tell Anicat is running."
            ) {
                SumiSwitch(isOn: $lanSharing)
            }

            SettingField(
                label: "Paired iPhones",
                badge: RemoteHost.shared.attachedRemoteName.map { "\($0) connected" },
                description: pairedCount == 0
                    ? "Anicat on an iPhone on this Wi-Fi can control playback here. The first time one asks, this Mac asks you first."
                    : "\(pairedCount) iPhone\(pairedCount == 1 ? "" : "s") may control playback on this Mac. Forgetting them means being asked again next time."
            ) {
                Button("Forget all", role: .destructive) {
                    RemoteHost.shared.unpairAll()
                    pairedCount = 0
                }
                .sumiSecondaryButton()
                .disabled(pairedCount == 0)
            }
        }
    }
    .onAppear { pairedCount = RemoteHost.pairedDevices().count }
    }
}
