import XCTest
@testable import CodeCaps

/// The Keychain seam: an in-memory fake keeps these tests off the real
/// Keychain entirely.
final class InfisicalIdentityStoreTests: XCTestCase {
    private var vault: [String: String] = [:]
    private var savedCalls: InfisicalIdentityStore.KeychainCalls!

    override func setUp() {
        super.setUp()
        savedCalls = InfisicalIdentityStore.calls
        InfisicalIdentityStore.calls = InfisicalIdentityStore.KeychainCalls(
            read: { [weak self] service, account in
                guard let self else { return nil }
                return self.vault["\(service)/\(account)"]
            },
            save: { [weak self] service, account, value in
                self?.vault["\(service)/\(account)"] = value
            },
            delete: { [weak self] service, account in
                self?.vault.removeValue(forKey: "\(service)/\(account)")
            }
        )
    }

    override func tearDown() {
        InfisicalIdentityStore.calls = savedCalls
        vault = [:]
        super.tearDown()
    }

    func testLoadIsNilBeforeProvisioning() {
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testSaveThenLoadRoundTrips() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertEqual(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"), identity)
    }

    func testDeleteRemovesTheIdentity() throws {
        let identity = InfisicalIdentityStore.Identity(clientId: "cid-1", clientSecret: "csec-1")
        try InfisicalIdentityStore.save(identity, bundleIdentifier: "com.jays.agent-bar.mac.test")
        try InfisicalIdentityStore.delete(bundleIdentifier: "com.jays.agent-bar.mac.test")
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testHalfWrittenIdentityReadsAsAbsent() {
        // Only the client ID made it in (e.g. the save was interrupted):
        // the store must not hand out a half identity.
        vault["com.jays.agent-bar.mac.test.infisical-identity/client-id"] = "cid-1"
        XCTAssertNil(InfisicalIdentityStore.load(bundleIdentifier: "com.jays.agent-bar.mac.test"))
    }

    func testServiceNameFollowsTheBuildsBundleIdentifier() {
        XCTAssertEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac"),
            "com.jays.agent-bar.mac.infisical-identity"
        )
        XCTAssertEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac.dev"),
            "com.jays.agent-bar.mac.dev.infisical-identity"
        )
        // A `.dev` build's identity can never collide with the owner's.
        XCTAssertNotEqual(
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac.dev"),
            InfisicalIdentityStore.serviceName(bundleIdentifier: "com.jays.agent-bar.mac")
        )
    }
}
