import SwiftUI

/// Reads a Syosetu (ncode.syosetu.com) light novel from a pasted URL —
/// see `AppModel.SyosetuSession`'s comment for why this is a direct-URL
/// flow rather than something reached from an AniList detail page.
public struct SyosetuReaderView: View {
    @Bindable var model: AppModel
    @State private var urlField: String = ""
    @State private var showToc = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        Group {
            if let session = model.syosetuSession {
                readerBody(session)
            } else {
                urlEntry
            }
        }
    }

    private var urlEntry: some View {
        SumiPage {
            SumiPageHeader(title: "Read a Light Novel", subtitle: "PASTE A SYOSETU LINK")
            VStack(alignment: .leading, spacing: 12) {
                Text("Paste a novel or chapter link from ncode.syosetu.com — the whole table of contents loads from it.")
                    .font(.system(size: 13))
                    .foregroundColor(SumiTheme.muted)
                HStack {
                    TextField("https://ncode.syosetu.com/n2267be/", text: $urlField)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(load)
                    SumiOutlineButton("Open", systemImage: "book", action: load)
                        .disabled(urlField.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(.top, 12)
        }
    }

    private func load() {
        let trimmed = urlField.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.openSyosetuReader(url: trimmed)
    }

    @ViewBuilder
    private func readerBody(_ session: AppModel.SyosetuSession) -> some View {
        VStack(spacing: 0) {
            header(session)
            Divider().background(SumiTheme.border)

            if let error = session.errorMessage {
                SumiEmptyState(headline: "Could not load", detail: error)
                    .frame(maxHeight: .infinity)
            } else if session.isLoading && session.chapterText.isEmpty {
                ProgressView().controlSize(.large).frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(session.chapterTitle)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundColor(SumiTheme.foreground)
                        ForEach(Array(session.chapterText.components(separatedBy: "\n\n").enumerated()), id: \.offset) { _, paragraph in
                            Text(paragraph.isEmpty ? " " : paragraph)
                                .font(.system(size: 16))
                                .lineSpacing(6)
                                .foregroundColor(SumiTheme.foreground)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(maxWidth: 640)
                    .padding(32)
                    .frame(maxWidth: .infinity)
                }
            }

            footer(session)
        }
        .sheet(isPresented: $showToc) {
            tocSheet(session)
        }
    }

    private func header(_ session: AppModel.SyosetuSession) -> some View {
        HStack {
            SumiOutlineButton("Close", systemImage: "xmark", action: model.closeSyosetuReader)
            Spacer()
            VStack(spacing: 2) {
                Text(session.info?.title ?? "").font(.system(size: 13, weight: .medium)).lineLimit(1)
                if let author = session.info?.author {
                    Text(author).sumiTabularMono(size: 10.5).foregroundColor(SumiTheme.muted)
                }
            }
            Spacer()
            SumiOutlineButton("Chapters", systemImage: "list.bullet", action: { showToc = true })
                .disabled(session.info == nil)
        }
        .padding(12)
    }

    private func footer(_ session: AppModel.SyosetuSession) -> some View {
        HStack {
            Button {
                jump(session, by: -1)
            } label: {
                Label("Previous", systemImage: "chevron.left")
            }
            .disabled(session.currentChapterIndex <= 0)

            Spacer()
            if let info = session.info {
                Text("\(session.currentChapterIndex + 1) / \(info.chapters.count)")
                    .sumiTabularMono(size: 11.5)
                    .foregroundColor(SumiTheme.muted)
            }
            Spacer()

            Button {
                jump(session, by: 1)
            } label: {
                Label("Next", systemImage: "chevron.right")
            }
            .disabled((session.info?.chapters.count ?? 0) <= session.currentChapterIndex + 1)
        }
        .buttonStyle(.sumiPressable)
        .padding(12)
    }

    private func jump(_ session: AppModel.SyosetuSession, by delta: Int) {
        guard let chapters = session.info?.chapters else { return }
        let target = session.currentChapterIndex + delta
        guard chapters.indices.contains(target) else { return }
        Task { await model.loadSyosetuChapter(url: chapters[target].url, index: target) }
    }

    private func tocSheet(_ session: AppModel.SyosetuSession) -> some View {
        NavigationStack {
            List {
                ForEach(Array((session.info?.chapters ?? []).enumerated()), id: \.offset) { index, chapter in
                    Button {
                        showToc = false
                        Task { await model.loadSyosetuChapter(url: chapter.url, index: index) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            if let volume = chapter.volumeName {
                                Text(volume).sumiTabularMono(size: 10).foregroundColor(SumiTheme.muted)
                            }
                            Text(chapter.title)
                                .foregroundColor(index == session.currentChapterIndex ? SumiTheme.indigo : SumiTheme.foreground)
                        }
                    }
                    .buttonStyle(.sumiPressable)
                }
            }
            .navigationTitle("Table of Contents")
        }
        .frame(minWidth: 360, minHeight: 480)
    }
}
