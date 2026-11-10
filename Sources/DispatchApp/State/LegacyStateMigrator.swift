import Foundation

// MARK: - KeychainStoring

/// Synchronous Keychain seam for the one-time legacy migration.
public protocol KeychainStoring: Sendable {
    func hasPAT() -> Bool
    func migratePAT(_ token: String) -> Bool
}

// MARK: - SystemKeychainStore

/// Production implementation backed by the same Keychain helpers the app uses.
public struct SystemKeychainStore: KeychainStoring {
    public init() {}

    public func hasPAT() -> Bool {
        AuthService.hasGitHubPAT()
    }

    public func migratePAT(_ token: String) -> Bool {
        AuthService.saveGitHubPAT(token)
    }
}

// MARK: - MigrationResult

public struct MigrationResult: Sendable {
    /// Whether a usable PAT is present in the Keychain after the migration.
    public let isConfigured: Bool
    /// True when a legacy PAT existed but could not be copied to the Keychain.
    public let needsReconnect: Bool

    public init(isConfigured: Bool, needsReconnect: Bool) {
        self.isConfigured = isConfigured
        self.needsReconnect = needsReconnect
    }
}

// MARK: - LegacyStateMigrator

/// One-time copy of the retired GitHub state into the new stores.
///
/// Runs before `OpenWorkStore` is constructed: it moves the PAT from
/// UserDefaults to the Keychain and seeds `dispatch.openWorkHiddenKeys` from the
/// old snapshot and dismissal defaults. Old keys are deleted only after the
/// copy and the seed succeed.
public enum LegacyStateMigrator {
    /// Old UserDefaults keys retired by the Open Work migration.
    static let legacyPATKey = "dispatch.githubPAT"
    static let legacyDismissedKeysKey = "dispatch.dismissedGitHubIssueIDs"
    /// Mirrors `OpenWorkStore.hiddenKeysDefaultsKey`; its constant is
    /// main-actor isolated, so the migrator carries the literal.
    static let hiddenKeysDefaultsKey = "dispatch.openWorkHiddenKeys"

    public static func run(
        defaults: UserDefaults = .standard,
        keychain: any KeychainStoring = SystemKeychainStore(),
        snapshotURL: URL = TriageStore.defaultSnapshotURL
    ) -> MigrationResult {
        seedHiddenKeys(defaults: defaults, snapshotURL: snapshotURL)

        let legacyToken = (defaults.string(forKey: legacyPATKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !legacyToken.isEmpty else {
            return MigrationResult(isConfigured: keychain.hasPAT(), needsReconnect: false)
        }

        guard keychain.migratePAT(legacyToken) else {
            // Keep both old defaults values for manual recovery. The token
            // provider stays Keychain-only, so the app reports reconnect needed.
            return MigrationResult(isConfigured: false, needsReconnect: true)
        }

        defaults.removeObject(forKey: legacyPATKey)
        defaults.removeObject(forKey: legacyDismissedKeysKey)

        return MigrationResult(isConfigured: true, needsReconnect: false)
    }

    // MARK: - Hidden Keys

    private static func seedHiddenKeys(defaults: UserDefaults, snapshotURL: URL) {
        let oldSnapshot = try? SnapshotData.load(from: snapshotURL)

        var migrated = Set<String>()
        for key in oldSnapshot?.dismissedGitHubKeys ?? [] {
            if let normalized = normalizeHiddenKey(key) {
                migrated.insert(normalized)
            }
        }
        for key in defaults.stringArray(forKey: legacyDismissedKeysKey) ?? [] {
            if let normalized = normalizeHiddenKey(key) {
                migrated.insert(normalized)
            }
        }

        var hidden = Set(
            (defaults.stringArray(forKey: hiddenKeysDefaultsKey) ?? [])
                .map { $0.lowercased() }
        )
        hidden.formUnion(migrated)
        defaults.set(hidden.sorted(), forKey: hiddenKeysDefaultsKey)
    }

    /// Strips the retired id prefixes longest-first, lowercases, and drops
    /// notification-thread keys, which have no Open Work equivalent.
    static func normalizeHiddenKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let lowered = trimmed.lowercased()
        guard !lowered.hasPrefix("gh:thread:") else { return nil }

        let key: String
        if lowered.hasPrefix("gh:issue:") {
            key = String(trimmed.dropFirst("gh:issue:".count))
        } else if lowered.hasPrefix("gh:pr:") {
            key = String(trimmed.dropFirst("gh:pr:".count))
        } else if lowered.hasPrefix("gh:") {
            key = String(trimmed.dropFirst("gh:".count))
        } else {
            key = trimmed
        }

        let normalized = key.lowercased()
        return normalized.isEmpty ? nil : normalized
    }
}
