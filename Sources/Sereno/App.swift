import SwiftUI
import AppKit
import Carbon.HIToolbox
import Observation
import UserNotifications

/// Pointing-hand cursor on hover. `.pointerStyle(.link)` is the modern SwiftUI
/// equivalent of NSCursor.pointingHand.set(), confirmed present in the macOS 26
/// SDK (macOS 15.0+). Factored out so every clickable control picks it up the
/// same way instead of repeating onContinuousHover per control.
private extension View {
    func pointerCursor() -> some View { pointerStyle(.link) }
}

/// The floating window's scene id, shared by the scene, the header button and the
/// Window menu command.
let serenoWindowID = "sereno-panel"

@main
struct SerenoApp: App {
    @State private var store: Store

    init() {
        GlobalHotkey.install()
        // LiveMessageSource asks the Keychain on every call, so connecting or
        // disconnecting Slack takes effect on the next refresh instead of the next launch.
        let store = Store(source: LiveMessageSource())
        _store = State(initialValue: store)
        Notify.start(store)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(store: store)
        } label: {
            MenuBarLabel(count: store.todos.filter { !$0.done && !$0.isSnoozed }.count)
        }
        .menuBarExtraStyle(.window)
        // No .defaultSize here. Apple documents it for WindowGroup, Window, DocumentGroup
        // and Settings, and MenuBarExtra is not on that list: it compiles, because
        // defaultSize is a Scene modifier, and does nothing. The popover's size comes from
        // MenuContent's own .frame(width: 360) and .frame(maxHeight: 400).

        // The same panel, as its own floating window. Chromeless and transparent, so the
        // content draws the card, and never fullscreen: this is a 380pt utility panel,
        // and a fullscreen one would be absurd.
        Window("Sereno", id: serenoWindowID) {
            MenuContent(store: store, windowed: true)
                .windowFullScreenBehavior(.disabled)
        }
        .windowStyle(.plain)
        .windowResizability(.contentSize)
        // No .windowLevel(.floating) here. It takes a value, not a binding, so it cannot
        // express the windowAlwaysOnTop preference, and measured on this SDK it re-asserts
        // its own level over the runtime one, which would silently undo the toggle being
        // switched off. Foreground.applyWindowTraits owns the level instead, on its own.
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 380, height: 600)
        .commands {
            // Also reachable from the menu bar the app grows while a window is up, so the
            // shortcut is not only live while the popover has focus.
            CommandGroup(after: .newItem) { OpenWindowItem() }
        }

        // A real Preferences window, and Cmd+, comes with it.
        Settings {
            SettingsForm()
        }
    }
}

/// A menu item, so it needs its own view to reach openWindow from the environment.
private struct OpenWindowItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Sereno Window") {
            Foreground.present(serenoWindowID) { openWindow(id: serenoWindowID) }
        }
            .keyboardShortcut("o", modifiers: [.command, .shift])
    }
}

/// LSUIElement makes this an accessory app, and an accessory app is not permitted to own
/// the foreground: a window it opens lands behind whatever was frontmost. That is the bug
/// the user hit with Settings, and the floating window would hit it too.
///
/// Being .regular for as long as a real window is up is what lets one come forward. Going
/// back to .accessory when the last one closes keeps a Dock icon from outliving it, so the
/// app is menu-bar-only again the moment the window goes away.
@MainActor
enum Foreground {
    /// Identified by the identifier SwiftUI stamps on each scene's window, not by class or
    /// by level. Measured on this SDK: the Settings scene's window is
    /// com_apple_SwiftUI_Settings_window and a Window scene's is its own scene id, while
    /// the menu bar popover has no identifier at all. That is what keeps the popover out of
    /// here. It is not a window anyone opened, so it must neither be ordered around nor
    /// hold the app in .regular.
    static let settingsID = "com_apple_SwiftUI_Settings_window"
    private static let managed: Set<String> = [settingsID, serenoWindowID]

    static var windows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && managed.contains($0.identifier?.rawValue ?? "") }
    }

    /// Runs `open`, then puts the window it opened in front.
    static func present(_ id: String, _ open: () -> Void) {
        // Before, not after: an accessory app cannot be activated, so the policy has to
        // change first or the activation is dropped on the floor.
        NSApp.setActivationPolicy(.regular)
        open()
        watch()

        // SwiftUI has not necessarily built the window by the time `open` returns, and the
        // policy change needs a pass of its own before activation takes, so both happen on
        // the next main queue turn.
        DispatchQueue.main.async {
            NSApp.activate()
            guard let window = windows.first(where: { $0.identifier?.rawValue == id }) else { return }
            window.makeKeyAndOrderFront(nil)
            // An app that was accessory a moment ago can still be refused key status.
            // orderFrontRegardless is the one call that ignores activation state.
            window.orderFrontRegardless()
        }
    }

    /// Everything about the floating window that only AppKit can say, applied to the live
    /// NSWindow found by scene identifier. Runs on every presentation of the windowed panel,
    /// so a window closed and reopened comes back with all of it, and on every flip of the
    /// always-on-top preference.
    ///
    /// Level: `.windowLevel` takes a value, not a binding, so the scene modifier could only
    /// decide the level the window opens at. Flipping the preference has to reach the live
    /// NSWindow, or it would not take until the next launch.
    ///
    /// Movability: `.windowBackgroundDragBehavior(.enabled)` does NOT set
    /// `isMovableByWindowBackground`. Measured on this SDK, a `.plain` Window scene carrying
    /// that modifier reads `isMovable: true`, `isMovableByWindowBackground: false`,
    /// `styleMask raw: 0`. So the AppKit mechanism that drags a window by its body was never
    /// armed, which is why the user could not move the window. Do not drop this line and
    /// assume the scene modifier covers it.
    ///
    /// Resizable: `styleMask raw: 0` is borderless with no `.resizable`, so despite
    /// `.windowResizability(.contentSize)` and a live `minSize` of 324x404 the window had no
    /// resize affordance at all. Inserting `.resizable` is what makes the stated 300x380
    /// minimum reachable.
    static func applyWindowTraits() {
        guard let window = NSApp.windows.first(where: {
            $0.identifier?.rawValue == serenoWindowID
        }) else { return }
        window.level = Preferences.shared.windowAlwaysOnTop ? .floating : .normal
        window.isMovableByWindowBackground = true
        window.styleMask.insert(.resizable)
    }

    /// The live menu bar popover, handed over by the WindowReader the popover's own content
    /// carries. Weak, so a popover window that has gone does not linger here, and re-read on
    /// every presentation because MenuBarExtra builds a fresh window each time it opens.
    private(set) static weak var popover: NSWindow?

    /// Ignores anything that carries a scene identifier. Nothing should reach here but the
    /// popover, and mistaking the floating window for the popover would order out the window
    /// the button just opened.
    static func capture(_ window: NSWindow?) {
        guard let window, window.identifier == nil else { return }
        popover = window
    }

    /// Closes the menu bar popover, so opening the window does not leave two copies of the
    /// same list on screen.
    ///
    /// The popover's real identity, probed with it actually open: class
    /// _TtGC7SwiftUI18MenuBarExtraWindowVS_7AnyView_, identifier nil, level 101, which is
    /// `.popUpMenu`, 360x323 under the status item. So the old level-and-nil-identifier
    /// guess did match in that probe, but the class had come back as SPRoundedWindow in an
    /// earlier one, and an attribute guess that misses matches nothing and fails silently,
    /// which is the symptom the user reported twice. The reference the content hands over
    /// is the same window by identity and cannot miss, so it leads and the guess is only
    /// the fallback for a nil reference.
    ///
    /// Ordered out rather than dismissed because MenuBarExtra's popover has no API to close
    /// itself. The caller still sends `dismiss()` first so SwiftUI updates its own state.
    static func closePopover() {
        DispatchQueue.main.async {
            if let popover {
                if popover.isVisible { popover.orderOut(nil) }
                return
            }
            for window in NSApp.windows
            where window.isVisible && window.level == .popUpMenu && window.identifier == nil {
                window.orderOut(nil)
            }
        }
    }

    private static var watching = false

    /// One observer for the process, not one per window: the policy has to revert when the
    /// LAST window goes. willClose fires before the window drops out of NSApp.windows,
    /// hence comparing against the closing one by identity.
    private static func watch() {
        guard !watching else { return }
        watching = true
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { note in
            // Identity only, not the window: NSWindow is not Sendable, and an
            // ObjectIdentifier crosses into the main actor without a data race.
            let closing = (note.object as? NSWindow).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard windows.allSatisfy({ ObjectIdentifier($0) == closing }) else { return }
                NSApp.setActivationPolicy(.accessory)
            }
        }
    }
}

/// Hands back the NSWindow hosting this view. The one way to know the popover's window for
/// certain instead of guessing it out of NSApp.windows by class or level.
///
/// Both calls hop to the next main queue turn: `view.window` is nil until the view is in a
/// window's hierarchy, which it is not yet inside makeNSView.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

/// SwiftUI puts a Settings item in the app menu for the Settings scene, even in an
/// accessory app with no visible menu bar, and performing it is what opens the window.
/// Found by its Cmd+, key equivalent, since the title is localized.
///
/// Not NSApp.sendAction(showSettingsWindow:): measured on this SDK it returns true and
/// opens nothing, which is the silently dead button.
@MainActor
private func openSettings() {
    Foreground.present(Foreground.settingsID) {
        guard let appMenu = NSApp.mainMenu?.items.first?.submenu,
              let index = appMenu.items.firstIndex(where: {
                  $0.keyEquivalent == "," && $0.keyEquivalentModifierMask == .command
              })
        else { return }
        appMenu.performActionForItem(at: index)
    }
}

/// "1 hour", "3 hours".
private func plural(_ count: Int, _ unit: String) -> String {
    "\(count) \(unit)\(count == 1 ? "" : "s")"
}

/// An hour of the day written the way the user's locale writes it, "9 AM" or "09".
private func hourLabel(_ hour: Int) -> String {
    let base = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: Date()) ?? Date()
    return base.formatted(.dateTime.hour())
}

/// One pane. There are eight settings, which is not a tab bar's worth.
@MainActor
private struct SettingsForm: View {
    @Bindable private var prefs = Preferences.shared
    /// Not @Bindable and not @State: an @Observable read during body is tracked either way,
    /// and this one is a shared controller the whole app signs in through, not view state.
    private let slack = SlackAuth.shared
    @State private var resolving = false
    /// What the last Resolve did, in one line. Success names the place Open-Meteo picked,
    /// which is the only way to tell the right Springfield from the wrong one.
    @State private var resolveNote: String?

    /// The stored value is always in the list, so a value set outside these choices
    /// (or clamped to 240) shows itself instead of leaving the picker blank.
    private var refreshChoices: [Int] { Array(Set([1, 5, 15, 30, 60, prefs.refreshMinutes])).sorted() }
    private var morningChoices: [Int] { Array(Set(Array(5...11) + [prefs.morningHour])).sorted() }

    var body: some View {
        Form {
            Section {
                slackControls
            } header: {
                Text("Slack")
            } footer: {
                Text("Connecting grants Sereno read-only access to the messages you can already see. The token is kept in your Keychain, never in a file or a preference, and nothing is sent anywhere except Slack itself.")
            }

            Section {
                TextField("Your role", text: $prefs.role,
                          prompt: Text("backend engineer, I own deployments and the public API"),
                          axis: .vertical)
                    .lineLimit(3...5)
            } header: {
                Text("About you")
            } footer: {
                Text("Used to judge whether an unaddressed channel message like \"Team, please complete the deployment doc\" is yours to act on. Leave it empty and only the explicit signals count.")
            }

            Section {
                Picker("Check for new work", selection: $prefs.refreshMinutes) {
                    ForEach(refreshChoices, id: \.self) { Text(plural($0, "minute")).tag($0) }
                }
            } header: {
                Text("Checking for work")
            } footer: {
                Text("The menu bar count is only as current as this.")
            }

            Section {
                Toggle("My name in the text", isOn: $prefs.countNameMentions)
                Toggle("@channel and @here", isOn: $prefs.countBroadcast)
            } header: {
                Text("What counts as yours")
            } footer: {
                Text("Name matching goes wrong when your name is also an ordinary word. A broadcast is addressed to a room, not to you, which is why it is off. DMs, @mentions, replies to you and replies in your threads always count and cannot be switched off.")
            }

            Section {
                Stepper(value: $prefs.snoozeHours, in: 1...23) {
                    Text("Snooze for \(plural(prefs.snoozeHours, "hour"))")
                }
                Picker("Tomorrow morning is", selection: $prefs.morningHour) {
                    ForEach(morningChoices, id: \.self) { Text(hourLabel($0)).tag($0) }
                }
            } header: {
                Text("Snooze")
            } footer: {
                Text("Both of these name the panel's Snooze menu.")
            }

            Section {
                Toggle("New to-dos", isOn: $prefs.notifyNewItems)
                Toggle("Snooze running out", isOn: $prefs.notifySnoozeWake)
            } header: {
                Text("Notifications")
            } footer: {
                Text("New to-dos are batched into one notification per check, not one per item.")
            }

            Section {
                Toggle("Keep window above other apps", isOn: $prefs.windowAlwaysOnTop)
            } header: {
                Text("Window")
            } footer: {
                Text("Off lets other windows cover it, the way an ordinary window behaves. Takes effect straight away, on an open window too.")
            }

            Section {
                Toggle("Sky follows the weather", isOn: $prefs.weatherEnabled)
                HStack {
                    TextField("City", text: $prefs.weatherCity, prompt: Text("Dhaka"))
                        .onSubmit(resolve)
                    Button(resolving ? "Looking up" : "Look up", action: resolve)
                        .disabled(resolving || city.isEmpty)
                }
                if let resolveNote {
                    Text(resolveNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Weather")
            } footer: {
                Text("Off by default. With it on, the header sky shows rain, snow, fog, cloud or a storm instead of only the time of day. Looking up a city sends that city name to Open-Meteo, and each check afterwards sends its coordinates, at most once every 25 minutes. Nothing about your Slack ever leaves this machine, and if the lookup fails the sky just follows the clock.")
            }

            Section("Sereno") {
                LabeledContent("Open the panel from anywhere", value: "⌘⇧T")
                LabeledContent("Open Sereno in its own window", value: "⌘⇧O")
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
    }

    /// Three shapes, one per state. Nothing to configure: the client_id is compiled in, so
    /// Connect Slack is the whole of the setup.
    @ViewBuilder private var slackControls: some View {
        switch slack.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Slack in your browser…")
                Spacer()
                Button("Cancel") { slack.cancelConnect() }
                    .pointerCursor()
            }
            Text("Approve Sereno in the tab that just opened. Sereno stops waiting after a couple of minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .connected(let workspace, let userID):
            LabeledContent("Workspace", value: workspace ?? "Connected")
            LabeledContent("Your Slack ID", value: userID)
            Button("Disconnect") { slack.disconnect() }
                .pointerCursor()

        case .disconnected, .failed:
            Button("Connect Slack") {
                Task { await slack.connect() }
            }
            .pointerCursor()
            // Inline, in plain language, and never a crash: a denied sign-in, a state
            // mismatch, a busy port, a dead network and Slack's own ok:false all land here.
            if case .failed(let reason) = slack.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var city: String { prefs.weatherCity.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Geocodes once, here, and caches the coordinates. Nothing else in the app ever calls
    /// the geocoder, so a refresh cannot turn into two requests.
    private func resolve() {
        guard !city.isEmpty, !resolving else { return }
        resolving = true
        resolveNote = nil
        Task {
            if let place = await Weather.geocode(city) {
                prefs.weatherCity = place.name
                prefs.weatherLatitude = place.latitude
                prefs.weatherLongitude = place.longitude
                // Otherwise the old city's sky keeps drawing until its cache ages out.
                Weather.shared.invalidate()
                Weather.shared.refreshIfStale()
                resolveNote = "Using \(place.name)."
            } else {
                // The field already says the new city, so leaving the old coordinates in
                // place would draw one city's weather under another city's name.
                prefs.weatherLatitude = nil
                prefs.weatherLongitude = nil
                Weather.shared.invalidate()
                resolveNote = "Could not find that city. The sky will follow the time of day."
            }
            resolving = false
        }
    }
}

/// Cmd+Shift+T from any app opens the panel.
///
/// Carbon's RegisterEventHotKey, not NSEvent.addGlobalMonitorForEvents: the NSEvent
/// monitor only ever fires once the process holds Accessibility permission, so on a
/// fresh install it would ship silently dead. The Carbon hotkey table needs no such
/// permission. Verified on macOS 26.6: registration returns noErr and the handler
/// fires on a real Cmd+Shift+T while another app is frontmost.
///
/// MenuBarExtra still has no API to open its own window, so this finds the
/// NSStatusBarButton SwiftUI installed and clicks it, which does open the panel.
/// A second press now closes it, by ordering out the window Foreground captured from
/// inside the popover's content rather than by clicking the status item again, which
/// did not reliably toggle it shut.
@MainActor
enum GlobalHotkey {
    private static var ref: EventHotKeyRef?

    static func install() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        _ = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { GlobalHotkey.openPanel(toggle: true) }
            }
            return noErr
        }, 1, &spec, nil, nil)

        _ = RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(cmdKey | shiftKey),
                                EventHotKeyID(signature: OSType(0x53545247), id: 1),
                                GetApplicationEventTarget(), 0, &ref)
    }

    /// Also the notification-click path, see Notify.ClickHandler, which passes no toggle:
    /// clicking a notification should show the panel, never shut one already up.
    ///
    /// The click goes out either way, open or shut, because it is what keeps MenuBarExtra's
    /// own idea of being presented in step. Ordering the window out on its own leaves that
    /// flag set, and one probe run then spent the following press getting back in step
    /// instead of opening anything, so the press after a close looked dead. Clicking is
    /// also what dismisses when it works at all. The order-out is the cleanup for a click
    /// that did not take.
    /// ponytail: three presses alternated open, shut, open in the probe. If a press ever
    /// still looks dead, the flag is out of step and the next thing to try is dropping the
    /// order-out for this path.
    static func openPanel(toggle: Bool = false) {
        let up = Foreground.popover?.isVisible == true
        guard toggle || !up else { return }
        clickStatusItem()
        if up { Foreground.closePopover() }
    }

    private static func clickStatusItem() {
        // The button sits a couple of views down inside NSStatusBarWindow, so search
        // for it instead of relying on a fixed path that a macOS update can shift.
        func control(_ view: NSView) -> NSControl? {
            if let control = view as? NSControl { return control }
            for sub in view.subviews {
                if let found = control(sub) { return found }
            }
            return nil
        }
        for window in NSApp.windows where window.className.contains("NSStatusBarWindow") {
            if let root = window.contentView, let button = control(root) {
                button.performClick(nil)
                return
            }
        }
    }
}

/// Every notification the app posts goes through `post`, so muting the whole
/// feature later is one early return, not a hunt through the views.
///
/// Nothing is hooked into the mutating calls. One observation loop on
/// `store.todos` catches every change, including the daily background refresh
/// that happens with no window on screen, which is exactly when a notification
/// is worth anything.
///
/// UNUserNotificationCenter.current() traps in a process with no bundle
/// identifier, which is what a plain `swift build` binary is, so every entry
/// point goes through `center` and does nothing without a bundle. Run build.sh.
@MainActor
enum Notify {
    private static let clicks = ClickHandler()
    private static var granted: Bool?
    /// Item ids already announced, so a re-render never re-announces.
    private static var known: Set<String> = []
    /// Wake requests believed to be pending, keyed like their identifiers.
    private static var scheduled: Set<String> = []

    private static var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    static func start(_ store: Store) {
        guard let center else { return }
        center.delegate = clicks
        // A wake scheduled in an earlier run can outlive the item it belonged to,
        // so drop everything and re-schedule from what is actually snoozed now.
        center.removeAllPendingNotificationRequests()
        known = Set(store.todos.filter { !$0.isManual }.map(\.id))
        sync(store.todos)
        observe(store)
    }

    private static func observe(_ store: Store) {
        withObservationTracking {
            _ = store.todos
            // Tracked too, so switching wakes off cancels the pending requests then
            // and there, not at the next change to the list.
            _ = Preferences.shared.notifySnoozeWake
        } onChange: {
            // onChange fires before the new value lands, hence the hop. Re-arming
            // inside it keeps one live observation, not one per change.
            Task { @MainActor in
                sync(store.todos)
                observe(store)
            }
        }
    }

    private static func sync(_ items: [TodoItem]) {
        announce(items)
        scheduleWakes(items)
    }

    private static func announce(_ items: [TodoItem]) {
        let fresh = items.filter { !$0.isManual && !$0.done && !known.contains($0.id) }
        // Recorded even with notifications off, so switching them on later announces
        // what arrives next rather than the whole backlog.
        known = Set(items.filter { !$0.isManual }.map(\.id))
        guard Preferences.shared.notifyNewItems, let text = batch(fresh) else { return }
        post(id: UUID().uuidString, title: text.title, body: text.body)
    }

    /// One notification per refresh, never one per item. A first scan finds a dozen
    /// at once, and a dozen banners gets the app muted for good. Split out from the
    /// posting so demoNotifyBatch can check it without a notification center.
    static func batch(_ fresh: [TodoItem]) -> (title: String, body: String)? {
        guard let top = TodoItem.ranked(fresh).first else { return nil }
        if fresh.count == 1 { return ("New to-do", top.action) }
        return ("\(fresh.count) new to-dos", "Most urgent: \(top.action)")
    }

    /// Scheduled, not polled: the trigger fires on its own, and unsnoozing,
    /// finishing or removing the item drops it out of `wanted` on the next
    /// change, which cancels the pending request.
    private static func scheduleWakes(_ items: [TodoItem]) {
        guard let center else { return }
        guard Preferences.shared.notifySnoozeWake else {
            // Switching the flag off takes the already-scheduled wakes with it.
            if !scheduled.isEmpty {
                center.removePendingNotificationRequests(withIdentifiers: Array(scheduled))
                scheduled = []
            }
            return
        }
        let due = items.filter { !$0.done && ($0.snoozedUntil ?? .distantPast) > Date() }
        let wanted = Dictionary(due.map { ("wake-\($0.id)", $0) }, uniquingKeysWith: { first, _ in first })

        let stale = scheduled.subtracting(wanted.keys)
        if !stale.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(stale))
        }
        for (id, item) in wanted where !scheduled.contains(id) {
            post(id: id, title: "Snooze over", body: item.action, at: item.snoozedUntil)
        }
        scheduled = Set(wanted.keys)
    }

    private static func post(id: String, title: String, body: String, at date: Date? = nil) {
        guard let center else { return }
        var trigger: UNNotificationTrigger?
        if let date {
            let wait = date.timeIntervalSinceNow
            guard wait > 0 else { return }
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: wait, repeats: false)
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: id, content: content, trigger: trigger)
        Task {
            guard await authorized(center) else { return }
            try? await center.add(request)
        }
    }

    /// Asked the first time something would actually be posted, not at launch, and
    /// the answer is cached, so a refusal is never asked about a second time.
    private static func authorized(_ center: UNUserNotificationCenter) async -> Bool {
        if let granted { return granted }
        let allowed = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        granted = allowed
        return allowed
    }
}

/// Checks the one rule that matters here: a refresh is one notification, or none.
@MainActor
func demoNotifyBatch() {
    func todo(_ id: String, _ action: String, _ priority: Int) -> TodoItem {
        TodoItem(id: id, action: action, priority: priority, reason: "", detail: "", links: [],
                 sender: "Sender", channel: nil, date: Date(), permalink: nil)
    }

    assert(Notify.batch([]) == nil)

    let one = Notify.batch([todo("a", "Reply to Marta", 3)])
    assert(one?.title == "New to-do" && one?.body == "Reply to Marta")

    let many = Notify.batch([
        todo("a", "Reply invoice", 4),
        todo("b", "Send Q3 numbers", 1),
        todo("c", "Review MR !41", 3),
    ])
    assert(many?.title == "3 new to-dos" && many?.body == "Most urgent: Send Q3 numbers")
    print("demoNotifyBatch: PASS \(many!.title) / \(many!.body)")
}

/// Clicking a notification opens the panel by the same NSStatusBarButton click
/// the global hotkey performs.
/// ponytail: that click is verified from the hotkey, not from a real notification
/// tap, which needs a human. If it turns out dead, the fallback is to activate the
/// app first and click on the next runloop pass.
private final class ClickHandler: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        await MainActor.run { GlobalHotkey.openPanel() }
    }

    // Without this the banner is swallowed while the app is frontmost, which it is
    // whenever the panel is open.
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions { [.banner, .sound] }
}

/// The tray icon plus a red count badge.
///
/// macOS treats a MenuBarExtra label as a template image, which flattens every color
/// to the menu bar ink, so a plain red Circle comes out grey. The whole label is
/// rasterized here and flagged isTemplate = false to keep the red. The cost is that
/// the glyph no longer inverts by itself, so the ink color is picked from the current
/// appearance and re-picked when the theme changes.
private struct MenuBarLabel: View {
    let count: Int
    @State private var dark = MenuBarLabel.darkMenuBar

    var body: some View {
        Image(nsImage: rendered)
            .onReceive(DistributedNotificationCenter.default.publisher(
                for: Notification.Name("AppleInterfaceThemeChangedNotification"))) { _ in
                dark = Self.darkMenuBar
            }
    }

    private static var darkMenuBar: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private var rendered: NSImage {
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = false
        return image
    }

    private var content: some View {
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "tray.full.fill" : "tray")
                .font(.system(size: 14))
                .foregroundStyle(dark ? .white : .black)
            if count > 0 {
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Brand.red, in: Capsule())
            }
        }
        .padding(.horizontal, 1)
    }
}

/// Slack's own brand palette. Hardcoded because these are identity colors, not
/// system colors: they must look the same in light and dark. Only ever used as
/// a fill behind fixed-contrast content, never as a text color.
private enum Brand {
    static let aubergine = Color(red: 0.29, green: 0.08, blue: 0.29) // #4A154B
    /// Aubergine taken down towards midnight. Only the header's upper gradient stop.
    static let nightSky = Color(red: 0.14, green: 0.04, blue: 0.16)
    static let red = Color(red: 0.88, green: 0.12, blue: 0.35)       // #E01E5A
    static let blue = Color(red: 0.21, green: 0.77, blue: 0.94)      // #36C5F0
    static let green = Color(red: 0.18, green: 0.71, blue: 0.49)     // #2EB67D
    static let yellow = Color(red: 0.93, green: 0.70, blue: 0.18)    // #ECB22E
    static let link = Color(red: 0.11, green: 0.61, blue: 0.82)      // #1D9BD1
    static let deepGreen = Color(red: 0.00, green: 0.48, blue: 0.35) // #007A5A

    /// Avatar fills paired with an initials color that stays legible on them.
    static let avatars: [(fill: Color, ink: Color)] = [
        (aubergine, .white), (red, .white), (deepGreen, .white),
        (link, .white), (green, .white), (yellow, .black.opacity(0.8)),
        (blue, .black.opacity(0.8)),
    ]
}

/// Time of day, as the header draws it. Five phases, each owning its own ground AND
/// its own ink: the sky swings from near-black at midnight to pale blue at noon, so a
/// single fixed foreground colour is unreadable at one end of the day or the other.
/// Afternoon stays separate from day, a warmer blue with the sun dropped near the
/// horizon, which is visibly a later hour without needing a second palette.
private enum SkyPhase: CaseIterable {
    case dawn, day, afternoon, dusk, night

    /// A pure function of the date, so it is assertable and the header can re-derive it
    /// from a timeline rather than caching whatever hour the panel opened in.
    static func at(_ date: Date, calendar: Calendar = .current) -> SkyPhase {
        switch calendar.component(.hour, from: date) {
        case 5..<8: .dawn
        case 8..<16: .day
        case 16..<18: .afternoon
        case 18..<21: .dusk
        default: .night
        }
    }

    /// Darker at the top, the way a sky is. Two stops, no dazzle.
    var gradient: LinearGradient {
        LinearGradient(colors: stops, startPoint: .top, endPoint: .bottom)
    }

    var stops: [Color] {
        switch self {
        case .night: [Brand.nightSky, Brand.aubergine]
        case .dusk: [Color(red: 0.20, green: 0.09, blue: 0.30),
                     Color(red: 0.62, green: 0.26, blue: 0.15)]
        case .afternoon: [Color(red: 0.33, green: 0.55, blue: 0.79),
                          Color(red: 0.69, green: 0.78, blue: 0.85)]
        case .day: [Color(red: 0.31, green: 0.60, blue: 0.87),
                    Color(red: 0.69, green: 0.85, blue: 0.95)]
        case .dawn: [Color(red: 0.86, green: 0.62, blue: 0.66),
                     Color(red: 0.80, green: 0.84, blue: 0.89)]
        }
    }

    /// True where the ground is pale, so the ink has to go dark.
    var lightGround: Bool {
        switch self {
        case .day, .afternoon, .dawn: true
        case .dusk, .night: false
        }
    }

    /// The title, the glass glyphs and the brand mark's hairline.
    var ink: Color { lightGround ? Color(red: 0.06, green: 0.10, blue: 0.16) : .white }

    /// The count, one step back from the title. Dark ink loses far more contrast per
    /// point of opacity than white does, since what leaks through is the bright sky,
    /// so it is faded much less.
    var inkSoft: Color { ink.opacity(lightGround ? 0.86 : 0.62) }

    /// Which stars are drawn: an alpha floor that keeps only the brighter ones, and a
    /// scale that fades the whole field. nil is a sky with no stars in it.
    var starfield: (floor: Double, scale: Double)? {
        switch self {
        case .night: (0, 1)
        case .dusk: (0.34, 0.75)     // the brightest few, coming up
        case .dawn: (0.34, 0.42)     // the same few, going out
        case .day, .afternoon: nil
        }
    }

    /// A soft glow: height in unit coordinates, radius as a fraction of the width. No
    /// rays. This is a 40pt utility bar the user opens twenty times a day.
    var sun: (y: Double, radius: Double, color: Color)? {
        switch self {
        case .dawn: (0.95, 0.34, Color(red: 1.00, green: 0.86, blue: 0.74))
        case .day: (0.28, 0.30, Color(red: 1.00, green: 0.97, blue: 0.86))
        case .afternoon: (0.78, 0.32, Color(red: 1.00, green: 0.91, blue: 0.72))
        // Dusk's orange lower stop is the sun already down. Night has none.
        case .dusk, .night: nil
        }
    }

    var streaks: Bool { self == .night }
}

/// What falls out of the sky, if anything.
private enum Falling { case rain, snow }

/// The window's titlebar stand-in. `.plain` has no titlebar to drag, and background dragging
/// only ever grabs background the content leaves uncovered, which in a panel that paints
/// every pixel is nothing at all. So the header carries the drag itself. Kept alongside the
/// `isMovableByWindowBackground` that Foreground.applyWindowTraits arms: that one is what
/// makes AppKit move the window at all, this one is the precise handle.
///
/// Gated on `windowed` rather than applied unconditionally: the menu bar popover is not a
/// window anyone can move, and a drag gesture on it would just eat clicks.
private struct DragHandle: ViewModifier {
    let active: Bool

    @ViewBuilder func body(content: Content) -> some View {
        if active {
            content.gesture(WindowDragGesture())
        } else {
            content
        }
    }
}

/// How a weather condition is drawn. This lives next to SkyPhase rather than in
/// Weather.swift because it is palette: Weather.swift knows what the sky is doing, this
/// knows what that looks like.
///
/// The phase still owns the ink. Every value here changes the ground only, and changes it
/// in the direction that keeps the phase's ink readable: a pale sky is muted towards a
/// paler overcast grey and never darkened, because mid-grey is the one ground that dark
/// ink fails on. A rainy day is still a pale day.
private extension WeatherCondition {
    /// A wash over the phase gradient, drawn as the first thing in the Canvas.
    func scrim(lightGround: Bool) -> (color: Color, opacity: Double) {
        let color = lightGround
            ? Color(red: 0.58, green: 0.60, blue: 0.63)   // overcast grey, lighter than the ink
            : Color(red: 0.05, green: 0.06, blue: 0.10)   // the night going out
        switch self {
        case .clear: return (color, 0)
        case .cloudy: return (color, lightGround ? 0.50 : 0.30)
        case .fog: return (color, lightGround ? 0.42 : 0.28)
        case .rain: return (color, lightGround ? 0.55 : 0.35)
        case .snow: return (color, lightGround ? 0.48 : 0.28)
        case .storm: return (color, lightGround ? 0.62 : 0.45)
        }
    }

    /// Cloud cover as the starfield sees it: a floor added to the phase's own, and a scale
    /// on whatever survives it. Star alphas run 0.14 to 0.46, so a floor of 0.4 leaves the
    /// brightest handful and hides the rest.
    var starCover: (floor: Double, scale: Double) {
        switch self {
        case .clear: return (0, 1)
        case .cloudy: return (0.40, 0.45)
        case .fog: return (0.38, 0.35)
        case .rain, .storm: return (0.44, 0.30)
        case .snow: return (0.40, 0.55)
        }
    }

    var falling: Falling? {
        switch self {
        case .rain, .storm: return .rain
        case .snow: return .snow
        case .clear, .cloudy, .fog: return nil
        }
    }

    /// Only a clear sky keeps the sun glow. Anything else has cloud in the way, and a sun
    /// shining through a rain scrim reads as a rendering mistake.
    var showsSun: Bool { self == .clear }

    /// Whether anything in this condition moves, which is what decides if the timeline runs
    /// at all. Reduce motion overrides it either way.
    var moves: Bool { self != .clear && self != .cloudy }
}

/// The one rule that would break the app if it went wrong: the wrong phase means the
/// wrong ink, and the wrong ink is an invisible header.
func demoSky() {
    func name(_ hour: Int, _ minute: Int = 0) -> String {
        let base = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0,
                                         of: Date())!
        return "\(SkyPhase.at(base))"
    }

    assert(name(3) == "night")
    assert(name(6) == "dawn")
    assert(name(12) == "day")
    assert(name(17) == "afternoon")
    assert(name(19, 30) == "dusk")
    assert(name(23) == "night")
    // The boundaries themselves, since the ink flips on some of them.
    assert(name(5) == "dawn" && name(8) == "day" && name(16) == "afternoon")
    assert(name(18) == "dusk" && name(21) == "night" && name(0) == "night")
    for phase in SkyPhase.allCases {
        assert(phase.ink != .clear && phase.inkSoft != .clear)
        assert(phase.stops.count == 2)
    }
    print("demoSky: PASS \(SkyPhase.allCases.map { "\($0)/\($0.lightGround ? "dark ink" : "white ink")" }.joined(separator: ", "))")
}

/// Urgency band. Priority is 1...5, shown as three sections so the section
/// header carries the urgency and rows can carry identity instead.
private enum Band: CaseIterable {
    case now, today, later

    var title: String {
        switch self {
        case .now: "NOW"
        case .today: "TODAY"
        case .later: "LATER"
        }
    }

    var color: Color {
        switch self {
        case .now: Brand.red
        case .today: Brand.yellow
        case .later: Brand.link
        }
    }

    /// What picking this band writes as the priority. Mid-band, so the item lands
    /// squarely inside it instead of on an edge.
    var pickerValue: Int {
        switch self {
        case .now: 1
        case .today: 3
        case .later: 5
        }
    }

    /// Only the top band tints its rows. One accent keeps p1 unmistakable
    /// without turning the list into a color chart.
    var rowTint: Color? { self == .now ? Brand.red : nil }

    func contains(_ priority: Int) -> Bool {
        switch self {
        case .now: priority <= 1
        case .today: priority == 2 || priority == 3
        case .later: priority >= 4
        }
    }
}

/// The panel, rendered by both scenes. The popover and the floating window share this
/// one view so the two cannot drift apart; `windowed` covers the three places they
/// legitimately differ. See the header button, `body` and `list`.
private struct MenuContent: View {
    let store: Store
    /// True in the Window scene. Chromeless there, so the content draws the card.
    let windowed: Bool
    @State private var composing: Bool
    @State private var showSnoozed: Bool
    @State private var undoShown: Bool
    @State private var undoTimer: Task<Void, Never>?
    /// Which row the keyboard navigation has highlighted, by item id. nil is "nothing
    /// selected", the state the list opens in. Held here, not in TodoRow, so only one row
    /// is ever selected and the arrow keys can move it. Every action re-looks-up the id in
    /// the current `items` before acting, so a stale id left behind by a removed or
    /// re-ranked row is treated as no selection rather than pointing at the wrong row.
    @State private var selectedID: String?
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    // ponytail: the three flags are parameters only so the render harness can shoot
    // the compose area, the snoozed list and the undo bar. ImageRenderer cannot click.
    init(store: Store, windowed: Bool = false, composing: Bool = false,
         showSnoozed: Bool = false, undoShown: Bool = false) {
        self.store = store
        self.windowed = windowed
        _composing = State(initialValue: composing)
        _showSnoozed = State(initialValue: showSnoozed)
        _undoShown = State(initialValue: undoShown)
    }

    /// Done and snoozed items are not part of the list, the count, or the badge.
    private var items: [TodoItem] { TodoItem.ranked(store.todos.filter { !$0.done && !$0.isSnoozed }) }

    private var snoozed: [TodoItem] {
        store.todos.filter { !$0.done && $0.isSnoozed }
            .sorted { ($0.snoozedUntil ?? .distantFuture) < ($1.snoozedUntil ?? .distantFuture) }
    }

    var body: some View {
        panel
            // Stale-guarded, so reopening the panel repeatedly does not re-run the model.
            // The Refresh button still calls refresh() directly and always works.
            // Weather is cached for 25 minutes, so this is a no-op nearly every time.
            .onAppear {
                Task { await store.refreshIfStale() }
                Weather.shared.refreshIfStale()
                if windowed { Foreground.applyWindowTraits() }
            }
            // Reading the preference here is what registers the observation, so flipping
            // the Settings toggle moves the open window immediately.
            .onChange(of: Preferences.shared.windowAlwaysOnTop) {
                if windowed { Foreground.applyWindowTraits() }
            }
    }

    /// The window has no chrome, so the content draws its own card: a rounded container on
    /// a translucent material, with the shadow the missing frame would have cast. The
    /// popover keeps its fixed width and its opaque system ground, which is what a popover
    /// hanging off the menu bar should look like.
    @ViewBuilder private var panel: some View {
        let core = VStack(spacing: 0) {
            header
            Divider()
            if composing {
                ComposeArea(store: store) { composing = false }
                Divider()
            }
            content
            if undoShown {
                UndoBar(label: store.lastUndoable?.label ?? "Removed.", undo: undo)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            Divider()
            footer
        }

        if windowed {
            let card = RoundedRectangle(cornerRadius: 18, style: .continuous)
            core
                .frame(minWidth: 300, idealWidth: 380, maxWidth: .infinity,
                       minHeight: 380, idealHeight: 600, maxHeight: .infinity)
                .background(.regularMaterial)
                .clipShape(card)
                .overlay { card.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.7) }
                .shadow(color: .black.opacity(0.32), radius: 16, y: 5)
                // Room for the shadow to fall in, since a transparent window clips at its
                // own edge and there is no frame to cast it.
                .padding(12)
        } else {
            core
                .frame(width: 360)
                .background(Color(nsColor: .textBackgroundColor))
                // Popover branch only. In the window branch this would hand the window
                // scene's own window to closePopover, which would then order out the window
                // the button had just opened.
                .background(WindowReader { Foreground.capture($0) })
        }
    }

    /// Five minutes, not a frame: only the phase is read off this, and the phase moves
    /// on the hour. The starfield keeps its own 24fps timeline inside Sky.
    private var header: some View {
        TimelineView(.periodic(from: .now, by: 300)) { timeline in
            headerBar(SkyPhase.at(timeline.date), weather: Weather.shared.condition)
        }
    }

    /// Takes the phase and the condition rather than reading the clock or the cache, so the
    /// render harness can shoot every combination without waiting for the day to go round
    /// or for it to rain.
    private func headerBar(_ phase: SkyPhase, weather: WeatherCondition? = nil) -> some View {
        // 7 rather than the original 9. A fourth button costs about 45pt and the bar was
        // only about 10pt from full, so the gaps give that back and nothing has to shrink.
        HStack(spacing: 7) {
            // The mark, the title, the count and the gap after them, grouped so the drag
            // gesture can own exactly that region. The buttons sit outside this group and
            // so are never inside the gesture's view, which is what keeps them clickable.
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Brand.aubergine)
                    .frame(width: 24, height: 24)
                    // Aubergine on an aubergine ground has nothing to separate it, so the
                    // mark keeps its brand fill and gains a hairline to hold its shape.
                    // The hairline follows the ink: white on a night sky, dark on a pale
                    // one, where a white edge would vanish.
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(phase.ink.opacity(0.22), lineWidth: 0.8)
                    }
                    .overlay {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                    }

                Text("Sereno")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(phase.ink)
                    // The app's own name never wraps and never truncates. If the bar runs
                    // out of room the count below gives way instead.
                    .fixedSize()

                Text(items.isEmpty ? "all clear" : "\(items.count) to reply")
                    .font(.caption)
                    .foregroundStyle(phase.inkSoft)
                    // A fourth button in the header leaves this narrow enough to wrap,
                    // which would make the bar two lines tall. It truncates instead.
                    .lineLimit(1)
                    .contentTransition(.numericText())
                    .animation(.snappy(duration: 0.22), value: items.count)

                Spacer(minLength: 0)
            }
            // So the empty gap after the count is grabbable, not just the glyphs.
            .contentShape(.rect)
            .modifier(DragHandle(active: windowed))

            Button {
                withAnimation(.snappy(duration: 0.2)) { composing.toggle() }
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phase.ink.opacity(0.92))
            }
            .buttonStyle(.glass)
            .keyboardShortcut("n", modifiers: .command)
            .help("New task")
            .pointerCursor()

            Button {
                Task { await store.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .symbolEffect(.rotate, options: .repeating, isActive: store.isRefreshing)
                    .foregroundStyle(phase.ink.opacity(0.92))
            }
            .buttonStyle(.glass)
            .keyboardShortcut("r", modifiers: .command)
            .help("Refresh")
            .pointerCursor()

            // One slot, two jobs, so the two scenes never grow separate header layouts.
            // In the window it closes: `.plain` has no title bar, so there is no other
            // way out but Cmd+W.
            Button {
                if windowed {
                    // In the window this slot closes it. `\.dismiss` resolves per scene,
                    // so the same call that shuts the popover below shuts the window here,
                    // which is exactly what a chromeless window needs.
                    dismiss()
                } else {
                    // Open first, then close the popover. The other order leaves the app
                    // with nothing visible for a moment, mid activation-policy change.
                    // openWindow reuses the window for a given id, so a second press
                    // brings the existing one forward instead of making another.
                    Foreground.present(serenoWindowID) { openWindow(id: serenoWindowID) }
                    dismiss()
                    Foreground.closePopover()
                }
            } label: {
                Image(systemName: windowed ? "xmark" : "macwindow")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phase.ink.opacity(0.92))
            }
            .buttonStyle(.glass)
            // Only on the popover's button. In the window, Escape already belongs to the
            // compose area's Cancel, and Cmd+W comes with the menu the app grows while a
            // window is up.
            .keyboardShortcut(windowed ? nil : KeyboardShortcut("o", modifiers: [.command, .shift]))
            .help(windowed ? "Close this window" : "Open Sereno in its own window")
            .pointerCursor()

            Button(action: openSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(phase.ink.opacity(0.92))
            }
            .buttonStyle(.glass)
            .help("Settings")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        // The header's ground is a sky, not a system surface, so every foreground above
        // comes from the phase rather than from `.primary` or `.secondary`. A semantic
        // colour would resolve to near-black in light mode and disappear at night.
        .background { Sky(phase: phase, weather: weather) }
        .background { phase.gradient }
    }

    @ViewBuilder private var content: some View {
        VStack(spacing: 8) {
            if let reason = store.unavailableReason {
                Banner(text: reason, symbol: "exclamationmark.triangle.fill", tint: Brand.yellow)
            }
            if let error = store.errorText {
                Banner(text: error, symbol: "xmark.octagon.fill", tint: Brand.red)
            }
            if showRoleHint {
                roleHint
            }
            if items.isEmpty {
                empty
            } else {
                list
            }
            snoozedSection
            // The popover is sized by its content, the window is not. With a list the
            // list itself absorbs the extra height, so this is only for the empty state,
            // which would otherwise float in the middle of the window.
            if windowed && items.isEmpty { Spacer(minLength: 0) }
        }
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    /// Only when the role is genuinely blank, the user has not waved the hint away, and
    /// there is no Apple-Intelligence banner already sitting on top: one quiet nudge, not
    /// a stack of banners.
    private var showRoleHint: Bool {
        Preferences.shared.role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !Preferences.shared.roleHintDismissed
            && store.unavailableReason == nil
    }

    /// A one-line nudge to fill in the role, which sharpens triage. Deliberately not a
    /// Banner: a Banner is for warnings and errors, and an empty role is neither. Tinted
    /// with the same faint link wash the compose area and undo bar use, so it reads as a
    /// suggestion the user can take or dismiss.
    private var roleHint: some View {
        HStack(spacing: 7) {
            Image(systemName: "person.text.rectangle")
                .font(.caption)
                .foregroundStyle(Brand.link)
            Text("Tell Sereno your role for sharper priorities.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Set role", action: openSettings)
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(Brand.link)
                .help("Open Settings to describe your role")
                .pointerCursor()
            Button {
                withAnimation(.snappy(duration: 0.2)) { Preferences.shared.roleHintDismissed = true }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Brand.link.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
    }

    /// Quiet by design: tertiary, 10pt, collapsed. Snoozed work is work the user
    /// already decided not to look at, so it must not compete with the open rows.
    @ViewBuilder private var snoozedSection: some View {
        if !snoozed.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(.spring(duration: 0.22)) { showSnoozed.toggle() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "clock").font(.system(size: 9, weight: .semibold))
                        Text("\(snoozed.count) snoozed")
                            .font(.system(size: 10, weight: .semibold))
                            .contentTransition(.numericText())
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .rotationEffect(.degrees(showSnoozed ? 90 : 0))
                        Spacer()
                    }
                    .foregroundStyle(.tertiary)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help(showSnoozed ? "Hide snoozed" : "Show snoozed")
                .pointerCursor()

                if showSnoozed {
                    ForEach(snoozed) { item in
                        SnoozedRow(item: item, store: store)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .animation(.snappy(duration: 0.22), value: snoozed.count)
        }
    }

    private var list: some View {
        // ScrollViewReader so a keyboard-selected row can be scrolled into view; the whole
        // scroll content is made .focusable() so .onKeyPress has somewhere to land, and
        // .focusEffectDisabled() keeps the framework from drawing a focus ring around the
        // entire list (the per-row accent wash is the only selection cue we want).
        ScrollViewReader { proxy in
            ScrollView {
                // No spacing between rows: the tinted top band then reads as one
                // block instead of stripes.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Band.allCases, id: \.self) { band in
                        let banded = items.filter { band.contains($0.effectivePriority) }
                        if !banded.isEmpty {
                            SectionHeader(band: band, count: banded.count)
                            ForEach(banded) { item in
                                TodoRow(item: item, band: band, store: store,
                                        selected: item.id == selectedID,
                                        expandToggle: expandToggle,
                                        onUndoable: showUndoBar)
                                    // .id on the row, not the section, so scrollTo can reach
                                    // the exact selected item across all three bands.
                                    .id(item.id)
                                    .transition(.opacity.combined(with: .move(edge: .leading)))
                            }
                        }
                    }
                }
                .padding(.bottom, 4)
            }
            .scrollContentBackground(.hidden)
            // The popover caps its own height, the window is resizable and the list is what
            // the extra height is for.
            .frame(maxHeight: windowed ? .infinity : 400)
            .animation(.spring(duration: 0.25), value: items.map(\.id))
            .focusable()
            .focusEffectDisabled()
            // Only the keys below are claimed, and only while not composing; everything
            // else returns .ignored so the app's own shortcuts (⌘N, ⌘R, ⌘⇧O, Escape,
            // ⌘W) and system keys keep working. The compose gate is the hard rule: while
            // the user is typing, every key must reach the TextField, so we bail before
            // touching selection at all.
            .onKeyPress(keys: [.upArrow, .downArrow, .return, .delete, .deleteForward, "d"]) { press in
                handleKey(press, proxy: proxy)
            }
            // Keep the selection valid as the list changes underneath it: a removed or
            // re-ranked item can leave selectedID pointing at a row that is gone. Drop it
            // to nil in that case so the highlight never lands on the wrong row and every
            // action's fresh lookup starts clean.
            .onChange(of: items.map(\.id)) { _, ids in
                if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
            }
        }
    }

    /// The keyboard navigation, kept in one place off the list. Returns `.ignored` for
    /// anything it does not own or cannot act on (composing, empty list, a key with no
    /// binding, Cmd+Return with no permalink) so the press propagates to the app's
    /// shortcuts and system keys; `.handled` only when it actually did something.
    ///
    /// Every action re-derives the selected item from the current `items` (`selectedItem`)
    /// rather than trusting the stored id, which may be stale.
    private func handleKey(_ press: KeyPress, proxy: ScrollViewProxy) -> KeyPress.Result {
        // Hard constraint: inert while typing. The TextField owns arrows/Return/Delete.
        guard !composing, !items.isEmpty else { return .ignored }

        switch press.key {
        case .upArrow:
            move(by: -1, proxy: proxy)
            return .handled
        case .downArrow:
            move(by: 1, proxy: proxy)
            return .handled
        case .return where press.modifiers.contains(.command):
            // Cmd+Return opens the message, matching TodoRow.open(); no-op without a
            // permalink (mock data always is), so it stays .ignored to let it propagate.
            guard let item = selectedItem, let url = item.permalink else { return .ignored }
            NSWorkspace.shared.open(url)
            return .handled
        case .return:
            // Return toggles expansion, matching the chevron. The row owns the actual
            // `expanded` state, so the panel bumps a counter the selected row watches
            // (see TodoRow.expandToggle). A counter, not a flag, so pressing Return twice
            // on the same row fires onChange both times.
            guard selectedItem != nil else { return .ignored }
            expandToggle += 1
            return .handled
        case .delete, .deleteForward:
            guard let item = selectedItem else { return .ignored }
            advanceSelection(from: item)
            // Same path the row's Remove button takes: store.remove + the undo bar, wrapped
            // in the identical spring so the row animates out the same way.
            withAnimation(.spring(duration: 0.25)) { store.remove(item) }
            showUndoBar()
            return .handled
        case "d" where press.modifiers.contains(.command):
            guard let item = selectedItem else { return .ignored }
            advanceSelection(from: item)
            // Mirrors TodoRow.markDone(): store.markDone (which arms lastUndoable) plus the
            // panel's undo bar, in the same spring.
            withAnimation(.spring(duration: 0.25)) { store.markDone(item) }
            showUndoBar()
            return .handled
        default:
            // Plain "d" with no Command, or anything else that slipped through the key set,
            // is not ours — let it propagate.
            return .ignored
        }
    }

    /// The selected item as it exists in the current `items`, or nil if the id is stale or
    /// nothing is selected. The single source of truth every keyboard action guards on.
    private var selectedItem: TodoItem? {
        guard let selectedID else { return nil }
        return items.first { $0.id == selectedID }
    }

    /// Up/Down through the on-screen order. `items` is already the flattened ranked list
    /// (NOW then TODAY then LATER), which is exactly the order the rows render in, so
    /// walking its indices matches what the user sees. Clamps at both ends — no wrap.
    /// From nothing, Down takes the first row and Up the last.
    private func move(by delta: Int, proxy: ScrollViewProxy) {
        let ids = items.map(\.id)
        guard !ids.isEmpty else { return }
        let next: String
        if let selectedID, let index = ids.firstIndex(of: selectedID) {
            let clamped = min(max(index + delta, 0), ids.count - 1)
            next = ids[clamped]
        } else {
            next = delta > 0 ? ids.first! : ids.last!
        }
        selectedID = next
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next, anchor: nil) }
    }

    /// After a delete/done, move the highlight to the row that takes the removed one's
    /// place: the next row, or the previous if it was last, or nil if the list empties.
    /// Computed against the CURRENT items (before the mutation), then set — the row it
    /// names is still present after the removal because it was never the one removed.
    private func advanceSelection(from item: TodoItem) {
        let ids = items.map(\.id)
        guard let index = ids.firstIndex(of: item.id) else { selectedID = nil; return }
        if index + 1 < ids.count {
            selectedID = ids[index + 1]
        } else if index > 0 {
            selectedID = ids[index - 1]
        } else {
            selectedID = nil
        }
    }

    /// Bumped on every Return press. The selected TodoRow watches this counter and toggles
    /// its own `expanded` when it changes — the only way to reach a row's private state
    /// from here without lifting `expanded` up into the panel (which the render harness and
    /// the chevron button both still depend on living in the row).
    @State private var expandToggle = 0

    private var empty: some View {
        VStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Brand.deepGreen.opacity(0.14))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(Brand.deepGreen)
                }
            Text("Todo sereno").font(.headline)
            Text("Nothing waiting on you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(updated)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .pointerCursor()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
    }

    private var updated: String {
        store.lastScan == .distantPast
            ? "Not scanned yet"
            : "Updated \(store.lastScan.formatted(.relative(presentation: .named)))"
    }

    /// Six seconds of second thoughts, then the bar goes away on its own. Held as a
    /// task so a second undoable action restarts the window instead of stacking two.
    /// Shared by Remove and the user's explicit Done, which is why it no longer names
    /// removal: the bar labels itself from store.lastUndoable.
    private func showUndoBar() {
        undoTimer?.cancel()
        withAnimation(.snappy(duration: 0.2)) { undoShown = true }
        undoTimer = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            withAnimation(.snappy(duration: 0.2)) { undoShown = false }
        }
    }

    private func undo() {
        undoTimer?.cancel()
        withAnimation(.spring(duration: 0.25)) {
            undoShown = false
            store.undoLast()
        }
    }
}

/// Transient, quiet, and gone in six seconds. Removal is one click, so it needs a
/// way back that does not turn into another permanent row.
private struct UndoBar: View {
    /// What was just undone-able, so the same bar reads "Removed." or "Marked done."
    let label: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 9, weight: .bold))
            Text(label)
            Spacer(minLength: 4)
            Button("Undo", action: undo)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Brand.link)
                .buttonStyle(.plain)
                .help("Put it back")
                .pointerCursor()
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Brand.aubergine.opacity(0.10))
    }
}

/// Type your own task. Priority is offered as the band names the user already
/// reads in the list, not as the 1...5 the model works in.
private struct ComposeArea: View {
    let store: Store
    let onClose: () -> Void

    @State private var task = ""
    @State private var note = ""
    @State private var priority = 3
    @FocusState private var taskFocused: Bool

    private var trimmed: String { task.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            TextField("What do you need to do?", text: $task)
                .font(.system(size: 13, weight: .semibold))
                .focused($taskFocused)
                .onSubmit(add)
            TextField("Note, optional", text: $note)
                .font(.system(size: 12))
                .onSubmit(add)

            HStack(spacing: 8) {
                Picker("", selection: $priority) {
                    Text("Now").tag(1)
                    Text("Today").tag(3)
                    Text("Later").tag(5)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .pointerCursor()

                Spacer(minLength: 0)

                Button("Cancel", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Add", action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty)
                    .pointerCursor()
            }
            .font(.caption)
            .buttonStyle(.glass)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Brand.aubergine.opacity(0.07))
        .onAppear { taskFocused = true }
    }

    private func add() {
        guard !trimmed.isEmpty else { return }
        withAnimation(.spring(duration: 0.25)) {
            _ = store.addManual(trimmed, priority: priority,
                                detail: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        onClose()
    }
}

/// One line per snoozed item: what it was, when it comes back, and a way out.
private struct SnoozedRow: View {
    let item: TodoItem
    let store: Store

    var body: some View {
        HStack(spacing: 6) {
            Text(item.action)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let until = item.snoozedUntil {
                Text("wakes \(until.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            Button("Unsnooze") {
                withAnimation(.spring(duration: 0.25)) { store.unsnooze(item) }
            }
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Brand.link)
            .buttonStyle(.plain)
            .help("Put this back in the list")
            .pointerCursor()
        }
        .padding(.vertical, 3)
    }
}

/// The header's sky, in whichever phase the clock is in. Sereno is the watchman's call
/// on a clear night, so the night phase is the identity one and keeps its full starfield
/// and its falling stars. The daylight phases trade those for a low sun and pause the
/// timeline entirely, since nothing in them moves.
private struct Sky: View {
    let phase: SkyPhase
    /// nil is the original behaviour: time of day only, which is also every failure path
    /// in Weather.swift and what the user gets while the toggle is off.
    var weather: WeatherCondition?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// MenuBarExtra should tear this down when the panel closes, but the timeline is
    /// gated on it anyway so a retained panel cannot keep drawing out of sight.
    @State private var onScreen = false

    private struct Star { let x, y, r, alpha: Double; let twinkles: Bool }

    /// Seeded once, at type level: the draw is a pure function of the timeline date, so
    /// picking positions inside it would reshuffle the whole sky on every frame.
    private static let stars: [Star] = {
        var seed: UInt64 = 0x5E7E_11A5
        func unit() -> Double {
            seed ^= seed << 13; seed ^= seed >> 7; seed ^= seed << 17
            return Double(seed % 100_000) / 100_000
        }
        return (0..<44).map { _ in
            Star(x: unit(), y: unit(), r: 0.45 + unit() * 0.7,
                 alpha: 0.14 + unit() * 0.32, twinkles: unit() < 0.25)
        }
    }()

    /// One streak per six second slot, offset by up to two seconds inside its slot, so
    /// consecutive streaks land four to eight seconds apart. Derived from `t` only.
    private static func streak(at t: Double, in size: CGSize) -> (from: CGPoint, to: CGPoint, alpha: Double)? {
        let slot = (t / 6).rounded(.down)
        var h = UInt64(bitPattern: Int64(slot)) &* 0x9E37_79B9_7F4A_7C15 | 1
        func unit() -> Double {
            h ^= h << 13; h ^= h >> 7; h ^= h << 17
            return Double(h % 100_000) / 100_000
        }
        let p = (t - slot * 6 - unit() * 2) / 0.6
        guard p > 0, p < 1 else { return nil }
        let origin = CGPoint(x: (0.06 + unit() * 0.48) * size.width,
                             y: (0.10 + unit() * 0.45) * size.height)
        let run = (0.22 + unit() * 0.16) * size.width   // crosses part of the header, not all of it
        let head = CGPoint(x: origin.x + run * p, y: origin.y + run * p * 0.42)
        let tail = CGPoint(x: head.x - run * 0.34, y: head.y - run * 0.34 * 0.42)
        return (tail, head, sin(p * .pi))
    }

    /// One restrained flash per nine second slot, placed anywhere in the first six seconds
    /// of it, so most slots look empty and none of it reads as a strobe. Derived from `t`
    /// only, like the streaks.
    private static func flash(at t: Double) -> Double? {
        let slot = (t / 9).rounded(.down)
        var h = UInt64(bitPattern: Int64(slot)) &* 0x9E37_79B9_7F4A_7C15 | 1
        h ^= h << 13; h ^= h >> 7; h ^= h << 17
        let start = Double(h % 100_000) / 100_000 * 6
        let p = (t - slot * 9 - start) / 0.22
        guard p > 0, p < 1 else { return nil }
        return sin(p * .pi)
    }

    var body: some View {
        let still = reduceMotion
        // Twinkle, streaks, rain, snow, haze drift and lightning are the moving parts, so
        // a clear starless sky is a still image and the schedule can stay parked.
        let animated = !still && onScreen
            && (phase.starfield != nil || weather?.moves == true)
        TimelineView(.animation(minimumInterval: 1.0 / 24.0, paused: !animated)) { timeline in
            // Frozen at zero when nothing is allowed to move, so reduce motion stops the
            // weather dead rather than drawing it slowly.
            let t = animated ? timeline.date.timeIntervalSinceReferenceDate : 0
            Canvas { ctx, size in
                let full = Path(CGRect(origin: .zero, size: size))
                if let scrim = weather?.scrim(lightGround: phase.lightGround), scrim.opacity > 0 {
                    ctx.fill(full, with: .color(scrim.color.opacity(scrim.opacity)))
                }
                if let sun = phase.sun, weather?.showsSun != false {
                    let r = sun.radius * size.width
                    let c = CGPoint(x: 0.56 * size.width, y: sun.y * size.height)
                    // Between the count and the buttons, so no text sits in the glow.
                    ctx.fill(Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r,
                                                    width: r * 2, height: r * 2)),
                             with: .radialGradient(
                                Gradient(stops: [
                                    .init(color: sun.color.opacity(0.72), location: 0),
                                    .init(color: sun.color.opacity(0.22), location: 0.38),
                                    .init(color: sun.color.opacity(0), location: 1),
                                ]),
                                center: c, startRadius: 0, endRadius: r))
                }
                // Fog is a haze layer, not a scrim: a soft band that drifts, sitting over
                // the sky and under the stars so it dims them the way real haze does.
                if weather == .fog {
                    let mid = (0.52 + 0.06 * sin(t * 0.11)) * size.height
                    let band = CGRect(x: 0, y: mid - size.height * 0.5,
                                      width: size.width, height: size.height)
                    ctx.fill(Path(band), with: .linearGradient(
                        Gradient(colors: [.white.opacity(0), .white.opacity(0.22),
                                          .white.opacity(0)]),
                        startPoint: CGPoint(x: 0, y: band.minY),
                        endPoint: CGPoint(x: 0, y: band.maxY)))
                }
                if let field = phase.starfield {
                    let cover = weather?.starCover ?? (floor: 0, scale: 1)
                    let field = (floor: max(field.floor, cover.floor),
                                 scale: field.scale * cover.scale)
                    for star in Self.stars where star.alpha > field.floor {
                        var alpha = star.alpha * field.scale
                        if animated, star.twinkles {
                            alpha *= 0.6 + 0.4 * sin(t * 0.55 + star.x * 17)
                        }
                        let box = CGRect(x: star.x * size.width - star.r,
                                         y: star.y * size.height - star.r,
                                         width: star.r * 2, height: star.r * 2)
                        ctx.fill(Path(ellipseIn: box), with: .color(.white.opacity(alpha)))
                    }
                }
                // Rain and snow reuse the one seeded table above rather than a second one:
                // x is the column, y the starting offset, r the per-particle speed. Both
                // wrap with truncatingRemainder, so position is a pure function of `t`.
                switch weather?.falling {
                case .rain:
                    // Slanted like the night streaks, and inked from the phase, so it is
                    // dark rain on a pale sky and pale rain on a dark one.
                    let ink = phase.lightGround ? phase.ink : .white
                    for drop in Self.stars {
                        let y = (drop.y + t * (1.7 + drop.r)).truncatingRemainder(dividingBy: 1)
                        let head = CGPoint(x: drop.x * size.width, y: y * size.height)
                        var path = Path()
                        path.move(to: CGPoint(x: head.x - 2.2, y: head.y - size.height * 0.30))
                        path.addLine(to: head)
                        ctx.stroke(path, with: .color(ink.opacity(0.34)), lineWidth: 0.9)
                    }
                case .snow:
                    // Fewer and slower. 44 flakes in a 46pt bar is a blizzard.
                    for flake in Self.stars.prefix(26) {
                        let y = (flake.y + t * 0.10 * (0.6 + flake.r))
                            .truncatingRemainder(dividingBy: 1)
                        let x = flake.x + 0.012 * sin(t * 0.5 + flake.x * 21)
                        let r = 0.8 + flake.r * 0.9
                        ctx.fill(Path(ellipseIn: CGRect(x: x * size.width - r,
                                                        y: y * size.height - r,
                                                        width: r * 2, height: r * 2)),
                                 with: .color(.white.opacity(0.85)))
                    }
                case nil:
                    break
                }
                if animated, weather == .storm, let flash = Self.flash(at: t) {
                    ctx.fill(full, with: .color(.white.opacity(0.14 * flash)))
                }
                if animated, phase.streaks, weather == nil || weather == .clear,
                   let s = Self.streak(at: t, in: size) {
                    var path = Path()
                    path.move(to: s.from)
                    path.addLine(to: s.to)
                    ctx.stroke(path, with: .linearGradient(
                        Gradient(colors: [.white.opacity(0), .white.opacity(0.55 * s.alpha)]),
                        startPoint: s.from, endPoint: s.to), lineWidth: 1)
                }
            }
        }
        .allowsHitTesting(false)
        .onAppear { onScreen = true }
        .onDisappear { onScreen = false }
    }
}

/// Slack-sidebar style section label: small, loud, all caps.
private struct SectionHeader: View {
    let band: Band
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(band.color).frame(width: 6, height: 6)
            Text(band.title)
                .font(.system(size: 10, weight: .heavy))
                .kerning(0.7)
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .contentTransition(.numericText())
                .animation(.snappy(duration: 0.22), value: count)
            Spacer()
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 3)
    }
}

private struct TodoRow: View {
    let item: TodoItem
    let band: Band
    let store: Store
    /// Tells the panel to show its undo bar. Every undoable path — Remove and the
    /// user's explicit Done, each reachable from both the hover button and the context
    /// menu — goes through one function so this fires once whichever way it was done.
    let onUndoable: () -> Void
    /// Drawn by the panel's keyboard navigation as the selection highlight. Passed in
    /// rather than held as row state so exactly one row can be selected at a time and the
    /// arrow keys can move it; hover stays the row's own business.
    let selected: Bool
    /// A counter the panel bumps on every Return press, shared by every row. Watching a
    /// value the panel owns is how a key press in the panel reaches this row's private
    /// `expanded` without lifting that state up. Every row's onChange fires, but only the
    /// selected one acts (see the guard on `selected`), which is what keeps arrowing
    /// between rows — a selection change, not a counter change — from toggling anything.
    let expandToggle: Int

    @State private var hovering = false
    @State private var expanded: Bool
    @State private var copied = false
    @State private var doneTaps = 0
    @State private var doneHovering = false
    @State private var removeHovering = false
    @State private var chevronHovering = false
    @State private var exported = false
    @FocusState private var doneFocused: Bool
    @FocusState private var removeFocused: Bool

    private var prefs: Preferences { .shared }

    /// `item` is a value copy the ForEach handed in, so it is a snapshot of the row as
    /// it was when the list was last built. Anything the user can change from inside
    /// this row has to be read back out of the store, or the control shows the old
    /// value and looks dead. One lookup, so every live read goes through one place.
    /// Falls back to the snapshot only while the item is on its way out of the store.
    private var current: TodoItem { store.todos.first { $0.id == item.id } ?? item }

    // ponytail: `expanded` and `selected` are parameters only so the render harness can
    // shoot an open row and the selection highlight. ImageRenderer cannot click or press
    // a key. Drop them if the harness ever goes away. `selected` defaults false so every
    // non-keyboard caller (context menu, live list before a key is pressed) is unaffected.
    init(item: TodoItem, band: Band, store: Store, expanded: Bool = false,
         selected: Bool = false, expandToggle: Int = 0,
         onUndoable: @escaping () -> Void = {}) {
        self.item = item
        self.band = band
        self.store = store
        self.selected = selected
        self.expandToggle = expandToggle
        self.onUndoable = onUndoable
        _expanded = State(initialValue: expanded)
    }

    private var showActions: Bool { hovering || doneFocused || removeFocused }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            rowBody

            if expanded {
                expansion
                    .padding(.leading, 39) // avatar width plus its gap, so text lines up
                    .padding(.top, 7)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(rowBackground)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        // Return from the keyboard toggles this row's expansion, matching the chevron.
        // Every row watches the shared counter, but only the selected one acts — so
        // arrowing between rows (which changes `selected`, not the counter) never toggles,
        // and a Return only ever opens the one highlighted row.
        .onChange(of: expandToggle) { _, _ in
            guard selected else { return }
            withAnimation(.spring(duration: 0.22)) { expanded.toggle() }
        }
        .help(item.reason.isEmpty ? item.action : "\(item.action). \(item.reason)")
        .contextMenu {
            Button("Done") { markDone() }
            Button("Remove", role: .destructive) { remove() }
            if item.permalink != nil {
                Button("Open in Slack") { open() }
            }
            Divider()
            Button("Mark as Now") { setPriority(1) }
            Button("Mark as Today") { setPriority(3) }
            Button("Mark as Later") { setPriority(5) }
            if current.userPriority != nil {
                Button("Use suggested priority") { setPriority(nil) }
            }
            Divider()
            Button("Snooze for \(plural(prefs.snoozeHours, "hour"))") { snooze(hoursFromNow: prefs.snoozeHours) }
            Button("Snooze until tomorrow \(hourLabel(prefs.morningHour))") { snoozeTomorrowMorning() }
            Divider()
            Button("Send to Reminders") { sendToReminders() }
        }
    }

    /// Tapping the row now goes to the Slack message, the chevron is the
    /// separate expand control. Only rows with a real permalink get the
    /// button wrapper and its pointing-hand cursor: the mock data's permalink
    /// is always nil, and a row that goes nowhere should not look clickable.
    @ViewBuilder private var rowBody: some View {
        let content = HStack(alignment: .top, spacing: 9) {
            if item.isManual { ManualMark() } else { Avatar(name: item.sender) }
            VStack(alignment: .leading, spacing: 1) {
                identityLine
                taskLine
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)

        if item.permalink != nil {
            Button(action: open) { content }
                .buttonStyle(.plain)
                .pointerCursor()
        } else {
            content
        }
    }

    private var identityLine: some View {
        HStack(spacing: 6) {
            // A manual task has no sender. "You" says who wrote it without
            // inventing a person, and keeps the bold-first-line rhythm.
            Text(item.isManual ? "You" : item.sender)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(item.isManual ? .secondary : .primary)
                .lineLimit(1)
            if let channel = item.channel {
                Text(channel)
                    .font(.caption)
                    .foregroundStyle(Brand.link)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // The timestamp reserves the trailing slot, and the buttons sit in an
            // overlay so their 28pt hit targets never change the row's height.
            HStack(spacing: 3) {
                if current.userPriority != nil {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .help("You set this priority")
                }
                Text(timeLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .opacity(showActions ? 0 : 1)
            .fixedSize()
            .frame(minWidth: 56, alignment: .trailing)
            .overlay(alignment: .trailing) { actions }
        }
    }

    /// A task typed a second ago formats as "in 0s", which reads like a bug. Under
    /// a minute is just "now".
    private var timeLabel: String {
        Date().timeIntervalSince(item.date) < 60
            ? "now"
            : item.date.formatted(.relative(presentation: .numeric, unitsStyle: .narrow))
    }

    private var taskLine: some View {
        HStack(spacing: 5) {
            // Always one line. Equal row heights read as a list, ragged ones read
            // as a mess. The full message is one click away in the expansion.
            Text(item.action)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
            chevronButton
            Spacer(minLength: 0)
        }
    }

    /// The chevron's own hit target, separate from the row body button below
    /// it. Its drawn size stays close to the old inline glyph so it does not
    /// stretch the row; contentShape's inset grows the tappable area to
    /// roughly 24x24 without touching layout.
    private var chevronButton: some View {
        Button {
            withAnimation(.spring(duration: 0.22)) { expanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(chevronHovering ? .primary : .tertiary)
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .padding(4)
                .background {
                    if chevronHovering { Circle().fill(Color.primary.opacity(0.08)) }
                }
                .contentShape(Rectangle().inset(by: -6))
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help(expanded ? "Collapse" : "Expand")
        .onHover { chevronHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: chevronHovering)
        .opacity(showActions || expanded ? 1 : 0)
    }

    /// The original message, its links, why it was ranked, and the two actions
    /// that need more than an icon.
    private var expansion: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !item.detail.isEmpty {
                Text(item.detail)
                    .font(.system(size: 12))
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(item.links, id: \.self) { ExpandedLink(url: $0) }
            if !item.reason.isEmpty {
                Text(item.reason)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            actionRow
            priorityRow
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One row, one style: small buttons with an icon and a word each.
    private var actionRow: some View {
        HStack(spacing: 6) {
            Button(action: copyDetail) {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .symbolEffect(.bounce, value: copied)
            }
            .help("Copy the original message")
            .pointerCursor()

            Button(action: sendToReminders) {
                Label(exported ? "Sent" : "Reminders", systemImage: exported ? "checkmark" : "list.bullet")
                    .symbolEffect(.bounce, value: exported)
            }
            .help("Send to Reminders")
            .pointerCursor()

            // Kept even though the row click now does the same thing: the row's
            // click-to-open has no visible affordance beyond the cursor, so this
            // stays as the discoverable, explicit way in.
            if item.permalink != nil {
                Button(action: open) {
                    Label("Open in Slack", systemImage: "arrow.up.forward.app")
                }
                .help("Open this message in Slack")
                .pointerCursor()
            }
            Spacer(minLength: 0)
        }
        .font(.caption)
        .buttonStyle(.glass)
        .controlSize(.small)
        .padding(.top, 1)
    }

    /// Priority is one exclusive choice out of three, so it is a segmented control
    /// and needs no caption. The words are the section headers', so moving a row is
    /// named the way the list is named. Snooze is one menu, which keeps the row to
    /// two controls and stays the same size when more durations get added.
    private var priorityRow: some View {
        HStack(spacing: 6) {
            Picker("Priority", selection: bandSelection) {
                Text("Now").tag(1)
                Text("Today").tag(3)
                Text("Later").tag(5)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            .help("Move this to Now, Today or Later")
            .pointerCursor()

            if current.userPriority != nil {
                Button { setPriority(nil) } label: {
                    Image(systemName: "xmark")
                }
                .help("Back to the suggested priority")
                .pointerCursor()
            }

            Spacer(minLength: 0)

            Menu {
                Button("For \(plural(prefs.snoozeHours, "hour"))") { snooze(hoursFromNow: prefs.snoozeHours) }
                Button("Until tomorrow \(hourLabel(prefs.morningHour))") { snoozeTomorrowMorning() }
            } label: {
                Label("Snooze", systemImage: "clock")
            }
            .menuStyle(.button)
            .fixedSize()
            .help("Hide this until later")
            .pointerCursor()
        }
        .font(.caption)
        .buttonStyle(.glass)
        .controlSize(.small)
    }

    /// The segmented control speaks in bands, the store in 1...5. Reading maps the
    /// effective priority to its band, writing sends that band's value.
    private var bandSelection: Binding<Int> {
        Binding {
            Band.allCases.first { $0.contains(current.effectivePriority) }?.pickerValue ?? 5
        } set: {
            setPriority($0)
        }
    }

    @ViewBuilder private var rowBackground: some View {
        ZStack(alignment: .leading) {
            if let tint = band.rowTint {
                tint.opacity(0.08)
                tint.frame(width: 3)
            }
            if hovering { Color.primary.opacity(0.06) }
            // Drawn last so selection reads as the stronger cue and coexists with hover:
            // a keyboard-selected row that the pointer also sits on shows the accent wash,
            // not the fainter hover grey. The accent leading bar mirrors the NOW band's
            // 3pt tint bar above so the two share one visual language, and full-opacity
            // accent there keeps the edge crisp against the low-opacity wash.
            if selected {
                Color.accentColor.opacity(0.14)
                Color.accentColor.frame(width: 3)
            }
        }
    }

    private var actions: some View {
        HStack(spacing: 0) {
            Button(action: markDone) {
                Image(systemName: "checkmark.circle.fill")
                    .symbolEffect(.bounce, value: doneTaps)
                    .foregroundStyle(doneHovering ? Brand.green : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background {
                        if doneHovering { Circle().fill(Brand.green.opacity(0.14)) }
                    }
                    .contentShape(.rect)
            }
            .focused($doneFocused)
            .help("Mark done")
            .pointerCursor()
            .onHover { doneHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: doneHovering)

            Button(action: remove) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(removeHovering ? Brand.red : Color.secondary)
                    .frame(width: 28, height: 28)
                    .background {
                        if removeHovering { Circle().fill(Brand.red.opacity(0.14)) }
                    }
                    .contentShape(.rect)
            }
            .focused($removeFocused)
            .help("Remove")
            .pointerCursor()
            .onHover { removeHovering = $0 }
            .animation(.easeOut(duration: 0.12), value: removeHovering)
        }
        .font(.system(size: 16.5))
        .buttonStyle(.plain)
        // Faded, not removed, so tab focus and VoiceOver still reach both buttons.
        .opacity(showActions ? 1 : 0)
        .animation(.easeOut(duration: 0.12), value: showActions)
    }

    private func markDone() {
        doneTaps += 1
        // markDone, not toggleDone: this is the user's explicit Done, so it arms the undo
        // bar the same way Remove does. The auto-done in Store.refresh() stays silent.
        withAnimation(.spring(duration: 0.25)) { store.markDone(item) }
        onUndoable()
    }

    private func setPriority(_ priority: Int?) {
        withAnimation(.spring(duration: 0.25)) { store.setUserPriority(item, to: priority) }
    }

    private func snooze(hoursFromNow hours: Int) {
        withAnimation(.spring(duration: 0.25)) {
            store.snooze(item, until: Date().addingTimeInterval(TimeInterval(hours) * 3600))
        }
    }

    /// Calendar, not now + 24h: adding a day and setting the hour lands on the
    /// user's morning hour in local time even across a DST change.
    private func snoozeTomorrowMorning() {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: Date()),
              let morning = calendar.date(bySettingHour: prefs.morningHour, minute: 0, second: 0,
                                          of: tomorrow) else { return }
        withAnimation(.spring(duration: 0.25)) { store.snooze(item, until: morning) }
    }

    /// Permission can be denied, so the failure path is the normal one. Success
    /// swaps to a checkmark like Copy does, failure goes to the error banner.
    private func sendToReminders() {
        Task {
            do {
                try await store.exportToReminders(item)
                exported = true
                try? await Task.sleep(for: .seconds(1.2))
                exported = false
            } catch {
                store.errorText = "Could not add to Reminders. \(error.localizedDescription)"
            }
        }
    }

    private func remove() {
        withAnimation(.spring(duration: 0.25)) { store.remove(item) }
        onUndoable()
    }

    private func copyDetail() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(item.detail.isEmpty ? item.action : item.detail, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            copied = false
        }
    }

    private func open() {
        // Shared by the row body tap, the context menu item, and the expanded
        // button. ponytail: mock permalinks are always nil, so all three stay
        // inert until the real Slack source lands.
        guard let url = item.permalink else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One link in the expanded area. Its own hover state, not the row's, since a
/// row can hold several links independently.
private struct ExpandedLink: View {
    let url: URL
    @State private var hovering = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            Text(url.absoluteString)
                .font(.caption)
                .foregroundStyle(Brand.link)
                .underline(hovering)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
        .pointerCursor()
        .onHover { hovering = $0 }
    }
}

/// A manual task has no sender, so there is no avatar to draw. A neutral glyph in
/// the same 30pt squircle keeps the row aligned with the Slack rows while reading
/// as self-authored. Initials of a made-up name would be a lie.
private struct ManualMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.secondary.opacity(0.16))
            .frame(width: 30, height: 30)
            .overlay {
                Image(systemName: "checklist")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
    }
}

/// Rounded-square initials, colored per sender. The squircle plus a stable
/// brand color per person is the most recognizable thing Slack does.
private struct Avatar: View {
    let name: String

    var body: some View {
        let palette = Brand.avatars[colorIndex]
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(palette.fill)
            .frame(width: 30, height: 30)
            .overlay {
                Text(initials)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(palette.ink)
            }
    }

    // Always two characters: initials of the first two words, else the first
    // two letters of a one-word name. Mixed 1 and 2 letter avatars look broken.
    private var initials: String {
        let words = name.split(separator: " ").filter { $0.first?.isLetter == true }
        if words.count >= 2 {
            return words.prefix(2).compactMap { $0.first?.uppercased() }.joined()
        }
        let letters = (words.first ?? "?").prefix(2)
        return letters.prefix(1).uppercased() + letters.dropFirst()
    }

    // Own hash, not hashValue: Swift seeds that per process, so the same person
    // would change color on every launch. 53 spread a sample of real names
    // better than 31, which gave two neighbors the same color.
    private var colorIndex: Int {
        let sum = name.unicodeScalars.reduce(0) { $0 &* 53 &+ Int($1.value) }
        return abs(sum) % Brand.avatars.count
    }
}

private struct Banner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(text)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 14)
    }
}
