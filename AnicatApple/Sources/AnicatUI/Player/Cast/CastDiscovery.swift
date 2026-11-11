#if os(macOS)
import Foundation
import Network
import Observation

struct CastDevice: Identifiable, Equatable {
    /// The receiver's TXT `id`, stable across reboots and renames.
    let id: String
    /// The name set on the TV (TXT `fn`), e.g. "55POS9002/12". The Bonjour
    /// instance name is a model code plus a hash and tells two TVs apart
    /// for nobody.
    let name: String
    let endpoint: NWEndpoint
}

/// Chromecast receivers on the LAN that can show video. Browses only while
/// the picker is open.
@MainActor
@Observable
final class CastDiscovery {
    private(set) var devices: [CastDevice] = []
    @ObservationIgnored private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_googlecast._tcp", domain: "local."), using: NWParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated { self?.update(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
    }

    /// Receivers (TXT `id`) never offered, set with `defaults write`: other
    /// people's TVs in the same house, which nobody should cast to by a
    /// misclick. Kept out of the code because the ids are this house's.
    static let hiddenKey = "anicat_cast_hidden_devices"

    private func update(_ results: Set<NWBrowser.Result>) {
        let hidden = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenKey) ?? [])
        devices = results.compactMap { result -> CastDevice? in
            guard case .bonjour(let txt) = result.metadata,
                  let id = txt["id"], !hidden.contains(id),
                  // Bit 0 of `ca` is video out. Speakers (a Nest Mini sits
                  // on the same service type) leave it clear.
                  let capabilities = txt["ca"].flatMap(Int.init), capabilities & 1 == 1 else { return nil }
            return CastDevice(id: id, name: txt["fn"] ?? id, endpoint: result.endpoint)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
#endif
