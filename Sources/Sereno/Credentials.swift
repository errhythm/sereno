import Foundation
import Security
import os

/// PRIVACY RULE FOR THIS WHOLE FILE. A credential value is never logged, never printed, and
/// never interpolated into an error. Every string this file can hand to a human or to the
/// unified log carries at most a credential's *name* (`slack-user-token`), a count, or a
/// filesystem reason produced by Foundation, which names paths and never contents.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "credentials")

// MARK: - Why this is a file and not the Keychain
//
// It used to be the Keychain, and on paper that is the stronger place: Keychain contents do
// not ride along in a Time Machine backup, and a file in Application Support is readable by
// anything already running as this user. The owner has been told that, twice, and has chosen
// the file anyway. The reason is that `build.sh` signs ad-hoc (`codesign -s -`, no Team ID),
// so the code signature changes on every single rebuild. A Keychain ACL binds to code
// identity, so every build is a different app to the Keychain and the ACL never matches:
// roughly twenty rebuilds in one evening meant roughly twenty permission dialogs.
//
// There is a second, sharper reason, and it is a correctness one rather than a comfort one.
// A Keychain read from an UNSIGNED binary can raise a permission dialog that nobody can see,
// and the process then blocks on it forever. `SlackAuth.shared`'s init used to read the
// Keychain, and `MenuContent` holds `SlackAuth.shared`, so a scratch-package demo that merely
// constructed that view hung with no output and SecurityAgent live. Nothing below can hang:
// the only Keychain call left in the whole app is `Legacy.keychain`, reached once, from
// `migrate()`, which the app calls at launch and which every demo stubs.
//
// The trade being accepted, stated plainly so nobody has to re-derive it: this file is
// unencrypted. Permissions are therefore the entire security story, which is why `write`
// re-applies the mode after every write rather than trusting the one it asked for.

enum CredentialsError: Error, Equatable {
    /// A filesystem reason, never a credential value.
    case unwritable(String)
    /// The legacy Keychain item would not go away. Carries an `OSStatus`, never a value.
    case legacyDeleteFailed(OSStatus)

    /// Plain language, shown inline in Settings, in the register the rest of the app uses.
    var message: String {
        switch self {
        case .unwritable(let why):
            "Could not save to Sereno's credentials file: \(why)"
        case .legacyDeleteFailed(let status):
            "Could not remove the old Keychain copy (error \(status))."
        }
    }
}

/// The two secrets Sereno holds, in one JSON file beside `state.json`.
///
/// Deliberately not two properties: `Name` is the whole of the API surface that has to grow
/// when a third credential appears, and `migrate()` walks `allCases` rather than a hand-kept
/// list. The raw values are the Keychain *account* names the old `SlackKeychain` and
/// `RemoteModelKeychain` used, which is what makes the migration below a one-liner per name.
enum Credentials {
    enum Name: String, CaseIterable, Sendable {
        case slackToken = "slack-user-token"
        case remoteModelAPIKey = "remote-model-api-key"
    }

    static let fileName = "credentials.json"

    /// The security story, in two numbers. Directory owner-only so nothing can even list it;
    /// file owner-only read/write.
    static let directoryMode = 0o700
    static let fileMode = 0o600

    /// Pure and derived from a directory, the same shape `Store.debugCaptureFileURL` has, so
    /// a demo pointed at a throwaway directory gets a throwaway credentials path for free and
    /// never the real one.
    nonisolated static func fileURL(directory: URL) -> URL {
        directory.appendingPathComponent(fileName)
    }

    /// Production location: a sibling of `state.json` and `debug-captures.jsonl`, reusing
    /// `Store.supportDirectory` rather than inventing a third way to find that folder.
    static var defaultFileURL: URL {
        fileURL(directory: Store.supportDirectory(
            candidates: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)))
    }

    // MARK: - On-disk shape

    /// `migrated` is what stops `migrate()` consulting the Keychain a second time. It has to
    /// be on disk rather than in memory: an in-process flag would ask again at every launch,
    /// and asking again is exactly the dialog this whole change exists to stop.
    private struct Vault: Codable {
        var migrated = false
        var values: [String: String] = [:]
    }

    /// A missing or unreadable file is an empty vault, not an error. There is nothing to
    /// recover here: no credential means "not connected", which every caller already handles.
    private static func read(_ url: URL) -> Vault {
        guard let data = try? Data(contentsOf: url),
              let vault = try? JSONDecoder().decode(Vault.self, from: data) else { return Vault() }
        return vault
    }

    /// The mode is re-applied after the write, every time, and that is not belt-and-braces.
    /// `createDirectory(attributes:)` only applies its attributes to a directory it actually
    /// creates, and `Data.write(options: .atomic)` writes a temp file and renames it over the
    /// target, which on a first write leaves the default 0644 behind. A write that silently
    /// widens permissions is the entire failure mode of storing a token in a file, so it is
    /// asserted in `demoCredentials`, on the overwrite path as well as the fresh one.
    private static func write(_ vault: Vault, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: directoryMode])
            try FileManager.default.setAttributes(
                [.posixPermissions: directoryMode], ofItemAtPath: directory.path)
            try JSONEncoder().encode(vault).write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: fileMode], ofItemAtPath: url.path)
        } catch {
            // localizedDescription on a Foundation filesystem error names the path and the
            // reason. It cannot name the contents, which is why this is safe to surface.
            throw CredentialsError.unwritable(error.localizedDescription)
        }
    }

    // MARK: - Read, write, delete

    /// nil for both "no such credential" and "stored empty", because every caller means the
    /// same thing by them: not configured.
    static func load(_ name: Name, from url: URL = defaultFileURL) -> String? {
        guard let value = read(url).values[name.rawValue], !value.isEmpty else { return nil }
        return value
    }

    static func save(_ value: String, as name: Name, to url: URL = defaultFileURL) throws {
        var vault = read(url)
        vault.values[name.rawValue] = value
        try write(vault, to: url)
    }

    static func delete(_ name: Name, from url: URL = defaultFileURL) throws {
        var vault = read(url)
        guard vault.values.removeValue(forKey: name.rawValue) != nil else { return }
        try write(vault, to: url)
    }

    /// Reset Sereno. The whole file goes, not just the values, so nothing is left on disk
    /// under a name a future version might read. Deleting a file that was never written is
    /// not an error, so a reset on a fresh install cannot fail.
    static func deleteFile(at url: URL = defaultFileURL) {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - One-time migration off the Keychain

    /// The call seam, the same shape `SlackSearch.Call`, `SlackMessageSource.Call` and
    /// `RemoteModelClient.Call` already use. It exists for one reason: a demo must never
    /// touch the real Keychain, because an unsigned harness binary that does can block on an
    /// invisible permission dialog forever. Every demo passes a stub; only `migrate()`'s
    /// default argument reaches `Legacy.keychain`.
    struct Legacy: Sendable {
        var read: @Sendable (Name) -> String?
        var delete: @Sendable (Name) throws -> Void
    }

    private static func keychainQuery(_ name: Name) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.rhystart.sereno",
         kSecAttrAccount as String: name.rawValue]
    }

    /// The only `SecItem` calls left in Sereno. Read and delete only: nothing writes to the
    /// Keychain any more, so once a machine has migrated these find nothing and stay quiet.
    static let keychain = Legacy(
        read: { name in
            var request = keychainQuery(name)
            request[kSecReturnData as String] = true
            request[kSecMatchLimit as String] = kSecMatchLimitOne
            var item: CFTypeRef?
            guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data else { return nil }
            return String(decoding: data, as: UTF8.self)
        },
        delete: { name in
            let status = SecItemDelete(keychainQuery(name) as CFDictionary)
            // errSecItemNotFound is success: the point is that nothing is stored afterwards.
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw CredentialsError.legacyDeleteFailed(status)
            }
        })

    /// Called once, from the app's own launch, and never from a `load`. Putting it in `load`
    /// would put a Keychain read back behind `SlackAuth.shared`'s init and behind
    /// `LiveMessageSource`'s per-call token check, which is the hang this change removes.
    ///
    /// One last permission prompt for a human who already has a token, then never again:
    /// `migrated` is persisted, so a second call reads the file and returns without asking.
    /// Returns how many credentials moved, for the log line and for the checks.
    @discardableResult
    static func migrate(legacy: Legacy = keychain, file url: URL = defaultFileURL) -> Int {
        var vault = read(url)
        guard !vault.migrated else { return 0 }

        var moved: [Name] = []
        for name in Name.allCases where vault.values[name.rawValue] == nil {
            guard let value = legacy.read(name), !value.isEmpty else { continue }
            vault.values[name.rawValue] = value
            moved.append(name)
        }
        vault.migrated = true

        do {
            try write(vault, to: url)
        } catch {
            // The Keychain copy is the only copy until the file has it. Losing the user's
            // token to a failed write would be worse than one more prompt next launch.
            log.error("credential migration could not write the file, Keychain copies kept count=\(moved.count, privacy: .public)")
            return 0
        }

        for name in moved {
            do {
                try legacy.delete(name)
            } catch {
                log.error("credential moved to the file but the Keychain copy remains name=\(name.rawValue, privacy: .public)")
            }
        }
        if !moved.isEmpty {
            log.notice("moved credentials out of the Keychain into the credentials file names=\(moved.map(\.rawValue).joined(separator: ","), privacy: .public)")
        }
        return moved.count
    }
}

// MARK: - Runnable checks

/// Plain asserts, this project's style: no test framework, no network, and no real Keychain.
/// Every path here is pointed at a throwaway directory under the temp directory, and every
/// migration is driven through a stubbed `Legacy`, so nothing in this function can raise a
/// Keychain permission dialog or touch the real credentials file.
///
/// Run from a scratch SwiftPM package under /private/tmp that copies this file with its own
/// @main, per this project's CLAUDE.md; nothing in the app calls this.
func demoCredentials() {
    func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
    }
    func scratchDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sereno-credentials-\(UUID().uuidString)", isDirectory: true)
    }

    // The path shape: a sibling of state.json, derived purely, so this never needs the real
    // Application Support directory to prove where the file lands.
    assert(Credentials.fileURL(directory: URL(fileURLWithPath: "/x", isDirectory: true)).path
           == "/x/credentials.json", "credentials file is not where the layout says it is")

    // MARK: round trip

    let roundTripDirectory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: roundTripDirectory) }
    let file = Credentials.fileURL(directory: roundTripDirectory)

    assert(Credentials.load(.slackToken, from: file) == nil, "a missing file must read as no credential")

    let token = "xoxp-not-a-real-token-0123456789"
    try! Credentials.save(token, as: .slackToken, to: file)
    assert(Credentials.load(.slackToken, from: file) == token, "load did not match save")
    // Two names, one file: writing one must not disturb the other.
    assert(Credentials.load(.remoteModelAPIKey, from: file) == nil, "an unwritten name must stay nil")

    // MARK: permissions, the whole security story

    assert(mode(file) == 0o600, "fresh write left mode \(mode(file).map { String($0, radix: 8) } ?? "none"), not 600")
    assert(mode(roundTripDirectory) == 0o700,
           "directory left at mode \(mode(roundTripDirectory).map { String($0, radix: 8) } ?? "none"), not 700")

    // The overwrite is the case that regresses: .atomic replaces the file through a temp file
    // and a rename, so a write that forgot to re-chmod would land back at 0644 right here.
    try! Credentials.save("xoxp-not-a-real-token-second", as: .slackToken, to: file)
    assert(Credentials.load(.slackToken, from: file) == "xoxp-not-a-real-token-second", "overwrite did not update")
    assert(mode(file) == 0o600, "overwrite left mode \(mode(file).map { String($0, radix: 8) } ?? "none"), not 600")

    // A second name written into the same file is also an overwrite of the file.
    try! Credentials.save("sk-not-a-real-key", as: .remoteModelAPIKey, to: file)
    assert(mode(file) == 0o600, "writing a second name widened the mode")
    assert(Credentials.load(.slackToken, from: file) == "xoxp-not-a-real-token-second",
           "writing one name clobbered the other")

    // MARK: delete

    try! Credentials.delete(.slackToken, from: file)
    assert(Credentials.load(.slackToken, from: file) == nil, "delete left the value behind")
    assert(Credentials.load(.remoteModelAPIKey, from: file) == "sk-not-a-real-key",
           "deleting one name took the other with it")
    assert(mode(file) == 0o600, "delete widened the mode")
    // Deleting nothing is not an error, so Disconnect with no token cannot fail.
    try! Credentials.delete(.slackToken, from: file)

    Credentials.deleteFile(at: file)
    assert(!FileManager.default.fileExists(atPath: file.path), "reset left the credentials file on disk")
    Credentials.deleteFile(at: file)

    // MARK: migration, through a stubbed legacy reader. Never the real Keychain.

    /// Single-threaded here, hence @unchecked, the same shape App.swift's demo box uses.
    final class Calls: @unchecked Sendable {
        var reads: [Credentials.Name] = []
        var deletes: [Credentials.Name] = []
    }

    // Absent from the file, present in legacy: the value comes back, the file now holds it,
    // and the legacy copy was deleted. The name already in the file is never asked for.
    let movedDirectory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: movedDirectory) }
    let movedFile = Credentials.fileURL(directory: movedDirectory)
    try! Credentials.save("sk-already-in-the-file", as: .remoteModelAPIKey, to: movedFile)

    let moved = Calls()
    let legacyWithToken = Credentials.Legacy(
        read: { name in
            moved.reads.append(name)
            return name == .slackToken ? "xoxp-legacy-token" : nil
        },
        delete: { name in moved.deletes.append(name) })

    assert(Credentials.migrate(legacy: legacyWithToken, file: movedFile) == 1, "one credential should have moved")
    assert(Credentials.load(.slackToken, from: movedFile) == "xoxp-legacy-token",
           "the migrated value is not readable from the file")
    assert(moved.reads == [.slackToken], "legacy was consulted for a name the file already had")
    assert(moved.deletes == [.slackToken], "the legacy copy was not deleted after the move")
    assert(mode(movedFile) == 0o600, "migration wrote the file at the wrong mode")
    assert(Credentials.load(.remoteModelAPIKey, from: movedFile) == "sk-already-in-the-file",
           "migration overwrote a credential the file already had")

    // Second pass must not consult legacy at all: that call is the permission dialog.
    assert(Credentials.migrate(legacy: legacyWithToken, file: movedFile) == 0, "migration ran twice")
    assert(moved.reads == [.slackToken], "a second migrate re-consulted the Keychain")

    // Absent from both: nil, and legacy is asked exactly once per name across two calls.
    let emptyDirectory = scratchDirectory()
    defer { try? FileManager.default.removeItem(at: emptyDirectory) }
    let emptyFile = Credentials.fileURL(directory: emptyDirectory)

    let empty = Calls()
    let emptyLegacy = Credentials.Legacy(
        read: { name in empty.reads.append(name); return nil },
        delete: { name in empty.deletes.append(name) })

    assert(Credentials.migrate(legacy: emptyLegacy, file: emptyFile) == 0, "nothing to move, nothing should move")
    assert(Credentials.migrate(legacy: emptyLegacy, file: emptyFile) == 0, "second migrate should be a no-op")
    assert(Credentials.load(.slackToken, from: emptyFile) == nil, "absent from both must read nil")
    assert(empty.reads.count == Credentials.Name.allCases.count,
           "legacy was consulted \(empty.reads.count) times for \(Credentials.Name.allCases.count) names")
    assert(empty.deletes.isEmpty, "nothing moved, so nothing should have been deleted from legacy")

    // MARK: no credential value in any error this API can produce

    let secret = "xoxp-secret-that-must-never-appear-in-a-string"
    // A path whose parent is a character device, so createDirectory fails with ENOTDIR.
    let unwritable = URL(fileURLWithPath: "/dev/null/sereno/credentials.json")
    do {
        try Credentials.save(secret, as: .slackToken, to: unwritable)
        assertionFailure("saving under /dev/null must fail")
    } catch let error as CredentialsError {
        assert(!error.message.contains(secret), "the user-facing error message leaked the credential")
        assert(!"\(error)".contains(secret), "the error's own description leaked the credential")
    } catch {
        assertionFailure("save threw something other than CredentialsError")
    }
    // The other case the API can produce, for the same reason.
    let legacyFailure = CredentialsError.legacyDeleteFailed(errSecInternalError)
    assert(!legacyFailure.message.contains(secret) && !"\(legacyFailure)".contains(secret),
           "the legacy-delete error leaked the credential")

    // Everything this demo created is under the three scratch directories the defers remove.
    print("demoCredentials: all checks passed, file mode 600, directory mode 700")
}
