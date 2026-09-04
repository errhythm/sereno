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
    /// Durable Slack call-reduction state. It is optional so state.json files written by
    /// older Sereno versions decode without migration work.
    private var slackScanState: SlackScanState?
    /// Conversation keys the user explicitly removed, with the moment they did it. Search
    /// discovery's candidate cutoff is now a bounded lookback (see
    /// SlackMessageSource.searchLookback) rather than a sliding watermark, so without this a
    /// wider re-scan could resurrect exactly what Remove was supposed to bury. "Not this, not
    /// again": a conversation stays out until it has a genuinely newer message than its
    /// dismissal. Lives in Store rather than SlackScanState because it is a user decision, not
    /// Slack-scan mechanics, and Store is the only thing that ever needs to read or write it.
    private var dismissed: [String: Date] = [:]
    private var restoredSlackScanState = false
    private var resetGeneration = 0
    /// Earliest time refreshIfStale() may try again after a failure. Deliberately NOT
    /// lastScan: lastScan is the `since` cursor handed to the source, so advancing it to
    /// buy quiet would silently skip every message that arrived in the gap. Without this a
    /// failed refresh stayed stale and re-ran on the next touch of the panel, which turned
    /// a 5 minute preference into a scan every 15 seconds against a rate limit.
    private var retryAfterFailure: Date?

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
    /// The least a failed refresh waits before refreshIfStale() tries again. A rate limit
    /// that named a longer wait gets its own number honoured instead.
    static let failureBackoff: TimeInterval = 60
    nonisolated private static let currentSchemaVersion = 1

    /// Interval the scheduled timer is actually running at, so a check can prove it
    /// derives from the preference. nil only before the first schedule.
    var refreshInterval: TimeInterval? { refreshTimer?.timeInterval }

    /// Wrapper for the on-disk state. Reads it fresh each call so the view always
    /// shows the current reason (the framework can flip this at any time).
    var unavailableReason: String? { Triage.unavailableReason() }

    private var debugCaptureURL: URL { Self.debugCaptureFileURL(stateFileURL: fileURL) }

    /// Bytes on disk, or nil when nothing has been captured (including when the feature
    /// is off, since then the file was never created). For the Settings row.
    var debugCaptureFileSizeBytes: Int? { DebugCapture.fileSizeBytes(at: debugCaptureURL) }

    /// The Settings "delete what has been captured" button, and part of resetAll()'s
    /// cleanup below. Safe to call whether or not anything was ever captured.
    func deleteDebugCapture() { DebugCapture.delete(at: debugCaptureURL) }

    private struct State: Codable {
        var schemaVersion: Int
        var todos: [TodoItem]
        var lastScan: Date
        var slackScanState: SlackScanState?
        var dismissed: [String: Date]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion, todos, lastScan, slackScanState, dismissed
        }

        init(todos: [TodoItem], lastScan: Date, slackScanState: SlackScanState?,
             dismissed: [String: Date] = [:], schemaVersion: Int = Store.currentSchemaVersion) {
            self.schemaVersion = schemaVersion
            self.todos = todos
            self.lastScan = lastScan
            self.slackScanState = slackScanState
            self.dismissed = dismissed
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            // A missing key is specifically the pre-schema format (version 0). Tying it
            // to the current version would quietly skip this migration after a bump.
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
            todos = try container.decode([TodoItem].self, forKey: .todos)
            lastScan = try container.decode(Date.self, forKey: .lastScan)
            slackScanState = try container.decodeIfPresent(SlackScanState.self, forKey: .slackScanState)
            // Absent in every state.json written before this field existed.
            dismissed = try container.decodeIfPresent([String: Date].self, forKey: .dismissed) ?? [:]
        }
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

    /// Debug capture's own file, a sibling of state.json rather than inside it, so it can
    /// be deleted (Settings' button, or a reset) without touching the todo list. Pure and
    /// derived from the state file's own directory, so a demo pointed at a throwaway
    /// state.json path gets a throwaway debug path for free, and never the real one.
    nonisolated static func debugCaptureFileURL(stateFileURL: URL) -> URL {
        stateFileURL.deletingLastPathComponent().appendingPathComponent(DebugCapture.fileName())
    }

    // fileURL override lets tests point at a throwaway path instead of the real
    // app support directory. nil (the default) is unchanged production behavior.
    init(source: any MessageSource, fileURL: URL? = nil) {
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
    /// itself checks again because direct callers do not pass through this stale check.
    ///
    /// The backoff is checked only here, so the Refresh button still goes straight through:
    /// a user pressing it is asking for the attempt now, whatever the last one did.
    func refreshIfStale() async {
        guard !isRefreshing, Date().timeIntervalSince(lastScan) >= Self.stalePeriod else { return }
        if let retryAfterFailure, Date() < retryAfterFailure { return }
        await refresh()
    }

    /// How long to stay quiet after a failure. A rate limit names the wait it wants, and
    /// honouring it is the only thing that stops the next attempt from renewing the same
    /// rejection. Everything else gets the flat minimum, short enough that a blip is not
    /// felt and long enough that a broken source is not asked again on every panel open.
    private static func backoff(after error: Error) -> TimeInterval {
        guard let slack = error as? SlackSourceError,
              case .rateLimited(let retryAfter) = slack
        else { return failureBackoff }
        return max(failureBackoff, retryAfter ?? 0)
    }

    /// Moves an unreadable or undecodable state file aside before load() lets a
    /// subsequent save() overwrite it. A rename needs write permission on the containing
    /// directory, not readability of the file itself, so this still works when the read
    /// that triggered it failed. The name carries a timestamp plus a short random suffix
    /// so repeated failures (e.g. across relaunches within the same second) each get their
    /// own sidecar instead of one clobbering another. Returns the sidecar URL on success;
    /// nil if the move itself failed, which is logged here but never allowed to block
    /// startup.
    private func quarantineCorruptStateFile() -> URL? {
        let sidecar = fileURL.deletingLastPathComponent().appendingPathComponent(
            "state-corrupt-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: sidecar)
            return sidecar
        } catch {
            log.error("failed to quarantine corrupt state file error=\(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    // Missing or corrupt state file just means "no history yet", not a crash. Missing is
    // normal on first launch; corrupt means the user's saved todos are gone, which they
    // will notice, so only that one is an error. Either failure quarantines the file first
    // (see quarantineCorruptStateFile) so the next save() cannot overwrite the only copy.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            // Absent is normal on first launch. Present-but-unreadable means the user's
            // saved list just vanished, which they will notice, so it is an error.
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let sidecar = quarantineCorruptStateFile()
                log.error("state file present but unreadable, starting empty sidecar=\(sidecar?.lastPathComponent ?? "none", privacy: .public)")
            } else {
                log.debug("no state file yet, starting empty")
            }
            todos = []
            lastScan = .distantPast
            slackScanState = nil
            dismissed = [:]
            return
        }
        do {
            let state = try JSONDecoder().decode(State.self, from: data)
            let loadedTodos: [TodoItem]
            if state.schemaVersion == 0 {
                // These files predate the required source, so non-manual todos may be
                // mock fixtures. Manual todos came from the user and must survive.
                loadedTodos = state.todos.filter(\.isManual)
                log.info("migrated pre-schema state dropped items=\(state.todos.count - loadedTodos.count, privacy: .public)")
            } else {
                loadedTodos = state.todos
            }
            var seenIDs = Set<String>()
            todos = loadedTodos.filter { seenIDs.insert($0.id).inserted }
            let duplicateCount = loadedTodos.count - todos.count
            if duplicateCount > 0 {
                log.info("deduplicated loaded state items=\(duplicateCount, privacy: .public)")
            }
            lastScan = state.lastScan
            slackScanState = state.slackScanState
            dismissed = state.dismissed
            if state.schemaVersion == 0 || duplicateCount > 0 { save() }
        } catch {
            let sidecar = quarantineCorruptStateFile()
            log.error("state file unreadable, starting empty bytes=\(data.count, privacy: .public) error=\(error.localizedDescription, privacy: .public) sidecar=\(sidecar?.lastPathComponent ?? "none", privacy: .public)")
            todos = []
            lastScan = .distantPast
            slackScanState = nil
            dismissed = [:]
        }
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(
                State(todos: todos, lastScan: lastScan, slackScanState: slackScanState, dismissed: dismissed)
            )
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
                    isCommitment: current.isCommitment || item.isCommitment,
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

    /// Drops conversations whose only non-context reasons for consideration were explicitly
    /// switched off by the user, per `Set<Addressing>.deservesTask`. Commitments carry an
    /// empty addressing set by design: they are authored by the user, not aimed at them.
    ///
    /// Deliberately conversation-level, not message-level: Triage judges the exchange as a
    /// whole, so a conversation survives as soon as ONE non-context message deserves a task.
    /// Filtering message by message would strip the context that makes a follow-up
    /// readable ("Hi", then "review it within the hour"). Only a conversation where NO
    /// non-context message deserves a task is dropped. Context can tag along with a kept
    /// conversation, but it can never be the reason one survives.
    ///
    /// An EMPTY addressing set deserves a task, so a source that never populates
    /// `addressing` — a future real Slack client that forgets to — loses nothing here.
    nonisolated static func addressed(
        _ messages: [SlackMessage],
        ignoring ignored: Set<Addressing>
    ) -> [SlackMessage] {
        let keep = Set(
            messages.filter {
                !$0.isContext && $0.addressing.deservesTask(ignoring: ignored)
            }.map(conversationKey)
        )
        return messages.filter { keep.contains(conversationKey($0)) }
    }

    /// "Not this, not again": a conversation the user dismissed stays out until it has a
    /// message genuinely newer than the dismissal. Whole-conversation, not per-message, like
    /// `addressed`: a re-discovered thread's context rows (the parent, earlier replies) are
    /// always older than or equal to the new message that triggered their re-fetch, so a
    /// per-message date filter would strip exactly the context a follow-up needs to read.
    nonisolated static func skippingDismissed(
        _ messages: [SlackMessage],
        dismissed: [String: Date]
    ) -> [SlackMessage] {
        guard !dismissed.isEmpty else { return messages }
        var newest: [String: Date] = [:]
        for message in messages {
            let key = conversationKey(message)
            newest[key] = max(newest[key] ?? .distantPast, message.date)
        }
        return messages.filter { message in
            let key = conversationKey(message)
            guard let dismissedAt = dismissed[key] else { return true }
            return (newest[key] ?? .distantPast) > dismissedAt
        }
    }

    /// Triage costs seconds and battery per conversation, and a bounded lookback re-offers
    /// the same conversations on every refresh. A candidate whose conversation already has a
    /// todo dated at or after its own newest message has nothing new to say, so it is dropped
    /// before triage rather than re-deriving the same task. Whole-conversation, same reasoning
    /// as `skippingDismissed`: a genuinely newer message keeps the conversation, context rows
    /// included.
    nonisolated static func droppingAlreadyAccounted(
        _ messages: [SlackMessage],
        existing todos: [TodoItem]
    ) -> [SlackMessage] {
        var accountedThrough: [String: Date] = [:]
        for todo in todos where !todo.conversationID.isEmpty {
            accountedThrough[todo.conversationID] = max(accountedThrough[todo.conversationID] ?? .distantPast, todo.date)
        }
        guard !accountedThrough.isEmpty else { return messages }
        var newest: [String: Date] = [:]
        for message in messages {
            let key = conversationKey(message)
            newest[key] = max(newest[key] ?? .distantPast, message.date)
        }
        return messages.filter { message in
            let key = conversationKey(message)
            guard let accountedDate = accountedThrough[key] else { return true }
            return (newest[key] ?? .distantPast) > accountedDate
        }
    }

    func refresh() async {
        guard !isRefreshing else { return }
        let refreshGeneration = resetGeneration
        isRefreshing = true
        defer { isRefreshing = false }

        let statefulSource = source as? any SlackScanStateSource
        if let statefulSource, !restoredSlackScanState {
            await statefulSource.restoreSlackScanState(slackScanState ?? SlackScanState())
            guard refreshGeneration == resetGeneration else { return }
            restoredSlackScanState = true
        }
        let previousSlackState = slackScanState

        let messages: [SlackMessage]
        do {
            messages = try await source.unrepliedMessages(since: lastScan)
            guard refreshGeneration == resetGeneration else { return }
        } catch {
            guard refreshGeneration == resetGeneration else { return }
            // The connection floor is established when the connected scan begins and must
            // survive even if Slack fails. Conversation edges do not advance on a failed
            // source call because a fatal result may have hidden another child's messages.
            if let statefulSource {
                let candidate = await statefulSource.currentSlackScanState()
                guard refreshGeneration == resetGeneration else { return }
                var rollback = candidate
                rollback.conversations = previousSlackState?.accountKey == candidate.accountKey
                    ? previousSlackState?.conversations ?? [:]
                    : [:]
                slackScanState = rollback
                await statefulSource.restoreSlackScanState(rollback)
                guard refreshGeneration == resetGeneration else { return }
                save()
            }
            log.error("refresh failed, list left unchanged error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
            retryAfterFailure = Date().addingTimeInterval(Self.backoff(after: error))
            return
        }

        let candidateSlackState: SlackScanState? = if let statefulSource {
            await statefulSource.currentSlackScanState()
        } else {
            nil
        }
        guard refreshGeneration == resetGeneration else { return }

        do {
            // Preferences is @MainActor and so is this, so read it straight.
            let notDismissed = Self.skippingDismissed(messages, dismissed: dismissed)
            let addressed = Self.addressed(notDismissed, ignoring: Preferences.shared.ignoredSignals)
            // Raised to .info: these are the counters that explain a refresh producing
            // nothing, and they were at .debug (uncaptured on this machine) the one time
            // that diagnosis actually mattered. Ids and counts only, never content.
            log.info("addressing filter dropped messages=\(notDismissed.count - addressed.count, privacy: .public) conversations=\(Set(notDismissed.map(Self.conversationKey)).count - Set(addressed.map(Self.conversationKey)).count, privacy: .public)")
            let unaccounted = Self.droppingAlreadyAccounted(addressed, existing: todos)
            log.info("already-accounted filter dropped conversations=\(Set(addressed.map(Self.conversationKey)).count - Set(unaccounted.map(Self.conversationKey)).count, privacy: .public)")
            let newItems = try await Triage.items(from: unaccounted)
            guard refreshGeneration == resetGeneration else { return }
            // Default OFF: a user who never opens Settings must never have a byte of
            // message text written. Only the exact input Triage received and the to-dos
            // it produced go to disk, never the wider `messages` or the merged `todos`.
            if Preferences.shared.debugCaptureEnabled {
                DebugCapture.append(
                    DebugCapture.records(messages: unaccounted, todos: newItems),
                    to: debugCaptureURL
                )
            }
            todos = Self.merged(existing: todos, new: newItems)
            log.info("refresh scanned messages=\(messages.count, privacy: .public) newItems=\(newItems.count, privacy: .public) fallbacks=\(newItems.filter { $0.reason.hasPrefix("Fallback") }.count, privacy: .public)")
        } catch {
            guard refreshGeneration == resetGeneration else { return }
            // Fetching does not count as accounting for a message until triage accepts it.
            // Preserve cheap identity/name work and the connection floor, but put every
            // conversation edge back so the same messages are offered again next time.
            if let statefulSource, var rollback = candidateSlackState {
                rollback.conversations = previousSlackState?.accountKey == rollback.accountKey
                    ? previousSlackState?.conversations ?? [:]
                    : [:]
                slackScanState = rollback
                await statefulSource.restoreSlackScanState(rollback)
                guard refreshGeneration == resetGeneration else { return }
                save()
            }
            log.error("refresh failed, list left unchanged error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
            retryAfterFailure = Date().addingTimeInterval(Self.backoff(after: error))
            return
        }

        if let candidateSlackState { slackScanState = candidateSlackState }
        lastScan = Date()
        errorText = nil
        retryAfterFailure = nil

        // Separate do/catch: a failure here must not lose the todos just merged
        // above or skip lastScan. Worst case is a stale done flag, not data loss.
        let openIDs = todos.filter { !$0.done && $0.supportsReplyDetection }.map(\.id)
        do {
            let repliedIDs = try await source.repliedIDs(among: openIDs)
            guard refreshGeneration == resetGeneration else { return }
            for index in todos.indices where repliedIDs.contains(todos[index].id) {
                // Stamped here rather than in a setter so the history can tell work the
                // user finished from work that closed itself because they answered in
                // Slack. Only on the false -> true edge: re-running detection over an
                // already-done row must not move its completion date forward.
                todos[index].setDone(true, byReply: true)
            }
        } catch {
            guard refreshGeneration == resetGeneration else { return }
            log.error("reply detection failed, done flags may be stale open=\(openIDs.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
            errorText = error.localizedDescription
        }

        guard refreshGeneration == resetGeneration else { return }
        save()
    }

    func regenerate() async {
        todos = []
        lastScan = .distantPast
        // Regeneration may re-read only the period since connection. It must never erase
        // that floor and expose messages which predate installation.
        slackScanState?.conversations = [:]
        if let statefulSource = source as? any SlackScanStateSource,
           let slackScanState {
            await statefulSource.restoreSlackScanState(slackScanState)
            restoredSlackScanState = true
        }
        save()
        await refresh()
    }

    /// A reset invalidates any refresh that was already waiting on Slack or the model, so
    /// its result cannot repopulate the list after the user has cleared it.
    func resetAll() {
        resetGeneration += 1
        todos = []
        lastScan = .distantPast
        slackScanState = nil
        dismissed = [:]
        restoredSlackScanState = false
        errorText = nil
        retryAfterFailure = nil
        lastRemoved = nil
        lastRemovedIndex = nil
        lastDoneID = nil
        lastUndoable = nil
        save()
        deleteDebugCapture()
    }

    func remove(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        lastRemoved = todos.remove(at: index)
        lastRemovedIndex = index
        lastUndoable = .removed
        // Tombstone the conversation so a wider search lookback cannot resurrect it. A
        // manual item and one with no Slack conversation behind it have nothing to bury.
        if !item.isManual, !item.conversationID.isEmpty {
            dismissed[item.conversationID] = Date()
        }
        save()
    }

    func undoRemove() {
        guard let lastRemoved, let lastRemovedIndex else {
            self.lastRemoved = nil
            self.lastRemovedIndex = nil
            lastUndoable = nil
            return
        }
        if !todos.contains(where: { $0.id == lastRemoved.id }) {
            todos.insert(lastRemoved, at: min(lastRemovedIndex, todos.count))
        }
        self.lastRemoved = nil
        self.lastRemovedIndex = nil
        lastUndoable = nil
        save()
    }

    func toggleDone(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }) else { return }
        todos[index].setDone(!todos[index].done)
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
        todos[index].setDone(true)
        lastDoneID = item.id
        lastUndoable = .markedDone
        lastRemoved = nil
        lastRemovedIndex = nil
        save()
    }

    /// Pull a finished row back into the list, from the History window.
    ///
    /// Separate from `undoLast`'s reopen on purpose, because the two mean different things.
    /// Undo reverses a Done the user pressed seconds ago and leaves detection alone. This is
    /// the user overruling the app days later, so it also stops reply detection touching the
    /// row: the conversation is still settled in Slack, and without the flag the very next
    /// refresh would close it again and look like the reopen simply did not work.
    ///
    /// A genuinely new message in that conversation resets it, because `Store.merged` builds
    /// a fresh row on a follow-up, which is the behaviour we want and costs nothing here.
    func reopen(_ item: TodoItem) {
        guard let index = todos.firstIndex(where: { $0.id == item.id }), todos[index].done else { return }
        todos[index].setDone(false)
        todos[index].reopenedByUser = true
        log.info("reopened a completed item id=\(item.id, privacy: .public)")
        save()
    }

    /// Reverses whatever the undo bar is currently offering, then disarms it.
    func undoLast() {
        switch lastUndoable {
        case .removed:
            undoRemove()
        case .markedDone:
            if let lastDoneID, let index = todos.firstIndex(where: { $0.id == lastDoneID }) {
                todos[index].setDone(false)
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
func demoStoreMerge() async {
    let oldDate = Date(timeIntervalSinceReferenceDate: 0)
    let newDate = oldDate.addingTimeInterval(60)
    func todo(_ id: String, action: String, priority: Int, reason: String, date: Date = oldDate,
              detail: String = "detail", links: [URL] = [], done: Bool = false,
              userPriority: Int? = nil, snoozedUntil: Date? = nil, isManual: Bool = false,
              isCommitment: Bool = false) -> TodoItem {
        TodoItem(id: id, action: action, priority: priority, reason: reason, detail: detail,
                 links: links, sender: "sender", channel: nil, date: date, permalink: nil,
                 conversationID: "conversation", isCommitment: isCommitment, done: done, userPriority: userPriority,
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

    let existingPromise = todo("paul", action: "Send report", priority: 2,
                               reason: "Promised.", date: newDate, isCommitment: true)
    let transformedPromise = Store.merged(existing: [before], new: [existingPromise])[0]
    assert(transformedPromise.isCommitment && !transformedPromise.supportsReplyDetection,
           "a promise merged into an inbound task must become user-completed only")
    let afterPromise = todo("paul", action: "Review follow-up", priority: 1,
                            reason: "New reply.", date: newDate.addingTimeInterval(60))
    let stillPromised = Store.merged(existing: [transformedPromise], new: [afterPromise])[0]
    assert(stillPromised.isCommitment && !stillPromised.supportsReplyDetection,
           "later Slack activity must not make a promise auto-completable")
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
    let store = Store(source: MockMessageSource(), fileURL: tempURL)
    let first = store.addManual("First", priority: 3, detail: "")
    _ = store.addManual("Second", priority: 4, detail: "")
    store.remove(first)
    assert(store.lastRemoved == first && store.todos.count == 1)
    store.undoRemove()
    assert(store.lastRemoved == nil && store.lastUndoable == nil &&
           store.todos.map(\.action) == ["First", "Second"])

    final class ReaddingSource: MessageSource, @unchecked Sendable {
        let message = SlackMessage(id: "undo-refresh", conversationID: "undo-refresh",
                                   sender: "sender", channel: nil,
                                   text: "Could you reply with the status?",
                                   date: Date(timeIntervalSinceReferenceDate: 60),
                                   directlyAddressed: true, addressing: [.directMessage], permalink: nil)

        func unrepliedMessages(since: Date) async throws -> [SlackMessage] { [message] }
        func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
    }
    let collisionURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-undo-collision-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: collisionURL) }
    let collisionStore = Store(source: ReaddingSource(), fileURL: collisionURL)
    await collisionStore.refresh()
    let refreshed = collisionStore.todos[0]
    collisionStore.remove(refreshed)
    await collisionStore.refresh()
    collisionStore.undoRemove()
    assert(collisionStore.todos.filter { $0.id == refreshed.id }.count == 1)

    struct LegacyState: Codable {
        var todos: [TodoItem]
        var lastScan: Date
        var slackScanState: SlackScanState?
    }
    let migrationURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-migration-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: migrationURL) }
    let legacy = LegacyState(todos: [manual, existingOnly], lastScan: newDate, slackScanState: nil)
    try! JSONEncoder().encode(legacy).write(to: migrationURL, options: .atomic)
    let migratedStore = Store(source: MockMessageSource(), fileURL: migrationURL)
    assert(migratedStore.todos == [manual])
    migratedStore.resetAll()
    assert(migratedStore.todos.isEmpty && migratedStore.lastScan == .distantPast)
    let resetStore = Store(source: MockMessageSource(), fileURL: migrationURL)
    assert(resetStore.todos.isEmpty && resetStore.lastScan == .distantPast)

    struct CurrentState: Codable {
        var schemaVersion: Int
        var todos: [TodoItem]
        var lastScan: Date
        var slackScanState: SlackScanState?
    }
    let dedupeURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-dedupe-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: dedupeURL) }
    let duplicateFirst = todo("duplicate", action: "Keep first", priority: 2, reason: "First.")
    let duplicateSecond = todo("duplicate", action: "Drop second", priority: 1, reason: "Second.")
    try! JSONEncoder().encode(CurrentState(schemaVersion: 1, todos: [duplicateFirst, duplicateSecond],
                                            lastScan: newDate, slackScanState: nil))
        .write(to: dedupeURL, options: .atomic)
    let deduplicatedStore = Store(source: MockMessageSource(), fileURL: dedupeURL)
    assert(deduplicatedStore.todos == [duplicateFirst])
    let rewrittenState = try! JSONDecoder().decode(CurrentState.self, from: Data(contentsOf: dedupeURL))
    assert(rewrittenState.todos == [duplicateFirst])

    // A state file that fails to decode must not let the very next save() overwrite the
    // only copy: load() quarantines it aside first, then starts empty as before.
    let corruptURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-corrupt-\(UUID().uuidString).json")
    let corruptDir = corruptURL.deletingLastPathComponent()
    func sidecarNames() -> Set<String> {
        Set((try! FileManager.default.contentsOfDirectory(atPath: corruptDir.path))
            .filter { $0.hasPrefix("state-corrupt-") })
    }
    let sidecarsBefore = sidecarNames()
    let invalidBytes = Data("not json at all".utf8)
    try! invalidBytes.write(to: corruptURL)
    let corruptStore = Store(source: MockMessageSource(), fileURL: corruptURL)
    assert(corruptStore.todos.isEmpty && corruptStore.lastScan == .distantPast)
    assert(!FileManager.default.fileExists(atPath: corruptURL.path),
           "the bad file must be moved aside so a subsequent save() writes fresh, not mixed with the bad one")
    let firstSidecars = sidecarNames().subtracting(sidecarsBefore)
    assert(firstSidecars.count == 1, "one corrupt load must produce exactly one sidecar")
    let firstSidecar = corruptDir.appendingPathComponent(firstSidecars.first!)
    defer { try? FileManager.default.removeItem(at: firstSidecar) }
    assert(try! Data(contentsOf: firstSidecar) == invalidBytes,
           "the sidecar must hold exactly the bad bytes that were written")

    // A second, independent corrupt load must not clobber the first quarantine.
    try! invalidBytes.write(to: corruptURL)
    let secondCorruptStore = Store(source: MockMessageSource(), fileURL: corruptURL)
    assert(secondCorruptStore.todos.isEmpty)
    let secondSidecars = sidecarNames().subtracting(sidecarsBefore).subtracting(firstSidecars)
    assert(secondSidecars.count == 1, "a second corrupt load must produce its own new sidecar")
    let secondSidecar = corruptDir.appendingPathComponent(secondSidecars.first!)
    defer { try? FileManager.default.removeItem(at: secondSidecar) }
    assert(secondSidecar != firstSidecar, "two corrupt loads must not share a sidecar name")

    // The normal path is untouched: a valid state file loads its todos and leaves no
    // sidecar behind.
    let validURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-valid-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: validURL) }
    try! JSONEncoder().encode(CurrentState(schemaVersion: 1, todos: [existingOnly], lastScan: newDate,
                                            slackScanState: nil))
        .write(to: validURL, options: .atomic)
    let sidecarsBeforeValidLoad = sidecarNames()
    let validStore = Store(source: MockMessageSource(), fileURL: validURL)
    assert(validStore.todos == [existingOnly])
    assert(sidecarNames() == sidecarsBeforeValidLoad, "a valid load must not create a sidecar")

    final class ResettingEmptySource: MessageSource, @unchecked Sendable {
        var reset: (@MainActor @Sendable () -> Void)?

        func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
            await reset?()
            return []
        }

        func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
    }
    let refreshURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-reset-refresh-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: refreshURL) }
    let staleSource = ResettingEmptySource()
    let staleStore = Store(source: staleSource, fileURL: refreshURL)
    staleSource.reset = { staleStore.resetAll() }
    await staleStore.refresh()
    assert(staleStore.todos.isEmpty && staleStore.lastScan == .distantPast && staleStore.errorText == nil)
    print("demoStoreMerge: PASS")
}

/// The addressing filter refresh() applies before triage: what creates a task, what
/// does not, and that a conversation is kept or dropped whole.
func demoAddressingFilter() {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    func message(_ id: String, conversation: String = "", _ addressing: Set<Addressing>,
                 offset: TimeInterval = 0, isContext: Bool = false,
                 isCommitment: Bool = false) -> SlackMessage {
        SlackMessage(id: id, conversationID: conversation, sender: "sender", channel: "#channel",
                     text: "text", isContext: isContext, isFromUser: isCommitment,
                     isCommitment: isCommitment, date: now.addingTimeInterval(offset),
                     directlyAddressed: false, addressing: addressing, permalink: nil)
    }
    func kept(_ messages: [SlackMessage], ignoring ignored: Set<Addressing> = []) -> [String] {
        Store.addressed(messages, ignoring: ignored).map(\.id)
    }

    // Broadcast ownership now belongs to the model; Swift no longer silently drops it.
    assert(kept([message("broadcast", [.broadcast])]) == ["broadcast"])
    assert(kept([message("dm", [.directMessage])]) == ["dm"])

    // Empty means "nothing explicit points at me", not "not mine". "Team, please complete
    // the deployment doc" has no signal at all and must reach the model.
    assert(kept([message("unaddressed", [])]) == ["unaddressed"])
    assert(kept([message("commitment", [], isCommitment: true)],
                ignoring: Set(Addressing.allCases)) == ["commitment"],
           "a promise is not an addressing preference and cannot be switched off")

    // A source that never populates addressing at all still gets everything through,
    // which is the safe direction: a silently empty list is the worst failure here.
    assert(kept([message("a", conversation: "C", []), message("b", conversation: "C", [])]) == ["a", "b"])

    // Mixed conversation: one personal signal keeps the WHOLE exchange, because dropping
    // the broadcast half strips the context the follow-up needs.
    let mixed = [message("mixed/1", conversation: "C_MIXED", [.broadcast]),
                 message("mixed/2", conversation: "C_MIXED", [.mention], offset: 60)]
    assert(kept(mixed) == ["mixed/1", "mixed/2"])

    // Broadcast all the way down now reaches the model, which has the conversation context
    // needed to decide whether the room-wide request belongs to this reader.
    assert(kept([message("all/1", conversation: "C_ALL", [.broadcast]),
                 message("all/2", conversation: "C_ALL", [.broadcast], offset: 60)]) ==
           ["all/1", "all/2"])

    // Context is evidence only: it cannot rescue a conversation by itself, but every
    // context row tags along when a non-context message survives.
    let contextOnly = message("context-only", conversation: "C_CONTEXT", [.mention], isContext: true)
    assert(kept([contextOnly]).isEmpty)
    let pending = message("pending", conversation: "C_KEPT", [.broadcast])
    let context = message("context", conversation: "C_KEPT", [], offset: -60, isContext: true)
    assert(kept([context, pending]) == ["context", "pending"])

    // The weakest signal, and the preference that switches it off.
    assert(kept([message("named", [.nameMentioned])], ignoring: []) == ["named"])
    assert(kept([message("named", [.nameMentioned])], ignoring: [.nameMentioned]).isEmpty)

    // "Not this, not again": a dismissed conversation with nothing newer than the
    // dismissal (including a message landing at the exact dismissal instant) is dropped
    // whole. A dismissed conversation with a genuinely newer message comes back whole,
    // context included: that context is what makes the new message readable. A
    // conversation never dismissed is untouched.
    let dismissedAt = now.addingTimeInterval(30)
    let staysOut = message("stays-out", conversation: "C_STAYS_OUT", [.mention], offset: -60)
    let staysOutAtInstant = message("stays-out/instant", conversation: "C_STAYS_OUT", [.mention], offset: 30)
    let oldContext = message("has-news/context", conversation: "C_HAS_NEWS", [.mention], offset: -60, isContext: true)
    let genuinelyNew = message("has-news/new", conversation: "C_HAS_NEWS", [.mention], offset: 90)
    let untouchedConversation = message("untouched", conversation: "C_LIVE", [.mention])
    let dismissedInput = [staysOut, staysOutAtInstant, oldContext, genuinelyNew, untouchedConversation]
    let dismissedResult = Store.skippingDismissed(
        dismissedInput,
        dismissed: ["C_STAYS_OUT": dismissedAt, "C_HAS_NEWS": dismissedAt]
    )
    assert(Set(dismissedResult.map(\.id)) == ["has-news/context", "has-news/new", "untouched"],
           "a conversation with nothing newer than its dismissal must be dropped whole; one " +
           "with a genuinely newer message must come back whole, context included, got \(dismissedResult.map(\.id))")
    assert(Store.skippingDismissed(dismissedInput, dismissed: [:]) == dismissedInput,
           "no recorded dismissals must be a no-op")

    // Triage is not worth paying for again when nothing has been said since the existing
    // todo: a conversation whose newest candidate is at or before its todo's date is
    // dropped whole; one with real news, or with no existing todo at all, survives.
    func todo(_ id: String, conversation: String, date: Date) -> TodoItem {
        TodoItem(id: id, action: "Reply", priority: 2, reason: "r", sender: "sender", channel: nil,
                 date: date, permalink: nil, conversationID: conversation)
    }
    let nothingNewTodo = todo("existing-nothing-new", conversation: "C_NOTHING_NEW", date: now)
    let olderCandidate = message("nothing-new/older", conversation: "C_NOTHING_NEW", [.mention], offset: -60)
    let sameDateCandidate = message("nothing-new/same", conversation: "C_NOTHING_NEW", [.mention])
    let hasNewsTodo = todo("existing-has-news", conversation: "C_HAS_NEWS", date: now)
    let newerCandidate = message("has-news", conversation: "C_HAS_NEWS", [.mention], offset: 60)
    let noExistingTodoCandidate = message("no-existing-todo", conversation: "C_OTHER", [.mention])
    let accountedResult = Store.droppingAlreadyAccounted(
        [olderCandidate, sameDateCandidate, newerCandidate, noExistingTodoCandidate],
        existing: [nothingNewTodo, hasNewsTodo]
    )
    assert(Set(accountedResult.map(\.id)) == ["has-news", "no-existing-todo"],
           "a conversation with nothing newer than its existing todo must be dropped whole; " +
           "one with genuine news, and one with no existing todo, must survive, got \(accountedResult.map(\.id))")

    print("demoAddressingFilter: PASS")
}

/// A source with nothing to hand back, so the refresh paths can be exercised without
/// calling the on-device model.
private struct SilentSource: MessageSource {
    func unrepliedMessages(since: Date) async throws -> [SlackMessage] { [] }
    func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
}

/// A source that can only fail, for the failure backoff.
private final class RateLimitedSource: MessageSource, @unchecked Sendable {
    var attempts = 0

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        attempts += 1
        throw SlackSourceError.rateLimited(retryAfter: 60)
    }

    func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
}

/// A no-network stateful source for proving Store's Slack state round-trip.
private actor StatefulSilentSource: SlackScanStateSource {
    let connectionTime: Date
    private var state = SlackScanState()
    private var restoredState: SlackScanState?

    init(connectionTime: Date) { self.connectionTime = connectionTime }

    func restoreSlackScanState(_ state: SlackScanState) {
        self.state = state
        restoredState = state
    }

    func currentSlackScanState() -> SlackScanState { state }

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        if state.connectedAt == nil { state.connectedAt = connectionTime }
        state.conversations["C_STATE"] = SlackConversationCheckpoint(
            newestTS: "123.000001", settled: true
        )
        return []
    }

    func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }

    func restoredConnectionTime() -> Date? { restoredState?.connectedAt }
    func restoredCheckpoint() -> SlackConversationCheckpoint? {
        restoredState?.conversations["C_STATE"]
    }
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
    let connectionTime = Date(timeIntervalSinceReferenceDate: 123_456)
    let statefulSource = StatefulSilentSource(connectionTime: connectionTime)
    let store = Store(source: statefulSource, fileURL: tempURL)
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
    let stateData = try! Data(contentsOf: tempURL)
    let stateJSON = try! JSONSerialization.jsonObject(with: stateData) as! [String: Any]
    let persistedSlack = stateJSON["slackScanState"] as? [String: Any]
    assert(persistedSlack?["connectedAt"] != nil, "the connection floor must be in state.json")
    assert((persistedSlack?["conversations"] as? [String: Any])?["C_STATE"] != nil,
           "the conversation watermark must be in state.json")

    // Fresh: the same call again must not scan, so lastScan cannot move.
    await store.refreshIfStale()
    assert(store.lastScan == firstScan, "refreshIfStale must skip a scan under 30 seconds old")
    assert(Store.stalePeriod == 30)

    // And an explicit refresh() is never skipped, that is the Refresh button.
    await store.refresh()
    assert(store.lastScan > firstScan, "refresh() must always scan")

    // A new Store and source receive the exact floor and checkpoint before scanning.
    let relaunchedSource = StatefulSilentSource(connectionTime: .distantFuture)
    let relaunchedStore = Store(source: relaunchedSource, fileURL: tempURL)
    await relaunchedStore.refresh()
    let restoredConnectionTime = await relaunchedSource.restoredConnectionTime()
    let restoredCheckpoint = await relaunchedSource.restoredCheckpoint()
    assert(restoredConnectionTime == connectionTime)
    assert(restoredCheckpoint?.newestTS == "123.000001")

    // A failed refresh must not be retried on the next touch of the panel. The measured
    // bug: refreshes 15 seconds apart against a 5 minute preference, because lastScan never
    // moved and every panel touch therefore looked stale. lastScan must NOT move, it is the
    // since cursor, so the quiet period gets its own timestamp.
    let failureURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-backoff-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: failureURL) }
    let failing = RateLimitedSource()
    let failingStore = Store(source: failing, fileURL: failureURL)
    await failingStore.refresh()
    assert(failing.attempts == 1 && failingStore.errorText != nil)
    assert(failingStore.lastScan == .distantPast,
           "a failed refresh must not advance the since cursor")
    await failingStore.refreshIfStale()
    assert(failing.attempts == 1, "a failed refresh must back off, attempts \(failing.attempts)")
    await failingStore.refresh()
    assert(failing.attempts == 2, "the Refresh button must bypass the backoff")
    assert(Store.failureBackoff == 60)
    print("demoRefreshTimer: PASS")
}
