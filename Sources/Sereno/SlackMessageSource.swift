import Foundation
import os

/// PRIVACY RULE FOR THIS WHOLE FILE. Ids, counts, HTTP status codes and Slack's own error
/// slugs are `.public`: none of them is content. Message text, sender names, channel names
/// and permalinks are Slack content and are never logged at all, at any privacy level.
/// The token is never logged, never written outside the Keychain, and never interpolated.
/// A colleague's message in the unified log is a leak, so the safe default here is silence.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "slack")

// MARK: - Errors

/// Distinguishable on purpose. "Reconnect Slack" and "no network" need different words in
/// the banner, and neither may be reported as an empty list: inbox zero is a lie the user
/// would act on. `Store.refresh()` shows `localizedDescription`, which LocalizedError
/// routes to `errorDescription`.
enum SlackSourceError: LocalizedError, Equatable {
    /// No token on this machine. The source router avoids this, so it means a disconnect
    /// landed mid-refresh.
    case notConnected
    /// invalid_auth, token_revoked, account_inactive. The credential is dead.
    case reconnect
    /// Slack named a scope the token does not carry.
    case missingScope(String)
    /// 429 after honouring Retry-After.
    case rateLimited
    case offline
    case network(String)
    /// Any other `ok: false`, carrying Slack's slug so the log and the banner agree.
    case slack(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Slack is not connected. Connect it in Settings."
        case .reconnect:
            "Slack rejected the saved sign-in. Reconnect Slack in Settings."
        case .missingScope(let scope):
            "Slack needs the \(scope) permission. Reconnect Slack in Settings to grant it."
        case .rateLimited:
            "Slack is rate limiting Sereno. The next refresh picks up where this one stopped."
        case .offline:
            "No network. Sereno could not reach Slack."
        case .network(let why):
            "Sereno could not reach Slack. \(why)"
        case .slack(let code):
            "Slack refused the request (\(code))."
        case .badResponse:
            "Slack sent a response Sereno could not read."
        }
    }

    /// A dead token or a missing scope will fail identically for every conversation, so
    /// there is nothing to salvage. Everything else is per-conversation bad luck.
    var isFatal: Bool {
        switch self {
        case .notConnected, .reconnect, .missingScope: true
        default: false
        }
    }
}

// MARK: - Raw Slack shapes

/// One message as `conversations.history` and `conversations.replies` return it.
/// Hand-decoded, matching SlackAuth: six fields out of a large object, and a Decodable
/// tree would be more code than this.
struct RawMessage: Sendable, Equatable {
    let ts: String
    let user: String
    let text: String
    let subtype: String?
    let threadTS: String?
    let replyCount: Int
    /// Up to five ids of people who replied, handed over for free with the parent.
    /// This is what saves a request per thread.
    let replyUsers: [String]

    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }
    /// A parent's own thread_ts equals its ts, so this is only true for a real reply.
    var isThreadReply: Bool { threadTS != nil && threadTS != ts }

    init?(_ json: [String: Any]) {
        guard let ts = json["ts"] as? String else { return nil }
        self.ts = ts
        user = json["user"] as? String ?? ""
        text = json["text"] as? String ?? ""
        subtype = json["subtype"] as? String
        threadTS = json["thread_ts"] as? String
        replyCount = json["reply_count"] as? Int ?? 0
        replyUsers = json["reply_users"] as? [String] ?? []
    }
}

/// One entry from `users.conversations`. `name` is nil for both DM kinds: SlackMessage
/// documents nil channel as "direct message", and an mpim's real name is machine noise
/// like "mpdm-a--b--c-1".
struct SlackConversation: Sendable, Equatable {
    let id: String
    let kind: ChannelKind
    let name: String?

    /// IMs and MPIMs first: there are few of them and they are the highest signal, so
    /// they must be the ones inside the call budget when a big workspace overflows it.
    var priority: Int {
        switch kind {
        case .im: 0
        case .mpim: 1
        case .privateChannel: 2
        case .publicChannel: 3
        }
    }
}

// MARK: - The source

/// The real Slack client. An `actor` because the caches (identity, conversation list, user
/// names) outlive one refresh and three requests are in flight at once; actor isolation is
/// the whole of the locking.
actor SlackMessageSource: MessageSource {
    /// The single seam. Returns raw response bytes for one Web API method, having already
    /// dealt with 429 and 5xx. `Data` rather than a parsed dictionary so nothing
    /// non-Sendable crosses back into the actor, and so the demo can hand over canned JSON.
    typealias Call = @Sendable (_ method: String, _ query: [(String, String)]) async throws -> Data

    /// CALL BUDGET. Slack's limits are per method per workspace, but the real hazard for a
    /// single custom app is the total burst of one refresh, so the budget is total. When it
    /// runs out the refresh STOPS and returns what it already has. A partial list is far
    /// better than an empty one, and the next refresh starts from a full budget.
    static let callBudget = 40
    /// Three in flight. Enough to hide latency, low enough that a 429 is a surprise.
    private static let maxInFlight = 3
    /// How far back one conversation is read. `since` picks WHICH conversations to return,
    /// this window decides how much of each one is in hand, and it has to be wide enough to
    /// contain the user's last message so the unreplied tail can be found at all.
    private static let historyWindow: TimeInterval = 7 * 24 * 60 * 60
    /// The conversation list changes rarely, so it is refetched every tenth refresh.
    private static let conversationCacheRefreshes = 10

    private let call: Call
    private let totalBudget: Int
    /// Requests held back for display-name lookups, so a workspace big enough to eat the
    /// budget still shows names rather than a column of user ids.
    private let nameReserve: Int
    private var budget = 0

    private var identity: Identity?
    private var permalinkHost = "app.slack.com"
    private var conversations: [SlackConversation] = []
    private var refreshCount = 0
    private var userNames: [String: String] = [:]

    /// Conversations whose newest real message this cycle was the user's own, which is
    /// exactly the question `repliedIDs(among:)` asks. Filled during the scan so reply
    /// detection costs no extra requests.
    private var settled: Set<String> = []

    init(call: Call? = nil, budget: Int = SlackMessageSource.callBudget) {
        self.call = call ?? SlackMessageSource.httpCall
        totalBudget = budget
        nameReserve = max(1, budget / 5)
    }

    // MARK: Budget

    /// Reserve one request. `reserve` keeps a tail of the budget for name lookups.
    private func spend(reserve: Int = 0) -> Bool {
        guard budget > reserve else { return false }
        budget -= 1
        return true
    }

    private func get(_ method: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        let data = try await call(method, query)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackSourceError.badResponse
        }
        guard root["ok"] as? Bool == true else { throw Self.error(for: root) }
        return root
    }

    // MARK: Identity

    private func ensureIdentity() async throws -> Identity {
        // A disconnect followed by a sign-in as someone else in the same app run must not
        // keep the old identity: addressing detection would then answer for the wrong human.
        if let identity, Self.storedUserID().map({ $0 == identity.userID }) ?? true {
            return identity
        }
        guard spend() else { throw SlackSourceError.rateLimited }
        let auth = try await get("auth.test")
        guard let userID = auth["user_id"] as? String, !userID.isEmpty else {
            throw SlackSourceError.badResponse
        }
        if let host = (auth["url"] as? String).flatMap({ URL(string: $0)?.host }) {
            permalinkHost = host
        }

        var display = "", real = ""
        if spend(), let info = try? await get("users.info", [("user", userID)]),
           let user = info["user"] as? [String: Any] {
            real = user["real_name"] as? String ?? ""
            display = ((user["profile"] as? [String: Any])?["display_name"] as? String) ?? ""
        }

        // usergroups.list needs its own scope and is missing on most plans, so a failure
        // degrades to no groups rather than losing the whole refresh. The cost is that
        // .userGroup never fires, not that the app stops working.
        var groups: Set<String> = []
        if spend(), let list = try? await get("usergroups.list", [("include_users", "true")]),
           let raw = list["usergroups"] as? [[String: Any]] {
            groups = Set(raw.compactMap { group in
                let members = group["users"] as? [String] ?? []
                return members.contains(userID) ? group["id"] as? String : nil
            })
        }

        // role is deliberately left empty: Triage fills it from Preferences.
        let built = Identity(userID: userID, displayName: display, realName: real, userGroupIDs: groups)
        identity = built
        log.info("identity resolved user=\(userID, privacy: .public) groups=\(groups.count, privacy: .public)")
        return built
    }

    private nonisolated static func storedUserID() -> String? {
        UserDefaults.standard.string(forKey: "slackUserID")
    }

    // MARK: Conversation list

    private func ensureConversations() async throws -> [SlackConversation] {
        if !conversations.isEmpty, refreshCount % Self.conversationCacheRefreshes != 0 {
            return conversations
        }
        var found: [SlackConversation] = []
        var cursor: String?
        var pages = 0
        repeat {
            guard spend(reserve: nameReserve) else { break }
            var query = [("types", "public_channel,private_channel,im,mpim"),
                         ("exclude_archived", "true"),
                         ("limit", "200")]
            if let cursor { query.append(("cursor", cursor)) }
            let page = try await get("users.conversations", query)
            found += Self.parseConversations(page)
            cursor = Self.nextCursor(page)
            pages += 1
        } while cursor != nil && pages < 5

        guard !found.isEmpty else { return conversations }
        conversations = found.sorted { ($0.priority, $0.id) < ($1.priority, $1.id) }
        log.info("conversations cached count=\(self.conversations.count, privacy: .public)")
        return conversations
    }

    // MARK: MessageSource

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        budget = totalBudget
        settled = []
        defer { refreshCount += 1 }

        let identity = try await ensureIdentity()
        let all = try await ensureConversations()

        var results: [Result<[Pending], Error>] = []
        var index = 0
        var skipped = 0

        // Three conversations in flight, refilled as each one lands, so the budget is
        // spent in priority order rather than all at once. A child never throws: one
        // unreadable channel must not cost the other thirty-nine.
        await withTaskGroup(of: Result<[Pending], Error>.self) { group in
            var inFlight = 0
            while index < all.count {
                guard budget > nameReserve else {
                    skipped = all.count - index
                    break
                }
                let conversation = all[index]
                index += 1
                group.addTask {
                    do { return .success(try await self.scan(conversation, since: since, identity: identity)) }
                    catch { return .failure(error) }
                }
                inFlight += 1
                if inFlight == Self.maxInFlight, let result = await group.next() {
                    inFlight -= 1
                    results.append(result)
                }
            }
            // No cancelAll: the conversations already in flight are results worth waiting
            // for, and cancelling them throws their requests away.
            for await result in group { results.append(result) }
        }

        var pending: [Pending] = []
        var firstError: Error?
        var failed = 0
        for result in results {
            switch result {
            case .success(let batch):
                pending += batch
            case .failure(let error):
                // A dead token or a missing scope fails identically everywhere, so there
                // is nothing left to salvage from this refresh.
                if let slack = error as? SlackSourceError, slack.isFatal { throw slack }
                firstError = firstError ?? error
                failed += 1
            }
        }

        // An empty list has to mean inbox zero. If nothing came back and something went
        // wrong, the banner gets the error instead.
        if pending.isEmpty, let firstError { throw firstError }
        log.info("""
            refresh done conversations=\(all.count, privacy: .public) \
            messages=\(pending.count, privacy: .public) \
            skippedForBudget=\(skipped, privacy: .public) \
            failedConversations=\(failed, privacy: .public) \
            callsLeft=\(self.budget, privacy: .public)
            """)

        let names = await resolveNames(Set(pending.map(\.raw.user)))
        return pending
            .map { $0.message(identity: identity, host: permalinkHost, names: names) }
            .sorted { $0.date > $1.date }
    }

    func repliedIDs(among ids: [String]) async throws -> Set<String> {
        // TodoItem ids are a conversationID or conversationID#n. Nothing is fetched here:
        // the scan that just ran already answered this for every conversation it read.
        // ponytail: a conversation the scan did not reach stays open until a later refresh
        // touches it. A thread ts carries no channel id, so resolving one on its own would
        // need a search call, and leaving an item open is the safe direction.
        Set(ids.filter { settled.contains(Self.conversationKey(ofItem: $0)) })
    }

    static func conversationKey(ofItem id: String) -> String {
        id.split(separator: "#").first.map(String.init) ?? id
    }

    // MARK: Scanning one conversation

    private struct Pending: Sendable {
        let raw: RawMessage
        let conversation: SlackConversation
        let thread: ThreadContext?

        func message(identity: Identity, host: String, names: [String: String]) -> SlackMessage {
            let facts = MessageFacts(
                text: raw.text,
                channelKind: conversation.kind,
                authorID: raw.user,
                threadTS: thread?.ts,
                parentAuthorID: thread?.parentAuthorID,
                threadParticipantIDs: thread?.participants ?? []
            )
            let signals = addressing(facts, identity: identity)
            return SlackMessage(
                id: "\(conversation.id)/\(raw.ts)",
                conversationID: thread?.ts ?? conversation.id,
                sender: names[raw.user] ?? raw.user,
                channel: conversation.name.map { "#\($0)" },
                text: raw.text,
                date: raw.date,
                directlyAddressed: signals.isPersonal,
                addressing: signals,
                permalink: SlackMessageSource.permalink(
                    host: host, channel: conversation.id, ts: raw.ts, threadTS: thread?.ts)
            )
        }
    }

    struct ThreadContext: Sendable {
        let ts: String
        let parentAuthorID: String?
        let participants: Set<String>
    }

    private func scan(
        _ conversation: SlackConversation,
        since: Date,
        identity: Identity
    ) async throws -> [Pending] {
        guard spend(reserve: nameReserve) else { return [] }
        let base = [("channel", conversation.id),
                    ("oldest", Self.slackTS(Date().addingTimeInterval(-Self.historyWindow))),
                    ("limit", "200")]
        let page = try await get("conversations.history", base)
        var raw = Self.parseMessages(page)

        // One extra page, and only when the first page holds nothing of the user's own.
        // History comes back newest first, so a second page is OLDER, and the only reason
        // to want older is that the start of the tail, the user's last message, is not in
        // hand yet. Paging past that would just buy context nobody reads.
        if !raw.contains(where: { $0.user == identity.userID }),
           page["has_more"] as? Bool == true,
           let cursor = Self.nextCursor(page),
           spend(reserve: nameReserve) {
            raw += Self.parseMessages(try await get("conversations.history", base + [("cursor", cursor)]))
        }

        let ordered = Self.ordered(raw)
        // "Settled" needs positive proof that the user's own message is the newest thing
        // here. An empty window proves nothing, and treating it as settled would silently
        // mark an old open task done.
        if let newest = ordered.last, newest.user == identity.userID {
            settled.insert(conversation.id)
        }

        var pending: [Pending] = []
        // Threads first, so a parent whose thread was read is not ALSO reported as a
        // channel message. A thread parent is a channel message, and emitting both would
        // put the same obligation on the list twice under two different conversation ids.
        var handled: Set<String> = []

        for parent in ordered where Self.shouldFetchReplies(parent, userID: identity.userID) {
            guard spend(reserve: nameReserve) else { break }
            let replies = Self.ordered(Self.parseMessages(
                try await get("conversations.replies",
                              [("channel", conversation.id), ("ts", parent.ts), ("limit", "200")])))
            guard let root = replies.first else { continue }
            handled.insert(parent.ts)
            let key = root.threadTS ?? root.ts
            if let newest = replies.last, newest.user == identity.userID { settled.insert(key) }

            let threadTail = Self.unrepliedTail(replies, userID: identity.userID)
            if let newest = threadTail.last, newest.date > since {
                let context = ThreadContext(ts: key,
                                            parentAuthorID: root.user,
                                            participants: Set(replies.map(\.user)))
                pending += threadTail.map {
                    Pending(raw: $0, conversation: conversation, thread: context)
                }
            }
        }

        let tail = Self.unrepliedTail(ordered, userID: identity.userID)
            .filter { !$0.isThreadReply && !handled.contains($0.ts) }
        if let newest = tail.last, newest.date > since {
            pending += tail.map { Pending(raw: $0, conversation: conversation, thread: nil) }
        }
        return pending
    }

    /// Display names, cached for the life of the process. ponytail: one users.info per
    /// unknown author, sequential, because after the first refresh this is nearly always
    /// zero calls. Switch to one paginated users.list if a cold cache ever costs real time.
    private func resolveNames(_ ids: Set<String>) async -> [String: String] {
        for id in ids.sorted() where userNames[id] == nil {
            guard spend() else { break }
            guard let info = try? await get("users.info", [("user", id)]),
                  let user = info["user"] as? [String: Any] else { continue }
            let display = ((user["profile"] as? [String: Any])?["display_name"] as? String) ?? ""
            let real = user["real_name"] as? String ?? ""
            userNames[id] = display.isEmpty ? (real.isEmpty ? id : real) : display
        }
        return userNames
    }

    // MARK: - Pure helpers, all of them checkable offline

    /// Slack permalinks are BUILT, not fetched. chat.getPermalink would be one request per
    /// message, which is the quickest way to spend a rate limit on pure string work: the
    /// archive URL is the channel id plus the ts with its dot removed. A threaded message
    /// also needs thread_ts and cid, or Slack opens the channel around the message rather
    /// than the thread it lives in.
    static func permalink(host: String, channel: String, ts: String, threadTS: String?) -> URL? {
        var string = "https://\(host)/archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))"
        if let threadTS { string += "?thread_ts=\(threadTS)&cid=\(channel)" }
        return URL(string: string)
    }

    /// Subtypes that are still a message a human might owe a reply to. Everything else with
    /// a subtype is channel furniture (channel_join, channel_leave, topic and purpose
    /// changes, pins) or a bot post. Bots are excluded deliberately: a webhook alert is not
    /// a reply you owe, and including them buried the real list in the earliest fixtures.
    static let keptSubtypes: Set<String> = ["thread_broadcast", "file_share", "me_message"]

    static func isRealMessage(_ message: RawMessage) -> Bool {
        guard !message.user.isEmpty else { return false }  // bot_id only, no human author
        guard let subtype = message.subtype else { return true }
        return keptSubtypes.contains(subtype)
    }

    /// Real messages, oldest first.
    static func ordered(_ raw: [RawMessage]) -> [RawMessage] {
        raw.filter(isRealMessage).sorted { $0.ts < $1.ts }
    }

    /// Everything that arrived after the user's own most recent message. If they have
    /// posted since, everything before that is settled, whatever it said.
    ///
    /// This returns the conversation's FULL tail, not just what is newer than the last
    /// scan. `since` decides which conversations are worth returning; the tail is what
    /// makes them readable. "Hi" followed an hour later by "review it within the hour" is
    /// one obligation, and handing Triage only the second half strips its antecedent.
    static func unrepliedTail(_ raw: [RawMessage], userID: String) -> [RawMessage] {
        let ordered = ordered(raw)
        guard let mine = ordered.lastIndex(where: { $0.user == userID }) else { return ordered }
        return Array(ordered[ordered.index(after: mine)...])
    }

    /// Whether a thread's replies are worth a request. `conversations.history` already hands
    /// over `reply_users` with the parent, so a thread the user has never touched is skipped
    /// without asking Slack about it. Without this, every thread in every channel costs a
    /// call, and a busy workspace would spend the whole budget on threads nobody is in.
    /// ponytail: Slack caps reply_users at five, so a thread with more than five distinct
    /// repliers can hide the user and gets skipped. Accepted: the alternative is a request
    /// per thread, which is the exact cost this exists to avoid.
    static func shouldFetchReplies(_ parent: RawMessage, userID: String) -> Bool {
        guard parent.replyCount > 0, !parent.isThreadReply else { return false }
        return parent.user == userID || parent.replyUsers.contains(userID)
    }

    /// Slack sends 429 with Retry-After in whole seconds, per method per workspace.
    static func retryAfter(_ response: HTTPURLResponse) -> Duration? {
        guard response.statusCode == 429,
              let raw = response.value(forHTTPHeaderField: "Retry-After"),
              let seconds = Int(raw.trimmingCharacters(in: .whitespaces)), seconds >= 0
        else { return nil }
        return .seconds(seconds)
    }

    static func error(for root: [String: Any]) -> SlackSourceError {
        switch root["error"] as? String ?? "" {
        case "invalid_auth", "token_revoked", "account_inactive", "not_authed":
            .reconnect
        case "missing_scope":
            .missingScope(root["needed"] as? String ?? "an extra")
        case "ratelimited":
            .rateLimited
        case let other:
            .slack(other.isEmpty ? "unknown_error" : other)
        }
    }

    static func parseMessages(_ root: [String: Any]) -> [RawMessage] {
        (root["messages"] as? [[String: Any]] ?? []).compactMap(RawMessage.init)
    }

    static func parseConversations(_ root: [String: Any]) -> [SlackConversation] {
        (root["channels"] as? [[String: Any]] ?? []).compactMap { channel in
            guard let id = channel["id"] as? String else { return nil }
            let kind: ChannelKind = if channel["is_im"] as? Bool == true { .im }
                else if channel["is_mpim"] as? Bool == true { .mpim }
                else if channel["is_private"] as? Bool == true { .privateChannel }
                else { .publicChannel }
            let named = kind == .im || kind == .mpim ? nil : channel["name"] as? String
            return SlackConversation(id: id, kind: kind, name: named)
        }
    }

    static func nextCursor(_ root: [String: Any]) -> String? {
        guard let cursor = (root["response_metadata"] as? [String: Any])?["next_cursor"] as? String,
              !cursor.isEmpty else { return nil }
        return cursor
    }

    static func slackTS(_ date: Date) -> String {
        String(format: "%.6f", date.timeIntervalSince1970)
    }

    // MARK: - Transport

    /// Sleeping longer than this stalls the whole refresh, so a long Retry-After is
    /// reported instead of waited out. The next refresh tries again.
    private static let maxRetryWait = Duration.seconds(30)

    private static func httpCall(_ method: String, _ query: [(String, String)]) async throws -> Data {
        guard let token = SlackKeychain.load() else { throw SlackSourceError.notConnected }
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw SlackSourceError.badResponse }
        var request = URLRequest(url: url)
        // The token lives in this frame and nowhere else. Not logged, not redacted, not
        // stored: the Keychain is the only copy.
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        for attempt in 0..<4 {
            let data: Data
            let response: URLResponse
            do {
                (data, response) = try await URLSession.shared.data(for: request)
            } catch let error as URLError {
                throw Self.transportError(error)
            }
            guard let http = response as? HTTPURLResponse else { return data }

            if let wait = retryAfter(http) {
                guard attempt < 2, wait <= maxRetryWait else { throw SlackSourceError.rateLimited }
                log.info("rate limited method=\(method, privacy: .public) waiting=\(wait.components.seconds, privacy: .public)s")
                try await Task.sleep(for: wait)
                continue
            }
            if http.statusCode >= 500 {
                // One retry, then give up. A 5xx that repeats is Slack's problem.
                guard attempt < 1 else { throw SlackSourceError.slack("http_\(http.statusCode)") }
                log.info("server error method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public)")
                try await Task.sleep(for: .seconds(1))
                continue
            }
            // Any other 4xx is a request this app got wrong. Retrying repeats the mistake.
            guard (200..<300).contains(http.statusCode) else {
                throw SlackSourceError.slack("http_\(http.statusCode)")
            }
            return data
        }
        throw SlackSourceError.rateLimited
    }

    private static func transportError(_ error: URLError) -> SlackSourceError {
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .cannotFindHost,
             .cannotConnectToHost, .dataNotAllowed, .dnsLookupFailed:
            .offline
        default:
            // localizedDescription here is URLSession's own wording. It carries no Slack
            // content, but it is still not logged, only shown to the user in the banner.
            .network(error.localizedDescription)
        }
    }
}

// MARK: - What App.swift installs

/// The source Store is given at launch. Store holds `let source` for the whole app run, so
/// the mock-or-Slack choice cannot be made once at startup: it is made per call, by asking
/// the Keychain. That is what makes connecting or disconnecting Slack take effect on the
/// next refresh instead of on the next launch. The caches live in the SlackMessageSource
/// instance, so switching back and forth costs nothing.
struct LiveMessageSource: MessageSource {
    private let slack = SlackMessageSource()
    private let mock = MockMessageSource()

    private var connected: Bool { SlackKeychain.load() != nil }

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        connected
            ? try await slack.unrepliedMessages(since: since)
            : try await mock.unrepliedMessages(since: since)
    }

    func repliedIDs(among ids: [String]) async throws -> Set<String> {
        connected
            ? try await slack.repliedIDs(among: ids)
            : try await mock.repliedIDs(among: ids)
    }
}

// MARK: - Runnable check

/// Plain asserts, no network: every response below is canned JSON. Run from a throwaway
/// main. Nothing here is a real workspace, a real person or a real token.
func demoSlackSource() async {
    typealias S = SlackMessageSource

    // MARK: permalink construction
    assert(S.permalink(host: "acme.slack.com", channel: "C0123", ts: "1728394855.123456", threadTS: nil)?
        .absoluteString == "https://acme.slack.com/archives/C0123/p1728394855123456")
    assert(S.permalink(host: "acme.slack.com", channel: "C0123", ts: "1728394999.000200", threadTS: "1728394855.123456")?
        .absoluteString == "https://acme.slack.com/archives/C0123/p1728394999000200?thread_ts=1728394855.123456&cid=C0123")
    // The dot is removed, never replaced, and never left in.
    assert(!S.permalink(host: "acme.slack.com", channel: "C0123", ts: "1.2", threadTS: nil)!
        .absoluteString.hasSuffix("p1.2"))

    // MARK: unreplied detection, the user posted in the middle
    func raw(_ json: String) -> [RawMessage] {
        S.parseMessages((try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
    }
    let interleaved = raw("""
    {"ok":true,"messages":[
      {"ts":"1728394805.000100","user":"U_OTHER","text":"first, before my reply"},
      {"ts":"1728394815.000100","user":"U_ME","text":"my reply"},
      {"ts":"1728394825.000100","user":"U_OTHER","text":"Hi"},
      {"ts":"1728394835.000100","user":"U_OTHER","text":"review it within the hour"},
      {"ts":"1728394845.000100","user":"U_OTHER","subtype":"channel_join","text":"joined"},
      {"ts":"1728394855.000100","user":"","subtype":"bot_message","text":"build failed"}
    ]}
    """)
    assert(interleaved.count == 6, "all six parse, filtering happens later")
    let tail = S.unrepliedTail(interleaved, userID: "U_ME")
    assert(tail.map(\.text) == ["Hi", "review it within the hour"],
           "only messages after the user's own last message, got \(tail.count)")
    // The user's own message and the join and the bot post are all gone.
    assert(!tail.contains { $0.user == "U_ME" })
    assert(!tail.contains { $0.subtype == "channel_join" })
    assert(!tail.contains { $0.user.isEmpty })
    assert(S.unrepliedTail(interleaved, userID: "U_NOBODY").count == 4,
           "a user who never posted owes the whole visible history")

    // MARK: reply_users decides whether a thread costs a request
    func parent(_ replyUsers: [String], count: Int = 2, author: String = "U_OTHER") -> RawMessage {
        let users = replyUsers.map { "\"\($0)\"" }.joined(separator: ",")
        return raw("""
        {"messages":[{"ts":"111.0001","user":"\(author)","text":"parent","thread_ts":"111.0001",
        "reply_count":\(count),"reply_users":[\(users)]}]}
        """)[0]
    }
    assert(S.shouldFetchReplies(parent(["U_X", "U_ME"]), userID: "U_ME"))
    assert(!S.shouldFetchReplies(parent(["U_X", "U_Y"]), userID: "U_ME"))
    assert(S.shouldFetchReplies(parent(["U_X"], author: "U_ME"), userID: "U_ME"),
           "the user's own thread is theirs to answer even if they never replied in it")
    assert(!S.shouldFetchReplies(parent(["U_ME"], count: 0), userID: "U_ME"),
           "no replies, nothing to fetch")

    // MARK: 429
    let limited = HTTPURLResponse(url: URL(string: "https://slack.com/api/conversations.history")!,
                                  statusCode: 429, httpVersion: nil,
                                  headerFields: ["Retry-After": "3"])!
    assert(S.retryAfter(limited) == .seconds(3), "Retry-After: 3 must be three seconds")
    let fine = HTTPURLResponse(url: URL(string: "https://slack.com/api/auth.test")!,
                               statusCode: 200, httpVersion: nil, headerFields: [:])!
    assert(S.retryAfter(fine) == nil)

    // MARK: error taxonomy
    func slackError(_ json: String) -> SlackSourceError {
        S.error(for: (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:])
    }
    assert(slackError(#"{"ok":false,"error":"invalid_auth"}"#) == .reconnect)
    assert(slackError(#"{"ok":false,"error":"token_revoked"}"#) == .reconnect)
    assert(slackError(#"{"ok":false,"error":"missing_scope","needed":"channels:history"}"#)
           == .missingScope("channels:history"))
    assert(slackError(#"{"ok":false,"error":"ratelimited"}"#) == .rateLimited)
    assert(slackError(#"{"ok":false,"error":"channel_not_found"}"#) == .slack("channel_not_found"))
    assert(SlackSourceError.reconnect.isFatal && SlackSourceError.missingScope("x").isFatal)
    assert(!SlackSourceError.rateLimited.isFatal)
    assert(SlackSourceError.reconnect.localizedDescription.contains("Reconnect"))

    // MARK: the whole pipeline, over canned JSON
    let now = Date()
    func ts(_ minutesAgo: Double) -> String { S.slackTS(now.addingTimeInterval(-minutesAgo * 60)) }
    let dmHistory = """
    {"ok":true,"messages":[
      {"ts":"\(ts(2))","user":"U_PAUL","text":"review it within the hour"},
      {"ts":"\(ts(40))","user":"U_PAUL","text":"Hi"}
    ]}
    """
    let threadChannel = """
    {"ok":true,"has_more":false,"messages":[
      {"ts":"\(ts(30))","user":"U_AYESHA","text":"deploy thread","thread_ts":"\(ts(30))",
       "reply_count":2,"reply_users":["U_ME","U_AYESHA"]},
      {"ts":"\(ts(90))","user":"U_AYESHA","text":"untouched thread","thread_ts":"\(ts(90))",
       "reply_count":4,"reply_users":["U_X","U_Y"]}
    ]}
    """
    let threadReplies = """
    {"ok":true,"messages":[
      {"ts":"\(ts(30))","user":"U_AYESHA","text":"deploy thread","thread_ts":"\(ts(30))"},
      {"ts":"\(ts(25))","user":"U_ME","text":"on it","thread_ts":"\(ts(30))"},
      {"ts":"\(ts(5))","user":"U_AYESHA","text":"any update <@U_ME>?","thread_ts":"\(ts(30))"}
    ]}
    """
    let settledChannel = """
    {"ok":true,"messages":[
      {"ts":"\(ts(10))","user":"U_ME","text":"answered already"},
      {"ts":"\(ts(20))","user":"U_TANVIR","text":"question"}
    ]}
    """
    let conversationList = """
    {"ok":true,"channels":[
      {"id":"D_PAUL","is_im":true,"user":"U_PAUL"},
      {"id":"C_ENG","name":"engineering","is_private":false},
      {"id":"C_SETTLED","name":"design","is_private":false},
      {"id":"C_PAD1","name":"pad1"},{"id":"C_PAD2","name":"pad2"},
      {"id":"C_PAD3","name":"pad3"},{"id":"C_PAD4","name":"pad4"},
      {"id":"C_PAD5","name":"pad5"},{"id":"C_PAD6","name":"pad6"}
    ]}
    """

    /// Counts what the client asked for, so the budget can be asserted rather than trusted.
    actor CallLog {
        var methods: [String] = []
        func record(_ method: String) { methods.append(method) }
        var count: Int { methods.count }
        func count(of method: String) -> Int { methods.filter { $0 == method }.count }
    }

    func cannedSource(budget: Int, log: CallLog) -> SlackMessageSource {
        SlackMessageSource(call: { method, query in
            await log.record(method)
            let channel = query.first { $0.0 == "channel" }?.1 ?? ""
            let body: String
            switch method {
            case "auth.test":
                body = #"{"ok":true,"user_id":"U_ME","team":"Acme","url":"https://acme.slack.com/"}"#
            case "users.info":
                let id = query.first { $0.0 == "user" }?.1 ?? "U"
                body = #"{"ok":true,"user":{"real_name":"Name \#(id)","profile":{"display_name":"n\#(id)"}}}"#
            case "usergroups.list":
                body = #"{"ok":true,"usergroups":[{"id":"S1","users":["U_ME"]},{"id":"S9","users":["U_X"]}]}"#
            case "users.conversations":
                body = conversationList
            case "conversations.replies":
                body = threadReplies
            case "conversations.history":
                body = switch channel {
                case "D_PAUL": dmHistory
                case "C_ENG": threadChannel
                case "C_SETTLED": settledChannel
                default: #"{"ok":true,"messages":[]}"#
                }
            default:
                body = #"{"ok":false,"error":"unknown_method"}"#
            }
            return Data(body.utf8)
        }, budget: budget)
    }

    let fullLog = CallLog()
    let source = cannedSource(budget: 40, log: fullLog)
    let messages = try! await source.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))

    // FULL CONTEXT: D_PAUL's newest message is inside the 20-minute window, so the whole
    // unreplied tail comes back, including the 40-minute-old "Hi".
    let paul = messages.filter { $0.conversationID == "D_PAUL" }
    assert(paul.count == 2, "the DM must come back whole, got \(paul.count)")
    assert(Set(paul.map(\.text)) == ["Hi", "review it within the hour"])
    assert(paul.allSatisfy { $0.channel == nil }, "a DM has no channel name")
    assert(paul.allSatisfy { $0.addressing == [.directMessage] })
    assert(paul.allSatisfy { $0.directlyAddressed })

    // MessageFacts mapping through the real addressing(): a reply in a thread the user
    // posted in, under someone else's parent, mentioning them.
    let threadTS = S.slackTS(now.addingTimeInterval(-30 * 60))
    let threadMessages = messages.filter { $0.conversationID == threadTS }
    assert(threadMessages.count == 1, "one unreplied thread message, got \(threadMessages.count)")
    assert(threadMessages[0].addressing == [.threadParticipant, .mention],
           "expected threadParticipant+mention, got \(threadMessages[0].addressing)")
    assert(threadMessages[0].permalink!.absoluteString.contains("thread_ts=\(threadTS)"))
    assert(threadMessages[0].channel == "#engineering")
    assert(threadMessages[0].sender == "nU_AYESHA", "display name resolved via users.info")

    // .replyToMe comes from the parent's author, so check the mapping directly too.
    let underMe = SlackMessageSource.ThreadContext(ts: "111.0001", parentAuthorID: "U_ME", participants: ["U_ME"])
    let me = Identity(userID: "U_ME", displayName: "nU_ME", realName: "Name U_ME", userGroupIDs: ["S1"])
    let signals = addressing(MessageFacts(text: "bumping this", channelKind: .publicChannel,
                                          authorID: "U_OTHER", threadTS: underMe.ts,
                                          parentAuthorID: underMe.parentAuthorID,
                                          threadParticipantIDs: underMe.participants),
                             identity: me)
    assert(signals == [.threadParticipant, .replyToMe], "got \(signals)")

    // A thread the user is not in never costs a request: two parents, one replies call.
    let repliesCalls = await fullLog.count(of: "conversations.replies")
    assert(repliesCalls == 1, "reply_users must gate the replies call, got \(repliesCalls)")
    // Nothing from the settled channel, and nothing from the empty pads.
    assert(!messages.contains { $0.conversationID == "C_SETTLED" }, "the user posted last there")
    assert(messages.count == 3, "3 unreplied messages across the workspace, got \(messages.count)")
    assert(messages == messages.sorted { $0.date > $1.date }, "newest first")

    // repliedIDs reuses the scan, costs nothing, and strips the #n suffix.
    let before = await fullLog.count
    let replied = try! await source.repliedIDs(among: ["C_SETTLED", "C_SETTLED#1", "D_PAUL", "C_NEVER_SEEN"])
    assert(replied == ["C_SETTLED", "C_SETTLED#1"], "got \(replied)")
    let after = await fullLog.count
    assert(after == before, "reply detection must not issue requests, spent \(after - before)")
    assert(S.conversationKey(ofItem: "C_X#2") == "C_X" && S.conversationKey(ofItem: "C_X") == "C_X")

    // MARK: a dead token is an error, never an empty list
    let deadLog = CallLog()
    let dead = SlackMessageSource(call: { _, _ in
        Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)
    })
    do {
        _ = try await dead.unrepliedMessages(since: .distantPast)
        assert(false, "a revoked token must throw, not report inbox zero")
    } catch let error as SlackSourceError {
        assert(error == .reconnect, "got \(error)")
    } catch {
        assert(false, "wrong error type")
    }
    _ = deadLog

    // MARK: the call budget stops work and returns partial results
    let tightLog = CallLog()
    let tight = cannedSource(budget: 6, log: tightLog)
    let partial = try! await tight.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    let spent = await tightLog.count
    assert(spent <= 6, "the budget must be a hard cap, spent \(spent)")
    assert(!partial.isEmpty, "a partial list beats an empty one")
    assert(partial.count < messages.count, "budget exhausted, so some conversations were skipped")
    assert(partial.contains { $0.conversationID == "D_PAUL" }, "IMs are scanned first, so they survive")

    print("demoSlackSource: PASS (\(messages.count) messages, \(await fullLog.count) calls, partial \(partial.count) in \(spent))")
}
