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

    /// One day of the forecast, in the place's own calendar.
    struct Day: Codable, Equatable, Identifiable {
        var date: String   // "2026-11-04"
        var code: Int
        var high: Double
        var low: Double
        var rain: Int?     // chance of rain, %
        var id: String { date }
    }

    struct Now: Codable, Equatable {
        var temp: Double
        var code: Int
        var isDay: Bool
        var high: Double?
        var low: Double?
        var at: Date
        // The detail behind the pill (missing from a reading saved before they were asked for).
        var feelsLike: Double?
        var humidity: Double?
        var wind: Double?      // mph
        var rainChance: Int?   // today's, %
        var sunrise: String?   // "2026-11-04T06:58", the place's own time
        var sunset: String?
        var days: [Day]?       // today and the next 5
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
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,wind_speed_10m,weather_code,is_day"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset"),
            URLQueryItem(name: "temperature_unit", value: "fahrenheit"),
            URLQueryItem(name: "wind_speed_unit", value: "mph"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "6"),
        ]
        guard let url = c.url else { return }
        let request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let answer = try? JSONDecoder().decode(Answer.self, from: data) else { return }
        let daily = answer.daily
        func item<T>(_ list: [T?]?, _ i: Int) -> T? {
            guard let list, i < list.count else { return nil }
            return list[i]
        }
        var days: [Day] = []
        for (i, date) in (daily?.time ?? []).enumerated() {
            guard let high = item(daily?.temperature_2m_max, i), let low = item(daily?.temperature_2m_min, i) else { continue }
            days.append(Day(date: date, code: item(daily?.weather_code, i) ?? 0, high: high, low: low,
                            rain: item(daily?.precipitation_probability_max, i).map { Int($0.rounded()) }))
        }
        let current = answer.current
        let reading = Now(temp: current.temperature_2m, code: current.weather_code,
                          isDay: (current.is_day ?? 1) == 1,
                          high: item(daily?.temperature_2m_max, 0), low: item(daily?.temperature_2m_min, 0), at: Date(),
                          feelsLike: current.apparent_temperature, humidity: current.relative_humidity_2m,
                          wind: current.wind_speed_10m, rainChance: days.first?.rain,
                          sunrise: item(daily?.sunrise, 0), sunset: item(daily?.sunset, 0),
                          days: days.isEmpty ? nil : days)
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
            var apparent_temperature: Double?
            var relative_humidity_2m: Double?
            var wind_speed_10m: Double?
        }
        struct Daily: Decodable {
            var time: [String]?
            var weather_code: [Int?]?
            var temperature_2m_max: [Double?]?
            var temperature_2m_min: [Double?]?
            var precipitation_probability_max: [Double?]?
            var sunrise: [String?]?
            var sunset: [String?]?
        }
        var current: Current
        var daily: Daily?
    }
}

extension HomeWeather.Now {
    /// "72°".
    var tempText: String { "\(Int(temp.rounded()))°" }

    /// "Partly Cloudy" and its SF Symbol, from the WMO weather code.
    var sky: (words: String, symbol: String) { HomeWeather.sky(code: code, isDay: isDay) }
}

extension HomeWeather {
    static func sky(code: Int, isDay: Bool) -> (words: String, symbol: String) {
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
}

extension HomeWeather.Now {

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
                    One short, witty, warm, family-friendly sentence that fits on one line: at most 7 words and 40 \
                    characters. Light humour about TV, movies, snacks, the couch, the weather or the time of day. \
                    No quotes, no emoji, no hashtags, no names, no dashes.
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
        // A real one-liner: one row under the greeting. Anything longer keeps the picked line instead.
        return t.count > 42 ? "" : t
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
        "Forecast: 100% chance of snacks.",
        "The couch misses you already.",
        "Pajamas count as an outfit until noon.",
        "Coffee now. Nobody gets hurt.",
        "The TVs are up, even if you're not.",
        "Fresh day. Same great couch.",
        "Plot twist: today's a good one.",
        "Second breakfast is still breakfast.",
        "Let's make today binge-worthy.",
        "New day, new episodes.",
        "Good things come to the awake.",
        "Morning mood: one more snooze.",
    ]

    private static let afternoon = [
        "Halfway there. Snack accordingly.",
        "Afternoon slump? The couch says hi.",
        "Plan tonight's movie now.",
        "The afternoon called. It wants a nap.",
        "Productivity's overrated. Popcorn isn't.",
        "Hydrate, snack, repeat.",
        "Somewhere, a TV is waiting just for you.",
        "Lunch was great. Dinner will be better.",
        "A nap is a short film, eyes closed.",
        "Keep calm and press play later.",
        "Look busy. Think about dinner.",
        "Snack o'clock is a real time zone.",
    ]

    private static let evening = [
        "Couch claimed. Snacks pending.",
        "Tonight's lineup is looking strong.",
        "One more episode. Famous last words.",
        "Popcorn won't make itself. Sadly.",
        "Who's picking the movie? Choose wisely.",
        "The day is done. The binge begins.",
        "Blankets out, lights low, let's go.",
        "Plot twist: everyone agrees on a movie.",
        "Bedtime is more of a suggestion.",
        "Lights down, volume up.",
        "Dinner, a movie, then one more movie.",
        "The remote runs this house.",
    ]

    private static let moods: [String: [String]] = [
        "rain": ["Rain outside, movie inside.", "Puddles out there, popcorn in here."],
        "snow": ["Snow day energy: blankets are mandatory.", "Let it snow. The queue awaits."],
        "storm": ["Thunder outside, surround sound inside.", "Stormy out there. Cozy in here."],
        "fog": ["Foggy out there. Crystal clear in here.", "The fog rolled in. So did the snacks."],
        "hot": ["Too hot out. The couch agrees.", "Too hot to move. Perfect excuse."],
        "cold": ["Too cold to go out. Too cozy to care.", "Bundle up, or just stay on the couch."],
        "sunny": ["Sunny now. Screens later.", "Sunshine outside, showtime inside later."],
    ]
}

// MARK: - Views

/// The weather as a small glass pill: its symbol in colour and the temperature (and the high and low, when wide).
struct WeatherPill: View {
    var detailed = false
    private let weather = HomeWeather.shared
    @State private var showing = false

    var body: some View {
        if let now = weather.now {
            Button { showing = true } label: {
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
                .glass(Capsule(), interactive: true)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(now.sky.words) \(now.tempText)")
            .accessibilityHint("Shows the forecast")
            .animation(.smooth, value: now)
            #if os(iOS)
            .sheet(isPresented: $showing) {
                WeatherSheet()
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
            #else
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                WeatherSheet().frame(width: 380, height: 560)
            }
            #endif
        }
    }
}

/// The weather in more detail, from the weather pill: now (feels like, humidity, wind, rain, sunrise and sunset),
/// then today and the next five days, each with its high and low on one shared scale.
struct WeatherSheet: View {
    private let weather = HomeWeather.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let now = weather.now {
                    VStack(spacing: 18) {
                        header(now)
                        details(now)
                        if let days = now.days, !days.isEmpty { forecast(days) }
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 24)
                } else {
                    Text("The weather shows once Woodruff knows where you are.")
                        .foregroundStyle(.secondary)
                        .padding(40)
                }
            }
            .navigationTitle("Weather")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        // A reading saved before the forecast was asked for gets one now.
        .task { HomeWeather.shared.refresh(force: weather.now?.days == nil) }
    }

    private func header(_ now: HomeWeather.Now) -> some View {
        VStack(spacing: 2) {
            Image(systemName: now.sky.symbol)
                .symbolRenderingMode(.multicolor)
                .font(.system(size: 40))
                .padding(.bottom, 4)
            Text(now.tempText)
                .font(.system(size: 64, weight: .thin, design: .rounded))
                .monospacedDigit()
            if !now.sky.words.isEmpty { Text(now.sky.words).font(.title3.weight(.semibold)) }
            if let range = now.range { Text(range).font(.subheadline).foregroundStyle(.secondary).monospacedDigit() }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    private func details(_ now: HomeWeather.Now) -> some View {
        var items: [Detail] = []
        if let v = now.feelsLike { items.append(Detail(name: "Feels Like", value: "\(Int(v.rounded()))°")) }
        if let v = now.humidity { items.append(Detail(name: "Humidity", value: "\(Int(v.rounded()))%")) }
        if let v = now.wind { items.append(Detail(name: "Wind", value: "\(Int(v.rounded())) mph")) }
        if let v = now.rainChance { items.append(Detail(name: "Chance of Rain", value: "\(v)%")) }
        if let v = Self.clock(now.sunrise) { items.append(Detail(name: "Sunrise", value: v)) }
        if let v = Self.clock(now.sunset) { items.append(Detail(name: "Sunset", value: v)) }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)], spacing: 12) {
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Text(item.value).font(.title3.weight(.semibold)).monospacedDigit()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glass(RoundedRectangle(cornerRadius: 18, style: .continuous), interactive: false)
            }
        }
    }

    private func forecast(_ days: [HomeWeather.Day]) -> some View {
        let lowest = days.map(\.low).min() ?? 0
        let highest = days.map(\.high).max() ?? 1
        return VStack(alignment: .leading, spacing: 0) {
            Text("\(days.count)-DAY FORECAST").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.bottom, 4)
            ForEach(Array(days.enumerated()), id: \.element.id) { i, day in
                if i > 0 { Divider() }
                HStack(spacing: 10) {
                    Text(Self.dayName(day.date, first: i == 0)).font(.body.weight(.semibold))
                        .frame(width: 56, alignment: .leading)
                    VStack(spacing: 1) {
                        Image(systemName: HomeWeather.sky(code: day.code, isDay: true).symbol)
                            .symbolRenderingMode(.multicolor)
                        if let rain = day.rain, rain >= 20 {
                            Text("\(rain)%").font(.caption2.weight(.semibold)).foregroundStyle(.cyan)
                        }
                    }
                    .frame(width: 36)
                    Text("\(Int(day.low.rounded()))°").foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                    TemperatureBar(low: day.low, high: day.high, lowest: lowest, highest: highest)
                    Text("\(Int(day.high.rounded()))°").monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.vertical, 9)
            }
        }
        .padding(16)
        .glass(RoundedRectangle(cornerRadius: 22, style: .continuous), interactive: false)
    }

    /// "Today", then "Thu", "Fri", …
    private static func dayName(_ date: String, first: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: date) else { return date }
        if Calendar.current.isDateInToday(d) || (first && !Calendar.current.isDateInTomorrow(d)) { return "Today" }
        return d.formatted(.dateTime.weekday(.abbreviated))
    }

    /// "6:58 AM" from Open-Meteo's local "2026-11-04T06:58".
    private static func clock(_ text: String?) -> String? {
        guard let text else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        guard let d = f.date(from: text) else { return nil }
        return d.formatted(date: .omitted, time: .shortened)
    }
}

private struct Detail: Identifiable {
    var name: String
    var value: String
    var id: String { name }
}

/// A day's low to high on the week's scale, like the Weather app's bars.
private struct TemperatureBar: View {
    var low: Double
    var high: Double
    var lowest: Double
    var highest: Double

    var body: some View {
        GeometryReader { g in
            let span = max(highest - lowest, 1)
            let start = (low - lowest) / span * g.size.width
            let width = max((high - low) / span * g.size.width, 6)
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(LinearGradient(colors: [.cyan, .green, .yellow, .orange], startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .offset(x: start)
            }
        }
        .frame(height: 5)
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
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
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
