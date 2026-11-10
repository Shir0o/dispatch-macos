import Foundation
import Testing
@testable import DispatchApp

// MARK: - Test Doubles

/// In-memory Keychain that models a save plus a presence check.
private final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private(set) var storedToken: String?
    private(set) var migrateCallCount = 0
    var saveSucceeds: Bool

    init(storedToken: String? = nil, saveSucceeds: Bool = true) {
        self.storedToken = storedToken
        self.saveSucceeds = saveSucceeds
    }

    func hasPAT() -> Bool {
        storedToken != nil
    }

    func migratePAT(_ token: String) -> Bool {
        migrateCallCount += 1
        guard saveSucceeds else { return false }
        storedToken = token
        return true
    }
}

// MARK: - Tests

@Suite("OpenWork Migration Tests")
@MainActor
struct OpenWorkMigrationTests {

    private let legacyPATKey = "dispatch.githubPAT"
    private let legacyDismissedKeysKey = "dispatch.dismissedGitHubIssueIDs"
    private let hiddenKeysDefaultsKey = "dispatch.openWorkHiddenKeys"

    // MARK: - Fixtures

    private struct Fixture {
        let defaults: UserDefaults
        let suiteName: String
        let snapshotURL: URL
        let snapshotDirectory: URL
    }

    private func makeFixture() throws -> Fixture {
        let suiteName = "OpenWorkMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)

        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OpenWorkMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)

        return Fixture(
            defaults: defaults,
            suiteName: suiteName,
            snapshotURL: snapshotDirectory.appendingPathComponent("snapshot.json"),
            snapshotDirectory: snapshotDirectory
        )
    }

    private func tearDown(_ fixture: Fixture) {
        fixture.defaults.removePersistentDomain(forName: fixture.suiteName)
        try? FileManager.default.removeItem(at: fixture.snapshotDirectory)
    }

    private func writeSnapshot(dismissedKeys: [String], to url: URL) throws {
        let snapshot = SnapshotData(
            gmailItems: [],
            gitHubItems: [],
            dismissedGitHubKeys: dismissedKeys
        )
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: url, options: .atomic)
    }

    private func hiddenKeys(_ defaults: UserDefaults) -> [String] {
        defaults.stringArray(forKey: hiddenKeysDefaultsKey) ?? []
    }

    // MARK: - PAT Migration

    @Test("A valid PAT is copied to the Keychain, verified and deleted from defaults")
    func testPATCopiedVerifiedAndDeleted() throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }

        fixture.defaults.set("ghp_legacy_token", forKey: legacyPATKey)
        fixture.defaults.set(["owner/repo#1"], forKey: legacyDismissedKeysKey)

        let keychain = FakeKeychain()
        let result = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )

        #expect(result.isConfigured == true)
        #expect(result.needsReconnect == false)
        #expect(keychain.storedToken == "ghp_legacy_token")
        #expect(keychain.migrateCallCount == 1)
        #expect(fixture.defaults.string(forKey: legacyPATKey) == nil)
        #expect(fixture.defaults.stringArray(forKey: legacyDismissedKeysKey) == nil)
    }

    @Test("A failed Keychain copy keeps the defaults token and requires a reconnect")
    func testPATFailureKeepsDefaultsAndNeedsReconnect() throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }

        fixture.defaults.set("ghp_legacy_token", forKey: legacyPATKey)

        let keychain = FakeKeychain(saveSucceeds: false)
        let result = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )

        #expect(result.isConfigured == false)
        #expect(result.needsReconnect == true)
        #expect(keychain.hasPAT() == false)
        // The old value stays only for manual recovery.
        #expect(fixture.defaults.string(forKey: legacyPATKey) == "ghp_legacy_token")
    }

    @Test("No legacy PAT reports the existing Keychain state without touching it")
    func testNoLegacyPATUsesKeychainPresence() throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }

        let keychain = FakeKeychain(storedToken: "already_there")
        let result = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )

        #expect(result.isConfigured == true)
        #expect(result.needsReconnect == false)
        #expect(keychain.migrateCallCount == 0)
        #expect(keychain.storedToken == "already_there")
    }

    // MARK: - Hidden Keys

    @Test("Hidden keys union from the snapshot and defaults into the existing set")
    func testHiddenKeysUnionFromSnapshotAndDefaults() throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }

        try writeSnapshot(
            dismissedKeys: ["gh:issue:Owner/Repo#7", "Keep#2"],
            to: fixture.snapshotURL
        )
        fixture.defaults.set(
            ["gh:pr:Other/Repo#3", "gh:thread:12345"],
            forKey: legacyDismissedKeysKey
        )
        fixture.defaults.set(["Existing#1"], forKey: hiddenKeysDefaultsKey)

        let keychain = FakeKeychain()
        let result = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )

        #expect(result.isConfigured == false)
        #expect(result.needsReconnect == false)
        #expect(
            hiddenKeys(fixture.defaults)
                == ["existing#1", "keep#2", "other/repo#3", "owner/repo#7"]
        )
    }

    @Test("Prefixes are stripped longest-first and thread keys are dropped")
    func testPrefixNormalization() {
        #expect(LegacyStateMigrator.normalizeHiddenKey("gh:issue:Owner/Repo#1") == "owner/repo#1")
        #expect(LegacyStateMigrator.normalizeHiddenKey("gh:pr:Owner/Repo#2") == "owner/repo#2")
        #expect(LegacyStateMigrator.normalizeHiddenKey("gh:Owner/Repo#3") == "owner/repo#3")
        #expect(LegacyStateMigrator.normalizeHiddenKey("Owner/Repo#4") == "owner/repo#4")
        #expect(LegacyStateMigrator.normalizeHiddenKey("gh:thread:12345") == nil)
        #expect(LegacyStateMigrator.normalizeHiddenKey("   ") == nil)
    }

    @Test("A second migration run is idempotent")
    func testSecondRunIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { tearDown(fixture) }

        fixture.defaults.set("ghp_legacy_token", forKey: legacyPATKey)
        fixture.defaults.set(["gh:issue:Owner/Repo#1"], forKey: legacyDismissedKeysKey)
        try writeSnapshot(dismissedKeys: ["gh:pr:Other/Repo#2"], to: fixture.snapshotURL)

        let keychain = FakeKeychain()

        let first = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )
        let keysAfterFirst = hiddenKeys(fixture.defaults)

        let second = LegacyStateMigrator.run(
            defaults: fixture.defaults,
            keychain: keychain,
            snapshotURL: fixture.snapshotURL
        )
        let keysAfterSecond = hiddenKeys(fixture.defaults)

        #expect(first.isConfigured == true)
        #expect(second.isConfigured == true)
        #expect(first.needsReconnect == false)
        #expect(second.needsReconnect == false)
        #expect(keysAfterFirst == ["other/repo#2", "owner/repo#1"])
        #expect(keysAfterSecond == keysAfterFirst)
        #expect(keychain.migrateCallCount == 1)
        #expect(keychain.storedToken == "ghp_legacy_token")
    }
}
