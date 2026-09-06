import SwiftUI

/// First-launch screen. One job: get an AniList token in, or let the
/// viewer say "not now" and land on a home screen that explains itself.
///
/// Before this there was nothing: a fresh install opened on empty shelves
/// with no hint that Settings, then Account, then a browser round trip and
/// a pasted URL was the way in. The Settings "Reset onboarding" button
/// cleared `anicat_onboarding_seen` for a screen that did not exist.
///
/// Same flow as the Account tab, deliberately: the browser opens AniList's
/// authorize page for Anicat's own client id, AniList redirects to a URL
/// carrying the token in its fragment, and the viewer pastes either the
/// whole URL or the token. `AppModel.signIn` accepts both.
public struct OnboardingView: View {
    @Bindable var model: AppModel
    @State private var tokenInput = ""
    @State private var isConnecting = false
    @State private var failure: String?
    @FocusState private var tokenFieldFocused: Bool

    public init(model: AppModel) {
        self.model = model
    }

    private static let authorizeURL = URL(string: "https://anilist.co/api/v2/oauth/authorize?client_id=20148&response_type=token")!

    public var body: some View {
        ZStack {
            SumiTheme.background
                .ignoresSafeArea()

            VStack(spacing: 0) {
                SumiLogoMark()
                    .frame(height: 96)
                    .padding(.bottom, 20)

                Text("Anicat")
                    .font(.sumiSans(size: 28, weight: .semibold))
                    .tracking(-0.4)
                    .foregroundColor(SumiTheme.foreground)

                Text("Watch, read and track anime and manga, with your AniList list as the source of truth.")
                    .font(.sumiSans(size: 14))
                    .foregroundColor(SumiTheme.muted)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.top, 8)
                    .padding(.bottom, 32)

                VStack(alignment: .leading, spacing: 18) {
                    step(number: 1, title: "Authorize in your browser") {
                        Button {
                            Platform.openExternal(Self.authorizeURL)
                            tokenFieldFocused = true
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "globe")
                                    .font(.system(size: 13, weight: .semibold))
                                Text("Connect AniList")
                                    .font(.system(size: 13, weight: .semibold))
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
                        .accessibilityLabel("Open AniList authorization in the browser")
                    }

                    step(number: 2, title: "Paste the page you were sent to") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("Redirect URL or token", text: $tokenInput)
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13))
                                    .foregroundColor(SumiTheme.foreground)
                                    .focused($tokenFieldFocused)
                                    .onSubmit(connect)
                                    .disabled(isConnecting)

                                Button(action: connect) {
                                    Group {
                                        if isConnecting {
                                            ProgressView()
                                                .controlSize(.small)
                                                .frame(width: 60)
                                        } else {
                                            Text("Connect")
                                                .font(.system(size: 12, weight: .semibold))
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

                            if let failure {
                                Text(failure)
                                    .font(.system(size: 12))
                                    .foregroundColor(SumiTheme.warning)
                                    .fixedSize(horizontal: false, vertical: true)
                            } else {
                                Text("The token stays in this Mac's Keychain. Anicat never sees your password.")
                                    .font(.system(size: 12))
                                    .foregroundColor(SumiTheme.muted)
                            }
                        }
                    }
                }
                .frame(maxWidth: 440)

                Button {
                    model.completeOnboarding()
                } label: {
                    Text("Skip for now")
                        .font(.system(size: 13))
                        .foregroundColor(SumiTheme.muted)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.sumiPressable)
                .padding(.top, 28)
                .accessibilityLabel("Skip AniList setup for now")

                Text("Browsing and playback work without an account. Tracking and your lists need one; connect any time from Settings.")
                    .font(.system(size: 11.5))
                    .foregroundColor(SumiTheme.muted.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 400)
                    .padding(.top, 6)
            }
            .padding(48)
        }
        .onChange(of: model.isSignedIn) { _, signedIn in
            if signedIn {
                model.completeOnboarding()
            }
        }
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
                // `signIn` also sets the global error banner; the message
                // belongs next to the field the viewer is looking at.
                failure = "AniList did not accept that. Paste the whole URL from the browser's address bar after authorizing."
                model.errorMessage = nil
            }
        }
    }

    @ViewBuilder
    private func step<Content: View>(number: Int, title: String, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
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
}
