import Testing
import Foundation
import MediaPlayer
@testable import AnicatUI

@Suite("NowPlayingBridge", .serialized)
struct NowPlayingBridgeTests {
    private let track = NowPlayingBridge.Track(title: "Frieren", episodeNumber: 3, episodeTitle: "Killing Magic")

    @Test("info dictionary carries title, episode subtitle, timeline and video type")
    func infoDictionary() {
        let info = NowPlayingBridge.info(track: track, elapsed: 42.5, duration: 1440, rate: 1.0)
        #expect(info[MPMediaItemPropertyTitle] as? String == "Frieren")
        #expect(info[MPMediaItemPropertyArtist] as? String == "Episode 3 - Killing Magic")
        #expect(info[MPNowPlayingInfoPropertyMediaType] as? UInt == MPNowPlayingInfoMediaType.video.rawValue)
        #expect(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 42.5)
        #expect(info[MPMediaItemPropertyPlaybackDuration] as? Double == 1440)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 1.0)
        #expect(info[MPMediaItemPropertyArtwork] == nil)
    }

    @Test("an unknown duration leaves the key out instead of publishing a zero-length bar")
    func unknownDuration() {
        let info = NowPlayingBridge.info(track: track, elapsed: 0, duration: 0, rate: 0)
        #expect(info[MPMediaItemPropertyPlaybackDuration] == nil)
        #expect(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)
    }

    @Test("subtitle falls back to the bare episode number")
    func subtitleFallback() {
        #expect(NowPlayingBridge.subtitle(episodeNumber: 12, episodeTitle: "") == "Episode 12")
        #expect(NowPlayingBridge.subtitle(episodeNumber: 12, episodeTitle: "   ") == "Episode 12")
        #expect(NowPlayingBridge.subtitle(episodeNumber: 1, episodeTitle: "The Journey's End") == "Episode 1 - The Journey's End")
    }

    @Test("a progress tick changes the timeline keys and nothing else; clear takes the tile down")
    func progressTickAndClear() {
        let bridge = NowPlayingBridge()
        let center = MPNowPlayingInfoCenter.default()
        bridge.setTrack(track, elapsed: 10, duration: 1440, rate: 1.0, coverURL: nil)
        #expect(center.nowPlayingInfo?[MPMediaItemPropertyTitle] as? String == "Frieren")
        #expect(center.nowPlayingInfo?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 10)

        bridge.updateProgress(elapsed: 11, duration: 1440, rate: 0)
        let after = center.nowPlayingInfo
        #expect(after?[MPMediaItemPropertyTitle] as? String == "Frieren")
        #expect(after?[MPMediaItemPropertyArtist] as? String == "Episode 3 - Killing Magic")
        #expect(after?[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double == 11)
        #expect(after?[MPNowPlayingInfoPropertyPlaybackRate] as? Double == 0)

        bridge.clear()
        #expect(center.nowPlayingInfo == nil)
        // A tick after clear must not resurrect a tile for a stopped player.
        bridge.updateProgress(elapsed: 12, duration: 1440, rate: 1.0)
        #expect(center.nowPlayingInfo == nil)
    }

    @Test("attach enables the transport commands and mirrors the controller's neighbours")
    func attachMirrorsNavigation() {
        let controller = PlayerController(title: "Frieren", episodeNumber: 3)
        controller.hasNextEpisode = true
        controller.hasPreviousEpisode = false
        let bridge = NowPlayingBridge()
        bridge.attach(to: controller)
        let center = MPRemoteCommandCenter.shared()
        #expect(center.togglePlayPauseCommand.isEnabled)
        #expect(center.changePlaybackPositionCommand.isEnabled)
        #expect(center.nextTrackCommand.isEnabled)
        #expect(!center.previousTrackCommand.isEnabled)
        #expect(center.skipForwardCommand.preferredIntervals == [NSNumber(value: NowPlayingBridge.skipInterval)])

        bridge.setNavigation(hasNext: false, hasPrevious: true)
        #expect(!center.nextTrackCommand.isEnabled)
        #expect(center.previousTrackCommand.isEnabled)
    }
}
