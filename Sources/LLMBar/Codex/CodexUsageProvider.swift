import Foundation

/// Codex adapter: owns the stored ChatGPT login, token refresh, HTTP access, and decoding.
/// Refresh mirrors Codex's guarded reload: re-read the store, use a token another process
/// already rotated, refuse when the account changed, and never retry a permanently failed token.
/// Duplicate refreshes inside LLMBar are prevented by ProviderUsageState's loading guard;
/// there is no lock shared with separate Codex processes.
@MainActor
final class CodexUsageProvider: UsageProvider {
    private let store: any CodexCredentialStoring
    private let client: any CodexOAuthFetching
    private let now: @Sendable () -> Date
    private var deadRefreshToken: String?
    private(set) var planType: String?

    init(store: any CodexCredentialStoring = CodexCredentialStore(),
         client: any CodexOAuthFetching = CodexOAuthClient(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.client = client
        self.now = now
    }

    private func decode(_ data: Data) throws -> UsageSnapshot {
        do {
            let response = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
            if let plan = CodexUsageAdapter.planBadge(response.planType) { planType = plan }
            return CodexUsageAdapter.snapshot(from: response)
        } catch {
            throw UsageProviderError(message: L("error.parse"))
        }
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let snapshot = try await readCredentials() else {
            throw UsageProviderError(message: L("error.not_logged_in"))
        }
        guard var tokens = snapshot.tokens else {
            throw UsageProviderError(message: L("error.no_access_token"))
        }
        if let plan = CodexUsageAdapter.planBadge(tokens.planType) { planType = plan }

        if tokens.needsRefresh(lastRefresh: snapshot.auth?.lastRefresh, now: now()) {
            tokens = try await freshTokens(replacing: snapshot)
        }

        switch await client.fetchUsage(token: tokens.accessToken, accountID: tokens.resolvedAccountID) {
        case .success(let data):
            return try decode(data)

        case .unauthorized:
            // Rejected despite a valid-looking expiry: reload or refresh, then retry exactly once
            let fresh = try await freshTokens(replacing: snapshot)
            switch await client.fetchUsage(token: fresh.accessToken, accountID: fresh.resolvedAccountID) {
            case .success(let data): return try decode(data)
            case .rateLimited: throw UsageProviderError(message: L("error.codex_rate_limited"))
            default: throw UsageProviderError(message: L("error.request_failed"))
            }

        case .rateLimited:
            // No refresh or immediate retry; the last snapshot stays and the next poll recovers
            throw UsageProviderError(message: L("error.codex_rate_limited"))

        case .failure(let message):
            throw UsageProviderError(message: message)
        }
    }

    // MARK: - Token Refresh

    private func freshTokens(replacing stale: CodexCredentialStore.Snapshot) async throws -> CodexTokens {
        guard let current = try await readCredentials(), let tokens = current.tokens else {
            throw UsageProviderError(message: L("error.not_logged_in"))
        }
        if let expected = stale.tokens?.resolvedAccountID, tokens.resolvedAccountID != expected {
            throw UsageProviderError(message: L("error.codex_account_changed"))
        }
        // Another Codex process rotated the token after our first read
        if tokens.accessToken != stale.tokens?.accessToken,
           !tokens.needsRefresh(lastRefresh: current.auth?.lastRefresh, now: now()) {
            return tokens
        }
        guard let refreshToken = tokens.refreshToken else {
            throw UsageProviderError(message: L("error.no_refresh_token"))
        }
        guard refreshToken != deadRefreshToken else {
            throw UsageProviderError(message: L("error.codex_login_required"))
        }

        let response: CodexTokenRefreshResponse
        do {
            response = try await client.refresh(refreshToken: refreshToken)
        } catch CodexOAuthClient.RefreshError.permanent {
            deadRefreshToken = refreshToken
            throw UsageProviderError(message: L("error.codex_login_required"))
        } catch {
            throw UsageProviderError(message: L("error.token_refresh_failed"))
        }

        do {
            let merged = try CodexCredentialMerger.merge(raw: current.raw, response: response, refreshedAt: now())
            try await writeCredentials(merged, to: current.source)
            return try JSONDecoder().decode(CodexAuthFile.self, from: merged).tokens ?? tokens
        } catch {
            throw UsageProviderError(message: L("error.token_refresh_failed"))
        }
    }

    // MARK: - Credential I/O

    /// Keychain access spawns `security`; keep it off the main thread
    private func readCredentials() async throws -> CodexCredentialStore.Snapshot? {
        let store = self.store
        do {
            return try await Task.detached(priority: .userInitiated) { try store.read() }.value
        } catch {
            throw UsageProviderError(message: L("error.codex_unsupported_storage"))
        }
    }

    private func writeCredentials(_ raw: Data, to source: CodexCredentialStore.Source) async throws {
        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.write(raw, to: source) }.value
    }
}

/// Injectable I/O boundaries let refresh regressions run without real accounts or HTTP.
protocol CodexCredentialStoring: Sendable {
    func read() throws -> CodexCredentialStore.Snapshot?
    func write(_ raw: Data, to source: CodexCredentialStore.Source) throws
}

protocol CodexOAuthFetching: Sendable {
    func fetchUsage(token: String, accountID: String?) async -> CodexOAuthClient.FetchResult
    func refresh(refreshToken: String) async throws -> CodexTokenRefreshResponse
}

extension CodexOAuthClient: CodexOAuthFetching {}
