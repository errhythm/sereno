import Foundation

/// Deterministic evidence that a message may be aimed at the user. A message can match
/// several of these; the model makes the ownership call, subject to the DM/mention floor.
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
    /// Whether any detected reason for considering this message remains enabled. An empty
    /// set is allowed through for the model to judge. A non-empty set is dropped only when
    /// every signal in it was explicitly switched off by the user.
    /// ponytail: `ignoring` is passed in rather than read from Preferences so this stays a
    /// pure function, testable without the @MainActor singleton.
    func deservesTask(ignoring ignored: Set<Addressing>) -> Bool {
        if isEmpty { return true }
        return !subtracting(ignored).isEmpty
    }
}

extension Addressing {
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
    /// Background fetched with a pending conversation. It is readable context, never the
    /// obligation itself and never a reason for the conversation to survive filtering.
    var isContext: Bool = false
    /// True when this is one of the reader's own messages. Triage labels it explicitly so
    /// the model can see that the reader already answered earlier in the exchange.
    var isFromUser: Bool = false
    let date: Date
    /// true when the message @-mentions the user or is a DM. Raises priority.
    /// ponytail: kept as the coarse flag existing code reads. `addressing` is the real
    /// answer, and this should become a computed property once callers move over.
    let directlyAddressed: Bool
    /// Every reason this message is aimed at the user.
    ///
    /// Swift uses this only for explicitly ignored preferences and the deterministic
    /// direct-message/mention floor. All other ownership decisions belong to the model.
    var addressing: Set<Addressing> = []
    /// Link that opens the message in Slack. Real permalink later, nil in the mock.
    let permalink: URL?
    /// Sender's Slack profile photo (image_72, falling back to image_48). nil in the mock
    /// and whenever Slack has none, in which case the UI falls back to initials.
    var avatarURL: URL? = nil
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
    /// Sender's Slack profile photo, carried from the newest message in the conversation.
    /// nil for a manual task (no sender) or when Slack has none; the UI falls back to
    /// initials either way.
    var avatarURL: URL? = nil
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
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
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
    /// Ties broken by id so the order is the same on every run: Swift's sort is not
    /// stable, and a conversation that splits into two tasks produces two items with
    /// identical effectivePriority and identical date (both take the conversation's
    /// newest message date), which without this would flip on-screen between refreshes
    /// for no reason.
    static func ranked(_ items: [TodoItem]) -> [TodoItem] {
        items.sorted { ($0.effectivePriority, $0.date, $0.id) < ($1.effectivePriority, $1.date, $1.id) }
    }
}

func demoModels() {
    // A state.json written before avatarURL existed has no such key at all. Swift's
    // synthesized init(from:) does NOT fall back to a stored property's default for a
    // missing key, it throws instead, which is exactly the trap that once dropped every
    // todo on load. TodoItem's custom init(from:) uses decodeIfPresent for this reason;
    // this proves a legacy blob still decodes instead of losing the user's saved todos.
    let legacyJSON = """
    {"id":"C1","action":"Reply","priority":2,"reason":"because","sender":"Ayesha",
     "channel":null,"date":0,"permalink":null}
    """
    let decoded = try! JSONDecoder().decode(TodoItem.self, from: Data(legacyJSON.utf8))
    assert(decoded.avatarURL == nil, "a pre-avatarURL row must decode with avatarURL defaulting to nil")
    assert(decoded.id == "C1" && decoded.sender == "Ayesha" && decoded.priority == 2,
           "the rest of a legacy row must survive intact")

    // ranked() must break ties by id. Two items from a conversation that split into two
    // tasks share both effectivePriority and date (both take the conversation's newest
    // message date), so without an id tiebreak Swift's non-stable sort can flip their
    // on-screen order between refreshes for no reason.
    let sameDate = Date()
    let itemB = TodoItem(id: "B", action: "Reply B", priority: 2, reason: "r",
                          sender: "Ayesha", channel: nil, date: sameDate, permalink: nil)
    let itemA = TodoItem(id: "A", action: "Reply A", priority: 2, reason: "r",
                          sender: "Ayesha", channel: nil, date: sameDate, permalink: nil)
    let ranked = TodoItem.ranked([itemB, itemA])
    assert(ranked.map(\.id) == ["A", "B"],
           "equal priority and date must still sort deterministically by id")
}
