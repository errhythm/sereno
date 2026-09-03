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
    /// No token on this machine, either before connection or after a disconnect.
    case notConnected
    /// invalid_auth, token_revoked, account_inactive. The credential is dead.
    case reconnect
    /// Slack named a scope the token does not carry.
    case missingScope(String)
    /// 429 after honouring Retry-After. The seconds Slack asked for are carried along
    /// because they are the only honest basis for deciding when to try the method again;
    /// nil means the wait was never seen, as when a budget ran out locally.
    case rateLimited(retryAfter: TimeInterval?)
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
    /// there is nothing to salvage. Other failures can still leave useful rows to return.
    var isFatal: Bool {
        switch self {
        case .notConnected, .reconnect, .missingScope: true
        default: false
        }
    }

    /// Slack can list a conversation that is no longer readable by the time history is
    /// fetched. That conversation says nothing about whether the rest of the refresh worked.
    var nonReportableConversationSlug: String? {
        guard case .slack(let slug) = self,
              ["channel_not_found", "is_archived", "not_in_channel"].contains(slug)
        else { return nil }
        return slug
    }

    /// A short, stable name for the case itself, for logs. Not `errorDescription`: that
    /// string is user-facing UI copy free to reword itself, and for `.network` it is built
    /// from a `URLError`'s own description, which is not safe to log. Every value folded in
    /// here is either nothing at all or something Slack or the OS defines (a scope name, an
    /// error slug, a retry delay), so the whole label is `.public`.
    var caseLabel: String {
        switch self {
        case .notConnected: "notConnected"
        case .reconnect: "reconnect"
        case .offline: "offline"
        case .badResponse: "badResponse"
        case .missingScope(let scope): "missingScope(\(scope))"
        case .rateLimited(let retryAfter): "rateLimited(\(retryAfter.map { String(Int($0)) } ?? "nil"))"
        case .slack(let slug): "slack(\(slug))"
        case .network: "network"
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

    /// A search match arrives in a different shape and carries no thread position, no
    /// subtype and no reply counts, so this is how one becomes the same RawMessage the
    /// history path produces. Everything search cannot know stays at its empty value.
    init(ts: String, user: String, text: String, threadTS: String?) {
        self.ts = ts
        self.user = user
        self.text = text
        subtype = nil
        self.threadTS = threadTS
        replyCount = 0
        replyUsers = []
    }

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

/// The durable edge of one logical Slack conversation. Channel ids checkpoint history;
/// thread timestamps checkpoint the settlement proof learned while reading replies.
struct SlackConversationCheckpoint: Codable, Sendable, Equatable {
    var newestTS: String
    var settled: Bool
}

/// Slack scan state lives in Store's state.json. Keeping it beside the todos makes an app
/// relaunch continue from the same edge instead of turning every launch into a cold scan.
struct SlackScanState: Codable, Sendable, Equatable {
    var accountKey: String? = nil
    var connectedAt: Date? = nil
    var conversations: [String: SlackConversationCheckpoint] = [:]
    var userNames: [String: String] = [:]
    /// Sender avatar URLs, cached next to userNames for the same reason: the request
    /// budget is scarce, so a relaunch must not need a fresh users.info pass.
    var userAvatars: [String: URL] = [:]
}

extension SlackScanState {
    // Swift's synthesized init(from:) does NOT fall back to a property's default for a
    // missing key, it throws. A state.json written before userAvatars existed has no such
    // key, so this decodes it explicitly rather than losing the whole scan state (and with
    // it every conversation watermark and cached display name) on load.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accountKey = try c.decodeIfPresent(String.self, forKey: .accountKey)
        connectedAt = try c.decodeIfPresent(Date.self, forKey: .connectedAt)
        conversations = try c.decodeIfPresent([String: SlackConversationCheckpoint].self, forKey: .conversations) ?? [:]
        userNames = try c.decodeIfPresent([String: String].self, forKey: .userNames) ?? [:]
        userAvatars = try c.decodeIfPresent([String: URL].self, forKey: .userAvatars) ?? [:]
    }
}

/// Store uses this refinement without widening MessageSource, so simple fixtures keep the
/// base protocol while the live source can round-trip its rate-limit state.
protocol SlackScanStateSource: MessageSource {
    func restoreSlackScanState(_ state: SlackScanState) async
    func currentSlackScanState() async -> SlackScanState
}

// MARK: - The source

/// The real Slack client. An `actor` because the caches (identity, conversation list, user
/// names) outlive one refresh and three requests are in flight at once; actor isolation is
/// the whole of the locking.
actor SlackMessageSource: SlackScanStateSource {
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
    /// How far back a conversation without a checkpoint may be read. After that first look,
    /// its own watermark replaces this window. The connection floor can make the first look
    /// smaller, which is deliberate for a newly connected installation.
    private static let historyWindow: TimeInterval = 7 * 24 * 60 * 60
    /// How far back search discovery's candidate cutoff looks, measured from now rather than
    /// from the sliding `since` watermark. THE BUG THIS FIXES: `since` advances on every
    /// successful refresh whether or not a candidate was found, so a message the search index
    /// had not yet indexed when its one covering refresh ran was lost forever once the window
    /// slid past it. A bounded lookback makes a miss self-heal on the next successful refresh
    /// instead, at the cost of re-asking Slack about the same window repeatedly, which is
    /// exactly what Tier 2 quota is for (see searchCallBudget below). 24 hours matches
    /// historyWindow's order of magnitude and comfortably covers both Slack's search-index
    /// lag and the multi-hour gaps sustained rate limiting produces between successful
    /// refreshes (measured: 5 successes against 159 failures over 8 hours in the field).
    private static let searchLookback: TimeInterval = 24 * 60 * 60
    /// The conversation list changes rarely, so it is refetched every tenth refresh.
    private static let conversationCacheRefreshes = 10
    /// Used when a 429 arrived without a readable Retry-After. A minute is what Slack asks
    /// for on the capped methods, and guessing shorter would just buy another rejection.
    private static let assumedCooldown: TimeInterval = 60

    private let call: Call
    private let observesStoredAccount: Bool
    private let totalBudget: Int
    /// Requests held back for display-name lookups, so a workspace big enough to eat the
    /// budget still shows names rather than a column of user ids.
    private let nameReserve: Int
    private var budget = 0

    private var identity: Identity?
    private var identityTask: Task<Identity, Error>?
    private var permalinkHost = "app.slack.com"
    private var conversations: [SlackConversation] = []
    private var hasConversationCache = false
    private var conversationsFetchedAt: Int?
    private var conversationsTask: Task<[SlackConversation], Error>?
    private var refreshCount = 0
    private var userNames: [String: String] = [:]
    private var userAvatars: [String: URL] = [:]
    private var scanState = SlackScanState()
    /// Earliest date each Web API method may be called again, learned from Slack's own
    /// Retry-After. Slack now allows this class of app about one conversations.history a
    /// minute, and a call made inside that window reads nothing and is rejected on the
    /// spot, so the request is pure waste and also renews the limit. Skipping the
    /// conversation instead leaves it unscanned for a later refresh, which is the same
    /// outcome the call budget already produces.
    private var cooldowns: [String: Date] = [:]
    /// Where the next sweep begins in the priority-ordered conversation list. A refresh
    /// held to about one history call cannot honour "IMs first" AND reach the rest of the
    /// workspace: starting at the top every time would re-read the same first conversation
    /// forever and never look at the other eighty-one. So a refresh the rate limit cut
    /// short hands the next one its stopping point.
    private var sweepStart = 0

    /// Conversations whose newest real message this cycle was the user's own, which is
    /// exactly the question `repliedIDs(among:)` asks. Filled during the scan so reply
    /// detection costs no extra requests.
    private var settled: Set<String> = []

    init(call: Call? = nil, budget: Int = SlackMessageSource.callBudget) {
        self.call = call ?? SlackMessageSource.httpCall
        observesStoredAccount = call == nil
        totalBudget = budget
        nameReserve = max(1, budget / 5)
    }

    func restoreSlackScanState(_ state: SlackScanState) {
        // Only a genuinely different account drops the identity. Store calls this on every
        // failed refresh to roll conversation watermarks back, and clearing the identity
        // there made each failure re-buy auth.test and usergroups.list, which is how a
        // rate-limited refresh managed to spend three requests before reading anything.
        // The correctness this used to provide is still provided: ensureIdentity compares
        // the cached user against the stored one on every call, and
        // synchronizeStoredAccount wipes the actor when the stored account changes, so a
        // sign-in as a different person cannot inherit the previous human's identity.
        if state.accountKey != scanState.accountKey {
            identity = nil
            permalinkHost = "app.slack.com"
        }
        scanState = state
        userNames = state.userNames
        userAvatars = state.userAvatars
    }

    func currentSlackScanState() -> SlackScanState {
        scanState.userNames = userNames
        scanState.userAvatars = userAvatars
        return scanState
    }

    // MARK: Budget

    /// Seconds left before this method may be called again, nil when it is free. Checked
    /// BEFORE `spend`, so a conversation nobody can read costs neither a request nor a
    /// slice of the budget.
    private func cooldown(_ method: String) -> TimeInterval? {
        guard let until = cooldowns[method], until > Date() else { return nil }
        return until.timeIntervalSinceNow
    }

    /// Reserve one request. `reserve` keeps a tail of the budget for name lookups.
    private func spend(reserve: Int = 0) -> Bool {
        guard budget > reserve else { return false }
        budget -= 1
        return true
    }

    private func get(_ method: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        let conversationID = query.first(where: { $0.0 == "channel" })?.1 ?? "none"
        log.debug("request method=\(method, privacy: .public) conversation=\(conversationID, privacy: .public) callsLeft=\(self.budget, privacy: .public)")
        do {
            let data = try await call(method, query)
            guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw SlackSourceError.badResponse
            }
            guard root["ok"] as? Bool == true else { throw Self.error(for: root) }
            return root
        } catch {
            // Slack's cap is per method, so a 429 is a fact about the method and not about
            // the conversation that happened to hit it. Recording it here, at the one place
            // every request passes through, is what lets the rest of the refresh stop.
            if let slack = error as? SlackSourceError, case .rateLimited(let retryAfter) = slack {
                cooldowns[method] = Date().addingTimeInterval(retryAfter ?? Self.assumedCooldown)
            }
            throw error
        }
    }

    // MARK: Identity

    private func ensureIdentity() async throws -> Identity {
        // A disconnect followed by a sign-in as someone else in the same app run must not
        // keep the old identity: addressing detection would then answer for the wrong human.
        if let identity,
           !observesStoredAccount || Self.storedUserID().map({ $0 == identity.userID }) ?? true {
            log.info("identity cache user=\(identity.userID, privacy: .public)")
            return identity
        }
        if let identityTask { return try await identityTask.value }
        let task = Task {
            defer { identityTask = nil }
            guard spend() else { throw SlackSourceError.rateLimited(retryAfter: nil) }
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
            log.info("identity auth.test user=\(userID, privacy: .public) groups=\(groups.count, privacy: .public)")
            return built
        }
        identityTask = task
        return try await task.value
    }

    private nonisolated static func storedUserID() -> String? {
        UserDefaults.standard.string(forKey: "slackUserID")
    }

    private nonisolated static func storedAccountKey() -> String? {
        guard let userID = storedUserID() else { return nil }
        let workspace = UserDefaults.standard.string(forKey: "slackWorkspaceName") ?? ""
        return "\(workspace)\u{0}\(userID)"
    }

    /// A different stored account must not inherit channel watermarks or a connection floor
    /// from the previous one. Canned sources do not consult process UserDefaults.
    private func synchronizeStoredAccount() {
        guard observesStoredAccount else { return }
        let accountKey = Self.storedAccountKey()
        guard scanState.accountKey != accountKey else { return }
        scanState = SlackScanState(accountKey: accountKey)
        identity = nil
        permalinkHost = "app.slack.com"
        conversations = []
        hasConversationCache = false
        userNames = [:]
        userAvatars = [:]
        sweepStart = 0
    }

    // MARK: Conversation list

    private func ensureConversations() async throws -> [SlackConversation] {
        // `conversationsFetchedAt` is what makes this callable twice in one refresh: search
        // discovery needs the list for channel kinds and the sweep needs it for the sweep
        // order, and on the refresh where the cache is due to be refetched the second caller
        // would otherwise buy the same three pages again.
        if hasConversationCache,
           conversationsFetchedAt == refreshCount || refreshCount % Self.conversationCacheRefreshes != 0 {
            return conversations
        }
        if let conversationsTask { return try await conversationsTask.value }
        let task = Task {
            defer { conversationsTask = nil }
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
            hasConversationCache = true
            conversationsFetchedAt = refreshCount
            log.info("conversations cached count=\(self.conversations.count, privacy: .public)")
            return conversations
        }
        conversationsTask = task
        return try await task.value
    }

    // MARK: MessageSource

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        budget = totalBudget
        searchBudget = Self.searchCallBudget
        synchronizeStoredAccount()
        log.info("refresh start budget=\(self.budget, privacy: .public) searchBudget=\(self.searchBudget, privacy: .public) cachedConversations=\(self.conversations.count, privacy: .public)")
        if scanState.connectedAt == nil { scanState.connectedAt = Date() }
        settled = Set(scanState.conversations.compactMap { $0.value.settled ? $0.key : nil })
        defer { refreshCount += 1 }

        let identity = try await ensureIdentity()

        // SEARCH FIRST, because it is the path that actually has quota. See the section
        // below: history is capped to nothing for an app of this class.
        let discovered = await discoverBySearch(since: since, identity: identity)

        // History SECOND and best-effort. It stays because a workspace with quota gets
        // strictly better rows from it, thread participants and parent authors included,
        // and because its cooldown bookkeeping is what stops the sweep hammering a capped
        // method. What it may no longer do is decide the refresh: a 429 here used to empty
        // the list and raise a banner even though search had already answered.
        let history: Result<[SlackMessage], Error>
        do {
            history = .success(try await sweepHistory(since: since, identity: identity))
        } catch {
            history = .failure(error)
        }

        switch history {
        case .success(let rows):
            return Self.merged(search: discovered.messages, history: rows)
        case .failure(let error):
            // Only a search that never got an answer leaves nothing to report. A search
            // that answered, even with zero matches, is a real reading of the one thing
            // this app looks for, so the refresh succeeded.
            guard discovered.ok else { throw error }
            let label = (error as? SlackSourceError)?.caseLabel ?? String(describing: type(of: error))
            log.info("refresh done via=search messages=\(discovered.messages.count, privacy: .public) historyError=\(label, privacy: .public)")
            return Self.merged(search: discovered.messages, history: [])
        }
    }

    /// History wins a duplicate: it is the only path that knows a message's real thread
    /// position, its parent author and its participants. A search match's thread position is
    /// at best read off a permalink.
    static func merged(search: [SlackMessage], history: [SlackMessage]) -> [SlackMessage] {
        var byID: [String: SlackMessage] = [:]
        for message in search + history { byID[message.id] = message }
        // Ties broken by id so the order is the same on every run: Swift's sort is not
        // stable, and two messages in the same second are ordinary in a busy channel.
        return byID.values.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }

    private func sweepHistory(since: Date, identity: Identity) async throws -> [SlackMessage] {
        let all = try await ensureConversations()

        var results: [(conversationID: String, result: Result<ScanResult, Error>)] = []
        var index = 0
        var skipped = 0
        var cooledSkipped = 0
        // Priority order, rotated to where the last rate-limited refresh stopped.
        let order = sweepStart > 0 && sweepStart < all.count
            ? Array(all[sweepStart...] + all[..<sweepStart])
            : all

        // How many children may be in flight is decided ONCE, here, before any child
        // exists. It used to be recomputed on every pass of the loop below by asking the
        // cooldown table whether history had ever been capped, and that table keeps its
        // entry after the window it describes has lapsed, so the limit could fall from
        // three to one while three children were already running. Collection was gated on
        // the in-flight count being exactly equal to the limit, so an in-flight count
        // sitting above it made the branch unreachable for the rest of the sweep: nothing
        // was ever collected again and the loop went on launching children with nobody
        // counting them. A limit fixed for the whole sweep cannot oscillate, and the
        // greater-or-equal test below cannot be stepped over even if one ever did.
        let concurrency = cooldowns["conversations.history"] == nil ? Self.maxInFlight : 1

        // Three conversations in flight, refilled as each one lands, so the budget is
        // spent in priority order rather than all at once. A child never throws: one
        // unreadable channel must not cost the other thirty-nine.
        await withTaskGroup(of: (String, Result<ScanResult, Error>).self) { group in
            var inFlight = 0
            while index < order.count {
                // A 429 on history closes the method for the rest of this refresh. Every
                // further conversation would be rejected at the same rate, so launching
                // them spends requests on certain failures and renews the limit for the
                // next refresh, which is how one bad minute became a permanent one.
                if cooldown("conversations.history") != nil {
                    cooledSkipped = order.count - index
                    break
                }
                // Reserve the history call before launching the child. Reserving inside
                // scan made the three children race for the last call, defeating priority.
                guard spend(reserve: nameReserve) else {
                    skipped = order.count - index
                    break
                }
                let conversation = order[index]
                index += 1
                group.addTask {
                    do {
                        return (conversation.id,
                                .success(try await self.scan(conversation, since: since, identity: identity)))
                    } catch {
                        return (conversation.id, .failure(error))
                    }
                }
                inFlight += 1
                // The first conversation goes alone, and every conversation goes alone on
                // a workspace that had already shown a 429 for history when this refresh
                // began. Three children start before the parent suspends, so concurrent
                // calls on a capped method are all rejected before the first rejection can
                // be recorded, and each rejection pushes the cooldown further out, which is
                // what would deny the NEXT refresh its one successful call. Serial is also
                // no slower there: a cap of one call a minute admits one either way. The
                // loop drains rather than collecting at most one result, so the in-flight
                // count is brought back under the limit however far over it has gone.
                let limit = results.isEmpty ? 1 : concurrency
                while inFlight >= limit, let result = await group.next() {
                    inFlight -= 1
                    results.append(result)
                }
            }
            // No cancelAll: the conversations already in flight are results worth waiting
            // for, and cancelling them throws their requests away.
            for await result in group { results.append(result) }
        }

        // Rotated only when the rate limit was what stopped the sweep. The budget path
        // keeps starting at the top, because starting at the top is exactly what puts the
        // IMs and MPIMs inside the budget on a workspace too big to read in one refresh.
        if cooledSkipped > 0, !order.isEmpty { sweepStart = (sweepStart + index) % order.count }

        var pending: [Pending] = []
        var firstError: Error?
        var reportableFailures = 0
        var scanned = 0
        for (conversationID, result) in results {
            switch result {
            case .success(let batch):
                scanned += 1
                pending += batch.pending
                for (key, checkpoint) in batch.checkpoints {
                    scanState.conversations[key] = checkpoint
                    if checkpoint.settled { settled.insert(key) } else { settled.remove(key) }
                }
            case .failure(let error):
                // A dead token or a missing scope fails identically everywhere, so there
                // is nothing left to salvage from this refresh.
                if let slack = error as? SlackSourceError, slack.isFatal { throw slack }
                if let slug = (error as? SlackSourceError)?.nonReportableConversationSlug {
                    // Keeping a conversation Slack says is unreadable would spend the same
                    // history call again on every refresh without yielding a usable message.
                    conversations.removeAll { $0.id == conversationID }
                    scanState.conversations.removeValue(forKey: conversationID)
                    settled.remove(conversationID)
                    log.info("conversation dropped id=\(conversationID, privacy: .public) error=\(slug, privacy: .public)")
                    continue
                }
                // Nothing logged this path before, so a reportable failure was invisible:
                // only the eventual "refresh failed" banner showed, never which conversation
                // or why. Slug when Slack named one, otherwise the error's own type, since a
                // raw description could be carrying message text up from deeper in the stack.
                if case .slack(let slug)? = error as? SlackSourceError {
                    log.info("conversation failed id=\(conversationID, privacy: .public) error=\(slug, privacy: .public)")
                } else {
                    // caseLabel over the bare type name: the type is always "SlackSourceError"
                    // regardless of which of its eight cases fired, which was the whole gap.
                    let label = (error as? SlackSourceError)?.caseLabel ?? String(describing: type(of: error))
                    log.info("conversation failed id=\(conversationID, privacy: .public) error=\(label, privacy: .public)")
                }
                firstError = firstError ?? error
                reportableFailures += 1
            }
        }

        // Every conversation held back by the cooldown means this refresh read nothing,
        // and an empty list would be shown as inbox zero, which is the one lie the user
        // would act on. So a fully blocked sweep is an error even though it made no request.
        if scanned == 0, firstError == nil, cooledSkipped > 0 {
            firstError = SlackSourceError.rateLimited(
                retryAfter: cooldown("conversations.history")
            )
        }

        // Built once so the throwing path and the success path report the same counters in
        // the same shape, which is what makes them comparable when grepped side by side.
        let counters = "conversations=\(all.count) messages=\(pending.count) " +
            "skippedForBudget=\(skipped) scanned=\(scanned) skippedForRateLimit=\(cooledSkipped) " +
            "failedConversations=\(reportableFailures) callsLeft=\(self.budget)"

        // An empty list has to mean inbox zero, so a refresh that read nothing at all and
        // failed reports the error. A refresh that read even one conversation succeeded in
        // part: its rows and its checkpoints are kept, because throwing them away is how a
        // single rate-limited conversation used to leave the user with nothing at all.
        if scanned == 0, let firstError {
            // This is the case that used to vanish: a refresh that attempted three
            // conversations.history calls and threw before a single counter reached the log.
            // The error is shown to the user already, so it is not new content, but it can
            // still carry a network library's own wording, so it stays private here anyway.
            log.error("refresh aborted \(counters, privacy: .public) error=\(firstError.localizedDescription, privacy: .private)")
            throw firstError
        }
        log.info("refresh done \(counters, privacy: .public)")

        let names = await resolveNames(
            Set(pending.map(\.raw.user)).union(pending.flatMap { mentionedUserIDs(in: $0.raw.text) })
        )
        return pending
            .map { $0.message(identity: identity, host: permalinkHost, names: names, avatars: userAvatars) }
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

    // MARK: Search discovery

    /// SEARCH IS THE DISCOVERY PATH. Slack grants an app of this class effectively zero
    /// `conversations.history` calls: on the workspace this was written for a freshly
    /// launched process is answered `429 retryAfter=60` on its first history request and
    /// every refresh ended `scanned=0`. `search.messages` is Tier 2, twenty or more calls a
    /// minute, and is explicitly not covered by that restriction, so candidates now come
    /// from four searches: the `<@USERID>` mention query, `to:<self>`, `is:thread with:<self>`
    /// for the messages, and `from:<self>` for reply detection.
    ///
    /// Two things this API cannot answer at compile time are answered at RUNTIME and logged,
    /// because guessing either one wrong is silent:
    ///   - the self-reference spelling. Production clients disagree: one documents `from:me`
    ///     and says `from:@me` returns nothing, others use `from:@me`. So `me` is tried, a
    ///     query that comes back empty is retried once with `@me`, and whichever produced
    ///     matches is kept for the rest of the process.
    ///   - the thread position. A match carries no `thread_ts`, only maybe a permalink that
    ///     embeds one. It is read from there when present, and a match without one is
    ///     treated as a plain channel message. A real message is NEVER dropped for want of
    ///     a thread position; the counts of both outcomes are logged so real traffic settles
    ///     how often the permalink carries it.
    ///
    /// Logging obeys the privacy rule at the top of this file: query KIND labels (never the
    /// query strings, one of which embeds the user id), integer counts, booleans, and Slack's
    /// own error slugs and scope names. Nothing from a match is logged, not even its channel.
    ///
    /// A per-refresh allowance of its own, deliberately not `budget`: one shared pool is how
    /// discovery would starve the sweep, or be starved by it.
    static let searchCallBudget = 8
    /// Full from birth, so a direct call to `discoverBySearch` in a demo has an allowance
    /// too; `unrepliedMessages` refills it at the start of every refresh.
    private var searchBudget = SlackMessageSource.searchCallBudget
    /// Which self-reference spelling this workspace actually accepts, learned from traffic.
    private var selfToken = SlackSearch.selfReference
    private var selfTokenConfirmed = false

    struct SearchDiscovery: Sendable {
        var messages: [SlackMessage] = []
        /// Conversation keys where the user's own message is the newest thing search saw.
        var settled: Set<String> = []
        /// Conversation keys with an inbound candidate newer than anything the user sent.
        var unsettled: Set<String> = []
        /// At least one CANDIDATE query got an answer. `from:<self>` alone does not count:
        /// it discovers nothing, so it cannot be the basis for reporting inbox zero.
        var ok = false
        /// Exactly the lines logged, so a demo can assert what was parsed without a Logger.
        var lines: [String] = []
    }

    /// One search: one budgeted request, one log line, no throw. `answered` distinguishes
    /// "Slack said zero" from "Slack said no", which is the difference between a spelling
    /// worth retrying and a scope that will refuse the retry too.
    private struct SearchStep {
        var matches: [SearchMatch]?
        var lines: [String] = []
        var answered = false
    }

    private func runSearch(_ search: SlackSearch, kind: String, query: String) async -> SearchStep {
        guard searchBudget > 0 else {
            return SearchStep(matches: nil, lines: ["kind=\(kind) skipped=allowance"])
        }
        searchBudget -= 1
        do {
            let result = try await search.search(query: query)
            let total = result.pagination?.total ?? result.matches.count
            return SearchStep(
                matches: result.matches,
                lines: ["kind=\(kind) ok=true total=\(total) matches=\(result.matches.count)"],
                answered: true
            )
        } catch {
            // caseLabel folds in only Slack's own vocabulary: an error slug, a scope name,
            // a retry delay. A raw description could be carrying content up from below.
            let label = (error as? SlackSourceError)?.caseLabel ?? String(describing: type(of: error))
            return SearchStep(matches: nil, lines: ["kind=\(kind) ok=false error=\(label)"])
        }
    }

    /// The runtime answer to the spelling question. Zero matches is not proof that a
    /// spelling is wrong, but it is the only signal this API offers, and one extra request
    /// on a Tier 2 method is far cheaper than being wrong for the whole process. A query
    /// Slack REFUSED is not retried: a missing scope refuses both spellings equally.
    private func selfSearch(
        _ search: SlackSearch,
        kind: String,
        build: (String) -> String
    ) async -> SearchStep {
        var step = await runSearch(search, kind: kind, query: build(selfToken))
        if selfTokenConfirmed { return step }
        if let matches = step.matches, !matches.isEmpty {
            selfTokenConfirmed = true
            step.lines.append("selfReference=\(selfToken) confirmed=true")
            return step
        }
        guard step.answered else { return step }
        let alternate = selfToken == "me" ? "@me" : "me"
        let retry = await runSearch(search, kind: "\(kind)-alt", query: build(alternate))
        step.lines += retry.lines
        step.answered = step.answered || retry.answered
        guard let matches = retry.matches, !matches.isEmpty else { return step }
        selfToken = alternate
        selfTokenConfirmed = true
        step.matches = matches
        step.lines.append("selfReference=\(alternate) confirmed=true")
        return step
    }

    /// Never throws. A search failure degrades discovery to whatever the history sweep can
    /// still do, which is the same shape of partial result the budget already produces.
    func discoverBySearch(since: Date, identity: Identity) async -> SearchDiscovery {
        // The conversation list is Tier 3 and cached for ten refreshes, and it is what gives
        // a match its channel kind, which .im and .mpim addressing depend on. Not fatal:
        // `conversation(for:)` infers what it can when the list is unavailable.
        _ = try? await ensureConversations()

        let search = SlackSearch(call: call)
        var out = SearchDiscovery()
        var threadTSPresent = 0
        var threadTSAbsent = 0

        func emit(_ lines: [String]) {
            out.lines += lines
            for line in lines { log.info("search probe \(line, privacy: .public)") }
        }

        // The candidate cutoff is a bounded LOOKBACK from now, not the sliding `since`
        // watermark: see searchLookback above for why. The connection floor still holds
        // absolutely: nothing predating connection may ever surface, however wide the
        // lookback gets.
        let floor = scanState.connectedAt ?? Date()
        let cutoff = max(Date().addingTimeInterval(-Self.searchLookback), floor)
        // `after:` takes a calendar DAY and excludes it, so the coarse filter is the day
        // before the cutoff and `SlackSearch.matches` applies the real cutoff in Swift.
        let candidateDay = cutoff.addingTimeInterval(-86_400)
        // Reply detection has to answer for every todo still open, not only for what this
        // refresh discovered, so it looks back over the window history backfills.
        let replyDay = Date().addingTimeInterval(-Self.historyWindow - 86_400)

        var found: [SearchMatch] = []
        let mention = await runSearch(search, kind: "mention",
                                      query: SlackSearch.mentionQuery(userID: identity.userID, after: candidateDay))
        emit(mention.lines)
        found += mention.matches ?? []

        let to = await selfSearch(search, kind: "to:self") {
            SlackSearch.toQuery(after: candidateDay, selfAs: $0)
        }
        emit(to.lines)
        found += to.matches ?? []

        // `with:<self>` is what makes the user a participant of these threads, which is the
        // one thread fact search can state rather than infer.
        let threads = await selfSearch(search, kind: "thread") {
            SlackSearch.threadQuery(after: candidateDay, selfAs: $0)
        }
        emit(threads.lines)
        let inThread = Set((threads.matches ?? []).map(\.ts))
        found += threads.matches ?? []

        // Reply detection. It discovers nothing, so its success alone must never be the
        // basis for reporting inbox zero, which is why `ok` ignores it.
        let own = await selfSearch(search, kind: "from:self") {
            SlackSearch.ownMessagesQuery(after: replyDay, selfAs: $0)
        }
        emit(own.lines)
        out.ok = mention.answered || to.answered || threads.answered

        /// A match's conversation key, the same one the history path checkpoints under: the
        /// thread timestamp when there is one, otherwise the channel.
        func key(_ match: SearchMatch) -> String? {
            guard let channel = match.channel else { return nil }
            return match.permalink.flatMap(SlackSearch.threadTS(fromPermalink:)) ?? channel.id
        }

        var ownNewest: [String: String] = [:]
        for match in own.matches ?? [] {
            guard let key = key(match) else { continue }
            ownNewest[key] = max(ownNewest[key] ?? "", match.ts)
        }

        var seen: Set<String> = []
        var inboundNewest: [String: String] = [:]
        var pending: [Pending] = []
        var answered = 0
        for match in SlackSearch.matches(found, after: cutoff).sorted(by: { $0.ts < $1.ts }) {
            guard let channel = match.channel,
                  let user = match.user, !user.isEmpty, user != identity.userID
            else { continue }
            // The same message is returned by more than one query, by design: a DM that
            // mentions you matches both. One obligation, one row.
            guard seen.insert("\(channel.id)/\(match.ts)").inserted else { continue }
            let threadTS = match.permalink.flatMap(SlackSearch.threadTS(fromPermalink:))
            if threadTS == nil { threadTSAbsent += 1 } else { threadTSPresent += 1 }
            let key = threadTS ?? channel.id
            // The user has spoken in this conversation since: the obligation is discharged.
            if let mine = ownNewest[key], mine > match.ts {
                answered += 1
                continue
            }
            let thread = threadTS.map {
                ThreadContext(ts: $0,
                              parentAuthorID: nil,
                              participants: inThread.contains(match.ts) ? [identity.userID] : [])
            }
            pending.append(Pending(
                raw: RawMessage(ts: match.ts, user: user, text: match.text, threadTS: threadTS),
                conversation: conversation(for: channel),
                thread: thread
            ))
            inboundNewest[key] = max(inboundNewest[key] ?? "", match.ts)
        }

        // Settlement still needs positive proof, exactly as the history path demands it:
        // the user's own message must be the newest thing in the conversation, and an empty
        // window proves nothing. Held in memory only, deliberately: writing it into
        // scanState would mean inventing a watermark for a conversation search never read
        // end to end, and the `from:<self>` window re-derives it on every refresh anyway.
        for (key, mine) in ownNewest where (inboundNewest[key] ?? "") < mine {
            out.settled.insert(key)
            settled.insert(key)
        }
        for (key, inbound) in inboundNewest where (ownNewest[key] ?? "") < inbound {
            out.unsettled.insert(key)
            settled.remove(key)
        }

        // A bare mention does not give triage enough context to infer the owed work. Search
        // has no thread parent, so buy at most one capped replies request to recover it.
        if let candidate = pending
            .filter({ $0.raw.threadTS != nil && strippingMarkupAndCode($0.raw.text)
                .split(whereSeparator: { $0.isWhitespace }).count < 4 })
            .max(by: { $0.raw.ts < $1.raw.ts }),
           let threadTS = candidate.raw.threadTS {
            if cooldown("conversations.replies") != nil {
                emit(["threadContext=skipped reason=cooldown"])
            } else if !spend(reserve: nameReserve) {
                emit(["threadContext=skipped reason=budget"])
            } else if let page = try? await get(
                "conversations.replies",
                [("channel", candidate.conversation.id), ("ts", threadTS), ("limit", "15")]
            ) {
                let replies = Self.ordered(Self.parseMessages(page))
                if let root = replies.first {
                    let context = ThreadContext(
                        ts: threadTS,
                        parentAuthorID: root.user,
                        participants: Set(replies.map(\.user))
                    )
                    let rootAdded = !pending.contains(where: { $0.raw.ts == root.ts })
                    let pendingTimestamps = Set(pending.filter {
                        $0.conversation.id == candidate.conversation.id
                    }.map(\.raw.ts))
                    pending += replies.filter { !pendingTimestamps.contains($0.ts) }.map {
                        Pending(raw: $0, conversation: candidate.conversation,
                                thread: context, isContext: true)
                    }
                    pending = pending.map {
                        guard $0.raw.threadTS == threadTS else { return $0 }
                        return Pending(raw: $0.raw, conversation: $0.conversation,
                                       thread: context, isContext: $0.isContext)
                    }
                    emit(["threadContext=fetched root=\(rootAdded ? "added" : "present") participants=\(context.participants.count)"])
                } else {
                    emit(["threadContext=skipped reason=empty"])
                }
            } else {
                emit(["threadContext=skipped reason=failed"])
            }
        }

        // Names come out of the reserve, so a big search result cannot spend the sweep's
        // requests on display names before the sweep has had its turn.
        let names = await resolveNames(
            Set(pending.map(\.raw.user)).union(pending.flatMap { mentionedUserIDs(in: $0.raw.text) }),
                                       reserve: max(0, budget - nameReserve))
        out.messages = pending.map { $0.message(identity: identity, host: permalinkHost, names: names, avatars: userAvatars) }
        emit(["candidates=\(out.messages.count) answered=\(answered) " +
             "threadTSPresent=\(threadTSPresent) threadTSAbsent=\(threadTSAbsent) " +
             "settled=\(out.settled.count) searchCallsLeft=\(searchBudget)"])
        return out
    }

    /// A search match's channel block has no `is_im`, so a DM and a private channel cannot
    /// be told apart from it. The cached conversation list is the authority; inference is the
    /// fallback and errs toward a channel, which costs addressing SIGNAL rather than dropping
    /// the message, and an unaddressed message still reaches the model to judge.
    private func conversation(for channel: SearchMatchChannel) -> SlackConversation {
        if let known = conversations.first(where: { $0.id == channel.id }) { return known }
        let kind: ChannelKind = if channel.isMpim { .mpim }
            else if channel.id.hasPrefix("D") { .im }
            else if channel.isPrivate { .privateChannel }
            else { .publicChannel }
        return SlackConversation(id: channel.id,
                                 kind: kind,
                                 name: kind == .im || kind == .mpim ? nil : channel.name)
    }

    // MARK: Scanning one conversation

    private struct Pending: Sendable {
        let raw: RawMessage
        let conversation: SlackConversation
        let thread: ThreadContext?
        var isContext: Bool = false

        func message(identity: Identity, host: String, names: [String: String], avatars: [String: URL]) -> SlackMessage {
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
                text: slackPlainText(raw.text, names: names),
                isContext: isContext,
                isFromUser: raw.user == identity.userID,
                date: raw.date,
                directlyAddressed: signals.isPersonal,
                addressing: signals,
                permalink: SlackMessageSource.permalink(
                    host: host, channel: conversation.id, ts: raw.ts, threadTS: thread?.ts),
                avatarURL: avatars[raw.user]
            )
        }
    }

    private struct ScanResult: Sendable {
        let pending: [Pending]
        let checkpoints: [String: SlackConversationCheckpoint]
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
    ) async throws -> ScanResult {
        // The caller reserves this history request before launching the child, so priority
        // order cannot be overturned by task scheduling.
        let scanStartedAt = Date()
        let previous = scanState.conversations[conversation.id]
        let floor = scanState.connectedAt ?? scanStartedAt
        let backfill = scanStartedAt.addingTimeInterval(-Self.historyWindow)
        let previousDate = previous.flatMap { Date(timeIntervalSince1970: Double($0.newestTS) ?? 0) }
        let oldest = max(floor, previousDate ?? backfill)
        let base = [("channel", conversation.id),
                    ("oldest", Self.slackTS(oldest)),
                    ("limit", "200")]
        let page = try await get("conversations.history", base)
        let lowerTS = previous?.newestTS
        func isNew(_ message: RawMessage) -> Bool {
            if let lowerTS { return message.ts > lowerTS }
            return message.date >= floor
        }
        var raw = Self.parseMessages(page).filter(isNew)
        var historyComplete = page["has_more"] as? Bool != true

        // One extra page, and only when the first page holds nothing of the user's own.
        // History comes back newest first, so a second page is OLDER, and the only reason
        // to want older is that the start of the tail, the user's last message, is not in
        // hand yet. Paging past that would just buy context nobody reads.
        if !raw.contains(where: { $0.user == identity.userID }),
           page["has_more"] as? Bool == true,
           let cursor = Self.nextCursor(page) {
            if cooldown("conversations.history") == nil, spend(reserve: nameReserve) {
                let second = try await get("conversations.history", base + [("cursor", cursor)])
                raw += Self.parseMessages(second).filter(isNew)
                historyComplete = second["has_more"] as? Bool != true
            } else {
                // historyComplete already reads false here, from page["has_more"] above;
                // this just makes that silent case visible. The history call itself still
                // succeeded, only the second page was skipped, which is the distinction the
                // next question after this one needs answered.
                log.debug("conversation partial id=\(conversation.id, privacy: .public) reason=historyPageSkipped")
            }
        }

        let ordered = Self.ordered(raw)
        // "Settled" needs positive proof that the user's own message is the newest thing
        // here. An empty window proves nothing, and treating it as settled would silently
        // mark an old open task done.
        var channelSettled = previous?.settled ?? false
        if let newest = ordered.last { channelSettled = newest.user == identity.userID }

        var pending: [Pending] = []
        // Threads first, so a parent whose thread was read is not ALSO reported as a
        // channel message. A thread parent is a channel message, and emitting both would
        // put the same obligation on the list twice under two different conversation ids.
        var handled: Set<String> = []
        var checkpoints: [String: SlackConversationCheckpoint] = [:]

        for parent in ordered where Self.shouldFetchReplies(parent, userID: identity.userID) {
            // A cooled method is treated exactly like an exhausted budget: the request is
            // not made, the watermark does not advance, and the next refresh sees this
            // thread again. Anything else would mark it read without having read it.
            guard cooldown("conversations.replies") == nil, spend(reserve: nameReserve) else {
                historyComplete = false
                log.debug("conversation partial id=\(conversation.id, privacy: .public) reason=repliesSkipped")
                break
            }
            let replies = Self.ordered(Self.parseMessages(
                try await get("conversations.replies",
                              [("channel", conversation.id), ("ts", parent.ts), ("limit", "200")])))
            guard let root = replies.first else { continue }
            handled.insert(parent.ts)
            let key = root.threadTS ?? root.ts
            if let newest = replies.last {
                checkpoints[key] = SlackConversationCheckpoint(
                    newestTS: newest.ts,
                    settled: newest.user == identity.userID
                )
            }

            let threadTail = Self.unrepliedTail(replies, userID: identity.userID)
            if let newest = threadTail.last, newest.date > since {
                let context = ThreadContext(ts: key,
                                            parentAuthorID: root.user,
                                            participants: Set(replies.map(\.user)))
                let tailTimestamps = Set(threadTail.map(\.ts))
                pending += replies.filter { !tailTimestamps.contains($0.ts) }.map {
                    Pending(raw: $0, conversation: conversation, thread: context, isContext: true)
                }
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
        if historyComplete {
            let newestAccounted = max(
                previous?.newestTS ?? "",
                raw.map(\.ts).max() ?? Self.slackTS(scanStartedAt)
            )
            checkpoints[conversation.id] = SlackConversationCheckpoint(
                newestTS: newestAccounted,
                settled: channelSettled
            )
        }
        return ScanResult(pending: pending, checkpoints: checkpoints)
    }

    /// Display names and avatars are persisted with the scan state, so an app relaunch is
    /// not a cold users.info pass. Unknown authors stay sequential because they are normally
    /// few. A name already cached but with no avatar yet (a state.json from before avatars
    /// existed) is refetched once, after which both are cached together.
    private func resolveNames(_ ids: Set<String>, reserve: Int = 0) async -> [String: String] {
        for id in ids.sorted() where userNames[id] == nil || userAvatars[id] == nil {
            guard spend(reserve: reserve) else { break }
            guard let info = try? await get("users.info", [("user", id)]),
                  let user = info["user"] as? [String: Any] else { continue }
            let profile = user["profile"] as? [String: Any]
            let display = (profile?["display_name"] as? String) ?? ""
            let real = user["real_name"] as? String ?? ""
            userNames[id] = display.isEmpty ? (real.isEmpty ? id : real) : display
            // ponytail: a genuinely avatar-less profile leaves userAvatars[id] unset, so the
            // where-clause above refetches that id on every future call. Real Slack users
            // always carry a default image_48/72, so this is dead weight rather than a real
            // cost; give it a resolved-but-nil sentinel if that ever stops being true.
            userAvatars[id] = Self.avatarURL(fromProfile: profile)
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
            .rateLimited(retryAfter: nil)
        case let other:
            .slack(other.isEmpty ? "unknown_error" : other)
        }
    }

    static func parseMessages(_ root: [String: Any]) -> [RawMessage] {
        (root["messages"] as? [[String: Any]] ?? []).compactMap(RawMessage.init)
    }

    /// image_72 preferred, image_48 as a fallback for a smaller/older profile payload.
    /// Both are public avatars.slack-edge.com URLs, no token needed to load them. nil,
    /// never a broken URL, when a profile has neither.
    static func avatarURL(fromProfile profile: [String: Any]?) -> URL? {
        let raw = (profile?["image_72"] as? String) ?? (profile?["image_48"] as? String)
        guard let raw, !raw.isEmpty else { return nil }
        return URL(string: raw)
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

        var lastRateLimitStatus = 429
        var lastRetryAfterSeconds: Int64?
        var lastRateLimitAttempt = 0
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
                let waitSeconds = wait.components.seconds
                lastRateLimitStatus = http.statusCode
                lastRetryAfterSeconds = waitSeconds
                lastRateLimitAttempt = attempt
                if wait > maxRetryWait {
                    log.error("rate limit gave up method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public) retryAfter=\(waitSeconds, privacy: .public)s attempt=\(attempt, privacy: .public) reason=waitExceedsMaxRetryWait")
                    throw SlackSourceError.rateLimited(retryAfter: TimeInterval(waitSeconds))
                }
                if attempt >= 2 {
                    log.error("rate limit gave up method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public) retryAfter=\(waitSeconds, privacy: .public)s attempt=\(attempt, privacy: .public) reason=attemptsRanOut")
                    throw SlackSourceError.rateLimited(retryAfter: TimeInterval(waitSeconds))
                }
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
                if http.statusCode != 429 && http.statusCode < 500 {
                    log.error("unexpected response method=\(method, privacy: .public) status=\(http.statusCode, privacy: .public)")
                }
                throw SlackSourceError.slack("http_\(http.statusCode)")
            }
            return data
        }
        let retryAfter = lastRetryAfterSeconds.map(String.init) ?? "none"
        log.error("rate limit gave up method=\(method, privacy: .public) status=\(lastRateLimitStatus, privacy: .public) retryAfter=\(retryAfter, privacy: .public) attempt=\(lastRateLimitAttempt, privacy: .public) reason=attemptsRanOut")
        throw SlackSourceError.rateLimited(retryAfter: lastRetryAfterSeconds.map(TimeInterval.init))
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

/// The source Store is given at launch. It checks the Keychain per call so connecting or
/// disconnecting Slack takes effect on the next refresh instead of the next launch. When
/// there is no token it reports notConnected; canned messages belong only to demos.
struct LiveMessageSource: SlackScanStateSource {
    private let slack: SlackMessageSource
    private let tokenAvailable: @Sendable () -> Bool

    init(
        slack: SlackMessageSource = SlackMessageSource(),
        tokenAvailable: @escaping @Sendable () -> Bool = { SlackKeychain.load() != nil }
    ) {
        self.slack = slack
        self.tokenAvailable = tokenAvailable
    }

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        guard tokenAvailable() else { throw SlackSourceError.notConnected }
        return try await slack.unrepliedMessages(since: since)
    }

    func repliedIDs(among ids: [String]) async throws -> Set<String> {
        guard tokenAvailable() else { throw SlackSourceError.notConnected }
        return try await slack.repliedIDs(among: ids)
    }

    func restoreSlackScanState(_ state: SlackScanState) async {
        await slack.restoreSlackScanState(state)
    }

    func currentSlackScanState() async -> SlackScanState {
        await slack.currentSlackScanState()
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

    // MARK: avatar URL parsing
    assert(S.avatarURL(fromProfile: ["image_72": "https://avatars.slack-edge.com/x_72.png"])?
        .absoluteString == "https://avatars.slack-edge.com/x_72.png")
    assert(S.avatarURL(fromProfile: ["image_48": "https://avatars.slack-edge.com/x_48.png"])?
        .absoluteString == "https://avatars.slack-edge.com/x_48.png", "image_48 is the fallback when image_72 is absent")
    assert(S.avatarURL(fromProfile: ["image_72": "https://a/72.png", "image_48": "https://a/48.png"])?
        .absoluteString == "https://a/72.png", "image_72 wins when both are present")
    assert(S.avatarURL(fromProfile: [:]) == nil, "a profile with neither field must yield nil, not a broken URL")
    assert(S.avatarURL(fromProfile: nil) == nil)

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
    assert(slackError(#"{"ok":false,"error":"ratelimited"}"#) == .rateLimited(retryAfter: nil))
    assert(slackError(#"{"ok":false,"error":"channel_not_found"}"#) == .slack("channel_not_found"))
    assert(SlackSourceError.slack("channel_not_found").nonReportableConversationSlug != nil)
    assert(SlackSourceError.slack("is_archived").nonReportableConversationSlug != nil)
    assert(SlackSourceError.slack("not_in_channel").nonReportableConversationSlug != nil)
    assert(SlackSourceError.slack("internal_error").nonReportableConversationSlug == nil)
    assert(SlackSourceError.reconnect.isFatal && SlackSourceError.missingScope("x").isFatal)
    assert(!SlackSourceError.rateLimited(retryAfter: 60).isFatal)
    assert(SlackSourceError.reconnect.localizedDescription.contains("Reconnect"))

    // MARK: the whole pipeline, over canned JSON
    let now = Date()
    @Sendable func ts(_ minutesAgo: Double) -> String { S.slackTS(now.addingTimeInterval(-minutesAgo * 60)) }
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
        var calls: [(String, [(String, String)])] = []
        func record(_ method: String, _ query: [(String, String)] = []) {
            methods.append(method)
            calls.append((method, query))
        }
        /// Budget spend, which is why search.messages is excluded: the diagnostic probe
        /// spends its own separate allowance, so counting its calls here would make the
        /// budget asserts below fail on requests the budget never paid for.
        var count: Int { methods.filter { $0 != "search.messages" }.count }
        func count(of method: String) -> Int { methods.filter { $0 == method }.count }
        /// The query string each call carried, so the self-reference spelling actually sent
        /// can be asserted rather than inferred from behaviour.
        func queries(of method: String) -> [String] {
            calls.compactMap { name, query in
                name == method ? query.first(where: { $0.0 == "query" })?.1 : nil
            }
        }
        func oldest(channel: String) -> [String] {
            calls.compactMap { method, query in
                guard method == "conversations.history",
                      query.first(where: { $0.0 == "channel" })?.1 == channel
                else { return nil }
                return query.first(where: { $0.0 == "oldest" })?.1
            }
        }
    }

    func cannedSource(budget: Int, log: CallLog) -> SlackMessageSource {
        SlackMessageSource(call: { method, query in
            await log.record(method, query)
            let channel = query.first { $0.0 == "channel" }?.1 ?? ""
            let body: String
            switch method {
            case "auth.test":
                body = #"{"ok":true,"user_id":"U_ME","team":"Acme","url":"https://acme.slack.com/"}"#
            case "users.info":
                let id = query.first { $0.0 == "user" }?.1 ?? "U"
                body = #"{"ok":true,"user":{"real_name":"Name \#(id)","profile":{"display_name":"n\#(id)","image_72":"https://avatars.slack-edge.com/\#(id)_72.png"}}}"#
            case "usergroups.list":
                body = #"{"ok":true,"usergroups":[{"id":"S1","users":["U_ME"]},{"id":"S9","users":["U_X"]}]}"#
            case "users.conversations":
                // Keep this call suspended so concurrent scans overlap at the cache boundary.
                try await Task.sleep(for: .milliseconds(20))
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

    let concurrentLog = CallLog()
    let concurrentSource = cannedSource(budget: 40, log: concurrentLog)
    async let concurrentFirst = concurrentSource.unrepliedMessages(since: now)
    async let concurrentSecond = concurrentSource.unrepliedMessages(since: now)
    _ = try! await (concurrentFirst, concurrentSecond)
    let concurrentConversationCalls = await concurrentLog.count(of: "users.conversations")
    assert(concurrentConversationCalls == 1,
           "concurrent refreshes requested users.conversations \(concurrentConversationCalls) times")

    let fullLog = CallLog()
    let source = cannedSource(budget: 40, log: fullLog)
    let originalFloor = now.addingTimeInterval(-2 * 60 * 60)
    await source.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
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
    // posted in, under someone else's parent, mentioning them. The root remains in the
    // emitted conversation even though unrepliedTail starts after the user's own reply.
    let threadTS = S.slackTS(now.addingTimeInterval(-30 * 60))
    let threadMessages = messages.filter { $0.conversationID == threadTS }
    assert(threadMessages.count == 3, "whole thread page plus unreplied message, got \(threadMessages.count)")
    assert(threadMessages.contains { $0.text == "deploy thread" }, "the history root is missing")
    assert(threadMessages.first { $0.text == "deploy thread" }?.isContext == true,
           "the thread root before the unreplied tail must be context")
    assert(threadMessages.first { $0.text == "on it" }?.isContext == true,
           "the reader's earlier reply must be context")
    assert(threadMessages.first { $0.text == "on it" }?.isFromUser == true,
           "the reader's own context must be labelled as theirs")
    let threadReply = threadMessages.first { $0.text.contains("any update") }!
    assert(!threadReply.isContext, "the unreplied tail is the obligation, not context")
    assert(threadReply.addressing == [.threadParticipant, .mention],
           "expected threadParticipant+mention, got \(threadReply.addressing)")
    assert(threadReply.permalink!.absoluteString.contains("thread_ts=\(threadTS)"))
    assert(threadReply.channel == "#engineering")
    assert(threadReply.sender == "nU_AYESHA", "display name resolved via users.info")
    assert(threadReply.avatarURL?.absoluteString == "https://avatars.slack-edge.com/U_AYESHA_72.png",
           "image_72 from the same users.info response must reach the emitted SlackMessage, got \(String(describing: threadReply.avatarURL))")

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
    assert(messages.count == 5, "thread context adds the root and earlier reply, got \(messages.count)")
    assert(messages == messages.sorted { $0.date > $1.date }, "newest first")

    // repliedIDs reuses the scan, costs nothing, and strips the #n suffix.
    let before = await fullLog.count
    let replied = try! await source.repliedIDs(among: ["C_SETTLED", "C_SETTLED#1", "D_PAUL", "C_NEVER_SEEN"])
    assert(replied == ["C_SETTLED", "C_SETTLED#1"], "got \(replied)")
    let after = await fullLog.count
    assert(after == before, "reply detection must not issue requests, spent \(after - before)")
    assert(S.conversationKey(ofItem: "C_X#2") == "C_X" && S.conversationKey(ofItem: "C_X") == "C_X")

    // MARK: later scans start at each conversation's own edge
    let firstState = await source.currentSlackScanState()
    assert(firstState.conversations["D_PAUL"]?.newestTS == ts(2))
    assert(firstState.conversations["C_SETTLED"]?.settled == true)
    let repliesAfterFirst = await fullLog.count(of: "conversations.replies")
    let usersAfterFirst = await fullLog.count(of: "users.info")
    let next = try! await source.unrepliedMessages(since: now)
    assert(next.isEmpty, "the canned old rows must be behind their watermarks")
    let repliesAfterSecond = await fullLog.count(of: "conversations.replies")
    let usersAfterSecond = await fullLog.count(of: "users.info")
    assert(repliesAfterSecond == repliesAfterFirst,
           "an old thread parent must not trigger another replies call")
    assert(usersAfterSecond == usersAfterFirst,
           "known names must not trigger another users.info call")
    let remembered = try! await source.repliedIDs(among: ["C_SETTLED"])
    assert(remembered == ["C_SETTLED"], "settled proof must survive an empty incremental window")
    let paulOldest = await fullLog.oldest(channel: "D_PAUL")
    assert(paulOldest.count == 2 && paulOldest[0] == S.slackTS(originalFloor) && paulOldest[1] == ts(2),
           "history did not move from the connection floor to the per-conversation watermark")

    // Persisted author names avoid refetching those profiles after a relaunch. Identity
    // itself is deliberately refreshed so user-group membership cannot become permanent.
    var savedState = await source.currentSlackScanState()
    savedState.conversations["D_PAUL"] = SlackConversationCheckpoint(
        newestTS: ts(3), settled: false
    )
    let relaunchLog = CallLog()
    let relaunched = cannedSource(budget: 40, log: relaunchLog)
    await relaunched.restoreSlackScanState(savedState)
    let relaunchedRows = try! await relaunched.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    let relaunchedAuthCalls = await relaunchLog.count(of: "auth.test")
    let relaunchedUserCalls = await relaunchLog.count(of: "users.info")
    let relaunchedGroupCalls = await relaunchLog.count(of: "usergroups.list")
    assert(relaunchedRows.count == 1 && relaunchedRows[0].sender == "nU_PAUL")
    assert(relaunchedAuthCalls == 1 && relaunchedGroupCalls == 1)
    assert(relaunchedUserCalls == 1,
           "only the user's identity, not a cached author, should need users.info")

    // MARK: a first connected scan establishes and obeys its floor
    let floorLog = CallLog()
    let beforeConnect = Date()
    let oldTS = S.slackTS(beforeConnect.addingTimeInterval(-60))
    let floorSource = SlackMessageSource(call: { method, query in
        await floorLog.record(method, query)
        let body: String
        switch method {
        case "auth.test":
            body = #"{"ok":true,"user_id":"U_ME"}"#
        case "users.info":
            body = #"{"ok":true,"user":{"real_name":"","profile":{"display_name":""}}}"#
        case "usergroups.list":
            body = #"{"ok":true,"usergroups":[]}"#
        case "users.conversations":
            body = #"{"ok":true,"channels":[{"id":"C_NEW","name":"new"}]}"#
        case "conversations.history":
            body = """
            {"ok":true,"messages":[{"ts":"\(oldTS)","user":"U_OTHER","text":"old"}]}
            """
        default:
            body = #"{"ok":false,"error":"unknown_method"}"#
        }
        return Data(body.utf8)
    })
    let oldRows = try! await floorSource.unrepliedMessages(since: .distantPast)
    let floorState = await floorSource.currentSlackScanState()
    let afterConnect = Date()
    let connectedAt = floorState.connectedAt!
    assert(connectedAt >= beforeConnect && connectedAt <= afterConnect)
    assert(oldRows.isEmpty, "a first connection must not return pre-connection messages")
    let floorOldest = await floorLog.oldest(channel: "C_NEW")
    assert(floorOldest == [S.slackTS(connectedAt)],
           "the first history oldest must be the connection floor")

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
    await tight.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    let partial = try! await tight.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    let spent = await tightLog.count
    assert(spent <= 6, "the budget must be a hard cap, spent \(spent)")
    assert(!partial.isEmpty, "a partial list beats an empty one")
    assert(partial.count < messages.count, "budget exhausted, so some conversations were skipped")
    assert(partial.contains { $0.conversationID == "D_PAUL" }, "IMs are scanned first, so they survive")
    let tightState = await tight.currentSlackScanState()
    assert(tightState.conversations["D_PAUL"] != nil)
    assert(tightState.conversations["C_ENG"] == nil,
           "a conversation skipped for budget must keep its old watermark")

    // MARK: a capped method costs one rejected call per refresh, not one per conversation
    // Slack answers conversations.history about once a minute for an app of this class.
    // The bug this pins: the sweep launched a request per conversation, roughly thirty of
    // them rejected on the spot, which kept the limit renewed so the first call of the
    // next refresh was rejected too, forever.
    func rateLimitedSource(
        readable: String?, history: String, retryAfter: TimeInterval = 60, log: CallLog
    ) -> SlackMessageSource {
        SlackMessageSource(call: { method, query in
            await log.record(method, query)
            let channel = query.first { $0.0 == "channel" }?.1 ?? ""
            // The seam's contract is that Retry-After has already been honoured, which is
            // what httpCall does before giving up on a wait it cannot afford.
            if method == "conversations.history", channel != readable {
                throw SlackSourceError.rateLimited(retryAfter: retryAfter)
            }
            let body: String
            switch method {
            case "auth.test":
                body = #"{"ok":true,"user_id":"U_ME","url":"https://acme.slack.com/"}"#
            case "users.info":
                let id = query.first { $0.0 == "user" }?.1 ?? "U"
                body = #"{"ok":true,"user":{"real_name":"Name \#(id)","profile":{"display_name":"n\#(id)"}}}"#
            case "usergroups.list":
                body = #"{"ok":true,"usergroups":[]}"#
            case "users.conversations":
                body = conversationList
            case "conversations.history":
                body = history
            default:
                body = #"{"ok":false,"error":"unknown_method"}"#
            }
            return Data(body.utf8)
        })
    }

    let cappedLog = CallLog()
    let capped = rateLimitedSource(readable: nil, history: dmHistory, log: cappedLog)
    await capped.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    do {
        let rows = try await capped.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
        assert(false, "a refresh that read nothing returned \(rows.count) rows instead of an error")
    } catch let error as SlackSourceError {
        assert(error == .rateLimited(retryAfter: 60), "got \(error)")
    } catch {
        assert(false, "wrong error type")
    }
    let cappedHistory = await cappedLog.count(of: "conversations.history")
    assert(cappedHistory == 1, "nine conversations must cost one rejected call, got \(cappedHistory)")

    // The cooldown outlives the refresh, so the next one makes no request at all, and it
    // still must not report inbox zero. Identity survives the round trip through Store's
    // rollback: clearing it there is what made every failed refresh re-buy auth.test.
    await capped.restoreSlackScanState(await capped.currentSlackScanState())
    do {
        _ = try await capped.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
        assert(false, "a fully blocked refresh must not be reported as inbox zero")
    } catch let error as SlackSourceError {
        guard case .rateLimited = error else {
            assert(false, "got \(error)")
            fatalError()
        }
    } catch {
        assert(false, "wrong error type")
    }
    let cappedHistoryAgain = await cappedLog.count(of: "conversations.history")
    let cappedAuthCalls = await cappedLog.count(of: "auth.test")
    assert(cappedHistoryAgain == 1, "a cooled method must not be called at all, got \(cappedHistoryAgain)")
    assert(cappedAuthCalls == 1, "a failed refresh must keep the cached identity, spent \(cappedAuthCalls)")

    // MARK: one readable conversation makes the refresh a partial success, not a failure
    let survivorLog = CallLog()
    let survivor = rateLimitedSource(readable: "D_PAUL", history: dmHistory, log: survivorLog)
    await survivor.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    let survived = try! await survivor.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    assert(Set(survived.map(\.text)) == ["Hi", "review it within the hour"],
           "the one readable conversation must come back, got \(survived.count) rows")
    // Four history calls, not thirty: the probe plus one batch of concurrent children,
    // after which the recorded cooldown stops the sweep. A workspace already known to be
    // capped serialises from the start and pays just one rejection.
    let survivorHistory = await survivorLog.count(of: "conversations.history")
    assert(survivorHistory <= 4, "the sweep must stop on the first 429, spent \(survivorHistory)")
    let survivorState = await survivor.currentSlackScanState()
    assert(survivorState.conversations["D_PAUL"]?.newestTS == ts(2),
           "a partial refresh must keep the checkpoint it earned")
    assert(survivorState.conversations["C_ENG"] == nil,
           "a conversation the rate limit blocked must keep its old watermark")

    // Owing nothing is not the same as reading nothing. A conversation the user has
    // already answered was still read, so the refresh succeeded: reporting an error here
    // would say nothing arrived when the truth is that nothing is owed, and it would throw
    // away the settlement proof that read just earned.
    let quietLog = CallLog()
    let quiet = rateLimitedSource(readable: "D_PAUL", history: settledChannel, log: quietLog)
    await quiet.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    do {
        let rows = try await quiet.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
        assert(rows.isEmpty, "the user answered last there, got \(rows.count) rows")
    } catch {
        assert(false, "a refresh that read one conversation must not fail: \(error)")
    }
    let quietState = await quiet.currentSlackScanState()
    assert(quietState.conversations["D_PAUL"]?.settled == true,
           "a partial refresh must keep the proof it earned")

    // MARK: the next refresh resumes past the conversation the limit blocked
    // One history call a minute means a refresh reads about one conversation, so starting
    // at the top every time would re-read the first one forever and never reach the rest.
    // The canned Retry-After is a fraction of a second so the cooldown can lapse between
    // these two refreshes without the check waiting out a real minute.
    let rotationLog = CallLog()
    let rotating = rateLimitedSource(
        readable: "C_ENG", history: dmHistory, retryAfter: 0.4, log: rotationLog
    )
    await rotating.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    do {
        let rows = try await rotating.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
        assert(false, "the DM was rate limited, so this refresh read nothing: \(rows.count) rows")
    } catch let error as SlackSourceError {
        guard case .rateLimited = error else {
            assert(false, "got \(error)")
            fatalError()
        }
    } catch {
        assert(false, "wrong error type")
    }
    try! await Task.sleep(for: .milliseconds(500))
    let resumed = try! await rotating.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    assert(Set(resumed.map(\.conversationID)) == ["C_ENG"],
           "the sweep must resume past the blocked conversation, got \(Set(resumed.map(\.conversationID)))")

    // MARK: every child the sweep launches is collected, and the limit is never exceeded
    // This pins the crash. The collection condition used to be an equality test against a
    // limit recomputed on every pass, and the cooldown table keeps its entry after the
    // window it describes has lapsed, so the limit fell to one while three children were
    // already running and the in-flight count could never equal it again. Collection
    // stopped dead while the loop went on launching, which is how a refresh ended up with
    // an unbounded number of children offering results into a group nobody was reading.
    // The peak is the assert that catches it: a sweep that honours its limit never holds
    // more than three history calls open at once, and the broken code held eighteen.
    actor SweepTracker {
        private var live = 0
        var peak = 0
        var historyCalls = 0
        var rejections = 0
        /// The fourth call is the one Slack caps, chosen so a success is already banked
        /// before the 429 lands and so fifteen conversations are still unswept after it.
        func enterHistory() -> Bool {
            historyCalls += 1
            live += 1
            peak = max(peak, live)
            let reject = historyCalls == 4
            if reject { rejections += 1 }
            return reject
        }
        func leaveHistory() { live -= 1 }
    }
    let tracker = SweepTracker()
    let wideTS = ts(2)
    let wideList = #"{"ok":true,"channels":[{"id":"D_ONE","is_im":true,"user":"U_OTHER"},"#
        + (1...20).map { #"{"id":"C_W\#($0)","name":"w\#($0)"}"# }.joined(separator: ",")
        + "]}"
    let wide = SlackMessageSource(call: { method, query in
        let body: String
        switch method {
        case "auth.test":
            body = #"{"ok":true,"user_id":"U_ME","url":"https://acme.slack.com/"}"#
        case "usergroups.list":
            body = #"{"ok":true,"usergroups":[]}"#
        case "users.conversations":
            body = wideList
        case "users.info":
            body = #"{"ok":true,"user":{"real_name":"Other","profile":{"display_name":"other"}}}"#
        case "conversations.history":
            let channel = query.first { $0.0 == "channel" }?.1 ?? ""
            let reject = await tracker.enterHistory()
            // A real request stays open for a while, which is what lets the parent come
            // back round the loop while children are still in flight. Without the wait
            // the sweep would be serial by accident and prove nothing.
            try? await Task.sleep(for: .milliseconds(15))
            await tracker.leaveHistory()
            // Retry-After zero is already in the past by the time the loop next reads the
            // table, so the cooldown is recorded but lapsed. That is the exact state that
            // used to tighten the limit under children that had already been launched,
            // and it is why the sweep continues here instead of breaking.
            if reject { throw SlackSourceError.rateLimited(retryAfter: 0) }
            body = #"{"ok":true,"messages":[{"ts":"\#(wideTS)","user":"U_OTHER","text":"\#(channel)"}]}"#
        default:
            body = #"{"ok":false,"error":"unknown_method"}"#
        }
        return Data(body.utf8)
    }, budget: 60)
    await wide.restoreSlackScanState(SlackScanState(connectedAt: originalFloor))
    let wideRows = try! await wide.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    let widePeak = await tracker.peak
    let wideHistory = await tracker.historyCalls
    let wideRejections = await tracker.rejections
    // Three is maxInFlight, spelled out because it is private to the actor.
    assert(widePeak <= 3, "the sweep held \(widePeak) history calls open at once, limit is 3")
    assert(wideHistory == 21, "the sweep must reach every conversation once, got \(wideHistory)")
    assert(wideRows.count == wideHistory - wideRejections,
           "\(wideHistory - wideRejections) children succeeded but \(wideRows.count) results came back")
    assert(wideRows.contains { $0.conversationID == "D_ONE" },
           "the success banked before the 429 was lost")

    // MARK: an unreadable conversation is skipped and evicted, not reported as refresh failure
    let goneLog = CallLog()
    let gone = SlackMessageSource(call: { method, query in
        await goneLog.record(method)
        let body: String
        switch method {
        case "auth.test":
            body = #"{"ok":true,"user_id":"U_ME","url":"https://acme.slack.com/"}"#
        case "users.info":
            body = #"{"ok":true,"user":{"real_name":"","profile":{"display_name":""}}}"#
        case "usergroups.list":
            body = #"{"ok":true,"usergroups":[]}"#
        case "users.conversations":
            body = #"{"ok":true,"channels":[{"id":"C_GONE","name":"gone"}]}"#
        case "conversations.history":
            let channel = query.first { $0.0 == "channel" }?.1 ?? ""
            body = channel == "C_GONE"
                ? #"{"ok":false,"error":"channel_not_found"}"#
                : #"{"ok":true,"messages":[]}"#
        default:
            body = #"{"ok":false,"error":"unknown_method"}"#
        }
        return Data(body.utf8)
    })
    do {
        let empty = try await gone.unrepliedMessages(since: .distantPast)
        assert(empty.isEmpty, "one unreadable conversation must still allow inbox zero")
    } catch {
        assert(false, "channel_not_found must not escape the conversation scan: \(error)")
    }
    do {
        _ = try await gone.unrepliedMessages(since: .distantPast)
    } catch {
        assert(false, "the evicted conversation must not fail the next refresh: \(error)")
    }
    let goneHistoryCalls = await goneLog.count(of: "conversations.history")
    let goneListCalls = await goneLog.count(of: "users.conversations")
    assert(goneHistoryCalls == 1, "the evicted conversation was scanned \(goneHistoryCalls) times")
    assert(goneListCalls == 1, "an empty loaded cache must not be mistaken for no cache")

    // MARK: search discovery carries a refresh on its own, with history unavailable
    @Sendable func searchMatch(channel: String, ts: String, user: String, text: String, threadTS: String? = nil) -> String {
        let permalink = "https://acme.slack.com/archives/\(channel)/p\(ts.replacingOccurrences(of: ".", with: ""))"
            + (threadTS.map { "?thread_ts=\($0)&cid=\(channel)" } ?? "")
        return #"{"ts":"\#(ts)","user":"\#(user)","text":"\#(text)","channel":{"id":"\#(channel)"},"permalink":"\#(permalink)"}"#
    }
    @Sendable func searchBody(_ matches: String...) -> Data {
        Data("""
        {"ok":true,"messages":{"pagination":{"total":\(matches.count),"page":1,"page_count":1,"per_page":100},
         "matches":[\(matches.joined(separator: ","))]}}
        """.utf8)
    }
    /// Everything except search.messages, which each source below answers for itself. This
    /// is the workspace Sereno actually runs on: conversations.history is answered 429 on
    /// the first request of a freshly launched process, so nothing comes from history.
    let engThreadTS = ts(30)
    let otherThreadTS = ts(31)
    @Sendable func searchOnlyCall(
        _ method: String,
        _ log: CallLog
    ) async throws -> Data? {
        await log.record(method)
        switch method {
        case "auth.test": return Data(#"{"ok":true,"user_id":"U_ME","url":"https://acme.slack.com/"}"#.utf8)
        case "users.info": return Data(#"{"ok":true,"user":{"real_name":"Ana","profile":{"display_name":"ana"}}}"#.utf8)
        case "usergroups.list": return Data(#"{"ok":true,"usergroups":[]}"#.utf8)
        case "users.conversations":
            return Data(#"{"ok":true,"channels":[{"id":"D_PAUL","is_im":true},{"id":"C_ENG","name":"eng"},{"id":"C_OTHER","name":"other"},{"id":"C_SETTLED","name":"design"}]}"#.utf8)
        case "conversations.history": throw SlackSourceError.rateLimited(retryAfter: 60)
        case "conversations.replies":
            return Data("""
            {"ok":true,"messages":[
              {"ts":"\(engThreadTS)","user":"U_ME","text":"The deployment plan needs review","thread_ts":"\(engThreadTS)"},
              {"ts":"\(ts(20))","user":"U_HELPER","text":"Earlier discussion","thread_ts":"\(engThreadTS)"},
              {"ts":"\(ts(4))","user":"U_DEV","text":"<@U_ME>","thread_ts":"\(engThreadTS)"}
            ]}
            """.utf8)
        default: return nil
        }
    }

    @Sendable func searchOnlySource(_ searchLog: CallLog) -> SlackMessageSource {
            SlackMessageSource(call: { method, query in
            if let canned = try await searchOnlyCall(method, searchLog) { return canned }
            await searchLog.record(method, query)
            let q = query.first { $0.0 == "query" }?.1 ?? ""
            // A DM that also mentions the user matches two of the queries, which is what the
            // deduplication below has to survive.
            if q.hasPrefix("<@U_ME>") {
                return searchBody(
                    searchMatch(channel: "D_PAUL", ts: ts(5), user: "U_PAUL", text: "<@U_ME> can you review this"),
                    searchMatch(channel: "C_SETTLED", ts: ts(15), user: "U_ANA", text: "<@U_ME> ping")
                )
            }
            if q.hasPrefix("to:me") {
                return searchBody(searchMatch(channel: "D_PAUL", ts: ts(5), user: "U_PAUL", text: "<@U_ME> can you review this"))
            }
            if q.hasPrefix("is:thread with:me") {
                return searchBody(
                    searchMatch(channel: "C_ENG", ts: ts(4), user: "U_DEV",
                                text: "<@U_ME>", threadTS: engThreadTS),
                    searchMatch(channel: "C_OTHER", ts: ts(8), user: "U_OTHER",
                                text: "need help", threadTS: otherThreadTS)
                )
            }
            if q.hasPrefix("from:me") {
                // Answered after the C_SETTLED mention above, which settles that conversation.
                return searchBody(searchMatch(channel: "C_SETTLED", ts: ts(2), user: "U_ME", text: "done"))
            }
            return Data(#"{"ok":false,"error":"unexpected_query"}"#.utf8)
        })
    }

    let searchLog = CallLog()
    let searchOnly = searchOnlySource(searchLog)
    await searchOnly.restoreSlackScanState(SlackScanState(connectedAt: now.addingTimeInterval(-60 * 60)))
    let searchRows = try! await searchOnly.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    let searchHistoryCalls = await searchLog.count(of: "conversations.history")
    assert(searchHistoryCalls >= 1, "history must still be attempted where quota might exist")
    assert(searchRows.count == 5, "the whole search thread page must be added, got \(searchRows.count)")
    assert(Set(searchRows.map(\.conversationID)) == ["D_PAUL", engThreadTS, otherThreadTS],
           "threaded matches are keyed by their threads: \(searchRows.map(\.conversationID))")
    // A match whose permalink carried no thread_ts is a plain channel message, never dropped.
    let searchDM = searchRows.first { $0.conversationID == "D_PAUL" }!
    assert(searchDM.addressing.contains(.directMessage) && searchDM.addressing.contains(.mention),
           "the DM kind came from the cached conversation list: \(searchDM.addressing)")
    assert(searchDM.sender == "ana" || searchDM.sender == "U_PAUL",
           "a name lookup may be skipped for budget but must not invent one")
    let contextualThread = searchRows.filter { $0.conversationID == engThreadTS }
    assert(contextualThread.contains { $0.text == "The deployment plan needs review" },
           "the context-starved reply must bring its root")
    assert(contextualThread.filter(\.isContext).map(\.text).sorted() ==
           ["Earlier discussion", "The deployment plan needs review"],
           "every non-pending row in the fetched thread page must be context")
    assert(contextualThread.filter { !$0.isContext }.count == 1,
           "the pending search match must remain the sole obligation")
    assert(contextualThread.contains { $0.addressing.contains(.threadParticipant) && $0.addressing.contains(.replyToMe) },
           "the fetched parent and participants must reach addressing: \(contextualThread.map(\.addressing))")
    let searchRepliesCalls = await searchLog.count(of: "conversations.replies")
    assert(searchRepliesCalls == 1, "two context-starved threads must cost one replies call, got \(searchRepliesCalls)")
    let searchSettled = try! await searchOnly.repliedIDs(among: ["C_SETTLED", "D_PAUL", engThreadTS, otherThreadTS])
    assert(searchSettled == ["C_SETTLED"], "from:<self> is the reply detector now, got \(searchSettled)")
    assert(!searchRows.contains { $0.conversationID == "C_SETTLED" },
           "a conversation the user has since answered is not an obligation")

    // MARK: what the search probe logged, which is the whole of what it is allowed to log
    let probeSource = searchOnlySource(CallLog())
    await probeSource.restoreSlackScanState(SlackScanState(connectedAt: now.addingTimeInterval(-60 * 60)))
    let searchLines = await probeSource.discoverBySearch(
        since: now.addingTimeInterval(-20 * 60),
        identity: Identity(userID: "U_ME", displayName: "", realName: "", userGroupIDs: [])
    ).lines
    assert(searchLines == ["kind=mention ok=true total=2 matches=2",
                           "kind=to:self ok=true total=1 matches=1",
                           "selfReference=me confirmed=true",
                           "kind=thread ok=true total=2 matches=2",
                           "kind=from:self ok=true total=1 matches=1",
                           "threadContext=skipped reason=budget",
                           "candidates=3 answered=1 threadTSPresent=2 threadTSAbsent=2 " +
                           "settled=1 searchCallsLeft=4"],
           "got \(searchLines)")
    assert(!searchLines.contains { $0.contains("D_PAUL") || $0.contains("C_ENG") || $0.contains("review")
                                   || $0.contains("acme.slack.com") || $0.contains("U_PAUL") },
           "a probe line carried content: \(searchLines)")

    // MARK: the self-reference spelling is settled at runtime, not guessed
    let altLog = CallLog()
    let alternate = SlackMessageSource(call: { method, query in
        if let canned = try await searchOnlyCall(method, altLog) { return canned }
        await altLog.record(method, query)
        let q = query.first { $0.0 == "query" }?.1 ?? ""
        // This workspace answers nothing for `me`, which is exactly the failure mode the
        // two conflicting production clients disagree about.
        if q.hasPrefix("to:@me") {
            return searchBody(searchMatch(channel: "C_OPEN", ts: ts(4), user: "U_PAUL", text: "please review"))
        }
        return searchBody()
    })
    await alternate.restoreSlackScanState(SlackScanState(connectedAt: now.addingTimeInterval(-60 * 60)))
    let altRows = try! await alternate.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    assert(altRows.count == 1, "the alternate spelling found the message, got \(altRows.count)")
    assert(altRows[0].conversationID == "C_OPEN", "got \(altRows[0].conversationID)")
    let altQueries = await altLog.queries(of: "search.messages")
    assert(altQueries.count == 5, "one retry, not one per query: \(altQueries)")
    assert(altQueries.contains { $0.hasPrefix("to:@me") } && altQueries.contains { $0.hasPrefix("to:me") },
           "both spellings must have been tried: \(altQueries)")
    assert(altQueries.contains { $0.hasPrefix("is:thread with:@me") },
           "the winning spelling must be kept for the rest of the process: \(altQueries)")

    // MARK: search discovery is a bounded lookback, not a sliding watermark
    // THE BUG THIS PINS: a refresh's `since` (Store's lastScan) advances on every success
    // whether or not anything was found, so under the old cutoff = max(since, floor) a
    // workspace with a fast refresh cadence had `since` sitting seconds behind "now" on
    // every pass, which silently excluded any match older than that instant. Only mention
    // queries answer here; to:/thread/from: queries return no matches, so a match reaching
    // the emitted rows can only have come through the cutoff this section pins.
    @Sendable func mentionOnlySource(matches: [(ts: String, text: String)]) -> SlackMessageSource {
        SlackMessageSource(call: { method, query in
            switch method {
            case "auth.test": return Data(#"{"ok":true,"user_id":"U_ME","url":"https://acme.slack.com/"}"#.utf8)
            case "users.info": return Data(#"{"ok":true,"user":{"real_name":"","profile":{"display_name":""}}}"#.utf8)
            case "usergroups.list": return Data(#"{"ok":true,"usergroups":[]}"#.utf8)
            case "users.conversations": return Data(#"{"ok":true,"channels":[{"id":"C_LOOKBACK","name":"lookback"}]}"#.utf8)
            case "conversations.history": throw SlackSourceError.rateLimited(retryAfter: 60)
            case "search.messages":
                let q = query.first { $0.0 == "query" }?.1 ?? ""
                guard q.hasPrefix("<@U_ME>") else { return searchBody() }
                let bodies = matches.map { searchMatch(channel: "C_LOOKBACK", ts: $0.ts, user: "U_OTHER", text: $0.text) }
                return Data("""
                {"ok":true,"messages":{"pagination":{"total":\(bodies.count),"page":1,"page_count":1,"per_page":100},
                 "matches":[\(bodies.joined(separator: ","))]}}
                """.utf8)
            default: return Data(#"{"ok":false,"error":"unknown_method"}"#.utf8)
            }
        })
    }

    // A match older than `since` but inside the lookback IS discovered: `since` sits one
    // second behind "now", exactly what a fast, repeatedly-successful refresh cadence
    // produces, while connectedAt is far older than the 24h lookback so it never binds.
    let staleWatermarkConnectedAt = now.addingTimeInterval(-10 * 24 * 60 * 60)
    let insideLookbackTS = S.slackTS(now.addingTimeInterval(-3 * 60 * 60))
    let staleWatermarkSource = mentionOnlySource(matches: [(insideLookbackTS, "old but inside the lookback")])
    await staleWatermarkSource.restoreSlackScanState(SlackScanState(connectedAt: staleWatermarkConnectedAt))
    let staleWatermarkRows = try! await staleWatermarkSource.unrepliedMessages(since: now.addingTimeInterval(-1))
    assert(staleWatermarkRows.contains { $0.text == "old but inside the lookback" },
           "a match older than `since` but inside the lookback must still be discovered, got \(staleWatermarkRows.map(\.text))")

    // A match older than connectedAt is still never discovered, even though it sits well
    // inside what the 24h lookback alone would allow: connectedAt is the tighter, absolute
    // floor here (2h ago vs. a 24h lookback), and it must still win.
    let recentConnectedAt = now.addingTimeInterval(-2 * 60 * 60)
    let beforeFloorTS = S.slackTS(recentConnectedAt.addingTimeInterval(-10 * 60))
    let floorGuardedSource = mentionOnlySource(matches: [(beforeFloorTS, "predates connection")])
    await floorGuardedSource.restoreSlackScanState(SlackScanState(connectedAt: recentConnectedAt))
    let floorGuardedRows = try! await floorGuardedSource.unrepliedMessages(since: now.addingTimeInterval(-20 * 60))
    assert(!floorGuardedRows.contains { $0.text == "predates connection" },
           "a match older than connectedAt must never surface, even inside the lookback")

    // MARK: a missing scope is Slack's own vocabulary, so it is logged, and history decides
    let scopeSource = SlackMessageSource(call: { method, _ in
        method == "search.messages"
            ? Data(#"{"ok":false,"error":"missing_scope","needed":"search:read"}"#.utf8)
            : Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)
    })
    let scopeLines = await scopeSource.discoverBySearch(
        since: now, identity: Identity(userID: "U_ME", displayName: "", realName: "", userGroupIDs: [])
    ).lines
    assert(scopeLines.filter { $0.hasSuffix("error=missingScope(search:read)") }.count == 4,
           "each of the four queries reports the named scope, and a REFUSED query is not " +
           "retried with the other spelling: \(scopeLines)")

    // MARK: the live source never substitutes sample rows for a missing token
    let disconnected = LiveMessageSource(tokenAvailable: { false })
    do {
        let rows = try await disconnected.unrepliedMessages(since: .distantPast)
        assert(false, "a disconnected live source returned \(rows.count) sample rows")
    } catch let error as SlackSourceError {
        assert(error == .notConnected, "got \(error)")
    } catch {
        assert(false, "wrong error type")
    }
    do {
        let ids = try await disconnected.repliedIDs(among: ["C_ONE"])
        assert(false, "a disconnected live source returned \(ids.count) replied ids")
    } catch let error as SlackSourceError {
        assert(error == .notConnected, "got \(error)")
    } catch {
        assert(false, "wrong error type")
    }

    print("demoSlackSource: PASS (\(messages.count) messages, \(await fullLog.count) calls, partial \(partial.count) in \(spent))")
}
