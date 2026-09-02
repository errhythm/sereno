import Foundation
import Observation
import os

/// Open-Meteo, not WeatherKit: WeatherKit needs the com.apple.developer.weatherkit
/// entitlement, that needs a provisioning profile, and an ad-hoc signed app cannot carry
/// one. Open-Meteo needs no key and no account.
///
/// This file is a fetcher and an enum. How a condition is drawn lives next to SkyPhase in
/// App.swift, because that is palette, not weather.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "weather")

/// Six conditions, because the header sky only has six ways to look. Anything finer would
/// be information a 46pt decorative bar cannot carry.
enum WeatherCondition: Sendable, CaseIterable {
    case clear, cloudy, fog, rain, snow, storm

    /// WMO 4677, the subset Open-Meteo returns. An unrecognised code draws a clear sky:
    /// a decorative header must never go blank because a service added a number.
    static func wmo(_ code: Int) -> WeatherCondition {
        switch code {
        case 0, 1: return .clear
        case 2, 3: return .cloudy
        case 45, 48: return .fog
        case 51...67, 80...82: return .rain
        case 71...77, 85, 86: return .snow
        case 95, 96, 99: return .storm
        default:
            log.warning("unmapped WMO code \(code, privacy: .public), drawing a clear sky")
            return .clear
        }
    }
}

/// One reading and when it was taken. Split out from the fetcher so the expiry rule is a
/// pure function and demoWeather can assert it without a network.
struct WeatherReading: Sendable {
    /// Weather does not change in seconds, and this is a free service being used politely.
    static let maxAge: TimeInterval = 25 * 60

    let condition: WeatherCondition
    let taken: Date

    func isFresh(at now: Date = .now) -> Bool {
        let age = now.timeIntervalSince(taken)
        return age >= 0 && age < Self.maxAge
    }
}

/// Caches one reading for the header to draw.
///
/// Every failure path degrades to time of day only. There is no error state and no banner:
/// the sky is decoration, and decoration that complains is worse than decoration that is
/// slightly less interesting.
@MainActor
@Observable
final class Weather {
    static let shared = Weather()

    private(set) var reading: WeatherReading?
    private var inFlight: Task<Void, Never>?

    /// What the header should draw, or nil for time of day only. A stale reading still
    /// draws while the replacement is on its way: an hour-old sky beats a sky that snaps
    /// back to clear every time the cache ages out.
    var condition: WeatherCondition? {
        Preferences.shared.canFetchWeather ? reading?.condition : nil
    }

    /// Called on every panel open, which is why the freshness check is the first thing it
    /// does. Nothing leaves the machine while the toggle is off or the city is unresolved.
    ///
    /// ponytail: a failed fetch retries on the next panel open, with no backoff. Panel
    /// opens are human-paced, so that is a few requests an hour at worst. Add a floor if
    /// that ever stops being true.
    func refreshIfStale() {
        let prefs = Preferences.shared
        guard prefs.canFetchWeather,
              let latitude = prefs.weatherLatitude,
              let longitude = prefs.weatherLongitude,
              reading?.isFresh() != true,
              inFlight == nil
        else { return }

        inFlight = Task { [weak self] in
            let fetched = await Self.current(latitude: latitude, longitude: longitude)
            guard let self else { return }
            if let fetched {
                reading = WeatherReading(condition: fetched, taken: .now)
            }
            inFlight = nil
        }
    }

    /// Drops the cache, so a city the user just changed is asked about instead of the old
    /// one's answer being drawn for another twenty five minutes.
    func invalidate() {
        inFlight?.cancel()
        inFlight = nil
        reading = nil
    }

    // MARK: - Network

    /// Short timeouts, so a hung network cannot make the header wait, and ephemeral so a
    /// weather lookup leaves nothing on disk.
    private nonisolated static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 8
        return URLSession(configuration: config)
    }()

    /// Called once when the user resolves a city, never on refresh. Returns the place name
    /// Open-Meteo settled on, so the user can see whether it found the right Springfield.
    nonisolated static func geocode(_ city: String) async
        -> (name: String, latitude: Double, longitude: Double)? {
        guard let url = geocodeURL(city: city) else { return nil }
        guard let body: GeocodeResponse = await get(url) else { return nil }
        guard let place = body.results?.first else {
            log.debug("no geocoding match for \(city, privacy: .private)")
            return nil
        }
        log.debug("""
            resolved \(city, privacy: .private) to \(place.name, privacy: .private) \
            at \(place.latitude, privacy: .private), \(place.longitude, privacy: .private)
            """)
        return (place.name, place.latitude, place.longitude)
    }

    private nonisolated static func current(latitude: Double, longitude: Double) async
        -> WeatherCondition? {
        guard let url = forecastURL(latitude: latitude, longitude: longitude),
              let body: ForecastResponse = await get(url)
        else { return nil }
        return .wmo(body.current.weatherCode)
    }

    /// The one place a failure is turned into nil. No network, timeout, HTTP error and
    /// malformed JSON all land here and all look the same to the caller.
    private nonisolated static func get<T: Decodable>(_ url: URL) async -> T? {
        do {
            let (data, response) = try await session.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                log.warning("open-meteo returned \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            return try decoder.decode(T.self, from: data)
        } catch {
            log.debug("open-meteo lookup failed, sky stays on the clock. \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// URLComponents does the percent-encoding, so a city like "São Paulo" needs no
    /// hand-rolled escaping.
    nonisolated static func geocodeURL(city: String) -> URL? {
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            .init(name: "name", value: city),
            .init(name: "count", value: "1"),
            .init(name: "language", value: "en"),
            .init(name: "format", value: "json"),
        ]
        return components?.url
    }

    /// is_day is in the query because it is part of the endpoint contract, but the value is
    /// not used: the header's phase comes from the user's own clock, not from whether the
    /// sun is up in the city they named, which may be a continent away.
    nonisolated static func forecastURL(latitude: Double, longitude: Double) -> URL? {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            .init(name: "latitude", value: "\(latitude)"),
            .init(name: "longitude", value: "\(longitude)"),
            .init(name: "current", value: "weather_code,is_day"),
        ]
        return components?.url
    }

    private struct GeocodeResponse: Decodable {
        struct Place: Decodable {
            let name: String
            let latitude: Double
            let longitude: Double
        }
        /// Absent entirely, not empty, when nothing matches.
        let results: [Place]?
    }

    private struct ForecastResponse: Decodable {
        struct Current: Decodable { let weatherCode: Int }
        let current: Current
    }
}

/// The pure parts: the code mapping, the expiry rule, and the two URLs. No network, so
/// this is safe to run anywhere and says nothing about whether Open-Meteo is up.
func demoWeather() {
    // Every mapped band, including both ends of each range.
    assert(WeatherCondition.wmo(0) == .clear && WeatherCondition.wmo(1) == .clear)
    assert(WeatherCondition.wmo(2) == .cloudy && WeatherCondition.wmo(3) == .cloudy)
    assert(WeatherCondition.wmo(45) == .fog && WeatherCondition.wmo(48) == .fog)
    assert(WeatherCondition.wmo(51) == .rain && WeatherCondition.wmo(67) == .rain)
    assert(WeatherCondition.wmo(80) == .rain && WeatherCondition.wmo(82) == .rain)
    assert(WeatherCondition.wmo(71) == .snow && WeatherCondition.wmo(77) == .snow)
    assert(WeatherCondition.wmo(85) == .snow && WeatherCondition.wmo(86) == .snow)
    assert(WeatherCondition.wmo(95) == .storm && WeatherCondition.wmo(99) == .storm)

    // Unknown codes must fall back to clear, not crash and not go blank. 4 and 44 sit in
    // the gaps between bands, 68 and 83 just past a band's end.
    for unknown in [-1, 4, 44, 49, 68, 78, 83, 87, 94, 97, 100, 999] {
        assert(WeatherCondition.wmo(unknown) == .clear, "WMO \(unknown) should degrade to clear")
    }

    // Cache expiry, at the boundary. 25 minutes is the age, so 24 is fresh and 26 is not.
    let taken = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let reading = WeatherReading(condition: .rain, taken: taken)
    assert(reading.isFresh(at: taken))
    assert(reading.isFresh(at: taken.addingTimeInterval(24 * 60)))
    assert(!reading.isFresh(at: taken.addingTimeInterval(25 * 60)), "25 minutes is the ceiling")
    assert(!reading.isFresh(at: taken.addingTimeInterval(26 * 60)))
    // A clock that went backwards must not read as fresh forever.
    assert(!reading.isFresh(at: taken.addingTimeInterval(-60)))

    // URL construction, with a city that needs percent-encoding.
    let geo = Weather.geocodeURL(city: "São Paulo")!
    assert(geo.absoluteString ==
        "https://geocoding-api.open-meteo.com/v1/search?name=S%C3%A3o%20Paulo&count=1&language=en&format=json",
        geo.absoluteString)
    let ampersand = Weather.geocodeURL(city: "A&B?C")!
    assert(!ampersand.absoluteString.contains("A&B?C"), "a raw & would truncate the query")

    let forecast = Weather.forecastURL(latitude: -23.5475, longitude: -46.63611)!
    assert(forecast.absoluteString ==
        "https://api.open-meteo.com/v1/forecast?latitude=-23.5475&longitude=-46.63611&current=weather_code,is_day",
        forecast.absoluteString)

    print("demoWeather: PASS \(geo.absoluteString)")
    print("demoWeather: PASS \(forecast.absoluteString)")
}
