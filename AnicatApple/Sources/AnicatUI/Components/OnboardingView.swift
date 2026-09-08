import SwiftUI

/// First run, as a short guided setup rather than a single wall.
///
/// Before this there was nothing: a fresh install opened on empty shelves
/// with no hint that Settings, then Account, then a browser round trip and
/// a pasted URL was the way in. That screen then became one page carrying
/// the whole AniList handshake and nothing else, so every other preference
/// -- dub or sub, skipping intros, notifications, presence -- was still
/// something you had to know to go looking for.
///
/// Each step previews what it is asking about, live and from the same
/// defaults Settings writes: the theme swatches are the real palettes, the
/// glow bar is drawn the way the player draws it. Nothing here is a picture
/// of the app, so nothing here can go stale against it.
///
/// Every control binds the same `anicat_*` key Settings does, so this adds
/// no state of its own and anything set here is changeable there afterwards.
public struct OnboardingView: View {
    @Bindable var model: AppModel

    @State private var stepIndex = 0
    @State private var tokenInput = ""
    @State private var isConnecting = false
    @State private var failure: String?
    @FocusState private var tokenFieldFocused: Bool

    // The same keys Settings binds. Defaults must match it exactly: a
    // different literal here would show the viewer one state and leave
    // another in force.
    @AppStorage("anicat_sub_dub") private var subDub: String = "Subtitled"
    @AppStorage("anicat_autoskip") private var autoSkipIntro: Bool = true
    @AppStorage("anicat_autoplay_next") private var autoPlayNext: Bool = true
    @AppStorage("anicat_gpu_upscaling") private var gpuUpscaling: Bool = true
    @AppStorage("anicat_ambient_glow") private var ambientGlow: Bool = true
    @AppStorage("anicat_notify_new_episodes") private var notifyNewEpisodes: Bool = true
    @AppStorage("anicat_discord_presence") private var discordPresence: Bool = true

    public init(model: AppModel) {
        self.model = model
    }

    private static let authorizeURL = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token")!

    private enum Step: Int, CaseIterable {
        case connect, watching, picture, alerts, look

        var title: String {
            switch self {
            case .connect: return "Connect AniList"
            case .watching: return "How you watch"
            case .picture: return "Picture"
            case .alerts: return "Alerts and presence"
            case .look: return "Look"
            }
        }

        var subtitle: String {
            switch self {
            case .connect:
                return "Your list is the source of truth for what you are watching and how far in you are."
            case .watching:
                return "Defaults for every episode. Changeable per title later."
            case .picture:
                return "Both cost GPU time and both can be turned off at any point."
            case .alerts:
                return "Anicat tells you when something airs, and can show what you are watching."
            case .look:
                return "Applies immediately. There are more in Settings."
            }
        }
    }

    private var step: Step { Step(rawValue: stepIndex) ?? .connect }
    private var isLastStep: Bool { stepIndex == Step.allCases.count - 1 }

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header

                // Scrolls rather than clips. The old screen laid its steps
                // out in a plain VStack, so on a short window "Skip for now"
                // fell off the bottom with no way to reach it -- the one
                // control that guarantees a way out of first run.
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        content
                    }
                    .frame(maxWidth: 460, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                }

                footer
            }
            .padding(.horizontal, 48)
            .padding(.vertical, 36)
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            // Straight on rather than out: connecting is the first of five
            // steps now, not the whole screen.
            if signedIn, step == .connect { advance() }
        }
    }

    // MARK: - Chrome

    private var header: some View {
        VStack(spacing: 8) {
            SumiLogoMark()
                .frame(height: 54)
                .padding(.bottom, 6)

            Text(step.title)
                .font(.sumiSans(size: 22, weight: .semibold))
                .tracking(-0.3)
                .foregroundColor(SumiTheme.foreground)

            Text(step.subtitle)
                .font(.sumiSans(size: 13))
                .foregroundColor(SumiTheme.muted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
    }

    private var footer: some View {
        VStack(spacing: 14) {
            HStack(spacing: 6) {
                ForEach(Step.allCases, id: \.rawValue) { s in
                    Capsule()
                        .fill(s.rawValue == stepIndex ? SumiTheme.indigo : SumiTheme.muted.opacity(0.3))
                        .frame(width: s.rawValue == stepIndex ? 18 : 6, height: 6)
                        .animation(.snappy, value: stepIndex)
                }
            }

            HStack(spacing: 10) {
                if stepIndex > 0 {
                    Button {
                        SumiHaptics.selection()
                        withAnimation(.smooth(duration: 0.28)) { stepIndex -= 1 }
                    } label: {
                        Text("Back")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundColor(SumiTheme.muted)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }

                Button {
                    SumiHaptics.selection()
                    if isLastStep { model.completeOnboarding() } else { advance() }
                } label: {
                    Text(continueLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.background)
                        .padding(.horizontal, 22)
                        .frame(height: 34)
                        .background(SumiTheme.indigo)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
                        .contentShape(Rectangle())
                    }
                .buttonStyle(.sumiPressable)
            }

            Button {
                model.completeOnboarding()
            } label: {
                Text("Skip all setup")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.sumiPressable)
            .accessibilityLabel("Skip the rest of setup and go to the app")
        }
    }

    /// "Continue without connecting" rather than a bare "Continue" on the
    /// one step that can be declined outright. The first version offered a
    /// single "Skip setup" at the foot, which was read as "skip this step"
    /// and dropped the viewer out of the whole flow -- the four preference
    /// steps never got a chance to be seen.
    private var continueLabel: String {
        if isLastStep { return "Start watching" }
        if step == .connect, !model.isSignedIn { return "Continue without connecting" }
        return "Continue"
    }

    private func advance() {
        withAnimation(.smooth(duration: 0.28)) {
            stepIndex = min(stepIndex + 1, Step.allCases.count - 1)
        }
    }

    // MARK: - Steps

    @ViewBuilder
    private var content: some View {
        switch step {
        case .connect: connectStep
        case .watching: watchingStep
        case .picture: pictureStep
        case .alerts: alertsStep
        case .look: lookStep
        }
    }

    @ViewBuilder
    private var connectStep: some View {
        if model.isSignedIn {
            // Already connected -- a fresh install with a token in the
            // Keychain, or a "Reset onboarding" from Settings. The old
            // screen showed the paste form regardless, so the one action on
            // screen was one that had already been done.
            HStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(SumiTheme.indigo)
                VStack(alignment: .leading, spacing: 2) {
                    Text(connectedLabel)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(SumiTheme.foreground)
                    Text("Progress written here shows up on AniList, and the other way round.")
                        .font(.system(size: 12))
                        .foregroundColor(SumiTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(SumiTheme.card)
            .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
            .overlay(
                RoundedRectangle(cornerRadius: SumiTheme.radiusMd)
                    .stroke(SumiTheme.indigo.opacity(0.35), lineWidth: 1)
            )
        } else {
            VStack(alignment: .leading, spacing: 16) {
                numbered(1, "Authorize in your browser") {
                    Button {
                        Platform.openExternal(Self.authorizeURL)
                        tokenFieldFocused = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "globe").font(.system(size: 13, weight: .semibold))
                            Text("Open AniList").font(.system(size: 13, weight: .semibold))
                        }
                        .foregroundColor(SumiTheme.indigo)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 9)
                        .background(SumiTheme.indigo.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm + 2))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm + 2)
                                .stroke(SumiTheme.indigo.opacity(0.30), lineWidth: 1)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.sumiPressable)
                }

                numbered(2, "Paste the page you were sent to") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            // A plain TextField, not a SecureField. macOS
                            // autofill claims a secure field and paints a
                            // saved password into the AppKit view without
                            // ever updating the SwiftUI binding -- the field
                            // looked full, `tokenInput` stayed empty, and so
                            // the Connect button stayed disabled and ate
                            // every click with no error. A token is not a
                            // password anyway.
                            TextField("Redirect URL or token", text: $tokenInput)
                                .textFieldStyle(.plain)
                                .font(.system(size: 13))
                                .foregroundColor(SumiTheme.foreground)
                                .focused($tokenFieldFocused)
                                .onSubmit(connect)
                                .disabled(isConnecting)

                            PasteButton(payloadType: String.self) { strings in
                                guard let pasted = strings.first else { return }
                                Task { @MainActor in
                                    tokenInput = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
                                }
                            }
                            .labelStyle(.iconOnly)
                            .buttonBorderShape(.capsule)

                            Button(action: connect) {
                                Group {
                                    if isConnecting {
                                        ProgressView().controlSize(.small).frame(width: 60)
                                    } else {
                                        Text("Connect").font(.system(size: 12, weight: .semibold))
                                    }
                                }
                                .foregroundColor(SumiTheme.background)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(SumiTheme.indigo)
                                .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.sumiPressable)
                            .disabled(trimmedInput.isEmpty || isConnecting)
                            .opacity(trimmedInput.isEmpty ? 0.5 : 1)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(SumiTheme.card)
                        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm + 2))
                        .overlay(
                            RoundedRectangle(cornerRadius: SumiTheme.radiusSm + 2)
                                .stroke(failure == nil ? SumiTheme.border : SumiTheme.warning.opacity(0.7), lineWidth: 1)
                        )

                        Text(failure ?? "The token stays in this device's Keychain. Anicat never sees your password.")
                            .font(.system(size: 12))
                            .foregroundColor(failure == nil ? SumiTheme.muted : SumiTheme.warning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Text("You can skip this and connect later from Settings. Browsing and playback work without an account; tracking does not.")
                    .font(.system(size: 12))
                    .foregroundColor(SumiTheme.muted.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var watchingStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            choiceRow(
                title: "Audio",
                caption: "A preference, not a filter: a dub wins when one exists, and nothing is hidden when one does not.",
                options: ["Subtitled", "Dubbed"],
                selection: $subDub
            )
            toggleRow("Skip intros and outros", "Uses AniSkip's timings, when it has them for the episode.", $autoSkipIntro)
            toggleRow("Play the next episode", "Starts the next one as the current ends, with a countdown you can cancel.", $autoPlayNext)

            preview {
                MockFrame {
                    VStack {
                        Spacer()
                        if autoSkipIntro {
                            HStack {
                                Spacer()
                                Text("Skip Intro")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color.black.opacity(0.55))
                                    .clipShape(Capsule())
                                    .overlay(Capsule().stroke(Color.white.opacity(0.35), lineWidth: 1))
                            }
                            .padding(.trailing, 10)
                            .padding(.bottom, 6)
                            .transition(.opacity)
                        }
                        Text(subDub == "Dubbed" ? "I told you, this castle is no place for you." : "この城はお前の来る場所じゃない")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white)
                            .shadow(color: .black.opacity(0.8), radius: 2)
                            .padding(.bottom, 12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pictureStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            toggleRow("Anime4K upscaling", "Sharpens a 1080p release toward your display. Costs GPU; turn it off on battery.", $gpuUpscaling)
            toggleRow("Ambient glow", "Spills the picture's own colour around the player.", $ambientGlow)

            preview {
                MockFrame(glow: ambientGlow) {
                    HStack(spacing: 0) {
                        MockArt(sharp: false)
                        MockArt(sharp: gpuUpscaling)
                    }
                    .overlay(alignment: .center) {
                        Rectangle()
                            .fill(Color.white.opacity(0.5))
                            .frame(width: 1)
                    }
                    .overlay(alignment: .bottom) {
                        HStack {
                            Text("Off").frame(maxWidth: .infinity)
                            Text(gpuUpscaling ? "Anime4K" : "Off").frame(maxWidth: .infinity)
                        }
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.9))
                        .padding(.bottom, 5)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var alertsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            toggleRow("New episode alerts", "A notification when something on your watching list airs. Announced once.", $notifyNewEpisodes)
            toggleRow("Discord presence", "Shows the title and episode you are on. Nothing else leaves the device.", $discordPresence)

            preview {
                VStack(spacing: 8) {
                    if notifyNewEpisodes {
                        MockNotification()
                            .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                    if discordPresence {
                        MockPresence()
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if !notifyNewEpisodes, !discordPresence {
                        Text("Nothing is announced and nothing is shared.")
                            .font(.system(size: 11))
                            .foregroundColor(SumiTheme.muted)
                            .frame(maxWidth: .infinity, minHeight: 60)
                    }
                }
                .animation(.smooth(duration: 0.25), value: notifyNewEpisodes)
                .animation(.smooth(duration: 0.25), value: discordPresence)
            }
        }
    }

    @ViewBuilder
    private var lookStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            OnboardingThemeRow()
            Text("Ink & Index is the original warm dark skin. OLED is a true black for panels that switch pixels off. Follow system uses Paper by day and Ink by night.")
                .font(.system(size: 12))
                .foregroundColor(SumiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Pieces

    @ViewBuilder
    private func numbered<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)")
                .sumiTabularMono(size: 11, weight: .semibold)
                .foregroundColor(SumiTheme.indigo)
                .frame(width: 22, height: 22)
                .background(SumiTheme.indigo.opacity(0.12))
                .clipShape(Circle())
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func toggleRow(_ title: String, _ caption: String, _ binding: Binding<Bool>) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                Text(caption)
                    .font(.system(size: 11.5))
                    .foregroundColor(SumiTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: binding)
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }

    private func choiceRow(
        title: String,
        caption: String,
        options: [String],
        selection: Binding<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(SumiTheme.foreground)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    let isOn = selection.wrappedValue == option
                    Button {
                        SumiHaptics.selection()
                        selection.wrappedValue = option
                    } label: {
                        Text(option)
                            .font(.system(size: 12, weight: isOn ? .semibold : .medium))
                            .foregroundColor(isOn ? SumiTheme.background : SumiTheme.muted)
                            .padding(.horizontal, 14)
                            .frame(height: 28)
                            .background(isOn ? SumiTheme.indigo : SumiTheme.card)
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(isOn ? Color.clear : SumiTheme.border, lineWidth: 1))
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            Text(caption)
                .font(.system(size: 11.5))
                .foregroundColor(SumiTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func preview<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PREVIEW")
                .sumiTabularMono(size: 9, weight: .semibold)
                .foregroundColor(SumiTheme.muted.opacity(0.7))
                .tracking(0.8)
            content()
        }
        .padding(.top, 2)
    }

    private var connectedLabel: String {
        if let name = model.viewer?.name, !name.isEmpty { return "Connected as \(name)" }
        return "Connected to AniList"
    }

    private var trimmedInput: String {
        tokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func connect() {
        let token = trimmedInput
        guard !token.isEmpty, !isConnecting else { return }
        isConnecting = true
        failure = nil
        Task { @MainActor in
            await model.signIn(token: token)
            isConnecting = false
            if !model.isSignedIn {
                failure = "AniList did not accept that. Paste the whole URL from the browser's address bar after authorizing."
                model.errorMessage = nil
            }
        }
    }
}

// MARK: - Previews drawn, not photographed

/// A 16:9 stand-in for the player, optionally wearing the ambient glow. The
/// glow is the same idea the real one implements -- the picture's colour
/// spilled outward -- drawn here from the mock's own palette so the step can
/// show what the switch does with no video playing.
private struct MockFrame<Content: View>: View {
    var glow: Bool = false
    @ViewBuilder var content: () -> Content
    @State private var drift = false

    var body: some View {
        ZStack {
            if glow {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [Color(red: 0.36, green: 0.42, blue: 0.85),
                                     Color(red: 0.75, green: 0.35, blue: 0.55),
                                     Color(red: 0.30, green: 0.55, blue: 0.70)],
                            startPoint: drift ? .topLeading : .bottomTrailing,
                            endPoint: drift ? .bottomTrailing : .topLeading
                        )
                    )
                    .blur(radius: 18)
                    .opacity(0.85)
                    .padding(-10)
            }
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.black)
                .overlay { content() }
                .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .onAppear {
            guard glow else { return }
            withAnimation(.easeInOut(duration: 6).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// Two halves of the same invented frame, one softened and one not. Shapes
/// rather than a bundled still: an asset would have to be licensed, would
/// have to ship, and would still only show one show.
private struct MockArt: View {
    let sharp: Bool

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.18, green: 0.20, blue: 0.34), Color(red: 0.42, green: 0.28, blue: 0.40)],
                startPoint: .top, endPoint: .bottom
            )
            Circle()
                .fill(Color(red: 0.98, green: 0.86, blue: 0.72))
                .frame(width: 44, height: 44)
                .offset(y: 6)
            Capsule()
                .fill(Color(red: 0.25, green: 0.55, blue: 0.85))
                .frame(width: 58, height: 26)
                .offset(y: 44)
            Text("A")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(Color(red: 0.20, green: 0.16, blue: 0.28))
                .offset(y: 4)
        }
        .blur(radius: sharp ? 0 : 1.6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

private struct MockNotification: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(SumiTheme.indigo.opacity(0.35))
                .frame(width: 34, height: 34)
                .overlay(Image(systemName: "bell.fill").font(.system(size: 13)).foregroundColor(SumiTheme.indigo))
            VStack(alignment: .leading, spacing: 2) {
                Text("An Archdemon's Dilemma")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
                Text("Episode 11 is out.")
                    .font(.system(size: 11))
                    .foregroundColor(SumiTheme.muted)
            }
            Spacer(minLength: 8)
            Text("now")
                .sumiTabularMono(size: 10)
                .foregroundColor(SumiTheme.muted.opacity(0.8))
        }
        .padding(10)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))
    }
}

private struct MockPresence: View {
    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.40, blue: 0.85),
                                              Color(red: 0.55, green: 0.35, blue: 0.75)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text("Watching Anicat")
                    .sumiTabularMono(size: 9, weight: .semibold)
                    .foregroundColor(SumiTheme.muted)
                Text("An Archdemon's Dilemma - EP 10")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
        }
        .padding(10)
        .background(SumiTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusMd))
        .overlay(RoundedRectangle(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))
    }
}

/// The skin swatches, drawn from each palette rather than from `SumiTheme`
/// -- the OLED swatch has to look like OLED while Paper is in force.
/// Onboarding offers the skin only; light/dark lives in Settings, and the
/// default (Follow system) is the right answer for a first launch. Its own
/// copy rather than Settings' `ThemePicker`, which is private to that file;
/// both read `ThemeStore.shared`, so the selection is the same one.
private struct OnboardingThemeRow: View {
    @State private var store = ThemeStore.shared
    // `maximum` pinned to the swatch width: left open it defaults to
    // `.infinity` and each swatch floats centred in an oversized cell.
    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 72), spacing: 12, alignment: .topLeading)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(SumiSkin.allCases) { skin in
                let isSelected = store.skin == skin
                Button {
                    guard !isSelected else { return }
                    SumiHaptics.selection()
                    store.select(skin)
                } label: {
                    VStack(spacing: 7) {
                        let palette = store.previewPalette(for: skin)
                        ZStack(alignment: .topLeading) {
                            RoundedRectangle(cornerRadius: 8).fill(palette.background)
                            VStack(alignment: .leading, spacing: 5) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(palette.card)
                                    .frame(width: 44, height: 12)
                                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(palette.border, lineWidth: 1))
                                HStack(spacing: 4) {
                                    Capsule().fill(palette.indigo).frame(width: 20, height: 5)
                                    Capsule().fill(palette.muted).frame(width: 12, height: 5)
                                }
                            }
                            .padding(8)
                        }
                        .frame(height: 52)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(isSelected ? SumiTheme.indigo : SumiTheme.border,
                                        lineWidth: isSelected ? 2 : 1)
                        )

                        Text(skin.displayName)
                            .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                            .foregroundColor(isSelected ? SumiTheme.foreground : SumiTheme.muted)
                            .lineLimit(1)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .help(skin.caption)
            }
        }
    }
}
