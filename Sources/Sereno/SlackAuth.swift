import Foundation
import AppKit
import CryptoKit
import Network
import Observation
import Security

// Credential layer only. Nothing here fetches messages.
//
// Two rules this file is built around, and neither is a style preference:
//
// 1. No secret is ever printed, logged or written outside the Keychain. There is no
//    `print`, no `Logger`, not even a `.private` one, on any path that can see a token,
//    a code, or a code_verifier. `redacted(_:)` exists for the one case where a human
//    needs to know a token is *there*, and it emits a prefix plus a length, never the
//    middle. An OAuth code in a log file is a usable credential until it is redeemed.
// 2. There is no client_secret. Under PKCE Slack explicitly does not want one, and a
//    Mac binary cannot keep one anyway: `strings Sereno.app/Contents/MacOS/Sereno`
//    would hand it to anybody. The client_id below is deliberately in the clear for
//    the same reason, and that is not a leak. See the comment on it.

// MARK: - Configuration

enum SlackOAuth {
    /// Sereno's own Slack app. **Deliberately public, and it must stay that way.**
    /// PKCE exists precisely so a native app needs no secret: the client_id is an
    /// identifier, not a credential, there is no client_secret anywhere in this app, and
    /// anything compiled into a Mac binary is one `strings` away from anybody regardless.
    /// Sereno is an app other people install, so asking each of them to register their
    /// own Slack app and paste an id would be configuration theatre, not security. Do not
    /// "fix" this by moving it into UserDefaults, a settings field, or an obfuscator; if
    /// it ever has to change, it changes here, in source.
    static let clientID = "11965903665317.11964850390275"

    /// Registered on the Slack app. Must match byte for byte, so it is written once.
    static let redirectURI = "http://localhost:47823/callback"
    static let callbackPort: UInt16 = 47823

    /// Read-only, and `user_scope`, never `scope`: a desktop redirect may not request bot
    /// scopes, and Sereno reads as the signed-in human anyway.
    static let userScopes = [
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "users:read", "usergroups:read",
    ].joined(separator: ",")

    private static let authorizeEndpoint = "https://slack.com/oauth/v2/authorize"
    private static let tokenEndpoint = "https://slack.com/api/oauth.v2.access"

    /// RFC 3986 unreserved. `URLComponents` leaves `:` and `/` raw in a query value, which
    /// makes `redirect_uri` a coin flip against a strict comparison on Slack's side, so the
    /// query is assembled by hand instead.
    private static let unreserved = CharacterSet(charactersIn:
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncode(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? ""
    }

    /// Opened in the user's own browser. Carries no secret: client_id is public under PKCE,
    /// and the challenge is a one-way hash of a verifier that never leaves this process.
    static func authorizeURL(state: String, codeChallenge: String) -> URL {
        let query = [
            ("client_id", clientID),
            ("user_scope", userScopes),
            ("redirect_uri", redirectURI),
            ("state", state),
            ("code_challenge", codeChallenge),
            ("code_challenge_method", "S256"),
        ]
        .map { "\($0)=\(percentEncode($1))" }
        .joined(separator: "&")
        // Force-unwrap is safe: every component above is percent-encoded to unreserved.
        return URL(string: "\(authorizeEndpoint)?\(query)")!
    }

    /// A random `state`, checked on the way back. Without the check the parameter is
    /// decoration: anything that can make the browser hit localhost:47823 could otherwise
    /// feed Sereno an attacker's authorization code.
    static func makeState() -> String { SlackPKCE.base64URL(randomBytes(16)) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        // A predictable verifier or state defeats the entire exchange, so a broken CSPRNG
        // must stop the app rather than downgrade to something guessable.
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    struct Credential {
        let accessToken: String
        let userID: String
        let workspace: String?
    }

    /// POST from the app, not the browser. No client_secret, by design and by Slack's own
    /// instruction for PKCE clients.
    static func exchange(code: String, verifier: String) async throws -> Credential {
        var request = URLRequest(url: URL(string: tokenEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8",
                         forHTTPHeaderField: "Content-Type")
        let body = [
            ("client_id", clientID),
            ("code", code),
            ("redirect_uri", redirectURI),
            ("code_verifier", verifier),
        ]
        .map { "\($0)=\(percentEncode($1))" }
        .joined(separator: "&")
        request.httpBody = Data(body.utf8)

        let data: Data
        do {
            (data, _) = try await URLSession.shared.data(for: request)
        } catch {
            throw SlackAuthError.network(error.localizedDescription)
        }

        // Decoded by hand: three fields out of a large response, and a hand-rolled
        // Decodable tree would be more code than this.
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackAuthError.slack("Slack sent a response Sereno could not read.")
        }
        guard root["ok"] as? Bool == true else {
            throw SlackAuthError.slack(root["error"] as? String ?? "unknown_error")
        }
        guard let user = root["authed_user"] as? [String: Any],
              let token = user["access_token"] as? String, !token.isEmpty,
              let userID = user["id"] as? String, !userID.isEmpty
        else {
            throw SlackAuthError.slack("Slack approved the sign-in but sent no user token.")
        }
        return Credential(accessToken: token,
                          userID: userID,
                          workspace: (root["team"] as? [String: Any])?["name"] as? String)
    }

    /// The ONLY way a credential is allowed to become a human-readable string.
    static func redacted(_ secret: String) -> String {
        let prefix = secret.prefix(5)
        return "\(prefix)…(\(secret.count) chars)"
    }
}

// MARK: - PKCE

enum SlackPKCE {
    /// RFC 7636 section 4.1: unreserved = ALPHA / DIGIT / "-" / "." / "_" / "~".
    static let verifierAllowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    /// 32 CSPRNG bytes, base64url-encoded: 43 characters, the floor of RFC 7636's 43...128,
    /// and every character is already in the allowed set with no filtering needed.
    static func makeVerifier() -> String { base64URL(SlackOAuth.randomBytes(32)) }

    static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// RFC 4648 section 5, padding stripped.
    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - Errors

enum SlackAuthError: Error, Equatable {
    case denied
    case stateMismatch
    case portInUse
    case network(String)
    case slack(String)
    case timedOut
    case cancelled
    case noCode
    case keychain(OSStatus)

    /// Plain language, shown inline in Settings. No jargon the user cannot act on.
    var message: String {
        switch self {
        case .denied:
            "Sign-in was cancelled in Slack. Nothing was connected."
        case .stateMismatch:
            "That sign-in did not match the one Sereno started, so it was rejected. Try connecting again."
        case .portInUse:
            "Port 47823 is already in use, so Sereno could not listen for Slack's reply. Quit whatever is using it, or quit and reopen Sereno, then try again."
        case .network(let why):
            "Could not reach Slack: \(why)"
        case .slack(let code):
            "Slack refused the sign-in: \(code)"
        case .timedOut:
            "Sereno stopped waiting after a few minutes. Try again when you are ready to approve it in the browser."
        case .cancelled:
            "Sign-in cancelled."
        case .noCode:
            "Slack's reply arrived without an authorization code."
        case .keychain(let status):
            "Could not use your Keychain (error \(status))."
        }
    }
}

// MARK: - Callback parsing

/// Split out from the listener so it is testable without a socket, and so the CSRF check
/// sits in one place with one order of business: prove the callback is ours, THEN read it.
enum SlackCallback {
    static func code(fromQuery query: String?, expectedState: String) -> Result<String, SlackAuthError> {
        let pairs = Dictionary(
            (query ?? "").split(separator: "&").compactMap { pair -> (String, String)? in
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard let name = parts.first else { return nil }
                let value = parts.count > 1 ? String(parts[1]) : ""
                return (String(name), value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value)
            },
            uniquingKeysWith: { first, _ in first })

        // State first, always. A callback that is not ours does not get to tell Sereno
        // anything else, not even that it failed.
        guard let state = pairs["state"], state == expectedState else {
            return .failure(.stateMismatch)
        }
        if let error = pairs["error"] {
            return .failure(error == "access_denied" ? .denied : .slack(error))
        }
        guard let code = pairs["code"], !code.isEmpty else { return .failure(.noCode) }
        return .success(code)
    }
}

// MARK: - Loopback listener

/// A localhost HTTP listener that exists for exactly one sign-in attempt.
///
/// Lifetime is bounded three ways, and all three end in `finish`, which cancels the
/// NWListener and every accepted connection exactly once:
///   - a callback arrives (good or bad), or
///   - the caller cancels (Cancel button, or its Task being cancelled), or
///   - the caller's timeout fires.
/// The caller holds it in a `defer { cancel() }`, so an unexpected throw closes the socket
/// too. Nothing schedules a retry and nothing holds a reference past the attempt.
///
/// `@unchecked Sendable`: every mutable field is touched only on `queue`, the same serial
/// queue NWListener delivers its callbacks on.
final class SlackLoopbackListener: @unchecked Sendable {
    /// Fixed at construction, so the CSRF value a callback is judged against cannot be
    /// written on one thread while a connection handler reads it on the queue.
    private let expectedState: String
    private let queue = DispatchQueue(label: "com.rhystart.sereno.oauth-callback")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var ready: CheckedContinuation<Void, Error>?
    private var waiter: CheckedContinuation<String, Error>?
    private var outcome: Result<String, SlackAuthError>?
    private var closed = false

    init(expectedState: String) { self.expectedState = expectedState }

    /// Binds, and resolves once the port is actually ours. Called before the browser opens,
    /// so "port already in use" is reported without first sending the user to Slack.
    func start() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                guard !self.closed else { return continuation.resume(throwing: SlackAuthError.cancelled) }
                self.ready = continuation

                let parameters = NWParameters.tcp
                // Loopback only. Sereno's callback is not something the network should reach.
                parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback),
                                                             port: .init(rawValue: SlackOAuth.callbackPort)!)
                // SO_REUSEADDR, so a TIME_WAIT left by the previous attempt's accepted
                // socket does not make an immediate retry look like a port conflict.
                parameters.allowLocalEndpointReuse = true

                let listener: NWListener
                do {
                    listener = try NWListener(using: parameters)
                } catch {
                    return self.resolveReady(.failure(SlackAuthError.portInUse))
                }
                self.listener = listener

                listener.stateUpdateHandler = { [weak self] state in
                    guard let self else { return }
                    switch state {
                    case .ready:
                        self.resolveReady(.success(()))
                    case .failed(let error):
                        let mapped: SlackAuthError = (error == .posix(.EADDRINUSE) || error == .posix(.EACCES))
                            ? .portInUse
                            : .network(error.localizedDescription)
                        self.resolveReady(.failure(mapped))
                        self.finish(.failure(mapped))
                    case .cancelled:
                        self.resolveReady(.failure(SlackAuthError.cancelled))
                    default:
                        break
                    }
                }
                listener.newConnectionHandler = { [weak self] in self?.accept($0) }
                listener.start(queue: self.queue)
            }
        }
    }

    /// The authorization code from a callback whose `state` matches. Anything else throws.
    func waitForCode() async throws -> String {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                queue.async {
                    if let outcome = self.outcome {
                        return continuation.resume(with: outcome.mapError { $0 as Error })
                    }
                    if self.closed { return continuation.resume(throwing: SlackAuthError.cancelled) }
                    self.waiter = continuation
                }
            }
        } onCancel: {
            self.cancel()
        }
    }

    /// Tears down the socket. Idempotent, and safe to call when nothing ever started.
    func cancel() { queue.async { self.finish(.failure(.cancelled)) } }

    // MARK: private

    private func resolveReady(_ result: Result<Void, Error>) {
        guard let continuation = ready else { return }
        ready = nil
        continuation.resume(with: result)
    }

    private func finish(_ result: Result<String, SlackAuthError>) {
        guard !closed else { return }
        closed = true
        if outcome == nil { outcome = result }
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        connections.forEach { $0.cancel() }
        connections.removeAll()
        resolveReady(.failure(SlackAuthError.cancelled))
        if let waiter {
            self.waiter = nil
            waiter.resume(with: (outcome ?? result).mapError { $0 as Error })
        }
    }

    private func accept(_ connection: NWConnection) {
        guard !closed else { return connection.cancel() }
        connections.append(connection)
        connection.start(queue: queue)
        // 8 KB is far more than "GET /callback?...": Slack's code and state are short, and
        // a request bigger than this is not the browser redirect we are waiting for.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            guard let self else { return connection.cancel() }
            let request = String(decoding: data ?? Data(), as: UTF8.self)
            self.handle(request: request, on: connection)
        }
    }

    private func handle(request: String, on connection: NWConnection) {
        guard !closed else { return connection.cancel() }
        // "GET /callback?code=...&state=... HTTP/1.1"
        let target = request.split(separator: "\r\n").first?
            .split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let parts = target.split(separator: "?", maxSplits: 1)
        let path = parts.first.map(String.init) ?? ""

        // A favicon probe or a stray hit must not end the attempt the user is mid-way
        // through, so only /callback is allowed to decide anything.
        guard path == "/callback" else {
            return respond(on: connection, status: "404 Not Found", html: page(
                title: "Nothing here",
                body: "This is Sereno waiting for a Slack sign-in. Nothing to see on this address."),
                then: nil)
        }

        let result = SlackCallback.code(fromQuery: parts.count > 1 ? String(parts[1]) : nil,
                                        expectedState: expectedState)
        // The browser is a person looking at a tab. A blank page or a dropped connection
        // reads as "the app is broken" even when the sign-in worked.
        let (status, html): (String, String) = switch result {
        case .success:
            ("200 OK", page(title: "Sereno is connected",
                            body: "You can close this tab and go back to Sereno."))
        case .failure(.denied):
            ("200 OK", page(title: "Sign-in cancelled",
                            body: "Nothing was connected. You can close this tab and go back to Sereno."))
        case .failure(.stateMismatch):
            ("400 Bad Request", page(title: "Sign-in rejected",
                                     body: "This reply did not match the sign-in Sereno started, so it was ignored. Close this tab and try again from Sereno."))
        case .failure:
            ("400 Bad Request", page(title: "Sign-in failed",
                                     body: "Slack's reply was not something Sereno could use. Close this tab and try again."))
        }
        // Finishing only after the response is on the wire: `finish` cancels the
        // connection, and a cancel before the flush would show the browser an error page
        // for a sign-in that actually succeeded.
        respond(on: connection, status: status, html: html, then: result)
    }

    private func respond(on connection: NWConnection,
                         status: String,
                         html: String,
                         then result: Result<String, SlackAuthError>?) {
        let body = Data(html.utf8)
        let head = """
        HTTP/1.1 \(status)\r
        Content-Type: text/html; charset=utf-8\r
        Content-Length: \(body.count)\r
        Connection: close\r
        \r

        """
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            guard let self, let result else { return }
            self.queue.async { self.finish(result) }
        })
    }

    private func page(title: String, body: String) -> String {
        """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <div style="font:16px -apple-system,system-ui,sans-serif;max-width:26em;margin:18vh auto;padding:0 1.5em;color:#1d1d1f">
        <h1 style="font-size:1.35em;font-weight:600;margin:0 0 .5em">\(title)</h1>
        <p style="margin:0;line-height:1.5;color:#494950">\(body)</p></div>
        """
    }
}

// MARK: - Keychain

/// `SecItem` generic password, service "com.rhystart.sereno". Not UserDefaults, not a file:
/// those are world-readable to anything running as this user, and a `xoxp-` token reads
/// every message the signed-in human can read.
enum SlackKeychain {
    static let service = "com.rhystart.sereno"
    static let defaultAccount = "slack-user-token"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// Add, or update when the item is already there. `SecItemAdd` returns
    /// errSecDuplicateItem rather than replacing, so re-connecting would fail forever
    /// without this fallback.
    static func save(_ token: String, account: String = defaultAccount) throws {
        let secret = Data(token.utf8)
        var attributes = query(account)
        attributes[kSecValueData as String] = secret
        // Needed on a machine that has booted but not been unlocked since; the default
        // (WhenUnlocked) would fail a background refresh on a locked screen.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(attributes as CFDictionary, nil)
        if status == errSecDuplicateItem {
            let update = SecItemUpdate(query(account) as CFDictionary,
                                       [kSecValueData as String: secret] as CFDictionary)
            guard update == errSecSuccess else { throw SlackAuthError.keychain(update) }
            return
        }
        guard status == errSecSuccess else { throw SlackAuthError.keychain(status) }
    }

    static func load(account: String = defaultAccount) -> String? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// errSecItemNotFound is success: the point is that nothing is stored afterwards.
    static func delete(account: String = defaultAccount) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SlackAuthError.keychain(status)
        }
    }
}

// MARK: - Controller

enum SlackAuthState {
    case disconnected
    case connecting
    case connected(workspace: String?, userID: String)
    case failed(String)
}

@MainActor
@Observable
final class SlackAuth {
    static let shared = SlackAuth()

    private(set) var state: SlackAuthState = .disconnected

    /// Slack's own docs put no clock on an authorize redirect, but an app is not allowed to
    /// hold a listening socket forever waiting for a human who has wandered off.
    private static let attemptTimeout: Duration = .seconds(150)

    private static let userIDKey = "slackUserID"
    private static let workspaceKey = "slackWorkspaceName"

    private var attempt: Task<Void, Never>?

    /// Whether a token is on this machine, not whether this session signed in.
    var hasToken: Bool { SlackKeychain.load() != nil }

    init() {
        // The id and workspace name are not secrets and are needed to render Settings
        // before anything touches the Keychain; the token itself stays in the Keychain.
        if hasToken, let userID = UserDefaults.standard.string(forKey: Self.userIDKey) {
            state = .connected(workspace: UserDefaults.standard.string(forKey: Self.workspaceKey),
                               userID: userID)
        }
    }

    /// No arguments, and nothing to configure first: the client_id is a constant.
    func connect() async {
        if case .connecting = state { return }

        state = .connecting
        let task = Task { await self.run() }
        attempt = task
        await task.value
        attempt = nil
    }

    /// Cancel from the UI. Cancelling the Task trips the listener's cancellation handler,
    /// which closes the socket; it does not merely stop waiting on it.
    func cancelConnect() {
        attempt?.cancel()
        attempt = nil
        state = .disconnected
    }

    /// Deletes the stored token. Forgetting it in memory would leave a working credential
    /// in the Keychain for the next launch to pick straight back up.
    func disconnect() {
        do {
            try SlackKeychain.delete()
            UserDefaults.standard.removeObject(forKey: Self.userIDKey)
            UserDefaults.standard.removeObject(forKey: Self.workspaceKey)
            state = .disconnected
        } catch {
            state = .failed((error as? SlackAuthError ?? .keychain(errSecInternalError)).message)
        }
    }

    private func run() async {
        let verifier = SlackPKCE.makeVerifier()
        let csrfState = SlackOAuth.makeState()
        let listener = SlackLoopbackListener(expectedState: csrfState)
        // Covers every exit: success, throw, timeout, cancellation.
        defer { listener.cancel() }

        do {
            // Bind before opening the browser, so a busy port is a message in Settings
            // rather than a Slack tab that fails on the way back.
            try await listener.start()
            NSWorkspace.shared.open(SlackOAuth.authorizeURL(
                state: csrfState,
                codeChallenge: SlackPKCE.challenge(for: verifier)))
            let code = try await withThrowingTaskGroup(of: String.self) { group in
                group.addTask { try await listener.waitForCode() }
                group.addTask {
                    try await Task.sleep(for: Self.attemptTimeout)
                    throw SlackAuthError.timedOut
                }
                defer { group.cancelAll() }
                return try await group.next()!
            }
            let credential = try await SlackOAuth.exchange(code: code, verifier: verifier)
            try SlackKeychain.save(credential.accessToken)
            UserDefaults.standard.set(credential.userID, forKey: Self.userIDKey)
            UserDefaults.standard.set(credential.workspace, forKey: Self.workspaceKey)
            state = .connected(workspace: credential.workspace, userID: credential.userID)
        } catch is CancellationError {
            state = .disconnected
        } catch let error as SlackAuthError {
            state = error == .cancelled ? .disconnected : .failed(error.message)
        } catch {
            state = .failed(SlackAuthError.network(error.localizedDescription).message)
        }
    }
}

// MARK: - Runnable checks

/// Plain asserts over the pure parts: no network, no browser, no real token, and the
/// Keychain round-trip uses a throwaway account it deletes on the way out.
///
/// Run from a scratch package that compiles this file with its own @main. Nothing in the
/// app calls it, so the app ships one entry point.
func demoSlackAuth() {
    // code_verifier: RFC 7636 section 4.1 length and charset.
    let verifier = SlackPKCE.makeVerifier()
    assert((43...128).contains(verifier.count), "verifier length \(verifier.count) outside 43...128")
    assert(verifier.allSatisfy { SlackPKCE.verifierAllowed.contains($0) }, "verifier has illegal characters")

    // Actually random, not a constant that merely looks like one.
    assert(SlackPKCE.makeVerifier() != SlackPKCE.makeVerifier(), "two verifiers matched")
    assert(SlackOAuth.makeState() != SlackOAuth.makeState(), "two states matched")

    // RFC 7636 Appendix B's vector, so the base64url-of-SHA256 encoding is proven against
    // an outside source instead of against itself.
    assert(SlackPKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
           == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM", "challenge disagrees with RFC 7636 B")
    // No padding, and no character outside the URL-safe alphabet.
    let challenge = SlackPKCE.challenge(for: verifier)
    assert(!challenge.contains("=") && !challenge.contains("+") && !challenge.contains("/"),
           "challenge is not base64url-no-padding")

    // Authorize URL. The client_id is a compiled-in constant now, not a preference, so the
    // assert is on the constant itself: a typo in it is a sign-in that fails at Slack.
    assert(!SlackOAuth.clientID.isEmpty, "client_id constant is empty")
    let url = SlackOAuth.authorizeURL(state: "st", codeChallenge: challenge)
    let query = url.query ?? ""
    assert(url.absoluteString.hasPrefix("https://slack.com/oauth/v2/authorize?"), "wrong authorize endpoint")
    assert(query.contains("client_id=11965903665317.11964850390275"), "authorize URL carries the wrong client_id")
    assert(query.contains("user_scope=channels%3Ahistory"), "user_scope missing or unencoded")
    // `scope=` on its own would be the bot-scope parameter. `user_scope=` contains it as a
    // substring, so the check has to be anchored to a parameter boundary.
    assert(!query.contains("&scope=") && !query.hasPrefix("scope="), "sends bot scope, not user_scope")
    assert(query.contains("code_challenge_method=S256"), "missing code_challenge_method=S256")
    assert(query.contains("redirect_uri=http%3A%2F%2Flocalhost%3A47823%2Fcallback"),
           "redirect_uri not percent-encoded exactly")
    assert(!query.contains("client_secret"), "client_secret in an authorize URL")

    // Callback: state is the gate.
    let good = "code=abc123&state=st"
    assert(SlackCallback.code(fromQuery: good, expectedState: "st") == .success("abc123"), "good callback rejected")
    assert(SlackCallback.code(fromQuery: good, expectedState: "other") == .failure(.stateMismatch),
           "mismatched state accepted")
    assert(SlackCallback.code(fromQuery: "code=abc123", expectedState: "st") == .failure(.stateMismatch),
           "missing state accepted")
    // A cancellation is a cancellation, not a crash and not silence.
    assert(SlackCallback.code(fromQuery: "error=access_denied&state=st", expectedState: "st") == .failure(.denied),
           "access_denied not reported as cancellation")
    assert(SlackCallback.code(fromQuery: "error=invalid_scope&state=st", expectedState: "st")
           == .failure(.slack("invalid_scope")), "other Slack error mislabelled")
    assert(SlackCallback.code(fromQuery: "state=st", expectedState: "st") == .failure(.noCode),
           "empty callback accepted")
    // An attacker's code with the wrong state must lose even when a code is present.
    assert(SlackCallback.code(fromQuery: "code=attacker&state=guess", expectedState: "st")
           == .failure(.stateMismatch), "CSRF check bypassed")

    // Keychain round-trip on a throwaway account, cleaned up below whatever happens.
    let scratch = "demo-only-\(UUID().uuidString)"
    assert(SlackKeychain.load(account: scratch) == nil, "throwaway account already had a value")
    let fake = "xoxp-not-a-real-token-0123456789"
    try! SlackKeychain.save(fake, account: scratch)
    assert(SlackKeychain.load(account: scratch) == fake, "keychain load did not match save")
    // The "already exists" path: save again must update, not fail.
    try! SlackKeychain.save(fake + "-updated", account: scratch)
    assert(SlackKeychain.load(account: scratch) == fake + "-updated", "second save did not update")
    try! SlackKeychain.delete(account: scratch)
    assert(SlackKeychain.load(account: scratch) == nil, "keychain delete left the item behind")
    // Deleting nothing is not an error, so a Disconnect with no token cannot fail.
    try! SlackKeychain.delete(account: scratch)

    // Redaction, the only string form a credential may take.
    let redacted = SlackOAuth.redacted(fake)
    assert(redacted == "xoxp-…(32 chars)", "unexpected redaction: \(redacted)")
    assert(!redacted.contains("not-a-real-token"), "redaction leaked the body")

    // Printable because it holds no secret: the client_id is public by design, and the
    // state and challenge are fed in as placeholders rather than the real random values.
    print("authorize URL: \(SlackOAuth.authorizeURL(state: "REDACTED", codeChallenge: "REDACTED"))")
    print("demoSlackAuth: all checks passed")
}
