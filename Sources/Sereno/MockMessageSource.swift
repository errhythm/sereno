import Foundation

/// Stand-in for the real Slack client until the API token exists.
/// Returns a fixed set of believable unreplied messages so the UI and triage
/// can be built and demoed end to end. Swap this out for a SlackMessageSource
/// that calls conversations.history, nothing else changes.
struct MockMessageSource: MessageSource {
    /// ids the user has replied to since. Empty by default so existing behavior
    /// is unchanged; tests and demos set this to drive auto-complete.
    var repliedTo: Set<String> = []

    func repliedIDs(among ids: [String]) async throws -> Set<String> {
        repliedTo.intersection(ids)
    }

    func unrepliedMessages(since: Date) async throws -> [SlackMessage] {
        let now = Date()
        func ago(_ minutes: Int) -> Date { now.addingTimeInterval(Double(-minutes) * 60) }

        // `addressing` is populated so the real pipeline exercises the signal line and
        // ignoredSignals filtering, not only the asserts. A channel message the user was
        // @-mentioned in gets .mention, a DM gets .directMessage, the thread fixture gets
        // .threadParticipant, and the two channel messages aimed at nobody in particular
        // keep an EMPTY set so the "not addressed to me" path has real cases.
        let all: [SlackMessage] = [
            SlackMessage(id: "C_ENG/1001", conversationID: "C_ENG/1001", sender: "Ayesha Rahman", channel: "#engineering",
                text: "Can you approve the deploy PR before standup? It's blocking the release.",
                date: ago(18), directlyAddressed: true, addressing: [.mention], permalink: nil),
            SlackMessage(id: "D_TANVIR/1002", conversationID: "D_TANVIR/1002", sender: "Tanvir Ahmed", channel: nil,
                text: "hey, lunch today?", date: ago(35), directlyAddressed: true,
                addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "C_DESIGN/1003", conversationID: "C_DESIGN/1003", sender: "Nabila Karim", channel: "#design",
                text: "@you the new icons are in Figma, need your sign off by EOD",
                date: ago(52), directlyAddressed: true, addressing: [.mention], permalink: nil),
            SlackMessage(id: "C_RANDOM/1004", conversationID: "C_RANDOM/1004", sender: "Rifat", channel: "#random",
                text: "anyone else seeing the coffee machine broken lol", date: ago(90),
                directlyAddressed: false, addressing: [], permalink: nil),
            SlackMessage(id: "D_CEO/1005", conversationID: "D_CEO/1005", sender: "Sadia (CEO)", channel: nil,
                text: "Quick q, can you send me the Q3 numbers when you get a sec?",
                date: ago(120), directlyAddressed: true, addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "C_ENG/1006", conversationID: "C_ENG/1006", sender: "Karim", channel: "#engineering",
                text: "the staging build is green now, fyi", date: ago(200),
                directlyAddressed: false, addressing: [], permalink: nil),
            SlackMessage(id: "C_ENG/1007", conversationID: "C_ENG/1007", sender: "Sarah", channel: "#engineering",
                text: "Please review MR !41 before we merge: https://gitlab.com/gitlab-org/gitlab/-/merge_requests/41",
                date: ago(240), directlyAddressed: true, addressing: [.mention], permalink: nil),
            SlackMessage(id: "C_PRODUCT/1008", conversationID: "C_PRODUCT/1008", sender: "Omar", channel: "#product",
                text: "Can you update ticket ENG-204? https://linear.app/example/issue/ENG-204",
                date: ago(275), directlyAddressed: true, addressing: [.mention], permalink: nil),
            SlackMessage(id: "C_ENG/1009", conversationID: "C_ENG/1009", sender: "Leila", channel: "#engineering",
                text: "Please read the rollout notes before tomorrow's planning session. The migration changes the API contract and the rollback steps are documented. Flag anything unclear before the meeting.",
                date: ago(310), directlyAddressed: true, addressing: [.mention], permalink: nil),
            SlackMessage(id: "D_PAUL/1010", conversationID: "D_PAUL", sender: "Paul", channel: nil,
                text: "Hi", date: ago(40), directlyAddressed: true,
                addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "D_PAUL/1011", conversationID: "D_PAUL", sender: "Paul", channel: nil,
                text: "make sure to review it within the next hour", date: ago(2), directlyAddressed: true,
                addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "D_LECOL_ASK/1012", conversationID: "D_LECOL_ASK", sender: "Marta", channel: nil,
                text: "please review MR !88", date: ago(45), directlyAddressed: true,
                addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "D_LECOL_ASK/1013", conversationID: "D_LECOL_ASK", sender: "Marta", channel: nil,
                text: "also can you reply to Lecol about the invoice", date: ago(3), directlyAddressed: true,
                addressing: [.directMessage], permalink: nil),
            SlackMessage(id: "C_ENG_THREAD/1014", conversationID: "C_ENG_THREAD", sender: "Imran", channel: "#engineering",
                text: "Could you review the deployment checklist?", date: ago(70), directlyAddressed: true,
                addressing: [.threadParticipant], permalink: nil),
            SlackMessage(id: "C_ENG_THREAD/1015", conversationID: "C_ENG_THREAD", sender: "Imran", channel: "#engineering",
                text: "Just a nudge on the deployment checklist.", date: ago(30), directlyAddressed: true,
                addressing: [.threadParticipant], permalink: nil),
            SlackMessage(id: "C_ENG_THREAD/1016", conversationID: "C_ENG_THREAD", sender: "Imran", channel: "#engineering",
                text: "Please review that checklist before we proceed.", date: ago(1), directlyAddressed: true,
                addressing: [.threadParticipant], permalink: nil),
            // Broadcast only, so the default-off @channel rule has something to act on:
            // with countBroadcast off this conversation reaches the model with no signal
            // line at all, and turning the preference on is what makes one appear.
            SlackMessage(id: "C_GENERAL/1017", conversationID: "C_GENERAL/1017", sender: "Farhan", channel: "#general",
                text: "@here heads up, the office wifi goes down for maintenance over the weekend",
                date: ago(150), directlyAddressed: false, addressing: [.broadcast], permalink: nil),
        ]
        // The contract on MessageSource (Models.swift) is that `since` selects
        // CONVERSATIONS, not messages: a conversation with any message newer than `since`
        // comes back WHOLE. Filtering per message stripped D_PAUL's "Hi" on every refresh
        // after the first, leaving the model to judge "review it within the next hour"
        // with no antecedent for "it", which quietly defeats the escalation feature.
        //
        // The real Slack client owes the same two steps: find the conversations with
        // activity newer than `since`, then fetch each one's full unreplied context
        // (conversations.replies for a thread, conversations.history otherwise).
        func key(_ message: SlackMessage) -> String {
            message.conversationID.isEmpty ? message.id : message.conversationID
        }
        let active = Set(all.filter { $0.date > since }.map(key))
        return all.filter { active.contains(key($0)) }.sorted { $0.date > $1.date }
    }
}

func demoMockSource() async {
    let msgs = try! await MockMessageSource().unrepliedMessages(since: .distantPast)
    assert(msgs.count == 17, "expected 17 mock messages, got \(msgs.count)")
    assert(msgs.first!.date > msgs.last!.date, "mock messages must be newest first")
    let old = try! await MockMessageSource().unrepliedMessages(since: Date().addingTimeInterval(-60 * 60))
    assert(old.count < msgs.count, "since filter should drop the oldest messages")

    // `since` selects conversations, not messages. D_PAUL's "Hi" is 40 minutes old and its
    // follow-up is 2 minutes old, so a cutoff between them must still return BOTH: handing
    // triage only the follow-up leaves "review it within the next hour" with no antecedent.
    let midConversation = try! await MockMessageSource()
        .unrepliedMessages(since: Date().addingTimeInterval(-20 * 60))
    let paul = midConversation.filter { $0.conversationID == "D_PAUL" }
    assert(paul.count == 2, "a conversation with new activity must come back whole, got \(paul.count) of D_PAUL")
    assert(Set(paul.map(\.id)) == ["D_PAUL/1010", "D_PAUL/1011"])
    assert(midConversation.filter { $0.conversationID == "C_ENG_THREAD" }.count == 3,
           "the thread fixture must come back whole too")
    assert(!midConversation.contains { $0.conversationID == "C_ENG/1006" },
           "a conversation with no new activity stays out")
    assert(midConversation == midConversation.sorted { $0.date > $1.date }, "still newest first overall")
    assert(msgs.filter { $0.conversationID == "D_PAUL" }.count == 2)
    assert(msgs.filter { $0.conversationID == "D_LECOL_ASK" }.count == 2)
    assert(msgs.filter { $0.conversationID == "C_ENG_THREAD" }.count == 3)

    // Addressing is populated for real, not only in asserts. The ids demoAutoComplete
    // pins must keep existing.
    func signals(_ id: String) -> Set<Addressing> { msgs.first { $0.id == id }!.addressing }
    assert(signals("C_ENG/1001") == [.mention])
    assert(signals("D_TANVIR/1002") == [.directMessage])
    assert(signals("C_DESIGN/1003") == [.mention])
    assert(signals("C_ENG_THREAD/1016") == [.threadParticipant])
    assert(signals("C_GENERAL/1017") == [.broadcast], "the default-off broadcast rule needs a case")
    assert(msgs.contains { $0.addressing.isEmpty && $0.channel != nil },
           "one channel fixture must stay unaddressed so the not-for-me path is exercised")
    assert(msgs.allSatisfy { $0.channel != nil || $0.addressing.contains(.directMessage) },
           "every DM fixture carries .directMessage")
    print("demoMockSource: PASS (\(msgs.count) messages)")
}

/// Proves Store.refresh() auto-completes todos the user has since replied to,
/// leaves unreplied ones alone, and doesn't touch already-done ones.
/// Uses a throwaway state file so this never touches the real app's saved todos.
@MainActor
func demoAutoComplete() async {
    let tempURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-demo-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let store = Store(source: MockMessageSource(), fileURL: tempURL)
    await store.refresh() // populates the fixture todos, all not done

    // Pick three of the fixed mock ids to play the three roles.
    let repliedID = "C_ENG/1001"
    let unrepliedID = "D_TANVIR/1002"
    let alreadyDoneID = "C_DESIGN/1003"
    store.toggleDone(store.todos.first { $0.id == alreadyDoneID }!)

    var source = MockMessageSource()
    source.repliedTo = [repliedID]
    let store2 = Store(source: source, fileURL: tempURL)
    await store2.refresh()

    func item(_ id: String) -> TodoItem { store2.todos.first { $0.id == id }! }
    assert(item(repliedID).done, "replied-to todo should auto-complete")
    assert(!item(unrepliedID).done, "unreplied todo should stay open")
    assert(item(alreadyDoneID).done, "already-done todo should stay done")
    print("demoAutoComplete: PASS")
}
