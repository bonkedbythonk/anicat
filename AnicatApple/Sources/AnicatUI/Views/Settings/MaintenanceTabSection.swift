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
    @Binding var copyFeedback: String?

    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_offline_cap_gb") private var offlineCapGb: Int = 2
    // Same literal-key constraint. `AppModel.isLnoriEnabled` owns the reader
    // and the default (off).
    @AppStorage("anicat_lnori_enabled") private var lnoriEnabled: Bool = false
    @State private var cacheBytes: UInt64?
    /// Nil until a check has run; "Up to date" afterwards. A blank row would
    /// leave the button looking like it had done nothing.
    @State private var updateResult: String?
    @State private var isPurging = false
    @State private var registryState: SettingsView.MaintenanceActionState = .idle
    @State private var onboardingResetState: SettingsView.MaintenanceActionState = .idle

    var body: some View {
    VStack(alignment: .leading, spacing: 20) {
        // Opt-in rather than a source picker: Syosetu carries text its
        // authors publish for free, Lnori carries publisher-owned volumes,
        // and the app must not contact the second without being told to.
        SettingsCard(
            title: "Light Novel Sources",
            description: "Where the text of a light novel comes from."
        ) {
            SettingField(
                label: "Official volumes",
                description: "Official volumes come from a third-party site that hosts licensed light novels. It is off until you turn it on. Web novels from Syosetu are unaffected."
            ) {
                SumiSwitch(isOn: $lnoriEnabled)
            }
        }

        // Storage, which had no home at all: the offline-manga cap was filed
        // under Account because the engine happens to own both, and the
        // torrent stream cache -- easily the largest thing the app writes,
        // gigabytes of it -- was not shown anywhere on macOS.
        SettingsCard(
            title: "Storage",
            description: "What Anicat keeps on this Mac, and how much of it."
        ) {
            SettingField(
                label: "Keep at most",
                description: "Downloaded chapters above this are removed, least recently read first. The chapter open in the reader is never removed."
            ) {
                Picker("", selection: $offlineCapGb) {
                    Text("1 GB").tag(1)
                    Text("2 GB").tag(2)
                    Text("5 GB").tag(5)
                    Text("10 GB").tag(10)
                    Text("No limit").tag(0)
                }
                .frame(maxWidth: 140)
                .font(.system(size: 12))
            }
            // The engine holds the cap in memory, so a change has to be
            // handed over rather than waiting for the next launch.
            .onChange(of: offlineCapGb) { _, _ in AppModel.shared?.applyOfflineLimit() }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Streamed video",
                description: "Episodes are streamed from a torrent and the pieces stay on disk so a rewatch or a seek backwards costs nothing. Emptying it frees the space; anything still playing is re-fetched."
            ) {
                HStack(spacing: 12) {
                    Text(cacheLabel)
                        .sumiTabularMono(size: 11.5)
                        .foregroundColor(SumiTheme.muted)

                    Button(isPurging ? "Emptying…" : "Empty") {
                        isPurging = true
                        Task {
                            await AppModel.shared?.purgeStreamCache()
                            cacheBytes = await AppModel.shared?.streamCacheBytes()
                            isPurging = false
                        }
                    }
                    .disabled(isPurging || (cacheBytes ?? 0) == 0)
                }
            }
        }
        .task { cacheBytes = await AppModel.shared?.streamCacheBytes() }

        // Updates Card
        SettingsCard(title: "Updates", description: "Keep the app up to date.") {
            HStack {
                Text("Current version:")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)

                // Read from the bundle, not typed here: the string said 1.0.0
                // for months after the version moved on, and the commit is
                // what tells two same-version installs apart.
                Text(Self.buildDescription)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(SumiTheme.foreground)
                    .sumiTextSelectable()
            }

            Divider()
                .background(SumiTheme.border)

            SettingField(
                label: "Check for updates",
                description: "Asks GitHub for the latest published release. Anicat does not update itself: the button opens the release page so you can replace the app yourself."
            ) {
                HStack(spacing: 10) {
                    if let update = AppModel.shared?.availableUpdate {
                        Text("\(update.version) available")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(SumiTheme.indigo)
                        Button("Open release") { Platform.openExternal(update.pageURL) }
                    } else {
                        if let checked = updateResult {
                            Text(checked)
                                .font(.system(size: 12))
                                .foregroundColor(SumiTheme.muted)
                        }
                        Button(AppModel.shared?.isCheckingForUpdate == true ? "Checking…" : "Check now") {
                            Task {
                                await AppModel.shared?.checkForUpdates(force: true)
                                updateResult = AppModel.shared?.availableUpdate == nil
                                    ? "Up to date"
                                    : nil
                            }
                        }
                        .disabled(AppModel.shared?.isCheckingForUpdate == true)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }

        SettingsCard(title: "Licenses", description: "Anicat is free software under the GPL, version 3.") {
            SettingField(
                label: "Acknowledgements",
                description: "The licenses of the libraries, fonts and shaders this app is built with, and where their source is."
            ) {
                AcknowledgementsButton {
                    Text("View")
                }
            }
        }

        // Logs & Debugging Card
        SettingsCard(title: "Logs & Debugging") {
            Button {
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
                withAnimation(.snappy) {
                    copyFeedback = "Debug report copied to clipboard!"
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
                    withAnimation(.snappy) {
                        copyFeedback = nil
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13))
                    Text("Copy Debug Report")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SumiTheme.foreground.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)

            #if os(macOS)
            // The file, not its contents: a log is attached to a report,
            // not read in a settings pane, and Finder is the way to attach.
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([AppLog.fileURL])
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 13))
                    Text("Reveal Log File")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(SumiTheme.foreground.opacity(0.85))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.white.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(SumiTheme.border, lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            #endif

            // Environment Snapshot. No live log stream is wired up in the
            // native build — this used to be five hardcoded strings
            // dressed up as a log window; only the sign-in line was ever
            // real. Better to show the handful of values that ARE real
            // than fabricate the rest.
            VStack(alignment: .leading, spacing: 4) {
                Text("Signed in: \(isSignedIn ? "yes" : "no")")
                Text("Anime4K upscaling: \(gpuUpscaling ? "enabled" : "disabled")")
                Text("macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
                Text("Log: \(AppLog.fileURL.path)")
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(SumiTheme.muted)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white.opacity(0.02))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(SumiTheme.border, lineWidth: 1)
            )
        }

        // System Maintenance Card
        SettingsCard(
            title: "System Maintenance",
            description: "Irreversible system actions."
        ) {
            // Clear Local Registry
            Button {
                if registryState == .confirming {
                    registryState = .working
                    Task {
                        let succeeded = await onClearRegistry()
                        await MainActor.run {
                            registryState = succeeded ? .done : .idle
                        }
                    }
                } else if registryState == .idle {
                    registryState = .confirming
                }
            } label: {
                Text(
                    registryState == .working
                        ? "Wiping Registry..."
                        : registryState == .done
                            ? "Registry Wiped"
                            : registryState == .confirming
                                ? "Are you sure? Click again to wipe"
                                : "Clear Local Registry"
                )
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(registryState == .done ? SumiTheme.successLight : SumiTheme.dangerLight)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    registryState == .confirming
                        ? SumiTheme.danger.opacity(0.18)
                        : registryState == .done
                            ? SumiTheme.success.opacity(0.18)
                            : Color.white.opacity(0.03)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            registryState == .confirming
                                ? SumiTheme.danger.opacity(0.40)
                                : registryState == .done
                                    ? SumiTheme.success.opacity(0.40)
                                    : SumiTheme.danger.opacity(0.20),
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .animation(.snappy, value: registryState)
            .disabled(registryState == .working || registryState == .done)

            // Reset Onboarding Setup
            Button {
                if onboardingResetState == .confirming {
                    UserDefaults.standard.removeObject(forKey: "anicat_onboarding_seen")
                    onboardingResetState = .done
                    onResetOnboarding()
                } else if onboardingResetState == .idle {
                    onboardingResetState = .confirming
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12))
                    Text(
                        onboardingResetState == .done
                            ? "Onboarding Reset"
                            : onboardingResetState == .confirming
                                ? "Are you sure? Click again to Reset"
                                : "Reset Onboarding Setup"
                    )
                    .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(onboardingResetState == .done ? SumiTheme.successLight : SumiTheme.muted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    onboardingResetState == .confirming
                        ? SumiTheme.danger.opacity(0.15)
                        : Color.white.opacity(0.02)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(
                            onboardingResetState == .confirming
                                ? SumiTheme.danger.opacity(0.35)
                                : SumiTheme.border,
                            lineWidth: 1
                        )
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .animation(.snappy, value: onboardingResetState)
            .disabled(onboardingResetState == .done)
        }
    }
}
}

// MARK: - Reusable Settings Components
