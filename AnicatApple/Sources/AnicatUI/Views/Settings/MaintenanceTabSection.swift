#if os(macOS)
import SwiftUI

struct MaintenanceTabSection: View {
    static var buildDescription: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let commit = info["AnicatCommit"] as? String
        let built = info["AnicatBuiltAt"] as? String
        var parts = [version]
        if let commit { parts.append(commit) }
        if let built { parts.append("built \(built)") }
        return parts.joined(separator: " · ")
    }

    /// Nil while the first read is in flight, which is a different thing
    /// from an empty cache and must not read as "0 bytes".
    private var cacheLabel: String {
        guard let cacheBytes else { return "Checking…" }
        return ByteCountFormatter.string(fromByteCount: Int64(cacheBytes), countStyle: .file)
    }

    let isSignedIn: Bool
    let username: String?
    let onClearRegistry: () async -> Bool
    let onResetOnboarding: () -> Void

    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_offline_cap_gb") private var offlineCapGb: Int = 2
    /// Zero is "No limit", which is why the dropdown shows labels over the
    /// stored gigabytes rather than the number itself.
    private static let capOptions: [(gb: Int, label: String)] = [
        (1, "1 GB"), (2, "2 GB"), (5, "5 GB"), (10, "10 GB"), (0, "No limit"),
    ]
    /// A viewer's own TMDB key, which wins over the one the app carries.
    /// `TmdbCredential` is the reader; `@AppStorage` needs a literal here, so
    /// the two spellings have to agree.
    @AppStorage("anicat_tmdb_key") private var tmdbKeyInput: String = ""
    @State private var cacheBytes: UInt64?
    /// Nil until a check has run; "Up to date" afterwards. A blank row would
    /// leave the button looking like it had done nothing.
    @State private var updateResult: String?
    @State private var copyFeedback: String?
    @State private var isPurging = false
    @State private var registryState: SettingsView.MaintenanceActionState = .idle
    @State private var onboardingResetState: SettingsView.MaintenanceActionState = .idle
    @State private var showsRegistryDialog = false
    @State private var showsOnboardingDialog = false

    var body: some View {
    VStack(alignment: .leading, spacing: 18) {
        SettingsCard(title: "Updates") {
            // Read from the bundle, not typed here: the string said 1.0.0
            // for months after the version moved on, and the commit is what
            // tells two same-version installs apart.
            SettingField(
                label: "Anicat \(Self.buildDescription)",
                description: AppModel.shared?.availableUpdate.map { "\($0.version) is out" } ?? updateResult
            ) {
                HStack(spacing: 8) {
                    if let update = AppModel.shared?.availableUpdate {
                        Button("Open release") { Platform.openExternal(update.pageURL) }
                            .sumiSecondaryButton()
                        if AppModel.shared?.canInstallUpdate == true {
                            Button(AppModel.shared?.isInstallingUpdate == true ? "Updating…" : "Update now") {
                                Task { await AppModel.shared?.installUpdate() }
                            }
                            .sumiPrimaryButton()
                            .disabled(AppModel.shared?.isInstallingUpdate == true)
                        }
                    } else {
                        Button(AppModel.shared?.isCheckingForUpdate == true ? "Checking…" : "Check now") {
                            Task {
                                await AppModel.shared?.checkForUpdates(force: true)
                                updateResult = AppModel.shared?.availableUpdate == nil
                                    ? "Up to date"
                                    : nil
                            }
                        }
                        .sumiSecondaryButton()
                        .disabled(AppModel.shared?.isCheckingForUpdate == true)
                    }
                }
            }
            .sumiTextSelectable()
        }

        // The offline-manga cap was once filed under Account because the
        // engine owns both, and the torrent stream cache -- easily the
        // largest thing the app writes -- was not shown anywhere on macOS.
        SettingsCard(title: "Storage") {
            SettingField(
                label: "Streaming cache",
                description: "\(cacheLabel) · kept so a rewatch or a seek back costs nothing"
            ) {
                Button(isPurging ? "Emptying…" : "Empty", role: .destructive) {
                    isPurging = true
                    Task {
                        await AppModel.shared?.purgeStreamCache()
                        cacheBytes = await AppModel.shared?.streamCacheBytes()
                        isPurging = false
                    }
                }
                .sumiSecondaryButton()
                .controlSize(.small)
                .disabled(isPurging || (cacheBytes ?? 0) == 0)
            }

            SettingField(
                label: "Downloaded chapters",
                description: "Least recently read go first; the open chapter is never removed"
            ) {
                SumiDropdown(options: Self.capOptions.map(\.label), selected: Binding(
                    get: { Self.capOptions.first { $0.gb == offlineCapGb }?.label ?? "\(offlineCapGb) GB" },
                    set: { label in
                        if let gb = Self.capOptions.first(where: { $0.label == label })?.gb { offlineCapGb = gb }
                    }
                ))
            }
            // The engine holds the cap in memory, so a change has to be
            // handed over rather than waiting for the next launch.
            .onChange(of: offlineCapGb) { _, _ in AppModel.shared?.applyOfflineLimit() }
        }
        .task { cacheBytes = await AppModel.shared?.streamCacheBytes() }

        SettingsCard(title: "Diagnostics") {
            // The file, not its contents: a log is attached to a report, not
            // read in a settings pane, and Finder is the way to attach.
            SettingField(label: "Log file") {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
                }
                .sumiSecondaryButton()
                .controlSize(.small)
            }

            SettingField(label: "Debug report", description: copyFeedback) {
                Button("Copy") {
                    let report = """
                    Anicat Version: \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    Platform: \(Platform.osName) \(ProcessInfo.processInfo.operatingSystemVersionString)
                    Architecture: arm64
                    Signed In: \(isSignedIn)
                    AniList Viewer: \(username ?? "None")
                    Anime4K Upscaling: \(gpuUpscaling ? "Enabled" : "Disabled")
                    Timestamp: \(Date())
                    """
                    Platform.copyToPasteboard(report)
                    withAnimation(.snappy) { copyFeedback = "Copied" }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                        withAnimation(.snappy) { copyFeedback = nil }
                    }
                }
                .sumiSecondaryButton()
                .controlSize(.small)
            }

            // Cinema reads TMDB with a key the app carries, so this is an
            // override and not a requirement -- the row says so, because an
            // empty credential box otherwise reads as a thing to fill in
            // before films will work.
            SettingField(
                label: "Your own TMDB key",
                description: "Optional; films and series work without one"
            ) {
                SecureField("Built-in key", text: $tmdbKeyInput)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.foreground)
                    .padding(.horizontal, 10)
                    .frame(width: 240, height: 26)
                    .overlay(
                        SumiRect(cornerRadius: SumiTheme.radiusSm)
                            .stroke(SumiTheme.border, lineWidth: 1)
                    )
                    // The engine holds the key in memory, so a paste has to
                    // be handed over; before this it reached nothing until
                    // the next launch and cinema mode stayed hidden with the
                    // key sitting right there.
                    .onChange(of: tmdbKeyInput) { _, _ in AppModel.shared?.applyTmdbKey() }
            }
        }

        SettingsCard(title: "Reset") {
            SettingField(
                label: "Clear local registry",
                description: "History, resume points and per-title preferences on this Mac"
            ) {
                Button(
                    registryState == .working ? "Clearing…" : registryState == .done ? "Cleared" : "Clear",
                    role: .destructive
                ) {
                    showsRegistryDialog = true
                }
                .sumiSecondaryButton()
                .controlSize(.small)
                .disabled(registryState == .working || registryState == .done)
                .confirmationDialog("Clear the local registry?", isPresented: $showsRegistryDialog) {
                    Button("Clear local registry", role: .destructive) {
                        registryState = .working
                        Task {
                            let succeeded = await onClearRegistry()
                            registryState = succeeded ? .done : .idle
                        }
                    }
                } message: {
                    Text("Your Films and TV list, watch and reading history, resume positions, remembered and rejected releases, skip timings and per-title preferences are deleted from this Mac. Downloads stay. Your list on AniList is not changed. This cannot be undone.")
                }
            }

            SettingField(label: "Show the setup screens again") {
                Button(onboardingResetState == .done ? "Reset" : "Reset onboarding") {
                    showsOnboardingDialog = true
                }
                .sumiSecondaryButton()
                .controlSize(.small)
                .disabled(onboardingResetState == .done)
                .confirmationDialog("Show the setup screens again?", isPresented: $showsOnboardingDialog) {
                    Button("Reset onboarding") {
                        UserDefaults.standard.removeObject(forKey: "anicat_onboarding_seen")
                        onboardingResetState = .done
                        onResetOnboarding()
                    }
                } message: {
                    Text("Setup opens now. Your settings stay as they are until you change them there.")
                }
            }
        }

        SettingsCard(title: "About") {
            SettingField(
                label: "Free software under the GPL, version 3",
                description: "Anime and manga data from AniList"
            ) {
                AcknowledgementsButton {
                    Text("Acknowledgements")
                }
                .sumiSecondaryButton()
                .controlSize(.small)
            }

            // Required by TMDB's API terms wherever their data is used, not
            // a courtesy line: the mark and the wording are both theirs.
            TMDBAttribution()
        }
    }
    }
}
#endif
