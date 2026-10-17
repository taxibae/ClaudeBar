import XCTest
@testable import ClaudeBar

@MainActor
final class ClaudeUsageProviderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func credentials(token: String = "old", expired: Bool = false, refreshToken: String? = "refresh") throws -> CredentialStore.Snapshot {
        var oauth: [String: Any] = [
            "accessToken": token,
            "expiresAt": Date().addingTimeInterval(expired ? -60 : 3600).timeIntervalSince1970 * 1000,
            "scopes": ["user:inference"], "subscriptionType": "max",
            "rateLimitTier": "default_claude_max_5x", "futureField": "preserved"
        ]
        oauth["refreshToken"] = refreshToken
        let data = try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth, "unrelated": "keep"])
        return CredentialStore.Snapshot(
            raw: data, oauth: try JSONDecoder().decode(KeychainCredentials.self, from: data).claudeAiOauth,
            source: .plaintextFile
        )
    }

    private func store(_ snapshots: [CredentialStore.Snapshot?]) -> StubCredentialStore {
        StubCredentialStore(directory: directory, snapshots: snapshots)
    }

    func testValidTokenFetchesWithoutRefreshAndMapsUsageAndPlan() async throws {
        let store = store([try credentials()])
        let client = StubClaudeOAuth()
        let provider = ClaudeUsageProvider(store: store, client: client)
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.menuBarPercent, 42)
        XCTAssertEqual(provider.planType, "Max 5x")
        let tokens = await client.fetchedTokens
        let calls = await client.refreshScopes
        XCTAssertEqual(tokens, ["old"])
        XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testExpiringTokenRefreshesUnderLocksAndPreservesCredentialFields() async throws {
        let store = store([try credentials(expired: true)])
        let client = StubClaudeOAuth()
        _ = try await ClaudeUsageProvider(store: store, client: client).fetchUsage()
        XCTAssertEqual(store.writes.count, 1)
        XCTAssertTrue(store.wroteUnderBothLocks)
        let written = try XCTUnwrap(store.writes.first)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: written) as? [String: Any])
        let oauth = try XCTUnwrap(root["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["accessToken"] as? String, "new")
        XCTAssertEqual(oauth["refreshToken"] as? String, "rotated")
        XCTAssertEqual(oauth["futureField"] as? String, "preserved")
        XCTAssertEqual(root["unrelated"] as? String, "keep")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.refreshLockPath.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.storageLockPath.path))
        let tokens = await client.fetchedTokens
        let scopes = await client.refreshScopes
        XCTAssertEqual(tokens, ["new"])
        XCTAssertEqual(scopes, [OAuthClient.defaultScopes])
    }

    func testUnauthorizedRefreshesAndRetriesUsageExactlyOnce() async throws {
        let client = StubClaudeOAuth(fetches: [.unauthorized, .success(Data("{}".utf8))])
        _ = try await ClaudeUsageProvider(store: store([try credentials()]), client: client).fetchUsage()
        let tokens = await client.fetchedTokens
        XCTAssertEqual(tokens, ["old", "new"])
    }

    func testRateLimitedUsageStopsAfterOneFetchWithoutRefreshingToken() async throws {
        let store = store([try credentials()])
        let client = StubClaudeOAuth(fetches: [.failure("HTTP 429")])
        let provider = ClaudeUsageProvider(store: store, client: client)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected rate limit")
        } catch {
            XCTAssertEqual(error.localizedDescription, "HTTP 429")
        }
        let tokens = await client.fetchedTokens
        let refreshes = await client.refreshScopes
        XCTAssertEqual(tokens, ["old"])
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testFailedUnauthorizedRetryKeepsOriginalErrorAndStopsRetrying() async throws {
        let client = StubClaudeOAuth(fetches: [.unauthorized, .unauthorized])
        let provider = ClaudeUsageProvider(store: store([try credentials()]), client: client)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected failed retry")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("error.request_failed"))
        }
        let tokens = await client.fetchedTokens
        XCTAssertEqual(tokens, ["old", "new"])
    }

    func testConcurrentClaudeCodeRefreshReusesNewTokenWithoutRotatingAgain() async throws {
        let store = store([try credentials(expired: true), try credentials(token: "from-claude-code")])
        let client = StubClaudeOAuth()
        _ = try await ClaudeUsageProvider(store: store, client: client).fetchUsage()
        let tokens = await client.fetchedTokens
        let scopes = await client.refreshScopes
        XCTAssertEqual(tokens, ["from-claude-code"])
        XCTAssertTrue(scopes.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testInvalidScopeFallsBackToStoredScopes() async throws {
        let client = StubClaudeOAuth(refreshes: [.failure(.invalidScope), .success(StubClaudeOAuth.refreshed)])
        _ = try await ClaudeUsageProvider(store: store([try credentials(expired: true)]), client: client).fetchUsage()
        let scopes = await client.refreshScopes
        XCTAssertEqual(scopes, [OAuthClient.defaultScopes, ["user:inference"]])
    }

    func testInvalidGrantIsNotRetriedOnEveryPoll() async throws {
        let client = StubClaudeOAuth(refreshes: [.failure(.invalidGrant)])
        let provider = ClaudeUsageProvider(store: store([try credentials(expired: true)]), client: client)
        for _ in 0..<2 {
            do {
                _ = try await provider.fetchUsage()
                XCTFail("Expected invalid grant")
            } catch {
                XCTAssertEqual(error.localizedDescription, L("error.login_required"))
            }
        }
        let scopes = await client.refreshScopes
        XCTAssertEqual(scopes.count, 1)
    }

    func testMissingCredentialsAndMissingOAuthPreserveOriginalErrors() async throws {
        let malformed = CredentialStore.Snapshot(raw: Data("{}".utf8), oauth: nil, source: .plaintextFile)
        for (snapshot, key): (CredentialStore.Snapshot?, String) in [(nil, "error.not_logged_in"), (malformed, "error.no_access_token")] {
            let client = StubClaudeOAuth()
            do {
                _ = try await ClaudeUsageProvider(store: store([snapshot]), client: client).fetchUsage()
                XCTFail("Expected missing credentials")
            } catch {
                XCTAssertEqual(error.localizedDescription, L(key))
            }
            let tokens = await client.fetchedTokens
            XCTAssertTrue(tokens.isEmpty)
        }
    }

    func testMissingRefreshTokenDoesNotCallRefreshEndpoint() async throws {
        let client = StubClaudeOAuth()
        let provider = ClaudeUsageProvider(store: store([try credentials(expired: true, refreshToken: nil)]), client: client)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected missing refresh token")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("error.no_refresh_token"))
        }
        let scopes = await client.refreshScopes
        XCTAssertTrue(scopes.isEmpty)
    }

    func testTransportAndParseErrorsStillExposePlan() async throws {
        for (reply, message): (OAuthClient.FetchResult, String) in [
            (.failure("network unavailable"), "network unavailable"),
            (.success(Data("invalid json".utf8)), L("error.parse"))
        ] {
            let provider = ClaudeUsageProvider(store: store([try credentials()]), client: StubClaudeOAuth(fetches: [reply]))
            do {
                _ = try await provider.fetchUsage()
                XCTFail("Expected fetch failure")
            } catch {
                XCTAssertEqual(error.localizedDescription, message)
                XCTAssertEqual(provider.planType, "Max 5x")
            }
        }
    }

    func testMissingCredentialsAfterSuccessDoesNotClearLastKnownPlan() async throws {
        let provider = ClaudeUsageProvider(store: store([try credentials(), nil]), client: StubClaudeOAuth())
        _ = try await provider.fetchUsage()
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected missing credentials")
        } catch {
            XCTAssertEqual(error.localizedDescription, L("error.not_logged_in"))
        }
        XCTAssertEqual(provider.planType, "Max 5x")
    }
}

/// Test-only storage with real temporary lock directories, never the user's Keychain.
private final class StubCredentialStore: ClaudeCredentialStoring, @unchecked Sendable {
    let refreshLockPath: URL
    let storageLockPath: URL
    private let lock = NSLock()
    private var snapshots: [CredentialStore.Snapshot?]
    private var recordedWrites: [Data] = []
    private var lockedWrites = false

    init(directory: URL, snapshots: [CredentialStore.Snapshot?]) {
        refreshLockPath = directory.appendingPathComponent("refresh.lock")
        storageLockPath = directory.appendingPathComponent("write.lock")
        self.snapshots = snapshots
    }

    var writes: [Data] { lock.withLock { recordedWrites } }
    var wroteUnderBothLocks: Bool { lock.withLock { lockedWrites } }

    func read() -> CredentialStore.Snapshot? {
        lock.withLock {
            if snapshots.count > 1 { return snapshots.removeFirst() }
            return snapshots.first ?? nil
        }
    }

    func write(_ raw: Data, to source: CredentialStore.Source) throws {
        try lock.withLock {
            recordedWrites.append(raw)
            lockedWrites = FileManager.default.fileExists(atPath: refreshLockPath.path)
                && FileManager.default.fileExists(atPath: storageLockPath.path)
            let oauth = try JSONDecoder().decode(KeychainCredentials.self, from: raw).claudeAiOauth
            snapshots = [CredentialStore.Snapshot(raw: raw, oauth: oauth, source: source)]
        }
    }
}

private actor StubClaudeOAuth: ClaudeOAuthFetching {
    static let refreshed = TokenRefreshResponse(accessToken: "new", refreshToken: "rotated", expiresIn: 3600, scope: nil)
    private var fetches: [OAuthClient.FetchResult]
    private var refreshes: [Result<TokenRefreshResponse, OAuthClient.RefreshError>]
    private(set) var fetchedTokens: [String] = []
    private(set) var refreshScopes: [[String]] = []

    init(fetches: [OAuthClient.FetchResult] = [.success(Data("{\"five_hour\":{\"utilization\":42}}".utf8))],
         refreshes: [Result<TokenRefreshResponse, OAuthClient.RefreshError>] = [.success(refreshed)]) {
        self.fetches = fetches
        self.refreshes = refreshes
    }

    func fetchUsage(token: String) async -> OAuthClient.FetchResult {
        fetchedTokens.append(token)
        return fetches.removeFirst()
    }

    func refresh(refreshToken: String, scopes: [String]) async throws -> TokenRefreshResponse {
        refreshScopes.append(scopes)
        return try refreshes.removeFirst().get()
    }
}
