import AppKit

enum UpdateResult {
    case upToDate(String)
    case available(version: String, pageURL: URL)
    case failed(String)
}

/// Looks at the GitHub Releases page for a newer version. It only reads the public release information;
/// nothing about you is sent.
enum UpdateChecker {
    static let repository = "t27124949-cell/notch-island"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    /// True when `latest` is a newer dotted version than `current` ("1.10" is newer than "1.9").
    static func isNewer(_ latest: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                .split(separator: ".")
                .map { Int($0.prefix(while: { $0.isNumber })) ?? 0 }
        }
        let a = parts(latest)
        let b = parts(current)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    static func check(_ done: @escaping (UpdateResult) -> Void) {
        guard let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest") else {
            done(.failed("Bad address"))
            return
        }
        let current = currentVersion
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("NotchIsland/\(current)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: request) { data, response, error in
            let result: UpdateResult
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if let error {
                result = .failed(error.localizedDescription)
            } else if status == 404 {
                result = .upToDate(current)   // no release published yet
            } else if !(200..<300).contains(status) {
                result = .failed("GitHub answered \(status)")
            } else if let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String {
                let page = (json["html_url"] as? String).flatMap { URL(string: $0) }
                    ?? URL(string: "https://github.com/\(repository)/releases")!
                let version = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                result = isNewer(version, than: current)
                    ? .available(version: version, pageURL: page)
                    : .upToDate(current)
            } else {
                result = .failed("Unexpected answer from GitHub")
            }
            DispatchQueue.main.async { done(result) }
        }.resume()
    }
}
