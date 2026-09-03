import Foundation
import os

/// Same privacy rule as SlackMessageSource, restated because this file is its own reader.
/// Ids, counts, HTTP status codes and Slack's own error slugs are `.public`: none of them is
/// content. Message text, sender names, channel names and permalinks are Slack content and
/// are never logged at all, at any privacy level.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "slackSearch")

// MARK: - Raw search shapes

/// The channel a search match happened in. Slack hands over fewer fields here than
/// `users.conversations` does: no `is_im`, so a DM and a genuine private channel cannot be
/// told apart from this struct alone. That is a real gap, not an oversight, and callers that
/// need to distinguish them will have to fall back to the conversation cache SlackMessageSource
/// already keeps.
struct SearchMatchChannel: Sendable, Equatable {
    let id: String
    let name: String?
    let isMpim: Bool
    let isPrivate: Bool

    init?(_ json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = json["name"] as? String
        isMpim = json["is_mpim"] as? Bool ?? false
        isPrivate = json["is_private"] as? Bool ?? false
    }
}

/// One row of `search.messages`. Hand-decoded to match RawMessage's style: a handful of
/// fields out of a larger object, and a Decodable tree would be more code than this.
///
/// What is NOT here on purpose: `thread_ts`. A search match does not carry a message's
/// thread position the way `conversations.history` does. `threadTS(fromPermalink:)` below is
/// the only lead this API offers toward recovering it.
struct SearchMatch: Sendable, Equatable {
    let channel: SearchMatchChannel?
    let iid: String?
    let permalink: String?
    let team: String?
    let text: String
    let ts: String
    let type: String?
    let user: String?
    let username: String?

    var date: Date { Date(timeIntervalSince1970: Double(ts) ?? 0) }

    init?(_ json: [String: Any]) {
        guard let ts = json["ts"] as? String else { return nil }
        self.ts = ts
        channel = (json["channel"] as? [String: Any]).flatMap(SearchMatchChannel.init)
        iid = json["iid"] as? String
        permalink = json["permalink"] as? String
        team = json["team"] as? String
        text = json["text"] as? String ?? ""
        type = json["type"] as? String
        user = json["user"] as? String
        username = json["username"] as? String
    }
}

/// The `messages.pagination` block. `count` and `page` both cap at 100, Slack's own ceiling,
/// so a caller wanting more has to page rather than ask for a bigger single request.
struct SearchPagination: Sendable, Equatable {
    let total: Int
    let page: Int
    let pageCount: Int
    let perPage: Int

    init?(_ json: [String: Any]) {
        guard let total = json["total"] as? Int,
              let page = json["page"] as? Int,
              let pageCount = json["page_count"] as? Int,
              let perPage = json["per_page"] as? Int
        else { return nil }
        self.total = total
        self.page = page
        self.pageCount = pageCount
        self.perPage = perPage
    }
}

struct SearchResult: Sendable, Equatable {
    let matches: [SearchMatch]
    let pagination: SearchPagination?
}

// MARK: - The client

/// Discovery through `search.messages` instead of `conversations.history`. History is capped
/// at about one call a minute for an app of this class, which fails permanently once the
/// user sits in more than a handful of conversations; `search.messages` is Tier 2, twenty or
/// more calls a minute, and is not covered by that cap. This file only builds queries and
/// parses responses. Wiring it into the scan that currently drives off history is a later
/// task, deliberately not attempted here.
///
/// A struct, not an actor: unlike SlackMessageSource there is no cache or in-flight state to
/// protect, only a call seam, so actor isolation would buy nothing.
struct SlackSearch: Sendable {
    /// The single seam. Returns raw response bytes for one Web API method, mirroring
    /// SlackMessageSource's Call so the demo can hand over canned JSON and count calls. This
    /// type never constructs a URL, never holds a token, and never touches the Keychain;
    /// that stays the caller's job.
    typealias Call = @Sendable (_ method: String, _ query: [(String, String)]) async throws -> Data

    private let call: Call

    init(call: @escaping Call) {
        self.call = call
    }

    /// One `search.messages` request for one already-built query string.
    func search(query: String, count: Int = 100, page: Int = 1) async throws -> SearchResult {
        let cappedCount = min(count, 100)
        let cappedPage = min(max(page, 1), 100)
        log.debug("request method=search.messages count=\(cappedCount, privacy: .public) page=\(cappedPage, privacy: .public)")
        let data = try await call("search.messages", [
            ("query", query),
            ("count", String(cappedCount)),
            ("page", String(cappedPage))
        ])
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackSourceError.badResponse
        }
        // Reusing SlackMessageSource.error(for:) rather than constructing a case here means
        // this file never has to know the exact associated-value shape of .rateLimited, only
        // that the function returning it still exists.
        guard root["ok"] as? Bool == true else { throw SlackMessageSource.error(for: root) }
        return Self.parse(root)
    }

    static func parse(_ root: [String: Any]) -> SearchResult {
        let messagesBlock = root["messages"] as? [String: Any] ?? [:]
        let matches = (messagesBlock["matches"] as? [[String: Any]] ?? []).compactMap(SearchMatch.init)
        let pagination = (messagesBlock["pagination"] as? [String: Any]).flatMap(SearchPagination.init)
        return SearchResult(matches: matches, pagination: pagination)
    }

    // MARK: Query building, pure and static so each is checkable without a network call

    /// How the user refers to themselves as the ARGUMENT of an operator, genuinely unsettled,
    /// and shared by `from:`, `to:` and `with:` since all three ask the same question. One
    /// widely used Slack client documents `from:me` as correct and states `from:@me` returns
    /// zero results because no user is literally named "me"; two other projects use `from:@me`
    /// and appear to work. Nobody here has run either against a real workspace, so the token
    /// lives behind this one constant instead of being picked separately, and inconsistently,
    /// in three places. It is only the STARTING guess now: SlackMessageSource passes a
    /// `selfAs:` token, tries this one first, and retries once with `@me` when a query comes
    /// back empty, so the workspace itself settles the question at runtime.
    ///
    /// This is deliberately NOT `<@USERID>`. That markup is how a mention renders inside
    /// message TEXT, which is why `mentionQuery` below searches for it as a bare keyword.
    /// As the argument to an operator, every real example found (production Slack clients on
    /// GitHub) uses a username-shaped token instead, e.g. `with:@me`, `from:@username`,
    /// `in:@username` for a DM: never the `<@U123>` markup. Putting the mention form here
    /// would look plausible and search for the wrong thing.
    static let selfReference = "me"

    /// `after:` only understands a calendar day, not a timestamp, so it cannot express
    /// "since the last scan five minutes ago" on its own. This formats the coarse day Slack
    /// accepts; `matches(_:after:)` below applies the precise cutoff afterward, in Swift,
    /// which is the app's limit to work around, not Slack's to fix.
    /// Not private: the search probe in SlackMessageSource builds one query this type has
    /// no builder for, the competing `from:@me` spelling, and it needs the same day format.
    static func day(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)
    }

    /// Messages that mention the user directly, using Slack's `<@USERID>` form. Unlike
    /// `from:`, a mention names a concrete id, so there is nothing ambiguous to pin down.
    static func mentionQuery(userID: String, after: Date) -> String {
        "<@\(userID)> after:\(day(after))"
    }

    /// The `to:` operator, Slack's other way of finding messages addressed at someone, mainly
    /// useful in a DM where the recipient is never actually named in the text. Self-referential
    /// on purpose, see `selfReference`.
    static func toQuery(after: Date, selfAs token: String = selfReference) -> String {
        "to:\(token) after:\(day(after))"
    }

    /// Threads the user has any part in, for the same reason SlackMessageSource reads
    /// `conversations.replies`: a thread is where a reply can actually be owed. Self-referential
    /// on purpose, see `selfReference`.
    static func threadQuery(after: Date, selfAs token: String = selfReference) -> String {
        "is:thread with:\(token) after:\(day(after))"
    }

    /// The user's own sent messages, for reply detection: this is what would tell a caller a
    /// conversation is already settled. Self-referential on purpose, see `selfReference`.
    static func ownMessagesQuery(after: Date, selfAs token: String = selfReference) -> String {
        "from:\(token) after:\(day(after))"
    }

    /// The coarse `after:` day already narrowed what Slack sent back; this applies the exact
    /// cutoff the caller actually wants. Strictly newer than the cutoff, matching the sense
    /// SlackMessageSource uses for `since`.
    static func matches(_ matches: [SearchMatch], after cutoff: Date) -> [SearchMatch] {
        matches.filter { $0.date > cutoff }
    }

    /// A search match carries no `thread_ts`. The one promising lead is that a threaded
    /// message's `permalink` may carry a `?thread_ts=` query parameter, exactly the URL shape
    /// `SlackMessageSource.permalink` already builds when it has a thread timestamp. Whether
    /// Slack actually populates this for a search result is unverified and needs a real
    /// workspace to confirm; until then this is a best-effort read, nil when absent.
    static func threadTS(fromPermalink permalink: String) -> String? {
        guard let components = URLComponents(string: permalink) else { return nil }
        return components.queryItems?.first(where: { $0.name == "thread_ts" })?.value
    }
}

// MARK: - Runnable check

/// Plain asserts, no network: every response below is canned JSON, run from a throwaway main.
/// Nothing here is a real workspace, a real person or a real token.
func demoSlackSearch() async {
    let now = Date(timeIntervalSince1970: 1_728_400_000) // 2024-10-08T14:13:20Z

    // MARK: query builders, including after: day formatting
    assert(SlackSearch.mentionQuery(userID: "U_ME", after: now) == "<@U_ME> after:2024-10-08")
    assert(SlackSearch.toQuery(after: now) == "to:me after:2024-10-08")
    assert(SlackSearch.threadQuery(after: now) == "is:thread with:me after:2024-10-08")
    assert(SlackSearch.ownMessagesQuery(after: now) == "from:me after:2024-10-08")
    // The self-reference spelling is unsettled by design; this pins the current choice so a
    // deliberate flip shows up as a one-line diff instead of a silent behaviour change.
    assert(SlackSearch.selfReference == "me")

    // MARK: thread timestamp from a permalink
    assert(SlackSearch.threadTS(
        fromPermalink: "https://acme.slack.com/archives/C_PRIV/p1728394855123456?thread_ts=1728394800.000100&cid=C_PRIV"
    ) == "1728394800.000100")
    assert(SlackSearch.threadTS(
        fromPermalink: "https://acme.slack.com/archives/G_MPIM/p1728394900000200"
    ) == nil, "a permalink with no thread_ts must not invent one")
    assert(SlackSearch.threadTS(fromPermalink: "not a url") == nil)

    // MARK: parsing a realistic multi-match response, a private channel and an mpim
    let body = """
    {"ok":true,"messages":{
      "pagination":{"total":2,"page":1,"page_count":1,"per_page":100},
      "matches":[
        {"iid":"abc-123","team":"T_ACME","type":"message","user":"U_OTHER","username":"other",
         "ts":"1728394855.123456","text":"can you review this",
         "channel":{"id":"C_PRIV","name":"secret-team","is_mpim":false,"is_private":true},
         "permalink":"https://acme.slack.com/archives/C_PRIV/p1728394855123456?thread_ts=1728394800.000100&cid=C_PRIV"},
        {"iid":"def-456","team":"T_ACME","type":"message","user":"U_THIRD","username":"third",
         "ts":"1728394900.000200","text":"no thread here",
         "channel":{"id":"G_MPIM","name":"mpdm-a--b--c-1","is_mpim":true,"is_private":true},
         "permalink":"https://acme.slack.com/archives/G_MPIM/p1728394900000200"}
      ]
    }}
    """
    let parsed = SlackSearch.parse((try? JSONSerialization.jsonObject(with: Data(body.utf8))) as? [String: Any] ?? [:])
    assert(parsed.matches.count == 2, "got \(parsed.matches.count)")
    assert(parsed.pagination?.total == 2 && parsed.pagination?.page == 1
           && parsed.pagination?.pageCount == 1 && parsed.pagination?.perPage == 100,
           "pagination must parse, got \(String(describing: parsed.pagination))")
    let privateMatch = parsed.matches.first { $0.channel?.id == "C_PRIV" }
    assert(privateMatch?.channel?.isPrivate == true && privateMatch?.channel?.isMpim == false)
    assert(privateMatch?.text == "can you review this")
    let mpimMatch = parsed.matches.first { $0.channel?.id == "G_MPIM" }
    assert(mpimMatch?.channel?.isMpim == true)
    assert(mpimMatch?.channel?.isPrivate == true)

    // MARK: the precise cutoff filter
    let cutoff = Date(timeIntervalSince1970: 1_728_394_860) // between the two matches above
    let kept = SlackSearch.matches(parsed.matches, after: cutoff)
    assert(kept.count == 1 && kept[0].channel?.id == "G_MPIM",
           "only the newer match should survive the precise cutoff, got \(kept.count)")

    // MARK: ok: false throws rather than returning empty
    actor CallLog {
        var count = 0
        func record() { count += 1 }
    }
    let errorLog = CallLog()
    let erroring = SlackSearch(call: { _, _ in
        await errorLog.record()
        return Data(#"{"ok":false,"error":"invalid_auth"}"#.utf8)
    })
    do {
        _ = try await erroring.search(query: "from:me after:2024-10-08")
        assert(false, "an ok:false response must throw, not report zero matches")
    } catch let error as SlackSourceError {
        assert(error == .reconnect, "got \(error)")
    } catch {
        assert(false, "wrong error type: \(error)")
    }

    // MARK: one call per search, not several
    let okLog = CallLog()
    let source = SlackSearch(call: { method, _ in
        await okLog.record()
        assert(method == "search.messages")
        return Data(#"{"ok":true,"messages":{"matches":[]}}"#.utf8)
    })
    _ = try! await source.search(query: SlackSearch.mentionQuery(userID: "U_ME", after: now))
    _ = try! await source.search(query: SlackSearch.threadQuery(after: now))
    let calls = await okLog.count
    assert(calls == 2, "two searches must cost exactly two calls, got \(calls)")

    print("demoSlackSearch: PASS")
}
