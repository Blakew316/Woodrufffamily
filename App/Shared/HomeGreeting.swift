import SwiftUI
import CoreLocation
import WoodruffKit
#if canImport(FoundationModels)
import FoundationModels
#endif

// MARK: - Weather

/// The weather where the family is, for Home's greeting: right now, and today's high and low, in °F. It comes from
/// Open-Meteo (free, no account) for the place Woodruff already uses for the TVs' weather: this device's location
/// when it may use it, otherwise the town the TVs were given.
@Observable @MainActor
final class HomeWeather {
    static let shared = HomeWeather()

    struct Now: Codable, Equatable {
        var temp: Double
        var code: Int
        var isDay: Bool
        var high: Double?
        var low: Double?
        var at: Date
    }

    /// The last reading (kept between launches, so Home shows it at once).
    private(set) var now: Now? = Saved.load("homeWeather", as: Now.self)
    @ObservationIgnored private var loading = false

    /// Asks again when the reading is more than 20 minutes old (or [force]).
    func refresh(force: Bool = false) {
        guard !Demo.isOn, !loading else { return }
        if !force, let n = now, Date().timeIntervalSince(n.at) < 20 * 60 { return }
        loading = true
        Task {
            await load()
            loading = false
        }
    }

    private func load() async {
        guard let spot = await coordinates() else { return }
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", spot.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", spot.longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "temperature_2m_max,temperature_2m_min"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1"),
        ]
        guard let url = c.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return }
        let reading = Now(temp: answer.current.temperature_2m, code: answer.current.weather_code,
                          isDay: (answer.current.is_day ?? 1) == 1,
                          high: answer.daily?.temperature_2m_max?.first ?? nil,
                          low: answer.daily?.temperature_2m_min?.first ?? nil, at: Date())
        now = reading
        Saved.save("homeWeather", reading)
    }

    /// Where to ask about: this device's last location (saved by LocationWeather), or the town the TVs were given,
    /// found on the map once and remembered.
    private func coordinates() async -> CLLocationCoordinate2D? {
        let d = UserDefaults.standard
        if d.object(forKey: "weatherLat") != nil {
            return CLLocationCoordinate2D(latitude: d.double(forKey: "weatherLat"), longitude: d.double(forKey: "weatherLon"))
        }
        var place = d.string(forKey: "weatherPlace") ?? ""
        if place.isEmpty, let c = Fleet.shared.hubClient(), let s = try? await c.settings() { place = s.weather ?? "" }
        guard !place.isEmpty else { return nil }
        if d.string(forKey: "weatherPlaceFound") == place, d.object(forKey: "weatherPlaceLat") != nil {
            return CLLocationCoordinate2D(latitude: d.double(forKey: "weatherPlaceLat"), longitude: d.double(forKey: "weatherPlaceLon"))
        }
        guard let loc = try? await CLGeocoder().geocodeAddressString(place).first?.location else { return nil }
        d.set(place, forKey: "weatherPlaceFound")
        d.set(loc.coordinate.latitude, forKey: "weatherPlaceLat")
        d.set(loc.coordinate.longitude, forKey: "weatherPlaceLon")
        return loc.coordinate
    }

    private struct Answer: Decodable {
        struct Current: Decodable {
            var temperature_2m: Double
            var weather_code: Int
            var is_day: Int?
        }
        struct Daily: Decodable {
            var temperature_2m_max: [Double?]?
            var temperature_2m_min: [Double?]?
        }
        var current: Current
        var daily: Daily?
    }
}

extension HomeWeather.Now {
    /// "72°".
    var tempText: String { "\(Int(temp.rounded()))°" }

    /// "Partly Cloudy" and its SF Symbol, from the WMO weather code.
    var sky: (words: String, symbol: String) {
        switch code {
        case 0: return isDay ? ("Sunny", "sun.max.fill") : ("Clear", "moon.stars.fill")
        case 1: return isDay ? ("Mostly Sunny", "sun.max.fill") : ("Mostly Clear", "moon.fill")
        case 2: return ("Partly Cloudy", isDay ? "cloud.sun.fill" : "cloud.moon.fill")
        case 3: return ("Cloudy", "cloud.fill")
        case 45, 48: return ("Foggy", "cloud.fog.fill")
        case 51, 53, 55: return ("Drizzle", "cloud.drizzle.fill")
        case 56, 57, 66, 67: return ("Freezing Rain", "cloud.sleet.fill")
        case 61, 63: return ("Rain", "cloud.rain.fill")
        case 65: return ("Heavy Rain", "cloud.heavyrain.fill")
        case 71, 73, 75, 77: return ("Snow", "cloud.snow.fill")
        case 80, 81: return ("Showers", isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill")
        case 82: return ("Heavy Showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow Showers", "cloud.snow.fill")
        case 95: return ("Thunderstorms", "cloud.bolt.rain.fill")
        case 96, 99: return ("Severe Storms", "cloud.bolt.rain.fill")
        default: return ("", isDay ? "sun.max.fill" : "moon.fill")
        }
    }

    /// "H 78° L 59°", when today's high and low came with it.
    var range: String? {
        guard let high, let low else { return nil }
        return "H \(Int(high.rounded()))°  L \(Int(low.rounded()))°"
    }

    fileprivate var mood: String {
        switch code {
        case 95, 96, 99: return "storm"
        case 51...67, 80...82: return "rain"
        case 71...77, 85, 86: return "snow"
        case 45, 48: return "fog"
        default:
            if temp >= 90 { return "hot" }
            if temp <= 35 { return "cold" }
            return (code <= 1 && isDay) ? "sunny" : ""
        }
    }
}

// MARK: - Greeting

/// "Good morning, Woodruff Family" and a fresh one-liner each time Home opens: written on the device by Apple
/// Intelligence when it's on (with the weather and the time of day in mind), otherwise picked from Woodruff's own.
@Observable @MainActor
final class HomeGreeting {
    static let shared = HomeGreeting()

    enum DayPart: String {
        case morning, afternoon, evening

        static func at(_ date: Date = Date()) -> DayPart {
            let h = Calendar.current.component(.hour, from: date)
            if (5..<12).contains(h) { return .morning }
            if (12..<17).contains(h) { return .afternoon }
            return .evening
        }
    }

    private(set) var part: DayPart = .at()
    private(set) var line: String = ""
    var greeting: String { "Good \(part.rawValue), Woodruff Family" }

    @ObservationIgnored private var refreshedAt = Date.distantPast
    @ObservationIgnored private var writing: Task<Void, Never>?
    /// When Woodruff opened, near enough: the greeting is made as it opens (the scene coming to the front, or Home).
    private let openedAt = Date()

    /// A new one-liner (not more than once a minute unless [force]: a tap on the greeting).
    func refresh(force: Bool = false) {
        let p = DayPart.at()
        guard force || p != part || line.isEmpty || Date().timeIntervalSince(refreshedAt) > 60 else { return }
        part = p
        refreshedAt = Date()
        let picked = Self.pick(p, weather: HomeWeather.shared.now)
        withAnimation(.smooth(duration: 0.35)) { line = picked }
        write(p)
    }

    /// Apple Intelligence's own line, when it's available on this device; it replaces the picked one.
    private func write(_ p: DayPart) {
        writing?.cancel()
        #if canImport(FoundationModels)
        let weather = HomeWeather.shared.now
        let sky = weather.map { "\($0.sky.words.lowercased()) and \(Int($0.temp.rounded()))°F" } ?? "unknown weather"
        // Just opened: the model waits a moment, so Woodruff's first seconds (Home drawn, its pictures, the TVs
        // answering) aren't shared with it. The picked line shows meanwhile.
        let settle = Date().timeIntervalSince(openedAt) < 5
        writing = Task { @MainActor in
            if settle {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard !Task.isCancelled else { return }
            }
            guard case .available = SystemLanguageModel.default.availability else { return }
            do {
                let session = LanguageModelSession(instructions: """
                    You write the one-liner under the greeting on the Woodruff family's TV and smart-home app. \
                    One short, witty, warm, family-friendly line, at most 12 words. Light humour about TV, movies, \
                    snacks, the couch, the weather or the time of day. No quotes, no emoji, no hashtags, no names.
                    """)
                let answer = try await session.respond(to: "It's \(p.rawValue) and \(sky). Write a fresh one-liner.")
                guard !Task.isCancelled, self.part == p else { return }
                let text = Self.tidy(answer.content)
                guard !text.isEmpty else { return }
                withAnimation(.smooth(duration: 0.45)) { self.line = text }
            } catch {}
        }
        #endif
    }

    /// One line from the model, as one short sentence without quotes.
    private static func tidy(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = t.split(whereSeparator: \.isNewline).first { t = String(first) }
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ "))
        return t.count > 90 ? "" : t
    }

    private static func pick(_ p: DayPart, weather: HomeWeather.Now?) -> String {
        var pool: [String]
        switch p {
        case .morning: pool = morning
        case .afternoon: pool = afternoon
        case .evening: pool = evening
        }
        if let mood = weather?.mood, let extra = moods[mood] { pool += extra + extra }
        // Not the same line twice in a row.
        let last = UserDefaults.standard.string(forKey: "greeting.last")
        let choices = pool.filter { $0 != last }
        let line = choices.randomElement() ?? pool.first ?? ""
        UserDefaults.standard.set(line, forKey: "greeting.last")
        return line
    }

    private static let morning = [
        "Coffee first. Decisions later.",
        "Rise and shine — or at least rise.",
        "Today's forecast: a 100% chance of snacks.",
        "The couch misses you already.",
        "Pajamas count as an outfit until noon.",
        "Somebody start the coffee and nobody gets hurt.",
        "The TVs are up, even if you're not.",
        "Fresh day. Same great couch.",
        "Plot twist: today's going to be a good one.",
        "Breakfast is the most important meal. Second breakfast is a close second.",
        "Let's make today binge-worthy.",
        "Yesterday's episodes are behind us. Onward.",
        "Good things come to those who get out of bed.",
        "Morning mood: one more snooze.",
    ]

    private static let afternoon = [
        "Halfway there. Snack accordingly.",
        "Afternoon slump? The couch has entered the chat.",
        "It's never too early to plan tonight's movie.",
        "The afternoon called. It wants a nap.",
        "Productivity is overrated. Popcorn isn't.",
        "Hydrate, snack, repeat.",
        "Somewhere, a TV is waiting just for you.",
        "Lunch was great. Dinner will be better.",
        "A nap is just a short film with your eyes closed.",
        "Keep calm and press play later.",
        "Afternoon plan: look busy, think about dinner.",
        "Snack o'clock is a real time zone.",
    ]

    private static let evening = [
        "Couch claimed. Remote located. Snacks pending.",
        "Tonight's lineup is looking strong.",
        "Just one more episode. Famous last words.",
        "Popcorn won't make itself. Sadly.",
        "Who's picking the movie? Choose wisely.",
        "The day is done. The binge begins.",
        "Blankets out, lights low, let's go.",
        "Plot twist: everyone agrees on what to watch.",
        "Bedtime is a suggestion. The credits are a commitment.",
        "Lights down, volume up.",
        "Dinner, a movie, then one more movie.",
        "The remote is the real head of the household.",
    ]

    private static let moods: [String: [String]] = [
        "rain": ["Rain outside, movie inside. Perfect math.", "Puddles out there, popcorn in here."],
        "snow": ["Snow day energy: blankets are mandatory.", "Let it snow. We've got a queue to finish."],
        "storm": ["Thunder outside means surround sound inside.", "Stormy out there. Cozy in here."],
        "fog": ["Foggy out there. Crystal clear in here.", "The fog rolled in. So did the snacks."],
        "hot": ["It's hot out. The AC and the couch agree.", "Too hot to move. Perfect excuse."],
        "cold": ["Too cold to go out. Too cozy to care.", "Bundle up, or just stay on the couch."],
        "sunny": ["Sunny out there. The screens can wait. A little.", "Sunshine outside, showtime inside later."],
    ]
}

// MARK: - Views

/// The weather as a small glass pill: its symbol in colour and the temperature (and the high and low, when wide).
struct WeatherPill: View {
    var detailed = false
    private let weather = HomeWeather.shared

    var body: some View {
        if let now = weather.now {
            HStack(spacing: 6) {
                Image(systemName: now.sky.symbol)
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: detailed ? 17 : 15, weight: .semibold))
                Text(now.tempText)
                    .font(.system(size: detailed ? 17 : 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                if detailed, let range = now.range {
                    Text(range).font(.caption.weight(.medium)).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .glass(Capsule(), interactive: false)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(now.sky.words) \(now.tempText)")
            .animation(.smooth, value: now)
        }
    }
}

/// "Good evening, Woodruff Family" over the one-liner. A tap writes a new one-liner.
struct GreetingText: View {
    var alignment: HorizontalAlignment = .center
    var compact = false
    private let greeting = HomeGreeting.shared

    var body: some View {
        VStack(alignment: alignment, spacing: compact ? 1 : 4) {
            Text(greeting.greeting)
                #if os(macOS)
                .font(compact ? .headline : .title3.weight(.semibold))
                #else
                .font(.title3.weight(.bold))
                #endif
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if !greeting.line.isEmpty {
                Text(greeting.line)
                    .font(compact ? .caption : .subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(compact ? 1 : 2)
                    .multilineTextAlignment(alignment == .center ? .center : .leading)
                    .contentTransition(.opacity)
                    .id(greeting.line)
                    .transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            #if os(iOS)
            UISelectionFeedbackGenerator().selectionChanged()
            #endif
            greeting.refresh(force: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Tap for another one-liner")
    }
}

#if os(macOS)
/// The Mac's Home greeting, in the middle of Woodruff's bar: the weather, then the greeting over its one-liner, in
/// one Liquid Glass capsule.
struct MacGreetingPill: View {
    var compact = false
    private let weather = HomeWeather.shared

    var body: some View {
        HStack(spacing: 12) {
            if let now = weather.now {
                HStack(spacing: 6) {
                    Image(systemName: now.sky.symbol)
                        .symbolRenderingMode(.multicolor)
                        .font(.system(size: 18, weight: .semibold))
                    Text(now.tempText)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                }
                .help([now.sky.words, now.range].compactMap { $0 }.joined(separator: " · "))
                Divider().frame(height: 26)
            }
            GreetingText(alignment: .leading, compact: true)
                .frame(maxWidth: compact ? 240 : 320, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .frame(height: 44)
        .glass(Capsule(), interactive: false)
        .fixedSize(horizontal: true, vertical: false)
    }
}
#endif
