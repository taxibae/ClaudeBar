import Foundation
import CryptoKit

/// Access to the ChatGPT login that the Codex CLI stores, following Codex 0.141.0
/// (codex-rs/login/src/auth/storage.rs):
/// - CODEX_HOME, or ~/.codex when unset or empty.
/// - `cli_auth_credentials_store` in config.toml selects `file` (default), `keyring` or `auto`.
/// - The file is CODEX_HOME/auth.json. The Keychain item uses service "Codex Auth" and account
///   "cli|" + the first 16 hex characters of sha256(canonical CODEX_HOME), holding the same JSON.
/// Codex's encrypted "secrets" keyring backend and ephemeral mode are not supported.
struct CodexCredentialStore: CodexCredentialStoring {
    enum Mode: String, Sendable, Equatable {
        case file, keyring, auto
    }

    enum Source: Sendable, Equatable {
        case keychain
        case file
    }

    /// Raw JSON travels with the decoded tokens so unknown fields survive a write.
    struct Snapshot: Sendable, Equatable {
        let raw: Data
        let auth: CodexAuthFile?
        let source: Source

        var tokens: CodexTokens? { auth?.tokens }
    }

    enum StoreError: Error, Equatable {
        case unsupportedMode(String)
        case securityFailed(Int32)
        case fileWriteFailed(String)
    }

    static let keychainService = "Codex Auth"

    let codexHome: URL
    let keychainService: String
    let keychainAccount: String

    init(environment: [String: String] = ProcessInfo.processInfo.environment,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let path = environment["CODEX_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? home.appendingPathComponent(".codex").path
        self.init(codexHome: URL(fileURLWithPath: Self.canonicalPath(path)),
                  keychainService: Self.keychainService)
    }

    /// Lets tests use a temporary directory and a separate service name, never the user's item.
    init(codexHome: URL, keychainService: String) {
        self.codexHome = codexHome
        self.keychainService = keychainService
        keychainAccount = Self.keychainAccount(codexHome: codexHome.path)
    }

    // MARK: - Location

    /// Rust's `canonicalize` is realpath(3). Foundation's symlink resolution strips "/private",
    /// which would hash to a different Keychain account than Codex's.
    static func canonicalPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func keychainAccount(codexHome: String) -> String {
        let digest = SHA256.hash(data: Data(codexHome.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "cli|" + hex.prefix(16)
    }

    var authFilePath: URL {
        codexHome.appendingPathComponent("auth.json")
    }

    var configPath: URL {
        codexHome.appendingPathComponent("config.toml")
    }

    /// Reads only the top-level key; tables after the first header cannot set it.
    static func parseMode(config: String) throws -> Mode {
        for line in config.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("[") { break }
            guard let equals = trimmed.firstIndex(of: "="),
                  trimmed[..<equals].trimmingCharacters(in: .whitespaces) == "cli_auth_credentials_store"
            else { continue }
            var value = trimmed[trimmed.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if let comment = value.firstIndex(of: "#") {
                value = value[..<comment].trimmingCharacters(in: .whitespaces)
            }
            let unquoted = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard let mode = Mode(rawValue: unquoted) else { throw StoreError.unsupportedMode(unquoted) }
            return mode
        }
        return .file
    }

    func mode() throws -> Mode {
        guard let data = try? Data(contentsOf: configPath) else { return .file }
        return try Self.parseMode(config: String(decoding: data, as: UTF8.self))
    }

    // MARK: - Read

    func read() throws -> Snapshot? {
        switch try mode() {
        case .file:
            return readFile()
        case .keyring:
            return readKeychain()
        case .auto:
            return readKeychain() ?? readFile()
        }
    }

    private func makeSnapshot(_ data: Data, source: Source) -> Snapshot {
        Snapshot(raw: data, auth: try? JSONDecoder().decode(CodexAuthFile.self, from: data), source: source)
    }

    private func readKeychain() -> Snapshot? {
        SecurityTool.readGenericPassword(service: keychainService, accounts: [keychainAccount])
            .map { makeSnapshot($0, source: .keychain) }
    }

    private func readFile() -> Snapshot? {
        guard let data = try? Data(contentsOf: authFilePath), !data.isEmpty else { return nil }
        return makeSnapshot(data, source: .file)
    }

    // MARK: - Write

    func write(_ raw: Data, to source: Source) throws {
        switch source {
        case .keychain:
            let status = SecurityTool.writeGenericPassword(raw, service: keychainService, account: keychainAccount)
            guard status == 0 else { throw StoreError.securityFailed(status) }
        case .file:
            do {
                try raw.write(to: authFilePath, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: authFilePath.path)
            } catch {
                throw StoreError.fileWriteFailed(error.localizedDescription)
            }
        }
    }
}

/// The part of Codex's AuthDotJson that LLMBar needs. Writes go through CodexCredentialMerger.
struct CodexAuthFile: Codable, Equatable, Sendable {
    let tokens: CodexTokens?
    /// RFC 3339 UTC, possibly with nanoseconds
    let lastRefresh: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case lastRefresh = "last_refresh"
    }
}

struct CodexTokens: Codable, Equatable, Sendable {
    /// Raw JWT; Codex stores the original string
    let idToken: String?
    let accessToken: String
    let refreshToken: String?
    let accountID: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }

    private var idClaims: [String: Any]? {
        idToken.flatMap(JWT.claims)?["https://api.openai.com/auth"] as? [String: Any]
    }

    /// Codex sends tokens.account_id; older files may only carry it in the ID token.
    var resolvedAccountID: String? {
        accountID ?? idClaims?["chatgpt_account_id"] as? String
    }

    var planType: String? {
        idClaims?["chatgpt_plan_type"] as? String
    }

    var accessTokenExpiry: Date? {
        (JWT.claims(accessToken)?["exp"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
    }

    /// Unlike Codex's five-minute window, LLMBar refreshes only once the token has expired:
    /// Codex has no cross-process lock and rotates refresh tokens, so the early window is
    /// left to the running Codex process. Without a readable expiry, Codex's 8-day rule applies.
    func needsRefresh(lastRefresh: String?, now: Date = Date()) -> Bool {
        if let expiry = accessTokenExpiry { return expiry <= now }
        guard let refreshed = ISO8601.parse(lastRefresh) else { return false }
        return refreshed < now.addingTimeInterval(-8 * 24 * 3600)
    }
}

/// Reads claims without verifying the signature; the server remains the authority.
enum JWT {
    static func claims(_ token: String) -> [String: Any]? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = parts[1].replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}

/// Like Codex's persist_tokens: replace only the returned tokens and stamp last_refresh,
/// leaving every other field of the raw JSON untouched.
enum CodexCredentialMerger {
    enum MergeError: Error {
        case notAnObject
        case missingTokens
    }

    static func merge(raw: Data, response: CodexTokenRefreshResponse, refreshedAt: Date) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw MergeError.notAnObject
        }
        guard var tokens = root["tokens"] as? [String: Any] else {
            throw MergeError.missingTokens
        }
        if let value = response.idToken { tokens["id_token"] = value }
        if let value = response.accessToken { tokens["access_token"] = value }
        if let value = response.refreshToken { tokens["refresh_token"] = value }
        root["tokens"] = tokens

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        root["last_refresh"] = formatter.string(from: refreshedAt)
        return try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .withoutEscapingSlashes])
    }
}
