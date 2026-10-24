import Foundation

// MARK: - Dot paths into a JSON response

enum JSONPath {
    static func value(_ path: String, in root: Any) -> Any? {
        var current: Any? = root
        for part in path.split(separator: ".") {
            guard let node = current else { return nil }
            if let dictionary = node as? [String: Any] {
                current = dictionary[String(part)]
            } else if let array = node as? [Any],
                      let index = Int(part),
                      array.indices.contains(index) {
                current = array[index]
            } else {
                return nil
            }
        }
        return current
    }

    static func number(_ path: String, in root: Any) -> Double? {
        switch value(path, in: root) {
        case let number as NSNumber: return number.doubleValue
        case let string as String: return Double(string)
        default: return nil
        }
    }

    static func string(_ path: String, in root: Any) -> String? {
        value(path, in: root) as? String
    }
}

// MARK: - Where the key lives

/// Resolved in order: `TOKENMETER_API_KEY`, the provider's env var, then a file
/// read fresh on every refresh. Nothing is written or cached.
struct KeyRef: Codable, Hashable {
    var env: String?
    var file: String?
    /// Dot path inside the file. With no path the whole file is the key.
    var jsonPath: String?

    func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        if let generic = environment["TOKENMETER_API_KEY"], !generic.isEmpty {
            return generic
        }

        if let env, let value = environment[env], !value.isEmpty {
            return value
        }

        guard let file, !file.isEmpty else { return nil }
        let url: URL
        if file.hasPrefix("~/") {
            url = home.appending(path: String(file.dropFirst(2)))
        } else {
            url = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
        }
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let jsonPath {
            guard let root = try? JSONSerialization.jsonObject(with: data),
                  let value = JSONPath.string(jsonPath, in: root),
                  !value.isEmpty else { return nil }
            return value
        }

        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    mutating func merge(_ override: KeyRef) {
        if let env = override.env { self.env = env }
        if let file = override.file { self.file = file }
        if let jsonPath = override.jsonPath { self.jsonPath = jsonPath }
    }
}

// MARK: - Reading a balance

struct BalanceSpec: Codable, Hashable {
    var url: String
    var method: String = "GET"
    /// `{key}` is replaced with the resolved key. `{}` sends no auth at all.
    var headers: [String: String]?
    var valuePath: String
    /// Subtracted from `valuePath` when a provider reports credit and usage
    /// separately (OpenRouter does).
    var subtractPath: String?
    var currencyPath: String?
    var currency: String = "USD"

    init(
        url: String,
        method: String = "GET",
        headers: [String: String]? = nil,
        valuePath: String,
        subtractPath: String? = nil,
        currencyPath: String? = nil,
        currency: String = "USD"
    ) {
        self.url = url
        self.method = method
        self.headers = headers
        self.valuePath = valuePath
        self.subtractPath = subtractPath
        self.currencyPath = currencyPath
        self.currency = currency
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decode(String.self, forKey: .url)
        valuePath = try container.decode(String.self, forKey: .valuePath)
        method = try container.decodeIfPresent(String.self, forKey: .method) ?? "GET"
        headers = try container.decodeIfPresent([String: String].self, forKey: .headers)
        subtractPath = try container.decodeIfPresent(String.self, forKey: .subtractPath)
        currencyPath = try container.decodeIfPresent(String.self, forKey: .currencyPath)
        currency = try container.decodeIfPresent(String.self, forKey: .currency) ?? "USD"
    }
}

struct Provider: Codable, Hashable {
    var name: String
    var key: KeyRef
    var balance: BalanceSpec?

    mutating func merge(_ override: ProviderOverride?) {
        guard let override else { return }
        if let name = override.name { self.name = name }
        if let key = override.key { self.key.merge(key) }
        if override.disablesBalance {
            balance = nil
        } else if let balance = override.balance {
            self.balance = balance
        }
    }
}

struct ProviderOverride: Decodable {
    var name: String?
    var key: KeyRef?
    var balance: BalanceSpec?
    /// `"balance": null` removes the preset's endpoint; an absent key keeps it.
    var disablesBalance = false

    private enum CodingKeys: String, CodingKey {
        case name, key, balance
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        key = try container.decodeIfPresent(KeyRef.self, forKey: .key)
        disablesBalance = container.contains(.balance)
        balance = try container.decodeIfPresent(BalanceSpec.self, forKey: .balance)
    }
}

// MARK: - Presets

struct Preset {
    var provider: Provider
    var pricing: Pricing

    static let deepSeek = Preset(
        provider: Provider(
            name: "DeepSeek",
            key: KeyRef(env: "DEEPSEEK_API_KEY", file: "~/.claude/settings.json", jsonPath: "env.ANTHROPIC_AUTH_TOKEN"),
            balance: BalanceSpec(
                url: "https://api.deepseek.com/user/balance",
                headers: ["Authorization": "Bearer {key}"],
                valuePath: "balance_infos.0.total_balance",
                currencyPath: "balance_infos.0.currency",
                currency: "USD"
            )
        ),
        pricing: .deepSeek
    )

    static let openRouter = Preset(
        provider: Provider(
            name: "OpenRouter",
            key: KeyRef(env: "OPENROUTER_API_KEY", file: "~/.claude/settings.json", jsonPath: "env.ANTHROPIC_AUTH_TOKEN"),
            balance: BalanceSpec(
                url: "https://openrouter.ai/api/v1/credits",
                headers: ["Authorization": "Bearer {key}", "X-Title": "Token Meter"],
                valuePath: "data.total_credits",
                subtractPath: "data.total_usage",
                currency: "USD"
            )
        ),
        pricing: Pricing()
    )

    static let moonshotCN = Preset(
        provider: Provider(
            name: "Moonshot",
            key: KeyRef(env: "MOONSHOT_API_KEY", file: "~/.claude/settings.json", jsonPath: "env.ANTHROPIC_AUTH_TOKEN"),
            balance: BalanceSpec(
                url: "https://api.moonshot.cn/v1/users/me/balance",
                headers: ["Authorization": "Bearer {key}"],
                valuePath: "data.available_balance",
                currency: "CNY"
            )
        ),
        pricing: Pricing()
    )

    static let moonshotInternational = Preset(
        provider: Provider(
            name: "Moonshot",
            key: KeyRef(env: "MOONSHOT_API_KEY", file: "~/.claude/settings.json", jsonPath: "env.ANTHROPIC_AUTH_TOKEN"),
            balance: BalanceSpec(
                url: "https://api.moonshot.ai/v1/users/me/balance",
                headers: ["Authorization": "Bearer {key}"],
                valuePath: "data.available_balance",
                currency: "USD"
            )
        ),
        pricing: Pricing()
    )

    /// No balance endpoint: the widget shows today's spend instead.
    static let custom = Preset(
        provider: Provider(
            name: "Custom",
            key: KeyRef(env: "TOKENMETER_API_KEY", file: "~/.claude/settings.json", jsonPath: "env.ANTHROPIC_AUTH_TOKEN"),
            balance: nil
        ),
        pricing: Pricing()
    )
}

enum Presets {
    /// Picks a preset from the endpoint Claude Code is already pointed at, so a
    /// fresh install usually needs no configuration at all.
    static func detect(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Preset {
        let base = baseURL(environment: environment, home: home) ?? ""
        let host = (URL(string: base)?.host ?? base).lowercased()

        if host.contains("deepseek") { return .deepSeek }
        if host.contains("openrouter") { return .openRouter }
        if host.contains("moonshot.cn") { return .moonshotCN }
        if host.contains("moonshot") { return host.contains(".ai") ? .moonshotInternational : .moonshotCN }
        return .custom
    }

    static func baseURL(
        environment: [String: String],
        home: URL
    ) -> String? {
        if let direct = environment["ANTHROPIC_BASE_URL"], !direct.isEmpty { return direct }
        if let direct = environment["TOKENMETER_BASE_URL"], !direct.isEmpty { return direct }

        let settings = home.appending(path: ".claude/settings.json")
        guard let data = try? Data(contentsOf: settings),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let env = root["env"] as? [String: Any],
              let base = env["ANTHROPIC_BASE_URL"] as? String,
              !base.isEmpty else { return nil }
        return base
    }
}

// MARK: - The one network call

enum BalanceClient {
    static func fetch(_ provider: Provider, key: String) async throws -> Balance {
        guard let spec = provider.balance,
              let url = URL(string: spec.url) else { throw MeterError.noProvider }

        var request = URLRequest(url: url)
        request.httpMethod = spec.method
        request.timeoutInterval = 15

        let headers = spec.headers ?? ["Authorization": "Bearer {key}"]
        for (name, value) in headers {
            request.setValue(
                value.replacingOccurrences(of: "{key}", with: key),
                forHTTPHeaderField: name
            )
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw MeterError.badResponse }
        guard http.statusCode == 200 else { throw MeterError.status(http.statusCode) }

        guard let root = try? JSONSerialization.jsonObject(with: data),
              let value = JSONPath.number(spec.valuePath, in: root) else {
            throw MeterError.badResponse
        }

        var total = value
        if let subtract = spec.subtractPath {
            guard let used = JSONPath.number(subtract, in: root) else { throw MeterError.badResponse }
            total -= used
        }

        let currency = spec.currencyPath.flatMap { JSONPath.string($0, in: root) } ?? spec.currency
        return Balance(total: total, granted: 0, toppedUp: 0, currency: currency, fetchedAt: .now)
    }
}

enum MeterError: LocalizedError {
    case badResponse
    case status(Int)
    case noToken
    case noProvider

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected balance response"
        case .status(let code): return "Balance API returned \(code)"
        case .noToken: return "No API key found (see Configuration)"
        case .noProvider: return "This provider has no balance endpoint"
        }
    }
}
