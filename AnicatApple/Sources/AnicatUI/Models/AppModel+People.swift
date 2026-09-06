// AppModel, people and threads domain: the character, staff and forum-thread
// pages that used to be an `openExternal` to anilist.co. One stack, one
// in-flight load, and the content for whatever sits on top of it.

import Foundation
import SwiftUI
import Observation
import AnicatCoreKit

extension AppModel {
    public var isPersonPageOpen: Bool { !personPageStack.isEmpty }

    public func openCharacter(id: Int64) {
        pushPersonPage(.character(id: id))
    }

    public func openStaff(id: Int64) {
        pushPersonPage(.staff(id: id))
    }

    public func openThread(id: Int64) {
        pushPersonPage(.thread(id: id))
    }

    /// One step back, whatever "back" currently means. The swipe gesture,
    /// the mouse back button and Alt+Left all called `closeDetail()`
    /// directly, which with a character page open dropped the detail page
    /// underneath it and left the character over the previous title.
    /// Escape goes through `handleEscapeKey`, which has the same branch in
    /// its own dismissal ladder.
    public func popBackOne() {
        if !personPageStack.isEmpty {
            closePersonPage()
        } else {
            closeDetail()
        }
    }

    /// Pops one level. The entry underneath reloads rather than being kept
    /// alive underneath the top one — see `loadedCharacter`'s comment.
    public func closePersonPage() {
        guard !personPageStack.isEmpty else { return }
        cancelPersonPageWork()
        personPageStack.removeLast()
        if personPageStack.isEmpty {
            resetPersonPageContent()
        } else {
            loadTopPersonPage()
        }
    }

    /// Drops the whole stack without touching the detail page under it. Used
    /// where the person page is being left for somewhere else entirely (a
    /// section switch, an appearance poster opening its own title), where
    /// there is nothing to step back to.
    public func clearPersonPages() {
        guard !personPageStack.isEmpty else { return }
        cancelPersonPageWork()
        personPageStack = []
        resetPersonPageContent()
    }

    /// An appearance/credit poster on a person page. Not wrapped in
    /// `withAnimation`: `openDetail` animates its own transaction, and
    /// racing a second one against it at the call site is what read as the
    /// page jittering (see the note on `onClose` in RootView).
    public func openTitleFromPersonPage(id: Int64, title: String?, coverURL: URL?, isManga: Bool) {
        clearPersonPages()
        Task { [weak self] in
            await self?.openDetail(id: id, title: title, coverURL: coverURL, isManga: isManga)
        }
    }

    public func retryPersonPage() {
        loadTopPersonPage()
    }

    func loadTopPersonPage() {
        guard let page = personPageStack.last else { return }
        guard let engine else {
            personPageError = "The engine is still starting up."
            return
        }
        cancelPersonPageWork()
        resetPersonPageContent()
        isPersonPageLoading = true

        activePersonPageTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                switch page {
                case .character(let id):
                    let detail = try await engine.characterDetail(characterId: id)
                    guard self.stillOnTop(page) else { return }
                    self.loadedCharacter = detail
                case .staff(let id):
                    let detail = try await engine.staffDetail(staffId: id)
                    guard self.stillOnTop(page) else { return }
                    self.loadedStaff = detail
                case .thread(let id):
                    let detail = try await engine.threadDetail(threadId: id)
                    guard self.stillOnTop(page) else { return }
                    self.loadedThread = detail
                    self.loadedThreadComments = detail.comments
                    self.threadHasMoreComments = detail.hasNextPage
                    self.threadCommentsNextPage = 2
                }
                self.recordAniListSuccess()
                self.isPersonPageLoading = false
            } catch {
                guard self.stillOnTop(page) else { return }
                self.recordAniListFailure(error)
                self.personPageError = Self.personPageMessage(for: error)
                self.isPersonPageLoading = false
            }
        }
    }

    public func loadMoreThreadComments() {
        guard case .thread(let id)? = personPageStack.last,
              let engine,
              threadHasMoreComments,
              !isLoadingMoreThreadComments else { return }
        let page = threadCommentsNextPage
        isLoadingMoreThreadComments = true

        activeThreadCommentsTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await engine.threadComments(threadId: id, page: page)
                guard self.stillOnTop(.thread(id: id)) else { return }
                self.loadedThreadComments.append(contentsOf: result.comments)
                self.threadHasMoreComments = result.hasNextPage
                self.threadCommentsNextPage = page + 1
                self.isLoadingMoreThreadComments = false
            } catch {
                guard self.stillOnTop(.thread(id: id)) else { return }
                self.recordAniListFailure(error)
                // Not `personPageError`: the thread itself is on screen and
                // readable. Replacing it with a full-page error over one
                // failed page of replies would throw away what did load.
                self.threadHasMoreComments = false
                self.isLoadingMoreThreadComments = false
                self.errorMessage = "Couldn't load more replies: \(Self.personPageMessage(for: error))"
            }
        }
    }

    // MARK: - Internals

    private func pushPersonPage(_ page: PersonPage) {
        guard personPageStack.last != page else { return }
        cancelPersonPageWork()
        personPageStack.append(page)
        loadTopPersonPage()
    }

    /// A cancelled `Task`'s continuation still resumes, and the reader can
    /// push or pop while a fetch is in flight — a slow character fetch
    /// landing after a jump to a voice actor would otherwise overwrite the
    /// staff page with the character it was navigated away from. Neither
    /// `Task.isCancelled` nor a `[weak self]` catches that on its own.
    private func stillOnTop(_ page: PersonPage) -> Bool {
        !Task.isCancelled && personPageStack.last == page
    }

    private func cancelPersonPageWork() {
        activePersonPageTask?.cancel()
        activePersonPageTask = nil
        activeThreadCommentsTask?.cancel()
        activeThreadCommentsTask = nil
    }

    private func resetPersonPageContent() {
        loadedCharacter = nil
        loadedStaff = nil
        loadedThread = nil
        loadedThreadComments = []
        threadHasMoreComments = false
        isLoadingMoreThreadComments = false
        threadCommentsNextPage = 2
        isPersonPageLoading = false
        personPageError = nil
    }

    /// A deleted thread comes back as `NotFound`, not `Network`, and telling
    /// the reader to check their connection over a thread that no longer
    /// exists sends them looking in the wrong place.
    static func personPageMessage(for error: Error) -> String {
        if let anicatError = error as? AnicatError {
            switch anicatError {
            case .NotFound:
                return "This page is no longer on AniList."
            case .Network(let msg):
                if msg.contains("anilist_down:") {
                    return "AniList is temporarily unavailable."
                }
                return "Couldn't reach AniList."
            case .Storage(let msg), .Internal(let msg):
                return msg
            }
        }
        return error.localizedDescription
    }
}
