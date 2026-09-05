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

    /// `nil` on any failure (no mapping, no data for this episode, network
    /// error, malformed response) — callers treat that the same as "AniSkip
    /// has nothing for this episode", not as an error to surface to the
    /// viewer. Skip times are a nicety, not something worth an error toast.
    public static func skipTimes(malId: Int64, episode: Int, episodeLengthSeconds: Double) async -> SkipTimes? {
        var components = URLComponents(string: "https://api.aniskip.com/v2/skip-times/\(malId)/\(episode)")
        components?.queryItems = [
            URLQueryItem(name: "types", value: "op"),
            URLQueryItem(name: "types", value: "ed"),
            URLQueryItem(name: "episodeLength", value: String(Int(episodeLengthSeconds.rounded()))),
        ]
        guard let url = components?.url else {
            print("[AniSkip] malformed URL for MAL id \(malId) episode \(episode)")
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse else {
                print("[AniSkip] no HTTP response for \(url.absoluteString)")
                return nil
            }
            guard http.statusCode == 200 else {
                // 404 here means "no skip times for this episode", which is
                // the common, expected case for anything not popular enough
                // to have community-submitted timestamps — not a failure
                // worth alarming about, just worth being able to see when
                // debugging "why didn't this skip".
                print("[AniSkip] HTTP \(http.statusCode) for \(url.absoluteString)")
                return nil
            }
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            guard decoded.found, let results = decoded.results, !results.isEmpty else {
                print("[AniSkip] no skip times found for MAL id \(malId) episode \(episode)")
                return nil
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
            guard introStart != nil || outroStart != nil else { return nil }
            return SkipTimes(introStart: introStart, introEnd: introEnd, outroStart: outroStart, outroEnd: outroEnd)
        } catch {
            print("[AniSkip] request failed for MAL id \(malId) episode \(episode): \(error)")
            return nil
        }
    }
}
