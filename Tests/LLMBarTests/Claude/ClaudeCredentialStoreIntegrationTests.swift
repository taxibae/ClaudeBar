import XCTest
@testable import LLMBar

/// Gerçek `security` aracıyla uçtan uca okuma/yazma. Kendi geçici servis adını kullanır,
/// Claude Code'un kaydına dokunmaz ve sonunda kaydı siler.
final class ClaudeCredentialStoreIntegrationTests: XCTestCase {

    private var tempDir: URL!
    private var serviceName: String!
    private var store: ClaudeCredentialStore!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("llmbar-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        serviceName = "LLMBar-selftest-\(UUID().uuidString.prefix(8))"
        store = ClaudeCredentialStore(
            configDir: tempDir,
            serviceName: serviceName,
            accountName: ClaudeCredentialStore.resolveAccountName(environment: ProcessInfo.processInfo.environment)
        )
    }

    override func tearDownWithError() throws {
        // Test kaydını Keychain'den temizle; yoksa security hata verir, umursamıyoruz
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["delete-generic-password", "-s", serviceName]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try? process.run()
        process.waitUntilExit()
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func credentials(token: String) -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(token)","refreshToken":"r-\(token)","expiresAt":1800000000000,"scopes":["user:inference"],"subscriptionType":"max","extra":{"keep":true}}}
        """.utf8)
    }

    func testKeychainWriteViaStdinThenReadAndUpdateInPlace() throws {
        // İlk yazma: kayıt yoktur, -U yine de oluşturur
        try store.write(credentials(token: "first"), to: .keychain)

        let first = try XCTUnwrap(store.read())
        XCTAssertEqual(first.source, .keychain)
        XCTAssertEqual(first.oauth?.accessToken, "first")
        XCTAssertEqual(first.raw, credentials(token: "first"))

        // İkinci yazma: aynı servis adı, -U sayesinde silmeden yerinde güncellenir
        try store.write(credentials(token: "second"), to: .keychain)

        let second = try XCTUnwrap(store.read())
        XCTAssertEqual(second.oauth?.accessToken, "second")
        XCTAssertEqual(second.oauth?.refreshToken, "r-second")
    }

    func testPlaintextFallbackWhenKeychainItemMissing() throws {
        try store.write(credentials(token: "file"), to: .plaintextFile)

        let attributes = try FileManager.default.attributesOfItem(atPath: store.plaintextPath.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let snapshot = try XCTUnwrap(store.read())
        XCTAssertEqual(snapshot.source, .plaintextFile)
        XCTAssertEqual(snapshot.oauth?.accessToken, "file")
    }
}
