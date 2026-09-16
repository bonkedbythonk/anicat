import Foundation

/// Fetches intro/outro skip times from the community AniSkip database
/// (https://api.aniskip.com), keyed by MyAnimeList id + episode number.
///
/// AniSkip's timestamps are measured against a specific episode file's
/// length, so a result is only trustworthy when the request's
/// `episodeLength` matches (or is close to) the file actually playing — a
/// different release/encode can have different opening/ending placement.
/// The API accounts for this itself (its own doc: pass 0 if unknown, results
/// get less precise, not wrong) and this client's own `interval` times are
/// still returned relative to the requested length, not absolute, so no
/// local rescaling is needed here.
public enum AniSkipClient {
    public struct SkipTimes: Sendable, Equatable {
        public let introStart: Double?
        public let introEnd: Double?
        public let outroStart: Double?
        public let outroEnd: Double?
    }

    private struct Response: Decodable {
        struct Result: Decodable {
            struct Interval: Decodable {
                let startTime: Double
                let endTime: Double
            }
            let interval: Interval
            let skipType: String
        }
        let found: Bool
        let results: [Result]?
    }

    private static let session = URLSession(configuration: .ephemeral)

    /// What a lookup came back with. The player's stream details show it:
    /// a 404 (nobody has submitted times for this episode, the usual case
    /// for a show in its first weeks) and a failed request both used to be
    /// a `nil` indistinguishable from each other, and from a skip that
    /// simply had not happened yet.
    public enum Lookup: Sendable, Equatable {
        case found(SkipTimes)
        case notFound
        case failed(String)
    }

    /// `nil` on any failure; see `lookup` for which one.
    public static func skipTimes(malId: Int64, episode: Int, episodeLengthSeconds: Double) async -> SkipTimes? {
        if case .found(let times) = await lookup(malId: malId, episode: episode, episodeLengthSeconds: episodeLengthSeconds) {
            return times
        }
        return nil
    }

    /// Not an error to surface as a toast either way: skip times are a
    /// nicety. The outcome is for the stream details panel and the log.
    public static func lookup(malId: Int64, episode: Int, episodeLengthSeconds: Double) async -> Lookup {
        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "op"),
            URLQueryItem(name: "types", value: "ed"),
            URLQueryItem(name: "episodeLength", value: String(Int(episodeLengthSeconds.rounded()))),
        ]
        guard let url = components?.url else {
            print("[AniSkip] malformed URL for MAL id \(malId) episode \(episode)")
            return .failed("malformed URL")
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                print("[AniSkip] no HTTP response for \(url.absoluteString)")
                return .failed("no HTTP response")
            }
            guard http.statusCode == 200 else {
                // 404 here means "no skip times for this episode", which is
                // the common, expected case for anything not popular enough
                // to have community-submitted timestamps — not a failure
                // worth alarming about, just worth being able to see when
                // debugging "why didn't this skip".
                print("[AniSkip] HTTP \(http.statusCode) for \(url.absoluteString)")
                return http.statusCode == 404 ? .notFound : .failed("HTTP \(http.statusCode)")
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.found, let results = decoded.results, !results.isEmpty else {
                print("[AniSkip] no skip times found for MAL id \(malId) episode \(episode)")
                return .notFound
            }

            var introStart: Double?
            var introEnd: Double?
            var outroStart: Double?
            var outroEnd: Double?
            for result in results {
                switch result.skipType {
                case "op":
                    introStart = result.interval.startTime
                    introEnd = result.interval.endTime
                case "ed":
                    outroStart = result.interval.startTime
                    outroEnd = result.interval.endTime
                default:
                    continue
                }
            }
            guard introStart != nil || outroStart != nil else { return .notFound }
            return .found(SkipTimes(introStart: introStart, introEnd: introEnd, outroStart: outroStart, outroEnd: outroEnd))
        } catch {
            print("[AniSkip] request failed for MAL id \(malId) episode \(episode): \(error)")
            return .failed(error.localizedDescription)
        }
    }
}
