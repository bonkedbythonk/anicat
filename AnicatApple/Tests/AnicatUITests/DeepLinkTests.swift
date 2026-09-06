import Testing
import Foundation
@testable import AnicatUI

@Suite("DeepLink")
struct DeepLinkTests {
    @Test("A title link carries the AniList id")
    func titleLink() {
        #expect(DeepLink(url: URL(string: "anicat://title/21")!) == .title(id: 21, isManga: false))
    }

    @Test("manga=1 opens the manga side of the same id")
    func mangaTitleLink() {
        #expect(DeepLink(url: URL(string: "anicat://title/30002?manga=1")!) == .title(id: 30002, isManga: true))
        #expect(DeepLink(url: URL(string: "anicat://title/30002?manga=true")!) == .title(id: 30002, isManga: true))
        #expect(DeepLink(url: URL(string: "anicat://title/30002?manga=0")!) == .title(id: 30002, isManga: false))
    }

    @Test("A play link carries the id and the episode")
    func playLink() {
        #expect(DeepLink(url: URL(string: "anicat://play/1535/26")!) == .play(id: 1535, episode: 26))
    }

    /// Episode 0 would resolve as "the episode before the first one", which
    /// every episode list here numbers from 1.
    @Test("A play link with a non-positive or missing episode is not a link")
    func rejectsBadPlayLinks() {
        #expect(DeepLink(url: URL(string: "anicat://play/1535/0")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://play/1535")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://play/notanid/3")!) == nil)
    }

    @Test("A search link carries its query, percent-decoded")
    func searchLink() {
        #expect(DeepLink(url: URL(string: "anicat://search?q=cowboy%20bebop")!) == .search(query: "cowboy bebop"))
        #expect(DeepLink(url: URL(string: "anicat://search")!) == .search(query: ""))
    }

    /// The route names are deliberately not `NavSection.rawValue` for these
    /// two, so a change to either vocabulary has to break this test.
    @Test("Section routes use their own names, not the sidebar's raw values")
    func sectionNamesAreIndependent() {
        #expect(DeepLink(url: URL(string: "anicat://section/library")!) == .section(.library))
        #expect(DeepLink(url: URL(string: "anicat://section/history")!) == .section(.history))
        #expect(DeepLink(url: URL(string: "anicat://section/lists")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://section/profile")!) == nil)
    }

    @Test("Every section has a route and every route round-trips")
    func everySectionRoundTrips() {
        for section in SidebarView.NavSection.allCases {
            let link = DeepLink.section(section)
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test("Links round-trip through their own URL form")
    func roundTrip() {
        let links: [DeepLink] = [
            .title(id: 21, isManga: false),
            .title(id: 21, isManga: true),
            .play(id: 1535, episode: 26),
            .search(query: "cowboy bebop"),
            .section(.downloads)
        ]
        for link in links {
            #expect(DeepLink(url: link.url) == link)
        }
    }

    @Test("Anything that is not an anicat link is refused")
    func rejectsForeignURLs() {
        #expect(DeepLink(url: URL(string: "https://anilist.co/anime/21")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://nonsense/21")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://title/notanid")!) == nil)
        #expect(DeepLink(url: URL(string: "anicat://section/nope")!) == nil)
    }

    /// The scheme arrives from the system in whatever case the caller typed.
    @Test("The scheme and the route are matched case-insensitively")
    func caseInsensitive() {
        #expect(DeepLink(url: URL(string: "ANICAT://Title/21")!) == .title(id: 21, isManga: false))
        #expect(DeepLink(url: URL(string: "anicat://section/Settings")!) == .section(.settings))
    }
}
