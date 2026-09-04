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
    /// True only after the narrow deterministic first-person intent detector accepts the text.
    /// This is separate from `addressing`: a promise is authored by the user, not aimed at
    /// them, and must not become an ignorable notification signal.
    var isCommitment: Bool = false
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
    /// Whether the conversation contains a future action the user promised. Slack cannot
    /// prove that a promise was kept: a later delivery message is ambiguous and a passed
    /// deadline means stale, not done. Only the user may complete one of these tasks.
    var isCommitment: Bool = false
    var done: Bool = false
    /// Set when the user overrides the model's ranking with Mark as Now/Today/Later.
    /// Re-triage must never reset this. The user's judgment outranks the model's.
    var userPriority: Int? = nil
    /// Hidden from the list until this date. nil means visible now.
    var snoozedUntil: Date? = nil
    /// True for a task the user typed in themselves. It has no Slack message behind it,
    /// so there is no permalink to open and no reply to auto-detect.
    var isManual: Bool = false
    /// When `done` last became true, which is the only record of WHEN work finished.
    /// `done` alone cannot answer "how many did I close on Tuesday", and a Bool cannot be
    /// backfilled, so history begins at the version that added this: rows completed before
    /// it decode with nil and are honestly excluded from the counts rather than dated by
    /// guesswork. Cleared when a row reopens, because a follow-up means it is owed again.
    var completedAt: Date? = nil
    /// Whether reply detection closed this rather than the user. "I closed twelve things"
    /// and "twelve resolved because I answered in Slack" are different facts about a week,
    /// and the distinction is free to record here and impossible to recover later.
    var completedByReply: Bool = false
}

extension TodoItem {
    /// What the list actually sorts and bands by. A user override wins over the model.
    var effectivePriority: Int { userPriority ?? priority }

    /// Snoozed items are hidden until their time comes back around.
    var isSnoozed: Bool {
        guard let snoozedUntil else { return false }
        return snoozedUntil > Date()
    }

    /// A manual task has no Slack thread, and a commitment cannot be proven complete from
    /// later Slack activity. Neither may enter automatic reply detection.
    var supportsReplyDetection: Bool { !isManual && !isCommitment }

    /// The one place `done` changes, so a completion date cannot be forgotten at one of the
    /// four call sites that set it.
    ///
    /// Only the false -> true EDGE stamps a date: reply detection runs over the whole list
    /// every refresh, and re-stamping an already-done row would walk its completion date
    /// forward every few minutes and quietly move it between days in the history. Reopening
    /// clears the date, because a row that is owed again was not completed.
    mutating func setDone(_ nowDone: Bool, byReply: Bool = false, at moment: Date = Date()) {
        guard nowDone != done else { return }
        done = nowDone
        completedAt = nowDone ? moment : nil
        completedByReply = nowDone ? byReply : false
    }
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
        isCommitment = try c.decodeIfPresent(Bool.self, forKey: .isCommitment) ?? false
        done = try c.decodeIfPresent(Bool.self, forKey: .done) ?? false
        userPriority = try c.decodeIfPresent(Int.self, forKey: .userPriority)
        snoozedUntil = try c.decodeIfPresent(Date.self, forKey: .snoozedUntil)
        isManual = try c.decodeIfPresent(Bool.self, forKey: .isManual) ?? false
        avatarURL = try c.decodeIfPresent(URL.self, forKey: .avatarURL)
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        completedByReply = try c.decodeIfPresent(Bool.self, forKey: .completedByReply) ?? false
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

/// What the history view draws. Pure and computed on demand from the to-dos already in
/// memory: there is no second store to keep in step, and a stat that disagrees with the
/// list would be worse than no stat.
///
/// Every date question is asked of an injected `Calendar`, never `Calendar.current`, so a
/// day boundary can be tested without waiting for midnight. Day bucketing and streaks are
/// where off-by-one bugs live, which is why this is a value type with a fixture table
/// rather than arithmetic inlined into a view.
struct CompletionStats: Sendable, Equatable {
    struct Day: Sendable, Equatable, Identifiable {
        /// Start of that day in the calendar the stats were built with.
        let date: Date
        let done: Int
        /// How many of `done` reply detection closed rather than the user.
        let byReply: Int
        var byHand: Int { done - byReply }
        var id: Date { date }
    }

    /// Oldest first, one entry per day across the whole window including days with none,
    /// so a chart draws the gaps instead of silently compressing them.
    var days: [Day] = []
    var total = 0
    var today = 0
    var last7 = 0
    /// Consecutive days ending at the most recent completion, counted only when that day is
    /// today or yesterday. Today being empty must not read as a broken streak before the day
    /// is over; two empty days must not read as a live one.
    var streak = 0
    /// Median hours from the message arriving to the row being completed. nil when nothing
    /// dated has been completed. Median, not mean: one to-do left open over a holiday would
    /// drag an average into meaninglessness.
    var medianHoursToClose: Double?
    /// Completions per priority as the user finally saw it, so an override counts as the
    /// band it was actually in.
    var byPriority: [Int: Int] = [:]
    /// Rows that are done but carry no `completedAt`: completed before this version existed.
    /// Surfaced rather than hidden, because a history that quietly omits work looks like a
    /// week where nothing happened.
    var undated = 0

    static func from(
        _ items: [TodoItem],
        now: Date,
        days windowDays: Int = 30,
        calendar: Calendar = .current
    ) -> CompletionStats {
        var stats = CompletionStats()
        stats.undated = items.filter { $0.done && $0.completedAt == nil }.count

        let closed = items.compactMap { item -> (day: Date, at: Date, item: TodoItem)? in
            guard item.done, let at = item.completedAt else { return nil }
            return (calendar.startOfDay(for: at), at, item)
        }
        stats.total = closed.count
        guard !closed.isEmpty else { return stats }

        let todayStart = calendar.startOfDay(for: now)
        stats.today = closed.count { $0.day == todayStart }
        if let weekAgo = calendar.date(byAdding: .day, value: -6, to: todayStart) {
            stats.last7 = closed.count { $0.day >= weekAgo }
        }
        for entry in closed {
            stats.byPriority[entry.item.effectivePriority, default: 0] += 1
        }

        // Zero-filled buckets, oldest first. Built by walking days rather than grouping,
        // so an empty day is present in the output instead of missing from it.
        var counts: [Date: (done: Int, byReply: Int)] = [:]
        for entry in closed {
            var bucket = counts[entry.day] ?? (0, 0)
            bucket.done += 1
            if entry.item.completedByReply { bucket.byReply += 1 }
            counts[entry.day] = bucket
        }
        stats.days = (0..<max(1, windowDays)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { return nil }
            let bucket = counts[day] ?? (0, 0)
            return Day(date: day, done: bucket.done, byReply: bucket.byReply)
        }

        stats.streak = streak(from: Set(counts.keys), todayStart: todayStart, calendar: calendar)

        let hours = closed
            .map { $0.at.timeIntervalSince($0.item.date) / 3600 }
            .filter { $0 >= 0 }
            .sorted()
        if !hours.isEmpty {
            let mid = hours.count / 2
            stats.medianHoursToClose = hours.count.isMultiple(of: 2)
                ? (hours[mid - 1] + hours[mid]) / 2
                : hours[mid]
        }
        return stats
    }

    /// Counted back from today, or from yesterday when today is still empty. A gap of a
    /// whole day ends it. Separate and pure because the rule is a judgment call, not a
    /// fact, and it should be readable on its own.
    static func streak(from activeDays: Set<Date>, todayStart: Date, calendar: Calendar) -> Int {
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: todayStart) else { return 0 }
        var cursor = activeDays.contains(todayStart) ? todayStart
            : activeDays.contains(yesterday) ? yesterday
            : nil
        var run = 0
        while let day = cursor, activeDays.contains(day) {
            run += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return run
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
    assert(!decoded.isCommitment, "a pre-commitment row must decode as an ordinary task")
    assert(decoded.completedAt == nil && !decoded.completedByReply,
           "a pre-history row must decode with no completion date rather than throwing")
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

    // MARK: completion history
    //
    // A fixed calendar and a fixed "now", so these do not drift with the machine's clock or
    // the time of day the suite runs. 12:00 noon deliberately: a fixture at midnight would
    // pass under a day-boundary bug that a midday fixture catches.
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "Asia/Dhaka")!
    let noon = cal.date(from: DateComponents(year: 2026, month: 9, day: 4, hour: 12))!
    func day(_ offset: Int, hour: Int = 9) -> Date {
        cal.date(byAdding: .day, value: offset, to: cal.date(from:
            DateComponents(year: 2026, month: 9, day: 4, hour: hour))!)!
    }
    /// `done` is separate from `at` on purpose: a row completed before this version existed
    /// is done with no date, which is the case `undated` counts, and a fixture that could not
    /// express it would leave that path untested.
    func closed(_ id: String, _ at: Date?, priority: Int = 2, byReply: Bool = false,
                arrived: Date? = nil, done: Bool? = nil) -> TodoItem {
        var item = TodoItem(id: id, action: "Reply \(id)", priority: priority, reason: "r",
                            sender: "Ayesha", channel: nil, date: arrived ?? at ?? noon,
                            permalink: nil)
        item.done = done ?? (at != nil)
        item.completedAt = at
        item.completedByReply = byReply
        return item
    }

    let history = CompletionStats.from([
        closed("t1", day(0)), closed("t2", day(0), byReply: true),
        closed("y1", day(-1), priority: 1),
        closed("d2", day(-2)),
        closed("old", day(-20)),
        closed("undated", nil, done: true),   // done with no date: closed before this version
        closed("open", nil),                  // not done at all: must count nowhere
    ], now: noon, days: 30, calendar: cal)

    assert(history.total == 5, "five dated completions, got \(history.total)")
    assert(history.today == 2, "two closed today, got \(history.today)")
    assert(history.last7 == 4, "today, yesterday and two days back, got \(history.last7)")
    assert(history.days.count == 30, "the window must be zero-filled, got \(history.days.count)")
    assert(history.days.last?.done == 2, "the last bucket is today")
    assert(history.days.last?.byReply == 1, "one of today's was closed by reply detection")
    assert(history.days.last?.byHand == 1, "the other was closed by hand")
    assert(history.days.first?.done == 0, "a day with nothing must still be present as zero")
    assert(history.byPriority[1] == 1 && history.byPriority[2] == 4,
           "completions split by the priority the user finally saw, got \(history.byPriority)")

    // The pre-history rows are counted separately and never dated by guesswork.
    assert(history.undated == 1, "a done row with no completedAt is reported, not hidden")

    // Streak: today, yesterday and the day before are all active, so three. The gap at -3
    // ends it, and the completion 20 days ago must not extend it.
    assert(history.streak == 3, "a run of three consecutive active days, got \(history.streak)")

    let todayStart = cal.startOfDay(for: noon)
    func back(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: todayStart)! }
    assert(CompletionStats.streak(from: [], todayStart: todayStart, calendar: cal) == 0,
           "no activity is no streak")
    assert(CompletionStats.streak(from: [back(1), back(2)], todayStart: todayStart, calendar: cal) == 2,
           "an empty today must not break a live streak before the day is over")
    assert(CompletionStats.streak(from: [back(2), back(3)], todayStart: todayStart, calendar: cal) == 0,
           "two empty days is a broken streak, not a live one")
    assert(CompletionStats.streak(from: [todayStart, back(2)], todayStart: todayStart, calendar: cal) == 1,
           "a gap ends the run even with older activity behind it")

    // Median, not mean: one row left open for a week must not drag the figure.
    let median = CompletionStats.from([
        closed("a", day(0, hour: 11), arrived: day(0, hour: 9)),   // 2h
        closed("b", day(0, hour: 13), arrived: day(0, hour: 9)),   // 4h
        closed("c", day(0, hour: 9), arrived: day(-7, hour: 9)),   // 168h
    ], now: noon, calendar: cal).medianHoursToClose
    assert(median == 4, "the middle value, not the average, got \(String(describing: median))")

    // setDone is the only writer of `done`, and only the edge stamps a date. Reply
    // detection runs over the whole list every refresh, so a re-stamp would walk a
    // completion date forward every few minutes and slide it between days in the history.
    var row = closed("edge", nil)
    let first = day(-1)
    row.setDone(true, byReply: true, at: first)
    assert(row.done && row.completedAt == first && row.completedByReply,
           "the false -> true edge must stamp the date and how it closed")
    row.setDone(true, byReply: true, at: day(0))
    assert(row.completedAt == first, "an already-done row must keep its original date")
    row.setDone(false)
    assert(!row.done && row.completedAt == nil && !row.completedByReply,
           "reopening must clear the date: a row that is owed again was not completed")
    row.setDone(true, at: day(0))
    assert(row.completedAt == day(0) && !row.completedByReply,
           "closing by hand after a reopen records the new date and no longer credits a reply")

    // Nothing completed at all must not invent a history.
    let empty = CompletionStats.from([closed("open", nil)], now: noon, calendar: cal)
    assert(empty.total == 0 && empty.days.isEmpty && empty.streak == 0
           && empty.medianHoursToClose == nil,
           "no dated completions means no history, not a zero-filled month of nothing")

    print("demoModels: PASS \(history.total) closed, streak \(history.streak)")
}
