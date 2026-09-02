import Foundation
import EventKit
import Observation
import os

/// Diagnostics for the store. Launched from the menu bar there is no stdout to read, so
/// the paths that used to fail silently (`try?` on the state file, the two refresh
/// catches) go to the unified log. Only ids, counts and error descriptions are .public:
/// file and JSON errors carry no Slack content. Anything derived from a message stays at
/// Logger's default privacy.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "store")

/// Owns the todo list: pulls from the message source, runs triage, persists to disk.
/// `source` is a protocol so a real Slack client can replace the mock with no UI change.
@MainActor
@Observable
final class Store {
    let source: any MessageSource
    private(set) var todos: [TodoItem] = []
    private(set) var lastScan: Date = .distantPast
    /// True while refresh() is in flight. Drives the spinner on the Refresh button.
    private(set) var isRefreshing = false
    var errorText: String?
    private(set) var lastRemoved: TodoItem?
    /// What the undo bar last offered to undo, so it can label itself and so undoLast()
    /// knows which path to reverse. nil once nothing is pending. Set by the two explicit
    /// user actions only, never by the background reply-detection done in refresh().
    private(set) var lastUndoable: UndoAction?

    private let fileURL: URL
    private var refreshTimer: Timer?
    private var lastRemovedIndex: Int?
    /// The id of the item the user last marked done by hand, so undoLast() can un-mark it.
    /// Auto-done items (reply detection) never touch this, so undo cannot reach them.
    private var lastDoneID: String?

    /// The one thing the undo bar can currently take back. Two paths lead here, and each
    /// clears the other's bookkeeping when it fires, so the bar always undoes the action
    /// it names rather than whichever happened to be recorded first.
    enum UndoAction: Equatable {
        case removed, markedDone

        var label: String {
            switch self {
            case .removed: "Removed."
            case .markedDone: "Marked done."
            }
        }
    }

    /// A scan younger than this counts as fresh. Opening the panel in a loop must not
    /// re-run the on-device model every time.
    static let stalePeriod: TimeInterval = 30

    /// Interval the scheduled timer is actually running at, so a check can prove it
    /// derives from the preference. nil only before the first schedule.
    var refreshInterval: TimeInterval? { refreshTimer?.timeInterval }

    /// Wrapper for the on-disk state. Reads it fresh each call so the view always
    /// shows the current reason (the framework can flip this at any time).
    var unavailableReason: String? { Triage.unavailableReason() }

    private struct State: Codable {
        var todos: [TodoItem]
        var lastScan: Date
    }

    /// Directory holding state.json. `urls(for:in:)` documents an array that can be
    /// empty, and the `[0]` that used to be here trapped during init, so the app died at
    /// launch with nothing in the log. An empty lookup falls back to the standard
    /// ~/Library/Application Support path instead. Pure, so the fallback is assertable
    /// without touching the real directory.
    nonisolated static func supportDirectory(
        candidates: [URL],
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let base = candidates.first ?? home
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        return base.appendingPathComponent("Sereno", isDirectory: true)
    }

    // fileURL override lets tests point at a throwaway path instead of the real
    // app support directory. nil (the default) is unchanged production behavior.
    init(source: any MessageSource = MockMessageSource(), fileURL: URL? = nil) {
        self.source = source
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let candidates = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            if candidates.isEmpty {
                log.error("no application support directory returned, falling back to the home Library path")
            }
            let base = Self.supportDirectory(candidates: candidates)
            do {
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            } catch {
                // Used to be a bare try?. If this fails every save() fails too, and the
                // user loses their list on quit, so it does not get to be silent.
                log.error("state directory unavailable, saves will fail error=\(error.localizedDescription, privacy: .public)")
            }
            self.fileURL = base.appendingPathComponent("state.json")
        }
        load()
        scheduleRefreshTimer()
    }

    // ponytail: no deinit invalidating refreshTimer. Store is a single @State instance
    // that lives for the whole app run, so this only matters at process exit, which
    // tears the timer down anyway. Revisit if Store ever gets created/destroyed at runtime.

    /// Background scan, every `Preferences.refreshMinutes` minutes. It used to be every
    /// 24 hours, which meant a 9am message stayed invisible and the badge stayed wrong
    /// all day.
    ///
    /// withObservationTracking fires onChange once, just BEFORE the new value lands, so
    /// the reschedule hops to the next main-actor turn and re-reads the preference, which
    /// also re-registers the observation. No polling, one timer at a time.
    private func scheduleRefreshTimer() {
        refreshTimer?.invalidate()
        let minutes = withObservationTracking {
            Preferences.shared.refreshMinutes
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefreshTimer() }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: Double(minutes) * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in
                // A tick while a refresh is still running would queue a second model pass
                // behind it. Drop it, the next tick is minutes away.
                guard let self, !self.isRefreshing else { return }
                await self.refresh()
            }
        }
    }

    /// For the panel-open path: skip the work when the last scan is recent. refresh()
    /// itself stays unguarded, that is the explicit Refresh button and regenerate().
    func refreshIfStale() async {
        guard !isRefreshing, Date().timeIntervalSince(lastScan) >= Self.stalePeriod else { return }
        await refresh()
    }

    // Missing or corrupt state file just means "no history yet", not a crash. Missing is
    // normal on first launch; corrupt means the user's saved todos are gone, which they
    // will notice, so only that one is an error.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // Absent is normal on first launch. Present-but-unreadable means the user's
            // saved list just vanished, which they will notice, so it is an error.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                log.error("state file present but unreadable, starting empty")
            } else {
                log.debug("no state file yet, starting empty")
            }
            todos = []
            lastScan = .distantPast
            return
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            todos = state.todos
            lastScan = state.lastScan
        } catch {
            log.error("state file unreadable, starting empty bytes=\(data.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            todos = []
            lastScan = .distantPast
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(State(todos: todos, lastScan: lastScan))
            try data.write(to: fileURL, options: .atomic)
        } catch {
            log.error("state save failed, changes stay in memory only items=\(self.todos.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated static func merged(existing: [TodoItem], new: [TodoItem]) -> [TodoItem] {
        var merged = existing
        var indices: [String: Int] = [:]
        for index in merged.indices { indices[merged[index].id] = index }

        for item in new {
            guard let index = indices[item.id] else {
                indices[item.id] = merged.endIndex
                merged.append(item)
                continue
            }
            let current = merged[index]
            guard !current.isManual, !item.isManual else { continue }

            if item.date > current.date {
                // ponytail: clearing the priority pin is deliberate. Keeping it and showing an
                // "updated" marker is the upgrade path if people need the old judgment retained.
                merged[index] = TodoItem(
                    id: current.id,
                    action: item.action,
                    priority: item.priority,
                    reason: item.reason,
                    detail: item.detail,
                    links: item.links,
                    sender: current.sender,
                    channel: current.channel,
                    date: item.date,
                    permalink: current.permalink,
                    conversationID: current.conversationID,
                    done: false,
                    userPriority: nil,
                    snoozedUntil: nil,
                    isManual: false
                )
            } else if current.reason.hasPrefix("Fallback"), !item.reason.hasPrefix("Fallback") {
                merged[index].action = item.action
                merged[index].priority = item.priority
                merged[index].reason = item.reason
                merged[index].detail = item.detail
                merged[index].links = item.links
            }
        }
        return merged
    }

    /// The unit both this filter and Triage.grouped() group by: the thread/channel id,
    /// falling back to the message id when a source leaves conversationID empty.
    private nonisolated static func conversationKey(_ message: SlackMessage) -> String {
        message.conversationID.isEmpty ? message.id : message.conversationID
    }

    /// Drops messages that are not the user's to act on, per `Set<Addressing>.deservesTask`.
    /// This is the only place the detected addressing decides whether a task exists.
    ///
    /// Deliberately conversation-level, not message-level: Triage judges the exchange as a
    /// whole, so a conversation survives as soon as ONE of its messages deserves a task.
    /// Filtering message by message would strip the context that makes a follow-up
    /// readable ("Hi", then "review it within the hour"). Only a conversation where NO
    /// message deserves a task is dropped.
    ///
    /// An EMPTY addressing set deserves a task, so a source that never populates
    /// `addressing` — a future real Slack client that forgets to — loses nothing here.
    nonisolated static func addressed(
        _ messages: [SlackMessage],
        ignoring ignored: Set<Addressing>
    ) -> [SlackMessage] {
        let keep = Set(
            messages.filter { $0.addressing.deservesTask(ignoring: ignored) }.map(conversationKey)
        )
        return messages.filter { keep.contains(conversationKey($0)) }
    }

    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let messages = try await source.unrepliedMessages(since: lastScan)
            // Preferences is @MainActor and so is this, so read it straight.
            let addressed = Self.addressed(messages, ignoring: Preferences.shared.ignoredSignals)
            log.debug("addressing filter dropped messages=\(messages.count - addressed.count, privacy: .public) conversations=\(Set(messages.map(Self.conversationKey)).count - Set(addressed.map(Self.conversationKey)).count, privacy: .public)")
            let newItems = try await Triage.items(from: addressed)
            todos = Self.merged(existing: todos, new: newItems)
            log.debug("refresh scanned messages=\(messages.count, privacy: .public) newItems=\(newItems.count, privacy: .public) fallbacks=\(newItems.filter { $0.reason.hasPrefix("Fallback") }.count, privacy: .public)")
        } catch {
            log.error("refresh failed, list left unchanged error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
            return
        }

        lastScan = Date()
        errorText = nil

        // Separate do/catch: a failure here must not lose the todos just merged
        // above or skip lastScan. Worst case is a stale done flag, not data loss.
        let openIDs = todos.filter { !$0.done && $0.supportsReplyDetection }.map(\.id)
        do {
            let repliedIDs = try await source.repliedIDs(among: openIDs)
            for index in todos.indices where repliedIDs.contains(todos[index].id) {
                todos[index].done = true
            }
        } catch {
            log.error("reply detection failed, done flags may be stale open=\(openIDs.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
        }

        save()
    }

    func regenerate() async {
        todos = []
        lastScan = .distantPast
        save()
        await refresh()
    }

    func remove(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        lastRemoved = todos.remove(at: index)
        lastRemovedIndex = index
        lastUndoable = .removed
        save()
    }

    func undoRemove() {
        guard let lastRemoved, let lastRemovedIndex else { return }
        todos.insert(lastRemoved, at: min(lastRemovedIndex, todos.count))
        self.lastRemoved = nil
        self.lastRemovedIndex = nil
        save()
    }

    func toggleDone(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].done.toggle()
        save()
    }

    /// The user's explicit Done (the checkmark button and the context-menu item). Unlike
    /// toggleDone it records the item for undo and arms the undo bar, so a manual Done is
    /// as reversible as a Remove. Clears the remove-undo fields so the two paths never
    /// cross and the bar undoes exactly what it names.
    ///
    /// ponytail: the auto-done in refresh() (reply detection) deliberately does NOT come
    /// through here — it happens in the background with no window to show a bar. Fully
    /// recovering an auto-done item would need a persistent "Completed" view, which is out
    /// of scope; this covers only the action the user just took and can see.
    func markDone(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].done = true
        lastDoneID = item.id
        lastUndoable = .markedDone
        lastRemoved = nil
        lastRemovedIndex = nil
        save()
    }

    /// Reverses whatever the undo bar is currently offering, then disarms it.
    func undoLast() {
        switch lastUndoable {
        case .removed:
            undoRemove()
        case .markedDone:
            if let lastDoneID, let index = todos.firstIndex(where: { $0.id == lastDoneID }) {
                todos[index].done = false
                save()
            }
            lastDoneID = nil
        case nil:
            break
        }
        lastUndoable = nil
    }

    @discardableResult
    func addManual(_ action: String, priority: Int, detail: String) -> TodoItem {
        let item = TodoItem(
            id: UUID().uuidString,
            action: action,
            priority: priority,
            reason: "Added manually.",
            detail: detail,
            links: [],
            sender: "You",
            channel: nil,
            date: Date(),
            permalink: nil,
            conversationID: "",
            isManual: true
        )
        todos.append(item)
        save()
        return item
    }

    func setUserPriority(_ item: TodoItem, to priority: Int?) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].userPriority = priority
        save()
    }

    func snooze(_ item: TodoItem, until date: Date) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].snoozedUntil = date
        save()
    }

    func unsnooze(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].snoozedUntil = nil
        save()
    }

    func exportToReminders(_ item: TodoItem) async throws {
        let store = EKEventStore()
        let granted: Bool
        if #available(macOS 14.0, *) {
            granted = try await store.requestFullAccessToReminders()
        } else {
            granted = try await store.requestAccess(to: .reminder)
        }
        guard granted else {
            throw NSError(
                domain: "Sereno",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Reminders access was denied. Enable it in System Settings and try again."]
            )
        }
        guard let calendar = store.defaultCalendarForNewReminders() else {
            throw NSError(
                domain: "Sereno",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "No default Reminders list is available."]
            )
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = item.action
        reminder.notes = item.detail
        reminder.priority = (min(max(item.effectivePriority, 1), 5) - 1) * 2 + 1
        reminder.calendar = calendar
        try store.save(reminder, commit: true)
    }
}

@MainActor
func demoStoreMerge() {
    let oldDate = Date(timeIntervalSinceReferenceDate: 0)
    let newDate = oldDate.addingTimeInterval(60)
    func todo(_ id: String, action: String, priority: Int, reason: String, date: Date = oldDate,
              detail: String = "detail", links: [URL] = [], done: Bool = false,
              userPriority: Int? = nil, snoozedUntil: Date? = nil, isManual: Bool = false) -> TodoItem {
        TodoItem(id: id, action: action, priority: priority, reason: reason, detail: detail,
                 links: links, sender: "sender", channel: nil, date: date, permalink: nil,
                 conversationID: "conversation", done: done, userPriority: userPriority,
                 snoozedUntil: snoozedUntil, isManual: isManual)
    }

    let before = todo("paul", action: "Get back to Paul", priority: 3, reason: "Needs a reply.",
                      done: true, userPriority: 3, snoozedUntil: newDate)
    let followUp = todo("paul", action: "Review Paul's reply within the hour", priority: 1,
                        reason: "Paul asked for review within an hour.", date: newDate,
                        detail: "Please review this in the next hour.")
    let reopened = Store.merged(existing: [before], new: [followUp])[0]
    assert(reopened.action == followUp.action && reopened.priority == followUp.priority &&
           reopened.reason == followUp.reason && reopened.detail == followUp.detail &&
           reopened.date == followUp.date && !reopened.done && reopened.userPriority == nil &&
           reopened.snoozedUntil == nil)
    print("follow-up before: action=\(before.action), priority=\(before.priority), done=\(before.done), userPriority=\(String(describing: before.userPriority))")
    print("follow-up after: action=\(reopened.action), priority=\(reopened.priority), done=\(reopened.done), userPriority=\(String(describing: reopened.userPriority)), snoozedUntil=\(String(describing: reopened.snoozedUntil))")

    let fallback = todo("fallback", action: "Review message", priority: 3,
                        reason: "Fallback because no usable model result was returned.",
                        detail: "old detail", links: [URL(string: "https://old.example")!], done: true,
                        userPriority: 2, snoozedUntil: newDate)
    let good = todo("fallback", action: "Reply to launch request", priority: 1, reason: "Blocking the launch.",
                    detail: "new detail", links: [URL(string: "https://new.example")!])
    let retriaged = Store.merged(existing: [fallback], new: [good])[0]
    assert(retriaged.action == good.action && retriaged.priority == good.priority &&
           retriaged.reason == good.reason && retriaged.detail == good.detail && retriaged.links == good.links &&
           retriaged.done && retriaged.userPriority == fallback.userPriority &&
           retriaged.snoozedUntil == fallback.snoozedUntil)

    let existingGood = todo("good", action: "Keep this", priority: 2, reason: "User-visible good result.")
    let newGood = todo("good", action: "Replace this", priority: 1, reason: "New result.")
    assert(Store.merged(existing: [existingGood], new: [newGood]) == [existingGood])

    let newFallback = todo("good", action: "Review message", priority: 3,
                           reason: "Fallback because no usable model result was returned.")
    assert(Store.merged(existing: [existingGood], new: [newFallback]) == [existingGood])

    let manual = todo("manual", action: "Write notes", priority: 4, reason: "Added manually.",
                      date: oldDate, isManual: true)
    let attemptedReplacement = todo("manual", action: "Replace manual task", priority: 1,
                                    reason: "New result.", date: newDate)
    assert(Store.merged(existing: [manual], new: [attemptedReplacement]) == [manual])

    let existingOnly = todo("existing-only", action: "Keep", priority: 4, reason: "Existing.")
    let newOnly = todo("new-only", action: "Add", priority: 1, reason: "New.")
    let combined = Store.merged(existing: [existingOnly], new: [newOnly])
    assert(Set(combined.map(\.id)) == [existingOnly.id, newOnly.id])

    // An empty applicationSupportDirectory lookup must not trap: it falls back under the
    // user's home Library. The primary lookup, when it has an entry, still wins.
    let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
    assert(Store.supportDirectory(candidates: [], home: home).path ==
           "/Users/example/Library/Application Support/Sereno")
    assert(Store.supportDirectory(candidates: [URL(fileURLWithPath: "/opt/appsupport", isDirectory: true)],
                                  home: home).path == "/opt/appsupport/Sereno")
    assert(Store.supportDirectory(candidates: [], home: home).lastPathComponent == "Sereno")

    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-undo-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let store = Store(fileURL: tempURL)
    let first = store.addManual("First", priority: 3, detail: "")
    _ = store.addManual("Second", priority: 4, detail: "")
    store.remove(first)
    assert(store.lastRemoved == first && store.todos.count == 1)
    store.undoRemove()
    assert(store.lastRemoved == nil && store.todos.map(\.action) == ["First", "Second"])
    print("demoStoreMerge: PASS")
}

/// The addressing filter refresh() applies before triage: what creates a task, what
/// does not, and that a conversation is kept or dropped whole.
func demoAddressingFilter() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    func message(_ id: String, conversation: String = "", _ addressing: Set<Addressing>,
                 offset: TimeInterval = 0) -> SlackMessage {
        SlackMessage(id: id, conversationID: conversation, sender: "sender", channel: "#channel",
                     text: "text", date: now.addingTimeInterval(offset),
                     directlyAddressed: false, addressing: addressing, permalink: nil)
    }
    func kept(_ messages: [SlackMessage], ignoring ignored: Set<Addressing> = [.broadcast]) -> [String] {
        Store.addressed(messages, ignoring: ignored).map(\.id)
    }

    // The bug: an @channel notice ranked priority 1 because nothing read its addressing.
    assert(kept([message("broadcast", [.broadcast])]).isEmpty)
    assert(kept([message("dm", [.directMessage])]) == ["dm"])

    // Empty means "nothing explicit points at me", not "not mine". "Team, please complete
    // the deployment doc" has no signal at all and must reach the model.
    assert(kept([message("unaddressed", [])]) == ["unaddressed"])

    // A source that never populates addressing at all still gets everything through,
    // which is the safe direction: a silently empty list is the worst failure here.
    assert(kept([message("a", conversation: "C", []), message("b", conversation: "C", [])]) == ["a", "b"])

    // Mixed conversation: one personal signal keeps the WHOLE exchange, because dropping
    // the broadcast half strips the context the follow-up needs.
    let mixed = [message("mixed/1", conversation: "C_MIXED", [.broadcast]),
                 message("mixed/2", conversation: "C_MIXED", [.mention], offset: 60)]
    assert(kept(mixed) == ["mixed/1", "mixed/2"])

    // Broadcast all the way down: nothing in it is anyone's task, so it goes entirely.
    assert(kept([message("all/1", conversation: "C_ALL", [.broadcast]),
                 message("all/2", conversation: "C_ALL", [.broadcast], offset: 60)]).isEmpty)

    // The weakest signal, and the preference that switches it off.
    assert(kept([message("named", [.nameMentioned])], ignoring: []) == ["named"])
    assert(kept([message("named", [.nameMentioned])], ignoring: [.nameMentioned]).isEmpty)

    print("demoAddressingFilter: PASS")
}

/// A source with nothing to hand back, so the refresh paths can be exercised without
/// calling the on-device model.
private struct SilentSource: MessageSource {
    func unrepliedMessages(since: Date) async throws -> [SlackMessage] { [] }
    func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
}

/// The refresh cadence: interval comes from the preference and follows it when it
/// changes, and refreshIfStale() skips a scan that just happened.
@MainActor
func demoRefreshTimer() async {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-timer-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let prefs = Preferences.shared
    let original = prefs.refreshMinutes
    defer { prefs.refreshMinutes = original }

    prefs.refreshMinutes = 5
    let store = Store(source: SilentSource(), fileURL: tempURL)
    assert(store.refreshInterval == 300,
           "timer must derive from refreshMinutes, got \(String(describing: store.refreshInterval))")
    assert(store.refreshInterval != 60 * 60 * 24, "the daily timer must be gone")

    // Changed while running: the observation reschedules on the next main-actor turn.
    prefs.refreshMinutes = 12
    for _ in 0..<20 where store.refreshInterval != 720 { await Task.yield() }
    assert(store.refreshInterval == 720,
           "timer must follow a preference change, got \(String(describing: store.refreshInterval))")
    print("refresh interval: 5 min -> \(store.refreshInterval == 720 ? 720 : -1)s after setting 12 min")

    // Stale (never scanned) runs, and the run makes it fresh.
    assert(store.lastScan == .distantPast)
    await store.refreshIfStale()
    let firstScan = store.lastScan
    assert(firstScan > .distantPast, "refreshIfStale must run when lastScan is old")

    // Fresh: the same call again must not scan, so lastScan cannot move.
    await store.refreshIfStale()
    assert(store.lastScan == firstScan, "refreshIfStale must skip a scan under 30 seconds old")
    assert(Store.stalePeriod == 30)

    // And an explicit refresh() is never skipped, that is the Refresh button.
    await store.refresh()
    assert(store.lastScan > firstScan, "refresh() must always scan")
    print("demoRefreshTimer: PASS")
}
