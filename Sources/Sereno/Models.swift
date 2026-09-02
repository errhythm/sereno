import Foundation

/// Why a message counts as aimed at the user. A message can match several of these.
/// Computed deterministically from the message and the user's identity, never guessed
/// by the model, because "is this even mine" decides whether a task exists at all.
enum Addressing: String, Codable, Sendable, CaseIterable {
    /// A 1:1 or group DM. Nothing else needs to be true.
    case directMessage
    /// An explicit <@U123> mention of the user.
    case mention
    /// A reply in a thread the user has posted in.
    case threadParticipant
    /// A reply directly under a message the user wrote.
    case replyToMe
    /// A user group the user belongs to was mentioned, <!subteam^S123>.
    case userGroup
    /// The user's name appears as plain text, no Slack markup. Weakest signal, and the
    /// one that produces false positives, so it is treated as such.
    case nameMentioned
    /// @here, @channel or @everyone. Aimed at a room, not at a person.
    case broadcast
}

extension Set<Addressing> {
    /// Whether this message should produce a task at all, given what the user has switched
    /// off. An empty set is ALLOWED through: nothing explicit points at the user, but the
    /// model still gets to judge it against their role. Only a message whose signals are
    /// all impersonal or all ignored is dropped.
    /// ponytail: `ignoring` is passed in rather than read from Preferences so this stays a
    /// pure function, testable without the @MainActor singleton.
    func deservesTask(ignoring ignored: Set<Addressing>) -> Bool {
        let kept = subtracting(ignored)
        if isEmpty { return true }
        return kept.isPersonal
    }
}

extension Addressing {
    /// How strongly this signal implies the user personally owes a response.
    /// Feeds the priority rubric, and lets the UI say why an item is on the list.
    var weight: Int {
        switch self {
        case .directMessage, .mention, .replyToMe: 3
        case .threadParticipant: 2
        case .userGroup, .nameMentioned: 1
        case .broadcast: 0
        }
    }

    /// Short phrase for the UI, e.g. "mentioned you".
    var label: String {
        switch self {
        case .directMessage: "direct message"
        case .mention: "mentioned you"
        case .threadParticipant: "your thread"
        case .replyToMe: "replied to you"
        case .userGroup: "your group"
        case .nameMentioned: "named you"
        case .broadcast: "channel-wide"
        }
    }
}

/// Who the user is, as far as addressing detection is concerned.
/// userID comes from auth.test, the names and groups from users.info and usergroups.list.
struct Identity: Sendable, Hashable {
    let userID: String
    let displayName: String
    let realName: String
    var userGroupIDs: Set<String> = []
    /// What the user actually does, in their own words, e.g. "backend engineer at NSBH,
    /// I own deployments and the public API". Not used for detection, which is pure
    /// string matching. This is context for the model when it judges whether an
    /// unaddressed channel message like "Team, please complete the deployment doc" is
    /// the user's to act on. Without it the model has no basis for that call.
    var role: String = ""
}

/// One Slack message the user may still owe a reply to.
/// Whatever the source (mock now, Slack Web API later), it produces these.
struct SlackMessage: Sendable, Hashable, Identifiable {
    /// Stable dedupe key. For Slack this is channel id + message ts.
    let id: String
    /// The conversation this message belongs to, and the unit triage works on.
    /// For Slack: the thread id when the message is in a thread, otherwise the channel
    /// or DM id. Messages sharing this are one ongoing obligation, not several, so a
    /// follow-up escalates the existing task instead of spawning a duplicate.
    var conversationID: String = ""
    /// Sender's display name.
    let sender: String
    /// Channel name for a channel message, nil for a direct message.
    let channel: String?
    /// The message text.
    let text: String
    let date: Date
    /// true when the message @-mentions the user or is a DM. Raises priority.
    /// ponytail: kept as the coarse flag existing code reads. `addressing` is the real
    /// answer, and this should become a computed property once callers move over.
    let directlyAddressed: Bool
    /// Every reason this message is aimed at the user.
    ///
    /// Three cases, and they are deliberately not the same:
    /// - Contains a personal signal (DM, mention, reply to you, your thread, your group,
    ///   or your name): definitely yours, always becomes a task.
    /// - EMPTY: nothing explicit points at you, but it still might be yours. "Team, please
    ///   complete the deployment doc" carries no signal at all, so the model judges it
    ///   using Preferences.role. Do NOT drop these, that was the old rule and it silently
    ///   lost real work.
    /// - Non-empty but NOT personal, meaning broadcast-only or everything in it is switched
    ///   off in settings: aimed at a room rather than a person, so no task. This is the one
    ///   case that gets filtered out.
    var addressing: Set<Addressing> = []
    /// Link that opens the message in Slack. Real permalink later, nil in the mock.
    let permalink: URL?
}

/// Anything that can hand back unreplied messages.
/// One method, so the mock and the real Slack client are interchangeable.
protocol MessageSource: Sendable {
    /// Unreplied messages, newest first, for every conversation that has had activity
    /// since `since`. IMPORTANT: return the conversation's FULL unreplied context, not
    /// only the messages newer than `since`. Triage groups by conversationID and judges
    /// the exchange as a whole, so handing it just the latest message strips the context
    /// that makes a follow-up readable ("Hi" then "review it within the hour").
    func unrepliedMessages(since: Date) async throws -> [SlackMessage]

    /// The subset of `ids` the user has since replied to. The store marks those done.
    /// `ids` are TodoItem ids, which encode a conversation, so the check is "did the user
    /// post in that conversation after its newest inbound message". For Slack that is
    /// conversations.history (or conversations.replies in a thread) filtered to the user's
    /// own id. Manual tasks are never passed here, they have no conversation.
    func repliedIDs(among ids: [String]) async throws -> Set<String>
}

/// One row in the to-do list. `id` matches the SlackMessage it came from.
struct TodoItem: Codable, Identifiable, Sendable, Hashable {
    let id: String
    /// Single line naming the task. Kept short enough not to wrap, e.g. "Review MR #41".
    var action: String
    /// 1 is most urgent, 5 is least.
    var priority: Int
    /// One short clause justifying the priority.
    var reason: String
    /// The original message, verbatim. Hidden until the row is expanded, and what
    /// the copy button copies. Never paraphrased, so copying gives the real text.
    var detail: String = ""
    /// Links found in the message text. Extracted with NSDataDetector, never written
    /// by the model, because a model will silently alter or invent a URL.
    var links: [URL] = []
    let sender: String
    let channel: String?
    /// Newest message in the conversation this task was derived from. Doubles as the
    /// "last activity" time the row shows, and as the marker for detecting a follow-up.
    let date: Date
    let permalink: URL?
    /// Which conversation produced this task. Several tasks can share one conversation
    /// only when the messages really are separate asks.
    var conversationID: String = ""
    var done: Bool = false
    /// Set when the user overrides the model's ranking with Mark as Now/Today/Later.
    /// Re-triage must never reset this. The user's judgment outranks the model's.
    var userPriority: Int? = nil
    /// Hidden from the list until this date. nil means visible now.
    var snoozedUntil: Date? = nil
    /// True for a task the user typed in themselves. It has no Slack message behind it,
    /// so there is no permalink to open and no reply to auto-detect.
    var isManual: Bool = false
}

extension TodoItem {
    /// What the list actually sorts and bands by. A user override wins over the model.
    var effectivePriority: Int { userPriority ?? priority }

    /// Snoozed items are hidden until their time comes back around.
    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    /// A task the user typed has no Slack thread to reply to, so reply detection
    /// must never be asked about it.
    var supportsReplyDetection: Bool { !isManual }
}

extension TodoItem {
    // Decode with defaults so a state.json written before `detail` and `links`
    // existed still loads instead of throwing away the user's saved todos.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        action = try c.decode(String.self, forKey: .action)
        priority = try c.decode(Int.self, forKey: .priority)
        reason = try c.decode(String.self, forKey: .reason)
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        links = try c.decodeIfPresent([URL].self, forKey: .links) ?? []
        sender = try c.decode(String.self, forKey: .sender)
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        date = try c.decode(Date.self, forKey: .date)
        permalink = try c.decodeIfPresent(URL.self, forKey: .permalink)
        conversationID = try c.decodeIfPresent(String.self, forKey: .conversationID) ?? ""
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        userPriority = try c.decodeIfPresent(Int.self, forKey: .userPriority)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
    }
}

/// Real links in a message. Deterministic, so the model never gets to touch a URL.
func extractLinks(from text: String) -> [URL] {
    guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    var seen = Set<URL>()
    return detector.matches(in: text, range: range).compactMap(\.url).filter { seen.insert($0).inserted }
}

extension TodoItem {
    /// Sort order for the list: urgent first, then oldest first within a priority.
    static func ranked(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { ($0.effectivePriority, $0.date) < ($1.effectivePriority, $1.date) }
    }
}
