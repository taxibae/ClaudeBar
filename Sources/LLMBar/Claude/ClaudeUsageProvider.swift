import Foundation

/// Claude adapter: owns credentials, coordinated token refresh, HTTP access, and decoding.
/// The refresh protocol is unchanged from the original UsageService.
@MainActor
final class ClaudeUsageProvider: UsageProvider {
    private let store: any ClaudeCredentialStoring
    private let client: any ClaudeOAuthFetching
    private var deadRefreshToken: String?
    private(set) var planType: String?

    init(store: any ClaudeCredentialStoring = ClaudeCredentialStore(),
         client: any ClaudeOAuthFetching = ClaudeOAuthClient()) {
        self.store = store
        self.client = client
    }

    private func decode(_ data: Data) throws -> UsageSnapshot {
        do {
            let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
            return ClaudeUsageAdapter.snapshot(from: response)
        } catch {
            throw UsageProviderError(message: L("error.parse"))
        }
    }

    func fetchUsage() async throws -> UsageSnapshot {
        guard let snapshot = await readCredentials() else {
            throw UsageProviderError(message: L("error.not_logged_in"))
        }
        guard let oauth = snapshot.oauth else {
            throw UsageProviderError(message: L("error.no_access_token"))
        }

        planType = ClaudePlanBadge.text(subscriptionType: oauth.subscriptionType, rateLimitTier: oauth.rateLimitTier)

        // Süresi dolmak üzereyse boşa 401 yemek yerine önce yenile
        var token = oauth.accessToken
        if oauth.isExpiringSoon() {
            let fresh = try await freshToken(replacing: snapshot)
            token = fresh
        }

        switch await client.fetchUsage(token: token) {
        case .success(let data):
            return try decode(data)

        case .unauthorized:
            // expiresAt güncel olmasa da sunucu reddettiyse yenile ve bir kez daha dene
            let fresh = try await freshToken(replacing: snapshot)
            if case .success(let data) = await client.fetchUsage(token: fresh) {
                return try decode(data)
            } else {
                throw UsageProviderError(message: L("error.request_failed"))
            }

        case .failure(let message):
            throw UsageProviderError(message: message)
        }
    }

    // MARK: - Token Refresh

    /// Yarış güvenli token yenileme. Claude Code'un kendi akışıyla aynı adımlar:
    /// 1. Yenileme kilidini al (~/.claude.lock). Alınamazsa Claude Code büyük olasılıkla şu an yeniliyor.
    /// 2. Depoyu yeniden oku. Token bu arada değiştiyse başkası yenilemiştir, onu kullan ve çık.
    /// 3. Değişmediyse refresh token ile yenile, sonucu ham JSON'a işleyip depoya yaz.
    private func freshToken(replacing stale: ClaudeCredentialStore.Snapshot) async throws -> String {
        let lock = DirectoryLock(path: store.refreshLockPath)
        let locked = await lock.acquire(retries: 5, minDelay: 1.0, maxDelay: 2.0)
        defer { if locked { lock.release() } }

        guard let current = await readCredentials(), let oauth = current.oauth else {
            throw UsageProviderError(message: L("error.not_logged_in"))
        }
        if oauth.accessToken != stale.oauth?.accessToken, !oauth.isExpiringSoon() {
            return oauth.accessToken
        }
        guard locked else {
            throw UsageProviderError(message: L("error.refresh_in_progress"))
        }
        guard let refreshToken = oauth.refreshToken else {
            throw UsageProviderError(message: L("error.no_refresh_token"))
        }
        guard refreshToken != deadRefreshToken else {
            throw UsageProviderError(message: L("error.login_required"))
        }

        let stored = oauth.scopes ?? []
        do {
            let response: ClaudeTokenRefreshResponse
            do {
                let scopes = stored.isEmpty ? ClaudeOAuthClient.defaultScopes : ClaudeOAuthClient.mergedScopes(stored: stored)
                response = try await client.refresh(refreshToken: refreshToken, scopes: scopes)
            } catch ClaudeOAuthClient.RefreshError.invalidScope where !stored.isEmpty {
                // Birleştirilmiş küme reddedildiyse token'ın verildiği scope'larla yeniden dene
                response = try await client.refresh(refreshToken: refreshToken, scopes: stored)
            }

            let expiresAt = Date().addingTimeInterval(TimeInterval(response.expiresIn ?? 3600))
            let merged = try ClaudeCredentialMerger.merge(
                raw: current.raw,
                accessToken: response.accessToken,
                refreshToken: response.refreshToken ?? refreshToken,
                expiresAt: expiresAt
            )
            try await writeCredentials(merged, to: current.source)
            return response.accessToken
        } catch ClaudeOAuthClient.RefreshError.invalidGrant {
            deadRefreshToken = refreshToken
            throw UsageProviderError(message: L("error.login_required"))
        } catch {
            throw UsageProviderError(message: L("error.token_refresh_failed"))
        }
    }

    // MARK: - Credential I/O

    /// `security` süreci ana iş parçacığını kilitlemesin diye okuma arka planda yapılır
    private func readCredentials() async -> ClaudeCredentialStore.Snapshot? {
        let store = self.store
        return await Task.detached(priority: .userInitiated) { store.read() }.value
    }

    /// Yazma, Claude Code'un depo kilidi altında yapılır; kilit alınamazsa yazılmaz,
    /// çünkü yarım kalmış bir Claude Code yazmasının üzerine binmek kaydı bozabilir.
    private func writeCredentials(_ raw: Data, to source: ClaudeCredentialStore.Source) async throws {
        let lock = DirectoryLock(path: store.storageLockPath)
        let locked = await lock.acquire(retries: 10, minDelay: 0.1, maxDelay: 1.0)
        guard locked else { throw ClaudeCredentialStore.StoreError.fileWriteFailed("storage lock busy") }
        defer { lock.release() }

        let store = self.store
        try await Task.detached(priority: .userInitiated) { try store.write(raw, to: source) }.value
    }
}

/// Injectable I/O boundaries let refresh regressions run without real accounts or HTTP.
protocol ClaudeCredentialStoring: Sendable {
    var refreshLockPath: URL { get }
    var storageLockPath: URL { get }
    func read() -> ClaudeCredentialStore.Snapshot?
    func write(_ raw: Data, to source: ClaudeCredentialStore.Source) throws
}

extension ClaudeCredentialStore: ClaudeCredentialStoring {}

protocol ClaudeOAuthFetching: Sendable {
    func fetchUsage(token: String) async -> ClaudeOAuthClient.FetchResult
    func refresh(refreshToken: String, scopes: [String]) async throws -> ClaudeTokenRefreshResponse
}

extension ClaudeOAuthClient: ClaudeOAuthFetching {}
