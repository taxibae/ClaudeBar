import XCTest
@testable import LLMBar

final class CodexCredentialStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    /// Never the user's "Codex Auth" item
    private func store() -> CodexCredentialStore {
        CodexCredentialStore(codexHome: directory, keychainService: "LLMBar-tests-\(UUID().uuidString)")
    }

    // MARK: - Location and mode

    func testKeychainAccountMatchesCodexStoreKey() {
        XCTAssertEqual(CodexCredentialStore.keychainAccount(codexHome: "/Users/test/.codex"), "cli|d446e73b91d0fe9e")
    }

    func testCodexHomeIsCanonicalizedLikeRust() {
        // /var is a symlink to /private/var; Foundation's resolution would drop the prefix
        let resolved = CodexCredentialStore.canonicalPath(directory.path)
        XCTAssertTrue(resolved.hasPrefix("/private/"), resolved)
        let environmentStore = CodexCredentialStore(environment: ["CODEX_HOME": directory.path], home: directory)
        XCTAssertEqual(environmentStore.codexHome.path, resolved)
        XCTAssertEqual(environmentStore.keychainService, "Codex Auth")
        let missing = "/nonexistent/\(UUID().uuidString)"
        XCTAssertEqual(CodexCredentialStore.canonicalPath(missing), missing)
    }

    func testDefaultHomeIsDotCodexWhenEnvironmentIsUnsetOrEmpty() {
        for environment in [[:], ["CODEX_HOME": ""]] {
            let store = CodexCredentialStore(environment: environment, home: URL(fileURLWithPath: "/nonexistent-home"))
            XCTAssertEqual(store.codexHome.path, "/nonexistent-home/.codex")
        }
    }

    func testParseModeReadsOnlyTopLevelSetting() throws {
        XCTAssertEqual(try CodexCredentialStore.parseMode(config: ""), .file)
        XCTAssertEqual(try CodexCredentialStore.parseMode(config: "model = \"o3\"\ncli_auth_credentials_store = \"keyring\""), .keyring)
        XCTAssertEqual(try CodexCredentialStore.parseMode(config: "cli_auth_credentials_store='auto' # comment"), .auto)
        XCTAssertEqual(try CodexCredentialStore.parseMode(config: "[profiles.x]\ncli_auth_credentials_store = \"keyring\""), .file)
        XCTAssertThrowsError(try CodexCredentialStore.parseMode(config: "cli_auth_credentials_store = \"ephemeral\""))
    }

    // MARK: - Read and write

    func testFileModeReadsAndWritesAuthJSONWithOwnerOnlyPermissions() throws {
        let raw = try codexAuthJSON(accessToken: "access")
        try raw.write(to: directory.appendingPathComponent("auth.json"))
        let store = store()
        let snapshot = try XCTUnwrap(try store.read())
        XCTAssertEqual(snapshot.source, .file)
        XCTAssertEqual(snapshot.tokens?.accessToken, "access")
        XCTAssertEqual(snapshot.tokens?.resolvedAccountID, "acct")

        try store.write(Data("{\"tokens\":{\"access_token\":\"next\"}}".utf8), to: .file)
        XCTAssertEqual(try store.read()?.tokens?.accessToken, "next")
        let attributes = try FileManager.default.attributesOfItem(atPath: store.authFilePath.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testAutoModeFallsBackToFileAndMissingLoginReadsNil() throws {
        let store = store()
        XCTAssertNil(try store.read())
        try Data("cli_auth_credentials_store = \"auto\"\n".utf8).write(to: store.configPath)
        XCTAssertNil(try store.read())
        try codexAuthJSON(accessToken: "access").write(to: store.authFilePath)
        XCTAssertEqual(try store.read()?.source, .file)
    }

    func testUnsupportedModeThrows() throws {
        let store = store()
        try Data("cli_auth_credentials_store = \"ephemeral\"\n".utf8).write(to: store.configPath)
        XCTAssertThrowsError(try store.read())
    }

    // MARK: - Tokens

    func testAccountIDAndPlanFallBackToIDTokenClaims() throws {
        let raw = try codexAuthJSON(accessToken: "access", accountID: nil)
        let tokens = try XCTUnwrap(try JSONDecoder().decode(CodexAuthFile.self, from: raw).tokens)
        XCTAssertEqual(tokens.resolvedAccountID, "acct")
        XCTAssertEqual(tokens.planType, "plus")
    }

    func testRefreshOnlyAfterExpiryOrEightDaysWithoutExpiry() {
        func tokens(_ access: String) -> CodexTokens {
            CodexTokens(idToken: nil, accessToken: access, refreshToken: "r", accountID: nil)
        }
        let now = Date()
        XCTAssertTrue(tokens(codexAccessToken("a", expiresIn: -1)).needsRefresh(lastRefresh: nil, now: now))
        XCTAssertFalse(tokens(codexAccessToken("a", expiresIn: 120)).needsRefresh(lastRefresh: nil, now: now),
                       "The five-minute early window belongs to the Codex process")
        let formatter = ISO8601DateFormatter()
        let old = formatter.string(from: now.addingTimeInterval(-9 * 24 * 3600))
        let recent = formatter.string(from: now.addingTimeInterval(-24 * 3600))
        XCTAssertTrue(tokens("opaque").needsRefresh(lastRefresh: old, now: now))
        XCTAssertFalse(tokens("opaque").needsRefresh(lastRefresh: recent, now: now))
        XCTAssertFalse(tokens("opaque").needsRefresh(lastRefresh: nil, now: now))
        XCTAssertTrue(tokens("opaque").needsRefresh(lastRefresh: "2020-01-01T00:00:00.123456789Z", now: now))
    }

    func testMergerReplacesOnlyReturnedTokensAndStampsLastRefresh() throws {
        let raw = try codexAuthJSON(accessToken: "old", idToken: "old-id", lastRefresh: "2020-01-01T00:00:00Z")
        let refreshedAt = Date(timeIntervalSince1970: 1_900_000_000)
        let merged = try CodexCredentialMerger.merge(
            raw: raw, response: CodexTokenRefreshResponse(idToken: nil, accessToken: "new", refreshToken: "rotated"),
            refreshedAt: refreshedAt
        )
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: merged) as? [String: Any])
        let tokens = try XCTUnwrap(root["tokens"] as? [String: Any])
        XCTAssertEqual(tokens["access_token"] as? String, "new")
        XCTAssertEqual(tokens["refresh_token"] as? String, "rotated")
        XCTAssertEqual(tokens["id_token"] as? String, "old-id")
        XCTAssertEqual(tokens["account_id"] as? String, "acct")
        XCTAssertEqual(tokens["futureTokenField"] as? String, "preserved")
        XCTAssertEqual(root["auth_mode"] as? String, "chatgpt")
        XCTAssertTrue(root["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(ISO8601.parse(root["last_refresh"] as? String), refreshedAt)
    }

    func testRefreshFailureClassificationMatchesCodex() {
        func classify(_ status: Int, _ body: String) -> CodexOAuthClient.RefreshError {
            CodexOAuthClient.refreshFailure(status: status, body: Data(body.utf8))
        }
        XCTAssertEqual(classify(401, ""), .permanent)
        XCTAssertEqual(classify(400, #"{"error":{"code":"refresh_token_reused"}}"#), .permanent)
        XCTAssertEqual(classify(400, #"{"error":"refresh_token_expired"}"#), .permanent)
        XCTAssertEqual(classify(400, #"{"code":"refresh_token_invalidated"}"#), .permanent)
        XCTAssertEqual(classify(400, #"{"error":"invalid_grant"}"#), .transient)
        XCTAssertEqual(classify(500, "oops"), .transient)
    }
}
