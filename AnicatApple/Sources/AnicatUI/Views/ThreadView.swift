import SwiftUI
import AnicatCoreKit

/// An AniList forum thread, in the app. Replaces the
/// `openExternal("https://anilist.co/forum/thread/<id>")` a discussion row
/// used to do.
struct ThreadView: View {
    let thread: FfiThreadDetail
    /// Pre-flattened in pre-order with a `depth` each, so this list indents
    /// rather than building a tree — see `FfiThreadComment.parentId`.
    let comments: [FfiThreadComment]
    let hasMoreComments: Bool
    let isLoadingMore: Bool
    let onLoadMore: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            header

            AniListMarkdownText(thread.body, font: .system(size: 13.5))

            Divider().background(SumiTheme.border)

            VStack(alignment: .leading, spacing: 12) {
                PersonSectionLabel("Comments", trailing: "\(thread.replyCount) replies")

                if comments.isEmpty {
                    SumiEmptyState(headline: "No replies yet", detail: "Nobody has replied to this thread.")
                } else {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(comments.enumerated()), id: \.offset) { _, comment in
                            ThreadCommentRow(comment: comment)
                        }
                    }
                }

                if hasMoreComments {
                    HStack(spacing: 10) {
                        SumiOutlineButton("Load more replies", systemImage: "arrow.down") {
                            onLoadMore()
                        }
                        .disabled(isLoadingMore)
                        if isLoadingMore {
                            ProgressView().controlSize(.small)
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(thread.title)
                .font(.system(size: 22, weight: .semibold))
                .tracking(-0.4)
                .foregroundColor(SumiTheme.foreground)
                .fixedSize(horizontal: false, vertical: true)

            if !thread.categories.isEmpty {
                HStack(spacing: 6) {
                    ForEach(thread.categories, id: \.self) { category in
                        StatusBadge(.format(category))
                    }
                }
            }

            HStack(spacing: 10) {
                CachedAsyncImage(url: thread.authorAvatarUrl.flatMap(URL.init(string:)), maxPixelSize: 96) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Circle().fill(SumiTheme.card)
                }
                .frame(width: 30, height: 30)
                .clipShape(Circle())
                .overlay(Circle().stroke(SumiTheme.border, lineWidth: 1))

                Text(thread.authorName ?? "Unknown")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(SumiTheme.foreground)

                Text(SumiTimeFormatter.relativeShort(unixSeconds: thread.createdAt))
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)

                Text("\(thread.viewCount) views · \(thread.replyCount) replies")
                    .sumiTabularMono(size: 10)
                    .foregroundColor(SumiTheme.muted)

                if thread.isLocked {
                    HStack(spacing: 4) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 9))
                        Text("Locked")
                    }
                    .sumiTabularMono(size: 10, weight: .medium)
                    .foregroundColor(SumiTheme.warning)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(SumiTheme.warning.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: SumiTheme.radiusSm))
                }

                Spacer(minLength: 0)
            }
        }
    }
}

private struct ThreadCommentRow: View {
    let comment: FfiThreadComment

    /// One rail per level rather than a flat indent: a reply five deep in an
    /// AniList thread is otherwise a paragraph floating in whitespace with
    /// nothing tying it to what it answers.
    private static let railIndent: CGFloat = 16

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(0..<Int(max(0, comment.depth)), id: \.self) { _ in
                Rectangle()
                    .fill(SumiTheme.border)
                    .frame(width: 1)
                    .padding(.trailing, Self.railIndent - 1)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    CachedAsyncImage(url: comment.authorAvatarUrl.flatMap(URL.init(string:)), maxPixelSize: 80) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Circle().fill(SumiTheme.card)
                    }
                    .frame(width: 24, height: 24)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(SumiTheme.border, lineWidth: 1))

                    Text(comment.authorName ?? "Unknown")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(SumiTheme.foreground)

                    Text(SumiTimeFormatter.relativeShort(unixSeconds: comment.createdAt))
                        .sumiTabularMono(size: 9.5)
                        .foregroundColor(SumiTheme.muted)

                    if comment.likeCount > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "heart.fill")
                                .font(.system(size: 8))
                            Text("\(comment.likeCount)")
                        }
                        .sumiTabularMono(size: 9.5)
                        .foregroundColor(SumiTheme.indigo)
                    }

                    Spacer(minLength: 0)
                }

                AniListMarkdownText(comment.body, font: .system(size: 12.5), lineSpacing: 3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
