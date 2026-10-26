import AppKit
import Combine

struct DayForecast {
    let date: Date
    let high: Double   // °C
    let low: Double    // °C
    let code: Int
}

enum WeatherCode {
    /// WMO weather interpretation codes → description and SF Symbol.
    static func info(_ code: Int) -> (text: String, symbol: String) {
        switch code {
        case 0: return ("Clear sky", "sun.max.fill")
        case 1: return ("Mostly clear", "sun.max.fill")
        case 2: return ("Partly cloudy", "cloud.sun.fill")
        case 3: return ("Overcast", "cloud.fill")
        case 45, 48: return ("Fog", "cloud.fog.fill")
        case 51, 53, 55, 56, 57: return ("Drizzle", "cloud.drizzle.fill")
        case 61, 63, 65, 66, 67: return ("Rain", "cloud.rain.fill")
        case 71, 73, 75, 77: return ("Snow", "cloud.snow.fill")
        case 80, 81, 82: return ("Showers", "cloud.heavyrain.fill")
        case 85, 86: return ("Snow showers", "cloud.snow.fill")
        case 95, 96, 99: return ("Thunderstorm", "cloud.bolt.rain.fill")
        default: return ("Unknown", "questionmark.circle")
        }
    }
}

/// Weather from Open-Meteo (free, no API key). The city is looked up by name, so no location permission.
final class WeatherStore: ObservableObject {
    enum State {
        case idle
        case loading
        case loaded
        case failed(String)
    }

    @Published var city: String
    @Published var resolvedName = ""
    @Published var temperature: Double = 0      // °C
    @Published var feelsLike: Double = 0        // °C
    @Published var code = 0
    @Published var wind: Double = 0             // km/h
    @Published var humidity: Int = 0
    @Published var daily: [DayForecast] = []
    @Published var state: State = .idle
    @Published var fahrenheit: Bool

    private var lastFetch: Date?
    private let defaults = UserDefaults.standard

    init() {
        city = defaults.string(forKey: "weatherCity") ?? "Accra"
        fahrenheit = defaults.bool(forKey: "weatherFahrenheit")
    }

    func setCity(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        city = trimmed
        defaults.set(trimmed, forKey: "weatherCity")
        refresh(force: true)
    }

    func toggleUnit() {
        fahrenheit.toggle()
        defaults.set(fahrenheit, forKey: "weatherFahrenheit")
    }

    func format(_ celsius: Double) -> String {
        let value = fahrenheit ? celsius * 9 / 5 + 32 : celsius
        return "\(Int(value.rounded()))°"
    }

    func refresh(force: Bool = false) {
        if !force, let last = lastFetch, Date().timeIntervalSince(last) < 900 {
            if case .loaded = state { return }
        }
        state = .loading
        let query = city
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://geocoding-api.open-meteo.com/v1/search?name=\(encoded)&count=1&language=en&format=json")
        else {
            state = .failed("Couldn't read that city name")
            return
        }
        fetchJSON(url) { [weak self] json in
            guard let self else { return }
            guard let json else {
                self.state = State.failed("Can't reach the weather service")
                return
            }
            guard let place = (json["results"] as? [[String: Any]])?.first,
                  let lat = place["latitude"] as? Double,
                  let lon = place["longitude"] as? Double
            else {
                self.state = State.failed("City not found")
                return
            }
            let name = place["name"] as? String ?? query
            let country = place["country"] as? String ?? ""
            self.resolvedName = country.isEmpty ? name : "\(name), \(country)"
            self.fetchForecast(latitude: lat, longitude: lon)
        }
    }

    private func fetchForecast(latitude: Double, longitude: Double) {
        let fields = "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m"
        let urlString = "https://api.open-meteo.com/v1/forecast?latitude=\(latitude)&longitude=\(longitude)"
            + "&current=\(fields)&daily=weather_code,temperature_2m_max,temperature_2m_min"
            + "&timezone=auto&forecast_days=5"
        guard let url = URL(string: urlString) else {
            state = .failed("Couldn't build the forecast request")
            return
        }
        fetchJSON(url) { [weak self] json in
            guard let self else { return }
            guard let json,
                  let current = json["current"] as? [String: Any],
                  let daily = json["daily"] as? [String: Any]
            else {
                self.state = State.failed("Couldn't read the forecast")
                return
            }
            self.temperature = current["temperature_2m"] as? Double ?? 0
            self.feelsLike = current["apparent_temperature"] as? Double ?? self.temperature
            self.humidity = current["relative_humidity_2m"] as? Int ?? 0
            self.code = current["weather_code"] as? Int ?? 0
            self.wind = current["wind_speed_10m"] as? Double ?? 0

            let times = daily["time"] as? [String] ?? []
            let codes = daily["weather_code"] as? [Int] ?? []
            let highs = daily["temperature_2m_max"] as? [Double] ?? []
            let lows = daily["temperature_2m_min"] as? [Double] ?? []
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            var days: [DayForecast] = []
            for index in 0..<min(times.count, codes.count, highs.count, lows.count) {
                if let date = formatter.date(from: times[index]) {
                    days.append(DayForecast(date: date, high: highs[index], low: lows[index], code: codes[index]))
                }
            }
            self.daily = days
            self.lastFetch = Date()
            self.state = .loaded
        }
    }

    private func fetchJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
        URLSession.shared.dataTask(with: url) { data, _, _ in
            var json: [String: Any]?
            if let data, let object = try? JSONSerialization.jsonObject(with: data) {
                json = object as? [String: Any]
            }
            DispatchQueue.main.async { completion(json) }
        }.resume()
    }
}
