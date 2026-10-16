import SwiftUI
import AnicatCoreKit

/// The Search page once a request has been asked: a thread of the viewer's
/// messages and the replies, each reply with its posters beneath it, and the
/// field kept at the bottom for the next message.
struct AskChatView: View {
    let chat: AskChat
    let onSend: (String) -> Void
    let onSelectMedia: (MediaCard.Item) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { page in
            VStack(spacing: 0) {
                HStack(alignment: .center) {
                    Text("Ask")
                        .font(.sumiHeading(size: 19, weight: .semibold))
                        .tracking(-0.3)
                        .foregroundColor(SumiTheme.foreground)
                    Spacer()
                    // Not mid-reply: that reply would go on writing the names it
                    // resolved into the chat this just emptied.
                    SumiOutlineButton("New chat") { chat.clear() }
                        .disabled(chat.isThinking)
                        .opacity(chat.isThinking ? 0.5 : 1)
                        .animation(.sumi(.tab), value: chat.isThinking)
                    SumiOutlineButton("Back to search", systemImage: "chevron.right") { chat.close() }
                }
                .padding(.horizontal, 40)
                .padding(.top, 40)
                .padding(.bottom, 16)

                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(chat.messages) { message in
                                row(message, isLast: message.id == chat.messages.last?.id)
                                    .id(message.id)
                                    // The page-open motion the rest of the app
                                    // uses: it rises and fades, nothing else.
                                    .sumiTransition(.opacity.combined(with: .offset(y: 16)))
                            }
                            if chat.isThinking {
                                thinking
                                    .id("thinking")
                                    // Gone at once when the reply arrives: fading out
                                    // under the reply rising into the same place left
                                    // "Choosing" ghosting through its first line.
                                    .sumiTransition(.asymmetric(insertion: .opacity, removal: .identity))
                            }
                            Color.clear.frame(height: 1).id("end")
                        }
                        .animation(.sumi(.page), value: chat.messages.count)
                        .animation(.sumi(.tab), value: chat.isThinking)
                        .padding(.horizontal, 40)
                        .padding(.bottom, 24)
                        .frame(maxWidth: SumiContentWidth.forAvailable(page.size.width), alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .onChange(of: chat.messages.count) { _, _ in
                        withAnimation(.sumi(.page)) { proxy.scrollTo("end", anchor: .bottom) }
                    }
                    .onChange(of: chat.isThinking) { _, thinking in
                        if thinking {
                            withAnimation(.sumi(.page)) { proxy.scrollTo("end", anchor: .bottom) }
                        } else {
                            focused = true
                            // The follow-up chips only appear once the model has
                            // stopped, a beat after the reply scrolled into view,
                            // so the thread was left a chip row short of the
                            // bottom. Scrolled again once they are laid out.
                            Task { @MainActor in
                                try? await Task.sleep(nanoseconds: 60_000_000)
                                withAnimation(.sumi(.tab)) { proxy.scrollTo("end", anchor: .bottom) }
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    TextField(chat.isThinking ? "Looking…" : "Say more, or ask for something different…", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15))
                        .foregroundColor(SumiTheme.foreground)
                        .focused($focused)
                        .onSubmit(send)
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 20))
                            .foregroundColor(canSend ? SumiTheme.indigo : SumiTheme.muted)
                    }
                    .buttonStyle(.sumiPressable)
                    .disabled(!canSend)
                    .animation(.sumi(.tab), value: canSend)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .clipShape(SumiRect(cornerRadius: SumiTheme.radiusLg))
                .overlay(
                    SumiRect(cornerRadius: SumiTheme.radiusLg)
                        .stroke(focused ? SumiTheme.indigo.opacity(0.6) : SumiTheme.border, lineWidth: 1)
                )
                .animation(.sumi(.tab), value: focused)
                .padding(.horizontal, 40)
                .padding(.bottom, 28)
                .frame(maxWidth: SumiContentWidth.forAvailable(page.size.width))
                .frame(maxWidth: .infinity)
            }
        }
        // Asked twice, as the Search page does: written once from `onAppear` the
        // focus was dropped when the page was opened from the sidebar, and typing
        // then went to the global letter shortcuts instead of the field.
        .task {
            focused = true
            try? await Task.sleep(nanoseconds: 80_000_000)
            if !focused { focused = true }
        }
        #if os(macOS)
        .onExitCommand { chat.close() }
        #endif
    }

    private var canSend: Bool {
        !chat.isThinking && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func send() {
        guard canSend else { return }
        onSend(draft)
        draft = ""
    }

    private var thinking: some View {
        HStack(spacing: 8) {
            ProgressView().scaleEffect(0.7).tint(SumiTheme.indigo)
            Text(chat.status.isEmpty ? "Looking" : chat.status)
                .font(.system(size: 13))
                .foregroundColor(SumiTheme.muted)
                .contentTransition(.opacity)
                .animation(.sumi(.tab), value: chat.status)
        }
    }

    @ViewBuilder
    private func row(_ message: AskChat.Message, isLast: Bool) -> some View {
        switch message.role {
        case .viewer:
            Text(message.text)
                .font(.system(size: 14))
                .foregroundColor(SumiTheme.foreground)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .overlay(SumiRect(cornerRadius: SumiTheme.radiusMd).stroke(SumiTheme.border, lineWidth: 1))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            VStack(alignment: .leading, spacing: 14) {
                Text(message.text)
                    .font(.system(size: 14.5))
                    .foregroundColor(SumiTheme.foreground)
                    .fixedSize(horizontal: false, vertical: true)
                if !message.cards.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: 16) {
                            ForEach(message.cards) { item in
                                MediaCard(item: item, namespace: nil) { onSelectMedia(item) }
                                    .frame(width: 168)
                            }
                        }
                    }
                }
                // Only under the newest reply, and only once nothing is being
                // asked: an older reply's follow-ups would answer a question
                // the thread has moved past.
                if isLast, !chat.isThinking, !message.suggestions.isEmpty {
                    SumiWrapHStack(spacing: 8, lineSpacing: 8) {
                        ForEach(message.suggestions, id: \.self) { suggestion in
                            // The full title is what gets sent, so the show still
                            // resolves; only what is drawn is cut, for a window
                            // narrower than a long title.
                            SumiOutlineButton(suggestion.count > 42 ? String(suggestion.prefix(40)) + "…" : suggestion) { onSend(suggestion) }
                                .lineLimit(1)
                        }
                    }
                    .sumiTransition(.opacity)
                }
            }
        }
    }
}
