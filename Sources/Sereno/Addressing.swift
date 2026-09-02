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
    /// Highest weight among the signals, 0 when empty. For the priority rubric.
    var strength: Int { map(\.weight).max() ?? 0 }

    /// True when the user personally owes something, as opposed to a room-wide notice.
    /// A set containing only .broadcast is NOT personal: @channel in a busy room is an
    /// announcement, not a to-do. The signal is kept in the set either way, so a
    /// "treat @channel as mine" preference can flip this without re-detection.
    var isPersonal: Bool { contains { $0 != .broadcast } }

    /// The single best phrase for the UI, e.g. "mentioned you". nil when empty.
    /// rawValue breaks weight ties so the phrase is stable across runs.
    var primaryLabel: String? {
        self.max { ($0.weight, $0.rawValue) < ($1.weight, $1.rawValue) }?.label
    }
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
private func strippingMarkupAndCode(_ text: String) -> String {
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
private func containsWord(_ needle: String, in haystack: String) -> Bool {
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
    assert(addressing(facts("<!here> deploy in 5"), identity: me).strength == 0)

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
    assert(Set<Addressing>().strength == 0)
    assert(Set<Addressing>().isPersonal == false)
    assert(Set<Addressing>().primaryLabel == nil)
    assert(Set<Addressing>([.nameMentioned]).strength == 1)
    assert(Set<Addressing>([.nameMentioned, .broadcast]).isPersonal)
    assert(Set<Addressing>([.broadcast, .mention]).strength == 3)
    assert(Set<Addressing>([.broadcast, .mention]).primaryLabel == "mentioned you")
    assert(Set<Addressing>([.broadcast]).primaryLabel == "channel-wide")
    assert(Set<Addressing>([.threadParticipant, .nameMentioned]).primaryLabel == "your thread")
    // Weight ties resolve the same way every run: directMessage < mention < replyToMe by rawValue.
    assert(Set<Addressing>([.directMessage, .mention, .replyToMe]).primaryLabel == "replied to you")

    print("demoAddressing: PASS")
}
