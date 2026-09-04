import Foundation
import os

/// Opt-in, on-disk record of real triage cases, so a failure the user reports can be
/// replayed against the actual conversation instead of a fixture invented after the fact.
///
/// **Privacy, read this before changing anything here.** This is the one place in Sereno
/// that writes Slack message text to disk in plain text, which is otherwise avoided
/// everywhere (on-device inference, `privacy: .private` log interpolations, message text
/// never logged). It exists only because `Preferences.debugCaptureEnabled` is explicitly
/// opted into, default OFF. No function in this file makes a network call, and none may
/// ever be added. Nothing here should call `Logger` with message text or file contents at
/// any privacy level; counts and byte sizes are fine at `.public`.
///
/// ## Record shape (JSON Lines, one `Record` per line, documented for a replay harness)
///
/// Each line is one conversation from one refresh: the messages exactly as `Triage.items`
/// received them, and the to-do(s) it produced (empty when the model declined the
/// conversation or fell back). `Todo.priority` is Swift's mapped 1...5 rank; the model's
/// semantic `category` label that produced it is not carried on `TodoItem` and so is not
/// reachable from `Store` — not captured here, `Todo.reason` is the closest available
/// explanation. `fellBack` is true when Triage could not identify a specific action
/// (mirrors `TodoItem.reason.hasPrefix("Fallback")`, the same convention `Store.merged`
/// relies on).
///
/// To rebuild the exact `SlackMessage` a captured `Message` came from for replay:
/// ```
/// SlackMessage(id: m.id, conversationID: m.conversationID, sender: m.sender,
///              channel: m.channel, text: m.text, isContext: m.isContext,
///              isFromUser: m.isFromUser, isCommitment: m.isCommitment, date: m.date,
///              directlyAddressed: m.directlyAddressed, addressing: m.addressing,
///              permalink: m.permalink)
/// ```
/// Then `Triage.items(from: messages)` reproduces the run. `DebugCapture.readAll(from:)`
/// decodes a captured file back into `[Record]` directly.
enum DebugCapture {
    private static let log = Logger(subsystem: "com.rhystart.sereno", category: "debugCapture")

    /// Bounded so leaving capture on for a month cannot fill a disk. 500 records: a handful
    /// of conversations per refresh, refreshed every few minutes, is comfortably more than a
    /// week of active use, and each record is a few hundred bytes to low kilobytes, so the
    /// file stays small even at the cap. Oldest records are dropped first, see `append`.
    static let maxRecords = 500

    static func fileName() -> String { "debug-captures.jsonl" }

    /// A message exactly as `Triage.items` received it. Mirrors `SlackMessage`'s fields
    /// (minus `avatarURL`, which triage never reads) so a harness can reconstruct one.
    struct Message: Codable, Sendable, Equatable {
        let id: String
        let conversationID: String
        let sender: String
        let channel: String?
        let text: String
        let isContext: Bool
        let isFromUser: Bool
        let isCommitment: Bool
        let date: Date
        let directlyAddressed: Bool
        let addressing: Set<Addressing>
        let permalink: URL?

        init(_ message: SlackMessage) {
            id = message.id
            conversationID = message.conversationID
            sender = message.sender
            channel = message.channel
            text = message.text
            isContext = message.isContext
            isFromUser = message.isFromUser
            isCommitment = message.isCommitment
            date = message.date
            directlyAddressed = message.directlyAddressed
            addressing = message.addressing
            permalink = message.permalink
        }
    }

    /// One to-do triage produced for the conversation. A conversation can produce zero
    /// (the model declined it, or every candidate was rejected) or two (the stage-2 split).
    struct Todo: Codable, Sendable, Equatable {
        let action: String
        let priority: Int
        let reason: String

        init(_ todo: TodoItem) {
            action = todo.action
            priority = todo.priority
            reason = todo.reason
        }
    }

    /// One conversation from one refresh.
    struct Record: Codable, Sendable, Equatable {
        var schemaVersion = 1
        let capturedAt: Date
        let conversationID: String
        let messages: [Message]
        let todos: [Todo]
        let fellBack: Bool

        init(capturedAt: Date, conversationID: String, messages: [Message], todos: [Todo]) {
            self.capturedAt = capturedAt
            self.conversationID = conversationID
            self.messages = messages
            self.todos = todos
            self.fellBack = todos.contains { $0.reason.hasPrefix("Fallback") }
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Pairs the messages `Triage.items` was handed with the to-dos it produced, one
    /// `Record` per conversation, in first-seen order. Uses the same grouping rule as
    /// `Store.conversationKey` and `Triage.grouped`: conversationID, falling back to the
    /// message id when a source leaves it empty. A conversation present in `messages` but
    /// absent from `todos` still gets a record, with an empty `todos` array — that is
    /// itself useful signal (the model declined it, or every candidate was rejected).
    static func records(
        messages: [SlackMessage],
        todos: [TodoItem],
        capturedAt: Date = Date()
    ) -> [Record] {
        func key(_ message: SlackMessage) -> String {
            message.conversationID.isEmpty ? message.id : message.conversationID
        }
        var order: [String] = []
        var grouped: [String: [SlackMessage]] = [:]
        for message in messages {
            let conversationKey = key(message)
            if grouped[conversationKey] == nil { order.append(conversationKey) }
            grouped[conversationKey, default: []].append(message)
        }
        var todosByConversation: [String: [TodoItem]] = [:]
        for todo in todos {
            todosByConversation[todo.conversationID, default: []].append(todo)
        }
        return order.map { conversationKey in
            Record(
                capturedAt: capturedAt,
                conversationID: conversationKey,
                messages: (grouped[conversationKey] ?? []).map(Message.init),
                todos: (todosByConversation[conversationKey] ?? []).map(Todo.init)
            )
        }
    }

    /// Appends each record as one JSON line, then trims the file to the newest
    /// `maxRecords` lines, oldest first dropped. A no-op when `records` is empty, so a
    /// quiet refresh never touches the file. Best-effort: a write failure is logged
    /// (counts only) and swallowed, the same way a save() failure never blocks Store.
    static func append(_ records: [Record], to fileURL: URL, maxRecords: Int = DebugCapture.maxRecords) {
        guard !records.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = encoder()
            var lines: [String] = []
            if let existing = try? String(contentsOf: fileURL, encoding: .utf8) {
                lines = existing.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            }
            for record in records {
                let data = try encoder.encode(record)
                guard let line = String(data: data, encoding: .utf8) else { continue }
                lines.append(line)
            }
            if lines.count > maxRecords {
                lines.removeFirst(lines.count - maxRecords)
            }
            try (lines.joined(separator: "\n") + "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
            log.error("debug capture write failed records=\(records.count, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
        }
    }

    /// Decodes a capture file back into records, for the demo below and for a replay
    /// harness that would rather link this file than reimplement the JSONL shape.
    static func readAll(from fileURL: URL) throws -> [Record] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        let decoder = decoder()
        return try String(data: data, encoding: .utf8)?
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { try decoder.decode(Record.self, from: Data($0.utf8)) } ?? []
    }

    /// The one-action delete Settings offers. Deleting a file that was never written is
    /// not an error, so this stays silent either way; a genuine failure only means "try
    /// again", it does not risk the user's todo list the way Store's own saves do.
    static func delete(at fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// For the Settings row: a size to show, or nil when nothing has been captured yet.
    static func fileSizeBytes(at fileURL: URL) -> Int? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        return attributes[.size] as? Int
    }
}

@MainActor
func demoDebugCapture() async {
    let now = Date(timeIntervalSinceReferenceDate: 0)
    let contextMessage = SlackMessage(
        id: "m0", conversationID: "conv1", sender: "Sam", channel: "#eng",
        text: "we're shipping the deployment doc today", date: now.addingTimeInterval(-60),
        directlyAddressed: false, permalink: nil
    )
    let askMessage = SlackMessage(
        id: "m1", conversationID: "conv1", sender: "Sam", channel: "#eng",
        text: "can you help me?", date: now, directlyAddressed: true,
        addressing: [.directMessage], permalink: URL(string: "https://slack.example/m1")
    )
    let danglingMessage = SlackMessage(
        id: "m2", conversationID: "conv2", sender: "Ali", channel: nil,
        text: "fyi the build is green", date: now, directlyAddressed: false, permalink: nil
    )
    let todo = TodoItem(
        id: "conv1", action: "Reply to help request", priority: 1, reason: "Sam asked for help.",
        sender: "Sam", channel: "#eng", date: now, permalink: askMessage.permalink, conversationID: "conv1"
    )

    // records(): one per conversation, in first-seen order; a conversation with no
    // resulting to-do (the model declined it) still gets a record with an empty array.
    let records = DebugCapture.records(
        messages: [contextMessage, askMessage, danglingMessage], todos: [todo], capturedAt: now
    )
    assert(records.map(\.conversationID) == ["conv1", "conv2"], "one record per conversation, in first-seen order")
    let conv1 = records[0]
    assert(conv1.messages.map(\.id) == ["m0", "m1"], "a conversation's record carries every message triage saw")
    assert(conv1.todos.map(\.action) == ["Reply to help request"])
    assert(!conv1.fellBack)
    assert(records[1].todos.isEmpty, "a conversation the model produced nothing for still gets a record")

    let fallbackTodo = TodoItem(
        id: "conv2", action: "Review message", priority: 3,
        reason: "Fallback: Apple Intelligence could not identify a specific action.",
        sender: "Ali", channel: nil, date: now, permalink: nil, conversationID: "conv2"
    )
    let fallbackRecord = DebugCapture.records(messages: [danglingMessage], todos: [fallbackTodo], capturedAt: now)[0]
    assert(fallbackRecord.fellBack, "a fallback to-do must be flagged so a harness can filter it out")

    // Round trip through the JSONL file: what comes back must equal what went in, and a
    // captured message must rebuild the exact SlackMessage triage was handed.
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-debugcapture-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    DebugCapture.append(records, to: tempURL)
    let decoded = try! DebugCapture.readAll(from: tempURL)
    assert(decoded == records, "JSONL round trip must reproduce the records exactly")

    let capturedAsk = conv1.messages[1]
    let rebuilt = SlackMessage(
        id: capturedAsk.id, conversationID: capturedAsk.conversationID, sender: capturedAsk.sender,
        channel: capturedAsk.channel, text: capturedAsk.text, isContext: capturedAsk.isContext,
        isFromUser: capturedAsk.isFromUser, isCommitment: capturedAsk.isCommitment, date: capturedAsk.date,
        directlyAddressed: capturedAsk.directlyAddressed, addressing: capturedAsk.addressing,
        permalink: capturedAsk.permalink
    )
    assert(rebuilt == askMessage, "a captured message must rebuild the exact SlackMessage triage saw")

    // The cap drops the OLDEST records first and keeps the file bounded no matter how
    // long capture stays on.
    let capURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-debugcapture-cap-\(UUID().uuidString).jsonl")
    defer { try? FileManager.default.removeItem(at: capURL) }
    for index in 0..<5 {
        let record = DebugCapture.Record(
            capturedAt: now.addingTimeInterval(Double(index)), conversationID: "c\(index)", messages: [], todos: []
        )
        DebugCapture.append([record], to: capURL, maxRecords: 3)
    }
    let capped = try! DebugCapture.readAll(from: capURL)
    assert(capped.map(\.conversationID) == ["c2", "c3", "c4"],
           "the cap must keep only the newest records, dropping the oldest first, got \(capped.map(\.conversationID))")

    // Delete removes the file outright, and is a harmless no-op run again on nothing.
    assert(FileManager.default.fileExists(atPath: capURL.path))
    DebugCapture.delete(at: capURL)
    assert(!FileManager.default.fileExists(atPath: capURL.path))
    DebugCapture.delete(at: capURL)
    assert(DebugCapture.fileSizeBytes(at: capURL) == nil, "no file means no size to show in Settings")

    // Store-level gating: OFF (the default) must not create a byte of the file, even
    // across a real refresh(); ON must write it; deleting it must leave OFF's guarantee
    // intact; and Store.resetAll() must clear it the same way it clears state.json.
    struct OneMessageSource: MessageSource {
        let message: SlackMessage
        func unrepliedMessages(since: Date) async throws -> [SlackMessage] { [message] }
        func repliedIDs(among ids: [String]) async throws -> Set<String> { [] }
    }
    let prefs = Preferences.shared
    let originalCaptureSetting = prefs.debugCaptureEnabled
    defer { prefs.debugCaptureEnabled = originalCaptureSetting }

    let stateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-debugcapture-store-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: stateURL) }
    let debugURL = Store.debugCaptureFileURL(stateFileURL: stateURL)
    defer { try? FileManager.default.removeItem(at: debugURL) }
    let source = OneMessageSource(message: SlackMessage(
        id: "gate1", conversationID: "gate1", sender: "Robin", channel: nil,
        text: "can you review the API doc today?", date: Date(), directlyAddressed: true,
        addressing: [.directMessage], permalink: nil
    ))

    prefs.debugCaptureEnabled = false
    let offStore = Store(source: source, fileURL: stateURL)
    await offStore.refresh()
    assert(!FileManager.default.fileExists(atPath: debugURL.path),
           "a user who never opts in must never have a byte of message text written")

    // Turning capture on AFTER offStore's conversation already produced a to-do: the next
    // refresh finds nothing new to triage at all (Store.droppingAlreadyAccounted keeps
    // triage from re-running over settled work, a real property landed alongside this
    // feature), so there is nothing to capture either. This must produce no file, not an
    // empty one — records(...) returning [] and append's own empty-guard both have to
    // hold for this to be true, and that interaction is worth pinning directly.
    prefs.debugCaptureEnabled = true
    await offStore.refresh()
    assert(!FileManager.default.fileExists(atPath: debugURL.path),
           "a refresh with nothing new to triage must not create an empty capture file")

    // A genuinely new conversation, on a fresh Store so droppingAlreadyAccounted has no
    // earlier to-do to compare the candidate against.
    let enabledStateURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-debugcapture-store-enabled-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: enabledStateURL) }
    let enabledDebugURL = Store.debugCaptureFileURL(stateFileURL: enabledStateURL)
    defer { try? FileManager.default.removeItem(at: enabledDebugURL) }
    let enabledStore = Store(source: source, fileURL: enabledStateURL)
    await enabledStore.refresh()
    assert(FileManager.default.fileExists(atPath: enabledDebugURL.path), "opting in must produce the capture file")
    let stored = try! DebugCapture.readAll(from: enabledDebugURL)
    assert(!stored.isEmpty && stored.allSatisfy { !$0.messages.isEmpty },
           "a captured record must carry the messages triage actually saw")

    enabledStore.deleteDebugCapture()
    assert(!FileManager.default.fileExists(atPath: enabledDebugURL.path),
           "the Settings delete button must remove the file")

    // Reset Sereno must clear captured debug data the same way it clears state.json.
    // Written directly rather than via another refresh, since resetAll()'s cleanup does
    // not care how the file came to exist.
    DebugCapture.append(
        [DebugCapture.Record(capturedAt: Date(), conversationID: "reset-check", messages: [], todos: [])],
        to: enabledDebugURL
    )
    assert(FileManager.default.fileExists(atPath: enabledDebugURL.path))
    enabledStore.resetAll()
    assert(!FileManager.default.fileExists(atPath: enabledDebugURL.path),
           "Reset Sereno must clear captured debug data the same way it clears state.json")

    print("demoDebugCapture: PASS")
}
