#if os(macOS)
import SwiftUI

/// Other devices that reach this Mac.
struct SharingTabSection: View {
    // `@AppStorage` needs a literal key; `AppModel.isLanSharingEnabled`
    // reads it and its defaults observer starts or stops the Bonjour
    // listener.
    @AppStorage("anicat_lan_sharing") private var lanSharing: Bool = false
    // Read once into state rather than off `UserDefaults` in the body: the
    // paired list is written by `RemoteHost` from a socket callback, which
    // no `@AppStorage` array binding observes.
    @State private var pairedCount = RemoteHost.pairedDevices().count

    var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "Remote control") {
            SettingField(
                label: "Let an iPhone on this Wi-Fi control this Mac",
                description: "Off, nothing on the network can tell Anicat is running"
            ) {
                SumiSwitch(isOn: $lanSharing, label: "Allow other devices")
            }

            SettingField(
                label: "Paired iPhones",
                badge: RemoteHost.shared.attachedRemoteName.map { "\($0) connected" },
                description: pairedCount == 0
                    ? "The first time one asks, this Mac asks you first"
                    : "\(pairedCount) iPhone\(pairedCount == 1 ? "" : "s") may control playback; forgotten ones must ask again"
            ) {
                Button("Forget all", role: .destructive) {
                    RemoteHost.shared.unpairAll()
                    pairedCount = 0
                }
                .sumiSecondaryButton()
                .controlSize(.small)
                .disabled(pairedCount == 0)
            }
        }
    }
    .onAppear { pairedCount = RemoteHost.pairedDevices().count }
    }
}
#endif
