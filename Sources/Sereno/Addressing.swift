import Foundation

/// Where a message was posted. Slack's conversation types.
enum ChannelKind: String, Sendable { case im, mpim, publicChannel, privateChannel }

/// Everything the detector needs about one raw Slack message.
struct MessageFacts: Sendable {
    var text: String
    var channelKind: ChannelKind
    var authorID: String            // who sent it
    var threadTS: String?           // non-nil when it sits in a thread
    var parentAuthorID: String?     // author of the thread's parent message, if known
    var threadParticipantIDs: Set<String> = []  // everyone who posted in that thread
}

/// Every reason this message is aimed at the user. Empty means it is not, and no task
/// should exist for it. Pure and order-independent: each rule reads only `facts` and
/// `identity` and inserts into a set, so running it twice gives the same answer.
func addressing(_ facts: MessageFacts, identity: Identity) -> Set<Addressing> {
    // Rule 1, checked first: nothing the user wrote is ever aimed at the user.
    if facts.authorID == identity.userID { return [] }

    var result: Set<Addressing> = []

    if facts.channelKind == .im || facts.channelKind == .mpim {
        result.insert(.directMessage)
    }

    // One pass over the <...> markup covers mentions, broadcasts and user groups.
    // A bare "U123ABC" in prose is never a token, so it never counts as a mention.
    for token in markupTokens(in: facts.text) {
        switch token {
        case .user(let id) where id == identity.userID:
            result.insert(.mention)
        case .bang(let keyword) where broadcastKeywords.contains(keyword):
            result.insert(.broadcast)
        case .bang(let keyword) where keyword.hasPrefix(subteamPrefix):
            if identity.userGroupIDs.contains(String(keyword.dropFirst(subteamPrefix.count))) {
                result.insert(.userGroup)
            }
        default:
            break
        }
    }

    if facts.threadTS != nil {
        if facts.threadParticipantIDs.contains(identity.userID) { result.insert(.threadParticipant) }
        if facts.parentAuthorID == identity.userID { result.insert(.replyToMe) }
    }

    if mentionsNamePlainly(facts.text, identity: identity) {
        result.insert(.nameMentioned)
    }

    return result
}

extension Set<Addressing> {
    /// True when the user personally owes something, as opposed to a room-wide notice.
    /// A set containing only .broadcast is NOT personal: @channel in a busy room is an
    /// announcement, not a to-do. The signal is kept in the set either way, so a
    /// "treat @channel as mine" preference can flip this without re-detection.
    var isPersonal: Bool { contains { $0 != .broadcast } }
}

// MARK: - Slack markup

private let broadcastKeywords: Set<String> = ["here", "channel", "everyone"]
private let subteamPrefix = "subteam^"

/// A `<...>` token, already stripped of its `|label` half.
private enum MarkupToken {
    case user(String)   // <@U123ABC> or <@U123ABC|display>
    case bang(String)   // <!here>, <!channel|@channel>, <!subteam^S1|@team>
}

private func markupTokens(in text: String) -> [MarkupToken] {
    var tokens: [MarkupToken] = []
    var i = text.startIndex
    while let open = text[i...].firstIndex(of: "<") {
        guard let close = text[text.index(after: open)...].firstIndex(of: ">") else { break }
        var inner = text[text.index(after: open)..<close]
        if let bar = inner.firstIndex(of: "|") { inner = inner[..<bar] }
        if inner.hasPrefix("@") {
            tokens.append(.user(String(inner.dropFirst())))
        } else if inner.hasPrefix("!") {
            tokens.append(.bang(String(inner.dropFirst())))
        }
        i = text.index(after: close)
    }
    return tokens
}

/// User ids that appear in Slack's explicit `<@…>` markup. This deliberately shares the
/// detector used by addressing(), so a name lookup cannot disagree with a mention signal.
func mentionedUserIDs(in text: String) -> Set<String> {
    Set(markupTokens(in: text).compactMap {
        if case .user(let id) = $0 { return id }
        return nil
    })
}

/// Slack stores its rich-text syntax in `text`. Triage and the UI need readable prose, but
/// MessageFacts must keep the raw form because addressing() relies on its exact markup.
func slackPlainText(_ text: String, names: [String: String]) -> String {
    var out = ""
    var i = text.startIndex

    while i < text.endIndex {
        guard text[i] == "<" else {
            out.append(text[i])
            i = text.index(after: i)
            continue
        }
        guard let close = text[text.index(after: i)...].firstIndex(of: ">") else {
            out.append(contentsOf: text[i...])
            break
        }

        let inner = text[text.index(after: i)..<close]
        let parts = inner.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        let token = String(parts[0])
        let label = parts.count == 2 ? String(parts[1]) : nil

        if token.hasPrefix("@") {
            let id = String(token.dropFirst())
            let display = label ?? names[id] ?? id
            out.append("@")
            out.append(contentsOf: display.drop(while: { $0 == "@" }))
        } else if token.hasPrefix("!") {
            let keyword = String(token.dropFirst())
            if broadcastKeywords.contains(keyword) {
                out.append("@")
                out.append(contentsOf: keyword)
            } else if keyword.hasPrefix(subteamPrefix) {
                if let label {
                    out.append("@")
                    out.append(contentsOf: label.drop(while: { $0 == "@" }))
                } else {
                    out.append("@team")
                }
            } else if let label {
                out.append(contentsOf: label)
            }
        } else if token.hasPrefix("#") {
            let channel = label ?? String(token.dropFirst())
            out.append("#")
            out.append(contentsOf: channel.drop(while: { $0 == "#" }))
        } else if token.contains("://") || token.hasPrefix("mailto:") || token.hasPrefix("tel:") {
            if let label {
                out.append(contentsOf: label)
                out.append(" (")
                out.append(contentsOf: token)
                out.append(")")
            } else {
                out.append(contentsOf: token)
            }
        } else {
            out.append(contentsOf: text[i...close])
        }
        i = text.index(after: close)
    }

    return out
        .replacingOccurrences(of: "&lt;", with: "<")
        .replacingOccurrences(of: "&gt;", with: ">")
        .replacingOccurrences(of: "&amp;", with: "&")
}

// MARK: - Plain-text name matching

/// FALSE-POSITIVE RISK: this is the only rule that guesses. A common first name ("Sam",
/// "Will", "Mark") turns every unrelated sentence into an obligation, so the matching is
/// deliberately narrow: whole words only, minimum 3 characters, and markup and code spans
/// are removed before searching so links, mention labels and identifiers never count.
/// It stays the weakest signal (weight 1) precisely because it can still be wrong.
private func mentionsNamePlainly(_ text: String, identity: Identity) -> Bool {
    let haystack = strippingMarkupAndCode(text).lowercased()
    var candidates = [identity.displayName, identity.realName]
    if let first = identity.realName.split(separator: " ").first {
        candidates.append(String(first))  // people get called by first name
    }
    for candidate in candidates {
        // Slack display names are often stored with the leading "@".
        let name = candidate
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .drop(while: { $0 == "@" })
            .lowercased()
        if name.count < 3 { continue }  // a 2-letter name would match constantly
        if containsWord(String(name), in: haystack) { return true }
    }
    return false
}

/// Replaces every `<...>` span and every backtick-delimited span with a space, so the
/// remaining text is only what a human typed as prose. Word boundaries survive because
/// the removed span becomes whitespace rather than vanishing.
/// ponytail: an unmatched backtick swallows the rest of the message. That errs toward
/// no match, which is the safe direction here. Pair the runs properly if it ever bites.
func strippingMarkupAndCode(_ text: String) -> String {
    var out = ""
    var inCode = false
    var i = text.startIndex
    while i < text.endIndex {
        let c = text[i]
        if c == "`" {
            // A run of backticks, one or three, is one delimiter. Toggling on each run
            // handles `inline` and ```fenced``` with the same two lines.
            while i < text.endIndex, text[i] == "`" { i = text.index(after: i) }
            inCode.toggle()
            out.append(" ")
            continue
        }
        if inCode {
            i = text.index(after: i)
            continue
        }
        if c == "<" {
            if let close = text[i...].firstIndex(of: ">") {
                i = text.index(after: close)
            } else {
                i = text.endIndex
            }
            out.append(" ")
            continue
        }
        out.append(c)
        i = text.index(after: i)
    }
    return out
}

/// Whole-word substring search. Both arguments must already be lowercased.
func containsWord(_ needle: String, in haystack: String) -> Bool {
    var from = haystack.startIndex
    while let found = haystack.range(of: needle, range: from..<haystack.endIndex) {
        let leftClear = found.lowerBound == haystack.startIndex
            || !isWordCharacter(haystack[haystack.index(before: found.lowerBound)])
        let rightClear = found.upperBound == haystack.endIndex
            || !isWordCharacter(haystack[found.upperBound])
        if leftClear && rightClear { return true }
        guard found.lowerBound < haystack.endIndex else { return false }
        from = haystack.index(after: found.lowerBound)
    }
    return false
}

private func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

// MARK: - First-person commitments

/// A deliberately narrow deterministic gate for promises of future action. The model may
/// phrase and rank text only after this says yes; it never gets to expand the candidate set.
///
/// ponytail: the ceiling is these 18 action heads after "I'll", "I will", "I can",
/// "I'm going to", or "let me": send, share, get, check, review, fix, finish, update,
/// reply, respond, follow up, handle, write, prepare, deliver, submit, investigate, and
/// look at/into/over. Plus the whole-message acknowledgements "on it" and "will do".
/// Do not widen this from anecdotes: every new head needs false-positive fixtures first.
func isCommitment(_ text: String) -> Bool {
    let prose = strippingMarkupAndCode(text)
        .replacingOccurrences(of: "’", with: "'")
        .lowercased()
    guard !prose.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }

    let action = #"(?:send|share|get\s+(?:back|the|this|that|it|these|those|you|them|him|her|us)|check|review|fix|finish|update|reply|respond|follow\s+up|handle|write|prepare|deliver|submit|investigate|look\s+(?:at|into|over))"#
    let firstPerson = #"(?:^|[^a-z0-9_])(?:i'll|i will|i can|i'm going to|i am going to|let me)\s+"#
    if prose.range(
        of: firstPerson + action + #"(?=$|[^a-z0-9_])"#,
        options: .regularExpression
    ) != nil {
        return true
    }

    // These are commitments only as complete acknowledgements. Matching them inside a
    // sentence ("I think Sam is on it") would turn third-person status into the user's task.
    let acknowledgement = #"^\s*(?:(?:sure|okay|ok|yes|yep)[,!:\- ]+\s*)?(?:(?:i'm|i am)\s+)?(?:on it|will do)[.!]?\s*$"#
    return prose.range(of: acknowledgement, options: .regularExpression) != nil
}

// MARK: - Runnable check

/// Plain asserts, no framework. This decides whether tasks exist at all, so it is worth
/// the lines. Call it from a scratch main to check the logic.
func demoAddressing() {
    let me = Identity(
        userID: "U_ME",
        displayName: "@rhythm",
        realName: "Rhythm Ebilane",
        userGroupIDs: ["S1", "S2"]
    )

    func facts(
        _ text: String,
        _ kind: ChannelKind = .publicChannel,
        author: String = "U_OTHER",
        threadTS: String? = nil,
        parent: String? = nil,
        participants: Set<String> = []
    ) -> MessageFacts {
        MessageFacts(
            text: text,
            channelKind: kind,
            authorID: author,
            threadTS: threadTS,
            parentAuthorID: parent,
            threadParticipantIDs: participants
        )
    }

    // Rule 1: the user's own message, whatever else is true, is never for the user.
    assert(addressing(facts("hey <@U_ME> in my own DM", .im, author: "U_ME"), identity: me).isEmpty)

    // Commitments are detected beside addressing, but are not Addressing cases: they are
    // authored by the user and cannot be disabled as though they were notification signals.
    let commitments = [
        "I'll send the report",
        "I will review the plan",
        "I can update the ticket",
        "Let me check the numbers",
        "On it",
        "Will do",
        "I'm going to fix the build",
        "I'll get the approval",
    ]
    for fixture in commitments {
        assert(isCommitment(fixture), "missed commitment: \(fixture)")
    }
    let nonCommitments = [
        "I'll be honest",
        "I'll admit I missed it",
        "I'd say the build is fine",
        "I'll bet it passes",
        "I think I'll never understand this API",
        "I'll get tired after lunch",
        "",
        "The report is due within the hour",
        "Sam is on it",
    ]
    for fixture in nonCommitments {
        assert(!isCommitment(fixture), "false commitment: \(fixture)")
    }

    // Rule 2: DMs and group DMs.
    assert(addressing(facts("can you check this", .im), identity: me) == [.directMessage])
    assert(addressing(facts("can you check this", .mpim), identity: me) == [.directMessage])
    assert(addressing(facts("standup at 10", .publicChannel), identity: me).isEmpty)

    // Rule 3: explicit mentions, plain and labelled.
    assert(addressing(facts("ping <@U_ME> please"), identity: me) == [.mention])
    assert(addressing(facts("ping <@U_ME|rhythm> please"), identity: me) == [.mention])
    assert(addressing(facts("ping <@U_SOMEONE_ELSE> please"), identity: me).isEmpty)
    assert(addressing(facts("the id U_ME is in the CSV"), identity: me).isEmpty)
    assert(addressing(facts("<@U_MEXTRA> is a different person"), identity: me).isEmpty)

    // Rule 4: broadcasts, and they are not personal.
    assert(addressing(facts("<!here> deploy in 5"), identity: me) == [.broadcast])
    assert(addressing(facts("<!here|@here> deploy in 5"), identity: me) == [.broadcast])
    assert(addressing(facts("<!channel> all hands"), identity: me) == [.broadcast])
    assert(addressing(facts("<!everyone> all hands"), identity: me) == [.broadcast])
    assert(addressing(facts("<!here> deploy in 5"), identity: me).isPersonal == false)

    // Rule 5: user groups, only the ones the user is in.
    assert(addressing(facts("<!subteam^S1> review please"), identity: me) == [.userGroup])
    assert(addressing(facts("<!subteam^S1|@platform> review please"), identity: me) == [.userGroup])
    assert(addressing(facts("<!subteam^S9|@design> review please"), identity: me).isEmpty)

    // Rules 6 and 7: threads.
    assert(addressing(facts("more on this", threadTS: "111.1", participants: ["U_ME", "U_X"]),
                      identity: me) == [.threadParticipant])
    assert(addressing(facts("more on this", threadTS: "111.1", parent: "U_ME"),
                      identity: me) == [.replyToMe])
    assert(addressing(facts("more on this", threadTS: "111.1", parent: "U_ME", participants: ["U_ME"]),
                      identity: me) == [.threadParticipant, .replyToMe])
    // Same text outside a thread is nobody's obligation.
    assert(addressing(facts("more on this", participants: ["U_ME"]), identity: me).isEmpty)

    // Rule 8: plain-text names, and everything that must NOT match.
    assert(addressing(facts("hey Rhythm can you look"), identity: me) == [.nameMentioned])
    assert(addressing(facts("Rhythm Ebilane owns this"), identity: me) == [.nameMentioned])
    assert(addressing(facts("rhythm?"), identity: me) == [.nameMentioned])
    assert(addressing(facts("the rhythmic pattern"), identity: me).isEmpty)
    assert(addressing(facts("arrhythmia is unrelated"), identity: me).isEmpty)
    assert(addressing(facts("see <https://x.com/rhythm|link>"), identity: me).isEmpty)
    assert(addressing(facts("see <https://x.com/rhythm>"), identity: me).isEmpty)
    assert(addressing(facts("run `rhythm --sync` first"), identity: me).isEmpty)
    assert(addressing(facts("```\nlet rhythm = 1\n```"), identity: me).isEmpty)
    assert(addressing(facts("ping <@U_OTHER|rhythm> instead"), identity: me).isEmpty)
    // Short names are ignored entirely, they would match constantly.
    let shortName = Identity(userID: "U_S", displayName: "@jo", realName: "Jo Li")
    assert(addressing(facts("the job is done", author: "U_OTHER"), identity: shortName).isEmpty)
    // ...but the full real name is long enough to trust.
    assert(addressing(facts("jo li owns it", author: "U_OTHER"), identity: shortName) == [.nameMentioned])

    // Rule 9: several signals at once.
    let everything = addressing(
        facts("<!here> <@U_ME> <!subteam^S2> Rhythm please review",
              .im, threadTS: "111.1", parent: "U_ME", participants: ["U_ME"]),
        identity: me
    )
    assert(everything == [.directMessage, .mention, .broadcast, .userGroup,
                          .threadParticipant, .replyToMe, .nameMentioned])

    // Rule 10: idempotent, and independent of how the signals arrived.
    let f = facts("<@U_ME> and <!here>", threadTS: "111.1", parent: "U_ME")
    assert(addressing(f, identity: me) == addressing(f, identity: me))
    assert(addressing(facts("<!here> <@U_ME>"), identity: me)
           == addressing(facts("<@U_ME> <!here>"), identity: me))

    // The Set helpers.
    assert(Set<Addressing>().isPersonal == false)
    assert(Set<Addressing>([.nameMentioned, .broadcast]).isPersonal)

    // Slack markup becomes readable prose for triage and the UI, while raw markup above
    // remains the source of truth for the addressing assertions.
    assert(slackPlainText("<@U1>", names: ["U1": "rhythm"]) == "@rhythm")
    assert(slackPlainText("<@U1|label>", names: [:]) == "@label")
    assert(slackPlainText("<@U1>", names: [:]) == "@U1")
    assert(slackPlainText("<@U1>", names: ["U1": "@rhythm"]) == "@rhythm")
    assert(slackPlainText("<!here> <!channel|ignored> <!everyone>", names: [:]) == "@here @channel @everyone")
    assert(slackPlainText("<!subteam^S1|@team> <!subteam^S1>", names: [:]) == "@team @team")
    assert(slackPlainText("<!date^123|Thursday>", names: [:]) == "Thursday")
    assert(slackPlainText("<!date^123>", names: [:]).isEmpty)
    assert(slackPlainText("<#C1|general> <#C2>", names: [:]) == "#general #C2")
    assert(slackPlainText("<https://x/y|label> <https://x/y>", names: [:]) == "label (https://x/y) https://x/y")
    assert(slackPlainText("<http://x/y|label> <http://x/y>", names: [:]) == "label (http://x/y) http://x/y")
    assert(slackPlainText("<mailto:a@b.com|email> <mailto:a@b.com>", names: [:]) == "email (mailto:a@b.com) mailto:a@b.com")
    assert(slackPlainText("<tel:+15551234|call>", names: [:]) == "call (tel:+15551234)")
    assert(slackPlainText("&amp;lt; &lt; &gt; &amp;", names: [:]) == "&lt; < > &")
    assert(slackPlainText("before <unfinished", names: [:]) == "before <unfinished")
    assert(mentionedUserIDs(in: "<@U1> <@U2|two> <!here>") == ["U1", "U2"])

    print("demoAddressing: PASS")
}
