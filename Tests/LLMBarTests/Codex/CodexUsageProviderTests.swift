import XCTest
@testable import LLMBar

@MainActor
final class CodexUsageProviderTests: XCTestCase {
    private func credentials(_ name: String = "old", expiresIn: TimeInterval = 3600, refreshToken: String? = "refresh",
                             accountID: String = "acct") throws -> CodexCredentialStore.Snapshot {
        let raw = try codexAuthJSON(accessToken: codexAccessToken(name, expiresIn: expiresIn),
                                    refreshToken: refreshToken, accountID: accountID)
        return CodexCredentialStore.Snapshot(
            raw: raw, auth: try JSONDecoder().decode(CodexAuthFile.self, from: raw), source: .file
        )
    }

    private func fetch(_ provider: CodexUsageProvider, expecting key: String,
                       file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await provider.fetchUsage()
            XCTFail("Expected \(key)", file: file, line: line)
        } catch {
            XCTAssertEqual(error.localizedDescription, L(key), file: file, line: line)
        }
    }

    func testValidTokenFetchesWithAccountHeaderWithoutRefreshing() async throws {
        let store = StubCodexStore([try credentials()])
        let client = StubCodexOAuth()
        let provider = CodexUsageProvider(store: store, client: client)
        let usage = try await provider.fetchUsage()
        XCTAssertEqual(usage.menuBarPercent, 32)
        XCTAssertEqual(provider.planType, "Pro", "The usage response's plan wins over the ID token claim")
        let fetches = await client.fetches
        let refreshes = await client.refreshTokens
        XCTAssertEqual(fetches.map(\.name), ["old"])
        XCTAssertEqual(fetches.map(\.accountID), ["acct"])
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testTokenNearExpiryIsLeftToCodex() async throws {
        let client = StubCodexOAuth()
        _ = try await CodexUsageProvider(store: StubCodexStore([try credentials(expiresIn: 120)]), client: client).fetchUsage()
        let refreshes = await client.refreshTokens
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testExpiredTokenRefreshesAndMergesIntoTheSourceStore() async throws {
        let store = StubCodexStore([try credentials(expiresIn: -60)])
        let client = StubCodexOAuth()
        _ = try await CodexUsageProvider(store: store, client: client).fetchUsage()
        let refreshes = await client.refreshTokens
        let fetches = await client.fetches
        XCTAssertEqual(refreshes, ["refresh"])
        XCTAssertEqual(fetches.map(\.name), ["new"])
        XCTAssertEqual(store.writes.count, 1)
        XCTAssertEqual(store.writeSources, [.file])
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(store.writes.first)) as? [String: Any])
        let tokens = try XCTUnwrap(root["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["refresh_token"] as? String, "rotated")
        XCTAssertEqual(tokens["futureTokenField"] as? String, "preserved")
        XCTAssertNotNil(ISO8601.parse(root["last_refresh"] as? String))
    }

    func testUnauthorizedReusesTokenRotatedByCodexWithoutRefreshing() async throws {
        let store = StubCodexStore([try credentials(), try credentials("from-codex")])
        let client = StubCodexOAuth(fetches: [.unauthorized, StubCodexOAuth.usage])
        _ = try await CodexUsageProvider(store: store, client: client).fetchUsage()
        let fetches = await client.fetches
        let refreshes = await client.refreshTokens
        XCTAssertEqual(fetches.map(\.name), ["old", "from-codex"])
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testUnauthorizedRefreshesAndRetriesExactlyOnce() async throws {
        let client = StubCodexOAuth(fetches: [.unauthorized, .unauthorized])
        let provider = CodexUsageProvider(store: StubCodexStore([try credentials()]), client: client)
        await fetch(provider, expecting: "error.request_failed")
        let fetches = await client.fetches
        let refreshes = await client.refreshTokens
        XCTAssertEqual(fetches.map(\.name), ["old", "new"])
        XCTAssertEqual(refreshes, ["refresh"])
    }

    func testPermanentRefreshFailureIsNotRetriedOnEveryPoll() async throws {
        let client = StubCodexOAuth(refreshes: [.failure(.permanent)])
        let provider = CodexUsageProvider(store: StubCodexStore([try credentials(expiresIn: -60)]), client: client)
        await fetch(provider, expecting: "error.codex_login_required")
        await fetch(provider, expecting: "error.codex_login_required")
        let refreshes = await client.refreshTokens
        XCTAssertEqual(refreshes.count, 1)
    }

    func testTransientRefreshFailureRetriesOnNextPoll() async throws {
        let client = StubCodexOAuth(refreshes: [.failure(.transient), .success(StubCodexOAuth.refreshed)])
        let store = StubCodexStore([try credentials(expiresIn: -60)])
        let provider = CodexUsageProvider(store: store, client: client)
        await fetch(provider, expecting: "error.token_refresh_failed")
        XCTAssertTrue(store.writes.isEmpty)
        _ = try await provider.fetchUsage()
        let refreshes = await client.refreshTokens
        XCTAssertEqual(refreshes, ["refresh", "refresh"])
    }

    func testAccountChangeBeforeRefreshIsRejected() async throws {
        let store = StubCodexStore([try credentials(expiresIn: -60), try credentials("other", expiresIn: -60, accountID: "other-acct")])
        let client = StubCodexOAuth()
        await fetch(CodexUsageProvider(store: store, client: client), expecting: "error.codex_account_changed")
        let refreshes = await client.refreshTokens
        let fetches = await client.fetches
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(fetches.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testRateLimitStopsWithoutRefreshOrRetry() async throws {
        let client = StubCodexOAuth(fetches: [.rateLimited])
        let store = StubCodexStore([try credentials()])
        await fetch(CodexUsageProvider(store: store, client: client), expecting: "error.codex_rate_limited")
        let fetches = await client.fetches
        let refreshes = await client.refreshTokens
        XCTAssertEqual(fetches.count, 1)
        XCTAssertTrue(refreshes.isEmpty)
        XCTAssertTrue(store.writes.isEmpty)
    }

    func testMissingLoginTokensAndUnsupportedStorageErrors() async throws {
        let empty = CodexCredentialStore.Snapshot(raw: Data("{}".utf8), auth: CodexAuthFile(tokens: nil, lastRefresh: nil), source: .file)
        await fetch(CodexUsageProvider(store: StubCodexStore([nil]), client: StubCodexOAuth()), expecting: "error.not_logged_in")
        await fetch(CodexUsageProvider(store: StubCodexStore([empty]), client: StubCodexOAuth()), expecting: "error.no_access_token")
        let unsupported = StubCodexStore([])
        unsupported.readError = CodexCredentialStore.StoreError.unsupportedMode("ephemeral")
        await fetch(CodexUsageProvider(store: unsupported, client: StubCodexOAuth()), expecting: "error.codex_unsupported_storage")
    }

    func testMissingRefreshTokenDoesNotCallRefreshEndpoint() async throws {
        let client = StubCodexOAuth()
        let store = StubCodexStore([try credentials(expiresIn: -60, refreshToken: nil)])
        await fetch(CodexUsageProvider(store: store, client: client), expecting: "error.no_refresh_token")
        let refreshes = await client.refreshTokens
        XCTAssertTrue(refreshes.isEmpty)
    }

    func testParseErrorStillExposesPlanFromIDToken() async throws {
        let client = StubCodexOAuth(fetches: [.success(Data("not json".utf8))])
        let provider = CodexUsageProvider(store: StubCodexStore([try credentials()]), client: client)
        await fetch(provider, expecting: "error.parse")
        XCTAssertEqual(provider.planType, "Plus")
    }
}

/// Test-only storage; never the user's Keychain or auth.json.
private final class StubCodexStore: CodexCredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [CodexCredentialStore.Snapshot?]
    private var recordedWrites: [(Data, CodexCredentialStore.Source)] = []
    var readError: Error?

    init(_ snapshots: [CodexCredentialStore.Snapshot?]) {
        self.snapshots = snapshots
    }

    var writes: [Data] { lock.withLock { recordedWrites.map(\.0) } }
    var writeSources: [CodexCredentialStore.Source] { lock.withLock { recordedWrites.map(\.1) } }

    func read() throws -> CodexCredentialStore.Snapshot? {
        try lock.withLock {
            if let readError { throw readError }
            if snapshots.count > 1 { return snapshots.removeFirst() }
            return snapshots.first ?? nil
        }
    }

    func write(_ raw: Data, to source: CodexCredentialStore.Source) throws {
        try lock.withLock {
            recordedWrites.append((raw, source))
            let auth = try JSONDecoder().decode(CodexAuthFile.self, from: raw)
            snapshots = [CodexCredentialStore.Snapshot(raw: raw, auth: auth, source: source)]
        }
    }
}

private actor StubCodexOAuth: CodexOAuthFetching {
    struct Fetch: Equatable {
        let name: String
        let accountID: String?
    }

    static let usage = CodexOAuthClient.FetchResult.success(Data("""
    {"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":32,"limit_window_seconds":18000,"reset_at":1893456000}}}
    """.utf8))
    static let refreshed = CodexTokenRefreshResponse(
        idToken: nil, accessToken: codexAccessToken("new"), refreshToken: "rotated"
    )

    private var fetchResults: [CodexOAuthClient.FetchResult]
    private var refreshResults: [Result<CodexTokenRefreshResponse, CodexOAuthClient.RefreshError>]
    private(set) var fetches: [Fetch] = []
    private(set) var refreshTokens: [String] = []

    init(fetches: [CodexOAuthClient.FetchResult] = [usage],
         refreshes: [Result<CodexTokenRefreshResponse, CodexOAuthClient.RefreshError>] = [.success(refreshed)]) {
        fetchResults = fetches
        refreshResults = refreshes
    }

    func fetchUsage(token: String, accountID: String?) async -> CodexOAuthClient.FetchResult {
        fetches.append(Fetch(name: JWT.claims(token)?["name"] as? String ?? token, accountID: accountID))
        return fetchResults.count > 1 ? fetchResults.removeFirst() : fetchResults[0]
    }

    func refresh(refreshToken: String) async throws -> CodexTokenRefreshResponse {
        refreshTokens.append(refreshToken)
        return try (refreshResults.count > 1 ? refreshResults.removeFirst() : refreshResults[0]).get()
    }
}
