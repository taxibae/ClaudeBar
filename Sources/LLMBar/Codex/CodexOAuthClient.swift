import Foundation

/// Stateless client for ChatGPT's usage endpoint and OpenAI's token endpoint.
///
/// Constants and the refresh request follow Codex 0.141.0 (codex-rs/login/src/auth/manager.rs).
struct CodexOAuthClient: Sendable {
    static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    /// Codex's backend client falls back to this user agent
    static let userAgent = "codex-cli"
    /// Codex treats these refresh failures as permanent; any other code is transient unless the status is 401
    static let permanentRefreshCodes: Set<String> = [
        "refresh_token_expired", "refresh_token_reused", "refresh_token_invalidated"
    ]

    enum FetchResult: Sendable, Equatable {
        case success(Data)
        case unauthorized
        case rateLimited
        case failure(String)
    }

    enum RefreshError: Error, Equatable {
        /// The refresh token can never succeed again; only `codex login` helps
        case permanent
        /// Network, server or decode failure; the next poll may succeed
        case transient
    }

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func fetchUsage(token: String, accountID: String?) async -> FetchResult {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let accountID {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 10

        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            switch status {
            case 200: return .success(data)
            case 401: return .unauthorized
            case 429: return .rateLimited
            default: return .failure(L("error.http", status))
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func refresh(refreshToken: String) async throws -> CodexTokenRefreshResponse {
        let body = [
            "client_id": Self.clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
        ]
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(body)
        request.timeoutInterval = 30

        let data: Data
        let status: Int
        do {
            let (received, response) = try await session.data(for: request)
            data = received
            status = (response as? HTTPURLResponse)?.statusCode ?? 0
        } catch {
            throw RefreshError.transient
        }

        guard status == 200 else { throw Self.refreshFailure(status: status, body: data) }
        guard let response = try? JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data) else {
            throw RefreshError.transient
        }
        return response
    }

    /// The code may arrive as error.code, a string error, or a top-level code.
    static func refreshFailure(status: Int, body: Data) -> RefreshError {
        if status == 401 { return .permanent }
        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return .transient }
        let code = ((root["error"] as? [String: Any])?["code"] as? String)
            ?? root["error"] as? String
            ?? root["code"] as? String
        return code.map(permanentRefreshCodes.contains) == true ? .permanent : .transient
    }
}

struct CodexTokenRefreshResponse: Codable, Equatable, Sendable {
    let idToken: String?
    let accessToken: String?
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case idToken = "id_token"
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
    }
}
