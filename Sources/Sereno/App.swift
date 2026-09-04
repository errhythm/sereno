import SwiftUI
import AppKit
import Charts
import KeyboardShortcuts
import ServiceManagement
import Observation
import UserNotifications
import CoreText
import OSLog

/// Pointing-hand cursor on hover. `.pointerStyle(.link)` is the modern SwiftUI
/// equivalent of NSCursor.pointingHand.set(), confirmed present in the macOS 26
/// SDK (macOS 15.0+). Factored out so every clickable control picks it up the
/// same way instead of repeating onContinuousHover per control.
private extension View {
    func pointerCursor() -> some View { pointerStyle(.link) }

    /// The up/down resize cursor, for the popover's bottom grab strip. Same shape as
    /// pointerCursor above: one place names the pointer style, every user just calls this.
    /// `.frameResize(position: .bottom)` is the SwiftUI spelling of NSCursor.resizeUpDown
    /// for an edge that only moves vertically.
    func resizeCursor() -> some View { pointerStyle(.frameResize(position: .bottom)) }
}

/// The floating window's scene id, shared by the scene, the header button and the
/// Window menu command.
let serenoWindowID = "sereno-panel"

/// First run's scene id. A window of its own rather than a sheet over the panel, because
/// the panel is a popover most of the time and a popover that closes when the browser
/// takes focus would drop the user halfway through signing in.
let onboardingWindowID = "sereno-onboarding"

/// The completion-history scene id. Its own window for the same reason onboarding has one:
/// a chart inside a 360pt popover that closes on focus loss is not something anyone can
/// read, and this is the one view in the app people will want to sit and look at.
let historyWindowID = "sereno-history"

/// The wordmark's font, shipped in the app rather than assumed to be installed.
///
/// Deliberately not `Bundle.module`: its generated accessor calls `fatalError` when the
/// resource bundle is missing, and a missing font must fall back to the system font
/// rather than take the app down. This walks the same two candidate roots by hand.
/// Nothing here reads `Bundle.main.bundleIdentifier`, which is nil in a bare binary.
private func registerBundledFonts() {
    let log = Logger(subsystem: "com.rhystart.sereno", category: "fonts")
    let roots = [Bundle.main.resourceURL, Bundle.main.bundleURL].compactMap { $0 }
    guard let resources = roots
            .map({ $0.appendingPathComponent("Sereno_Sereno.bundle") })
            .compactMap(Bundle.init(url:)).first,
          let fonts = resources.urls(forResourcesWithExtension: "ttf", subdirectory: "Fonts"),
          !fonts.isEmpty
    else {
        log.error("no bundled fonts found, wordmark falls back to the system font")
        return
    }
    for url in fonts {
        var error: Unmanaged<CFError>?
        if CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) {
            log.info("registered font \(url.lastPathComponent, privacy: .public)")
        } else {
            // .private on the message only: a CFError can quote the path, and the
            // failure itself is all that has to reach the log in the clear.
            log.error("""
                font registration failed for \(url.lastPathComponent, privacy: .public): \
                \(error?.takeRetainedValue().localizedDescription ?? "unknown", privacy: .private)
                """)
        }
    }
}

/// The app's only AppKit delegate, and it exists for one reason.
///
/// A SwiftUI app terminates when its last scene window closes. Sereno used to survive with
/// nothing on screen because `MenuBarExtra` was itself a scene. Now that the tray owns the
/// panel, every remaining scene — the window, Settings, onboarding, History — is closed most of the time,
/// and the app would quit out from under the user. Measured with a probe before the
/// migration: hiding the last scene window killed the process mid-run, silently, with no
/// error and nothing for an assert to catch. It would have presented as Sereno vanishing
/// from the menu bar some time after launch, most likely just after closing History.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { false }
}

@main
struct SerenoApp: App {
    @State private var store: Store
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        registerBundledFonts()
        GlobalHotkey.install()
        // One last Keychain permission prompt for anyone upgrading, then never again:
        // the Slack token and the remote model key move into a 0600 file beside state.json.
        // This is the ONLY place the app reaches the Keychain now, and it has to run before
        // Store, because LiveMessageSource reads that file on the first refresh. The reason
        // any of this happens at all is in Credentials.swift.
        Credentials.migrate()
        // LiveMessageSource reads the credentials file on every call, so connecting or
        // disconnecting Slack takes effect on the next refresh instead of the next launch.
        let store = Store(source: LiveMessageSource())
        _store = State(initialValue: store)
        Notify.start(store)
        Chime.start(store)
        // The tray owns the status item and the panel outright; there is no menu bar scene
        // any more. The async hop is required: NSStatusBar.system must not be touched
        // before NSApp exists.
        DispatchQueue.main.async {
            Tray.shared.install(store: store) { AnyView(PanelRoot(store: store)) }
        }
    }

    var body: some Scene {
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

        // First run, shown until it is finished or skipped. Given an ordinary title bar,
        // unlike the panel, so it can be moved and closed the way any other window is.
        //
        // .windowResizability(.contentSize) is here for the size it proposes, not for the
        // style mask: measured on this SDK it leaves a `.plain` window with no .resizable
        // at all, which is exactly what a three-step window at a fixed frame wants, so
        // nothing here depends on which of the two it actually does.
        Window("Welcome to Sereno", id: onboardingWindowID) {
            Onboarding()
                .windowFullScreenBehavior(.disabled)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Completed work. An ordinary titled window, resizable, unlike the panel: a chart
        // is something people widen, and its own scene keeps it out of the popover, which
        // closes the moment focus moves.
        Window("History", id: historyWindowID) {
            HistoryPane(store: store)
                .windowFullScreenBehavior(.disabled)
        }
        .defaultSize(width: 620, height: 460)
        .defaultPosition(.center)

        // A real Preferences window, and Cmd+, comes with it.
        Settings {
            SettingsView(store: store)
        }
    }
}

/// Completed work, day by day. Reads the same `store.todos` the list reads, through
/// `CompletionStats`, so a figure here can never disagree with the rows: there is no second
/// store to fall out of step.
///
/// Every number is derived on demand rather than accumulated, which is what makes the
/// honesty below possible — a to-do completed before `completedAt` existed carries no date,
/// and is COUNTED SEPARATELY rather than dated by guesswork or silently dropped. A history
/// that quietly omits work reads as a week where nothing happened.
private struct HistoryPane: View {
    let store: Store
    /// Which rows are showing their original message. Ids, not indexes, so the set survives
    /// the list reordering under it when something is reopened.
    @State private var expanded: Set<String> = []

    /// Recomputed on each body pass, deliberately: the list is dozens of items, not
    /// thousands, and caching it would be a second source of truth for no measurable gain.
    private var stats: CompletionStats {
        CompletionStats.from(store.todos, now: Date())
    }

    var body: some View {
        let stats = stats
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if stats.total == 0 {
                    empty(stats)
                } else {
                    tiles(stats)
                    chart(stats)
                    bands(stats)
                }
                completedList()
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 460, minHeight: 380)
    }

    private func empty(_ stats: CompletionStats) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Nothing completed yet")
                .font(.headline)
            Text("Sereno started recording completion dates in this version, so this fills in from here. Finish something and it shows up the same day.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tiles(_ stats: CompletionStats) -> some View {
        HStack(alignment: .top, spacing: 22) {
            tile("\(stats.today)", "today")
            tile("\(stats.last7)", "last 7 days")
            tile("\(stats.total)", "all time")
            tile(stats.streak > 0 ? "\(stats.streak)" : "—",
                 stats.streak == 1 ? "day streak" : "day streak")
            if let hours = stats.medianHoursToClose {
                tile(CompletionStats.closeTimeLabel(hours), "typical time to close")
            }
        }
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 26, weight: .semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One bar per day, split by who closed it. Bars rather than a line: a completion count
    /// belongs to a whole day, and a line between days would imply values at times nobody
    /// finished anything.
    private func chart(_ stats: CompletionStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Completed per day").font(.subheadline).foregroundStyle(.secondary)
            Chart {
                ForEach(stats.days) { day in
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Closed", day.byHand))
                        .foregroundStyle(by: .value("How", "by you"))
                    BarMark(x: .value("Day", day.date, unit: .day),
                            y: .value("Closed", day.byReply))
                        .foregroundStyle(by: .value("How", "you replied in Slack"))
                }
            }
            .chartForegroundStyleScale([
                "by you": Brand.deepGreen,
                "you replied in Slack": Brand.link,
            ])
            // Every fifth day: a 30-bar axis labelled daily is unreadable at this width.
            .chartXAxis {
                AxisMarks(values: .stride(by: .day, count: 5)) { _ in
                    AxisGridLine()
                    AxisTick()
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                }
            }
            .chartYAxis { AxisMarks(position: .leading) }
            .frame(height: 190)
        }
    }

    private func bands(_ stats: CompletionStats) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("By urgency when you closed it")
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 22) {
                ForEach(Band.allCases, id: \.self) { band in
                    let count = stats.byPriority
                        .filter { band.contains($0.key) }
                        .values.reduce(0, +)
                    HStack(spacing: 6) {
                        Circle().fill(band.color).frame(width: 7, height: 7)
                        Text("\(count)").monospacedDigit()
                        Text(band.title.lowercased()).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// The finished work itself, grouped by the day it was finished. A count tells you the
    /// week was busy; this tells you what the week was.
    @ViewBuilder private func completedList() -> some View {
        let groups = CompletionStats.completedGroups(store.todos)
        let undated = CompletionStats.undatedCompleted(store.todos)
        if !groups.isEmpty || !undated.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Text("Completed").font(.subheadline).foregroundStyle(.secondary)
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(dayHeading(group.day))
                            .font(.caption).foregroundStyle(.tertiary)
                        ForEach(group.items) { item in row(item, at: item.completedAt) }
                    }
                }
                if !undated.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Before Sereno recorded dates")
                            .font(.caption).foregroundStyle(.tertiary)
                        ForEach(undated) { item in row(item, at: nil) }
                    }
                }
            }
        }
    }

    /// "Today" and "Yesterday" rather than a date for the two headings a person reads most,
    /// since those are the ones they are checking against their own memory of the day.
    private func dayHeading(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// One finished item. Clickable straight through to the Slack message when there is one,
    /// which is the whole product rule: Sereno puts you one click from the conversation and
    /// never tries to be the conversation.
    private func row(_ item: TodoItem, at completed: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            rowLine(item, at: completed)
            if expanded.contains(item.id), !item.detail.isEmpty {
                // The message as it was sent, verbatim. This is what a person is actually
                // asking when they click a finished row: what was this?
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 20)
            }
        }
    }

    private func rowLine(_ item: TodoItem, at completed: Date?) -> some View {
        // Clicking READS, it does not navigate. The main list opens Slack on a row tap
        // because that list exists to get you to the message; this one exists to be looked
        // at, everything in it is already dealt with, and an accidental jump out of a review
        // into Slack is a context switch nobody asked for. Slack is still one right-click
        // away, which is the right weight for a rare action.
        Button {
            withAnimation(.snappy(duration: 0.18)) {
                if expanded.contains(item.id) { expanded.remove(item.id) } else { expanded.insert(item.id) }
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: item.completedByReply ? "arrowshape.turn.up.left" : "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(item.completedByReply ? Brand.link : Brand.deepGreen)
                    .help(item.completedByReply
                          ? "Closed because you replied in Slack"
                          : "You marked this done")
                    .frame(width: 12)
                Text(item.action).lineLimit(1)
                Text(item.isManual ? "You" : item.sender)
                    .foregroundStyle(.secondary)
                if let channel = item.channel {
                    Text(channel).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                if let completed {
                    Text(completed.formatted(date: .omitted, time: .shortened))
                        .foregroundStyle(.tertiary).monospacedDigit()
                }
            }
            .font(.callout)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        // A context menu rather than a visible button per row: reopening is the rare case,
        // and a list of finished work should read as a record, not as a control panel.
        .contextMenu {
            Button("Reopen") { store.reopen(item) }
            if let url = item.permalink {
                Button("Open in Slack") { NSWorkspace.shared.open(url) }
            }
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
    private static let managed: Set<String> = [settingsID, serenoWindowID, onboardingWindowID]

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
    /// One logger for the popover's geometry, shared by the grab strip and the panel's
    /// own window reader so both land in the same category for one `log show` predicate.
    private static let popoverLog = Logger(subsystem: "com.rhystart.sereno", category: "popover")

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

/// The popover's bottom edge, made draggable, because the owner asked to set the panel's
/// height by dragging rather than by typing a number into Settings.
///
/// 5pt tall and overlaid on the footer's bottom padding, so it sits below the "Quit"
/// button rather than over it and is nowhere near the list — it cannot steal a scroll
/// from the ScrollView because it does not overlap it at all. A trackpad two-finger
/// swipe arrives as scroll events, not drag events, which is the other half of why this
/// has to be a real click-drag on a strip outside the scrolling region.
private struct PopoverResizeGrip: View {
    /// Screen y and panel height at mouse-down, in SCREEN coordinates deliberately. This
    /// strip travels DOWN with the bottom edge as the panel grows, so the pointer barely
    /// moves relative to this view and DragGesture's own `translation` stalls out after
    /// the first event. NSEvent.mouseLocation is absolute and immune to the window
    /// moving underneath it.
    @State private var anchor: (y: CGFloat, height: CGFloat)?

    var body: some View {
        Color.clear
            .frame(height: 5)
            .contentShape(.rect)
            .resizeCursor()
            .help("Drag to set the height, double-click to fit it to the list")
            // Exclusive, tap first: the drag cannot recognise until the pointer has moved
            // a point, so a double-click that stays still reaches the tap and anything
            // that moves is a resize. That is also the escape hatch — a drag that left
            // the panel a useless size is undone by double-clicking the same strip.
            .gesture(
                TapGesture(count: 2)
                    .onEnded { Tray.shared.clearHeight() }
                    .exclusively(before: DragGesture(minimumDistance: 1)
                        .onChanged { _ in
                            let y = NSEvent.mouseLocation.y
                            // The anchor is the height this WRITES, not the window's, so
                            // a second drag carries on from where the first left off
                            // instead of drifting by the window's chrome each time. Only
                            // the very first drag has no stored height, and the live
                            // window is the closest thing to it.
                            let start = anchor ?? (y, Tray.shared.currentHeight)
                            anchor = start
                            // Screen y counts upwards and the panel grows downwards from
                            // a pinned top edge, so a falling y is what makes it taller.
                            Tray.shared.setHeight(start.height + (start.y - y))
                        }
                        .onEnded { _ in anchor = nil })
            )
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
    // Every caller is a button inside the popover, so this belongs here and not at the
    // call sites: the gear and the role hint both needed it, and a third caller cannot
    // forget it now. Same order as the window button, open first so the app is never
    // left with nothing on screen mid activation-policy change, and closePopover hops
    // to the next main queue turn regardless.
    Tray.shared.hide()
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

/// Settings, as tabs. It was one pane carrying nine sections at a fixed 460x620, so the
/// weather controls and the shortcut list sat below the fold of a window that gives no
/// sign it scrolls. Five panes, each short enough to be read without moving anything.
///
/// The panes are separate views rather than properties of one, because a Settings TabView
/// takes its height from the pane on screen and a pane can only state its own size if it
/// is its own view.
@MainActor
private struct SettingsView: View {
    let store: Store

    /// Persisted, so Settings reopens on the pane it was left on, and so a deep link has
    /// something to write. The key is the one Apple documents for this.
    @AppStorage("selectedSettingsTab") private var tab: SettingsTab = .general

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: SettingsTab.general) {
                GeneralPane()
            }
            Tab("Slack", systemImage: "link", value: SettingsTab.slack) {
                SlackPane()
            }
            Tab("Model", systemImage: "cpu", value: SettingsTab.model) {
                ModelPane()
            }
            Tab("Notifications", systemImage: "bell", value: SettingsTab.notifications) {
                NotificationsPane()
            }
            Tab("Appearance", systemImage: "cloud.sun", value: SettingsTab.appearance) {
                AppearancePane()
            }
            Tab("About", systemImage: "info.circle", value: SettingsTab.about) {
                AboutPane(store: store)
            }
        }
    }
}

/// String raw values, not the case order, because this is written to UserDefaults and
/// inserting a tab later must not land an existing user on a different one.
private enum SettingsTab: String {
    case general, slack, model, notifications, appearance, about
}

/// The shape every pane shares. The width is fixed so the tab bar does not jump as the
/// selection moves; the height is left to the content, which is the whole point of
/// splitting the form up.
private struct Pane<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        Form { content }
            .formStyle(.grouped)
            .frame(width: 460)
    }
}

/// What the General pane's toggle shows. Only `.enabled` means the app actually launches
/// at login right now -- `.requiresApproval` needs a further flip in System Settings, and
/// `.notFound`/`.notRegistered` mean it won't launch -- so showing "on" for anything but
/// `.enabled` would misstate what happens on the next login. A free function, not inlined,
/// so it is checkable without ever calling register().
func loginItemToggleIsOn(_ status: SMAppService.Status) -> Bool { status == .enabled }

/// Pins the pure mapping only. Whether `register()`/`unregister()` actually succeed for
/// this ad-hoc signed bundle -- and whether the toggle reflects a change made in System
/// Settings instead of by Sereno -- both need a human: either one means really adding or
/// removing a login item, a real system-state change this demo deliberately does not make.
func demoLoginItemStatus() {
    assert(loginItemToggleIsOn(.enabled), "enabled must read as on")
    assert(!loginItemToggleIsOn(.notRegistered), "never registered must read as off")
    assert(!loginItemToggleIsOn(.requiresApproval), "not yet approved must read as off, not a lie that it's running")
    assert(!loginItemToggleIsOn(.notFound), "not found must read as off")
    print("demoLoginItemStatus: PASS")
}

/// What the app does for this particular user, and how often it does it.
@MainActor
private struct GeneralPane: View {
    @Bindable private var prefs = Preferences.shared

    /// The truth is SMAppService.mainApp.status, not a stored bool: if the user removes
    /// the login item from System Settings > General > Login Items, this must show that
    /// on the next read rather than keep insisting it's on. Read fresh in `.task`, since
    /// nothing posts a notification when the system-side state changes.
    @State private var loginItemStatus = SMAppService.mainApp.status
    @State private var loginItemError: String?

    private static let log = Logger(subsystem: "com.rhystart.sereno", category: "loginItem")

    /// The stored value is always in the list, so a value set outside these choices
    /// (or clamped to 240) shows itself instead of leaving the picker blank.
    private var refreshChoices: [Int] {
        Array(Set([1, 5, 15, 30, 60, prefs.refreshMinutes])).sorted()
    }

    private var launchAtLogin: Binding<Bool> {
        Binding(
            get: { loginItemToggleIsOn(loginItemStatus) },
            set: { wantsOn in
                loginItemError = nil
                do {
                    // ponytail: login items are keyed to code identity, and this app is ad-hoc
                    // signed with a signature that changes on every rebuild -- the same root
                    // cause as the Keychain problem Credentials.swift moved off. macOS may
                    // therefore refuse register() here, or accept it but drop the item on the
                    // next rebuild. NOT verified either way: doing so means actually adding a
                    // real login item, a system-state change this change deliberately avoids
                    // as a side effect of writing it. A human needs to toggle this once and
                    // read the result. Upgrade path if it fails: a stable Developer ID signature.
                    if wantsOn { try SMAppService.mainApp.register() }
                    else { try SMAppService.mainApp.unregister() }
                } catch {
                    let nsError = error as NSError
                    Self.log.error("login item \(wantsOn ? "register" : "unregister", privacy: .public) failed: \(nsError.domain, privacy: .public) \(nsError.code, privacy: .public)")
                    loginItemError = wantsOn
                        ? "Couldn't add Sereno to Login Items. Try System Settings > General > Login Items instead."
                        : "Couldn't remove Sereno from Login Items. Try System Settings > General > Login Items instead."
                }
                loginItemStatus = SMAppService.mainApp.status
            }
        )
    }

    var body: some View {
        Pane {
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
                Toggle("Launch at login", isOn: launchAtLogin)
                if let loginItemError {
                    Text(loginItemError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("Startup")
            } footer: {
                Text("Reflects System Settings > General > Login Items, not a choice Sereno remembers itself -- turning it off there shows up here too.")
            }

            Section {
                Toggle("Keep window above other apps", isOn: $prefs.windowAlwaysOnTop)
            } header: {
                Text("Window")
            } footer: {
                Text("Off lets other windows cover it, the way an ordinary window behaves. Takes effect straight away, on an open window too.")
            }
        }
        // Nothing posts a notification when System Settings changes the login item, so
        // re-read it whenever this pane comes on screen rather than trust the value from
        // whenever the toggle last touched it.
        .task { loginItemStatus = SMAppService.mainApp.status }
    }
}

/// The account, and which of its signals are allowed to create work.
@MainActor
private struct SlackPane: View {
    @Bindable private var prefs = Preferences.shared
    /// Not @Bindable and not @State: an @Observable read during body is tracked either way,
    /// and this one is a shared controller the whole app signs in through, not view state.
    private let slack = SlackAuth.shared

    var body: some View {
        Pane {
            Section {
                slackControls
            } header: {
                Text("Slack")
            } footer: {
                Text("Connecting grants Sereno read-only access to the messages you can already see, and nothing is sent anywhere except Slack itself. The token is kept unencrypted, in plain text, in ~/Library/Application Support/Sereno/credentials.json, in a file only your account can read. It is deliberately not in your Keychain: Sereno is signed ad-hoc, so every rebuild looks like a different app to the Keychain and asks permission all over again. A file is the weaker place — anything running as you can read it, and it rides along in a Time Machine backup — and that trade was made on purpose.")
            }

            Section {
                Toggle("My name in the text", isOn: $prefs.countNameMentions)
                Toggle("@channel and @here", isOn: $prefs.countBroadcast)
            } header: {
                Text("What counts as yours")
            } footer: {
                Text("Name matching goes wrong when your name is also an ordinary word. A broadcast is addressed to a room, not to you, which is why it is off. DMs, @mentions, replies to you and replies in your threads always count and cannot be switched off.")
            }
        }
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
}

/// Which model triages a conversation, and its credentials. On-device is the default and
/// the only choice that makes zero network calls; the footer under the picker says so in
/// plain language for every other choice, per this app's one rule about staying a Slack
/// helper and CLAUDE.md's disclosure requirement for this pane specifically.
///
/// The API key never touches `Preferences`/UserDefaults: it round-trips through
/// `Credentials` directly, loaded once into local `@State` on appear and written back
/// only on an explicit Save, the same shape SlackPane already uses for its own credential
/// (there the token never surfaces in Settings at all; here it has to, so the user can type
/// it, but it is never bound directly to a persisted preference).
@MainActor
private struct ModelPane: View {
    @Bindable private var prefs = Preferences.shared
    @State private var apiKey = ""
    @State private var keyStatus: String?

    var body: some View {
        Pane {
            Section {
                Picker("Model", selection: $prefs.modelProvider) {
                    ForEach(RemoteModelProvider.allCases, id: \.self) { Text($0.label).tag($0) }
                }
            } header: {
                Text("Model")
            } footer: {
                // Not softened and not a tooltip: this is the one place the app says a
                // network call is about to start carrying message text off the Mac.
                if let disclosure = prefs.modelProvider.disclosure {
                    Text(disclosure)
                } else {
                    Text("Runs entirely on this Mac. Nothing about your Slack messages ever leaves it.")
                }
            }

            if prefs.modelProvider != .onDevice {
                Section {
                    TextField("Model ID", text: $prefs.remoteModelID,
                              prompt: Text(prefs.modelProvider == .openRouter
                                           ? "meta-llama/llama-3.3-70b-instruct:free"
                                           : "the model name your endpoint expects"))
                    if prefs.modelProvider == .custom {
                        TextField("Base URL", text: $prefs.customBaseURLString,
                                  prompt: Text("http://localhost:1234/v1/chat/completions"))
                    }
                } header: {
                    Text(prefs.modelProvider == .openRouter ? "OpenRouter" : "Endpoint")
                } footer: {
                    Text(prefs.modelProvider == .openRouter
                         ? "Model names on OpenRouter change often, free ones included, so type the exact id from openrouter.ai/models."
                         : "Any OpenAI-compatible /chat/completions endpoint, including one you run yourself.")
                }

                Section {
                    SecureField("API key", text: $apiKey, prompt: Text("stored in credentials.json, not in Settings"))
                        .onSubmit(saveKey)
                    HStack {
                        Button("Save key", action: saveKey)
                            .disabled(apiKey.isEmpty)
                            .pointerCursor()
                        Button("Clear key", role: .destructive, action: clearKey)
                            .pointerCursor()
                        Spacer()
                        if let keyStatus {
                            Text(keyStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("API key")
                } footer: {
                    Text("Kept beside the Slack token, unencrypted, in plain text, in ~/Library/Application Support/Sereno/credentials.json, in a file only your account can read. Never in Settings' own storage. Clear key removes it from that file straight away.")
                }
            }
        }
        .onAppear { apiKey = Credentials.load(.remoteModelAPIKey) ?? "" }
    }

    private func saveKey() {
        guard !apiKey.isEmpty else { return }
        do {
            try Credentials.save(apiKey, as: .remoteModelAPIKey)
            keyStatus = "Saved."
        } catch {
            keyStatus = (error as? CredentialsError)?.message ?? "Could not save the key."
        }
    }

    private func clearKey() {
        do {
            try Credentials.delete(.remoteModelAPIKey)
            apiKey = ""
            keyStatus = "Removed."
        } catch {
            keyStatus = (error as? CredentialsError)?.message ?? "Could not remove the key."
        }
    }
}

/// What interrupts you, and what happens to an item you push away. Snooze lives here
/// rather than under General because both of its settings are about a later interruption.
@MainActor
private struct NotificationsPane: View {
    @Bindable private var prefs = Preferences.shared

    private var morningChoices: [Int] { Array(Set(Array(5...11) + [prefs.morningHour])).sorted() }

    var body: some View {
        Pane {
            Section {
                Toggle("New to-dos", isOn: $prefs.notifyNewItems)
                Toggle("Snooze running out", isOn: $prefs.notifySnoozeWake)
            } header: {
                Text("Notifications")
            } footer: {
                Text("New to-dos are batched into one notification per check, not one per item.")
            }

            Section {
                Picker("Sound", selection: $prefs.chimeSoundName) {
                    Text("Off").tag("")
                    ForEach(Chime.availableSounds, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .onChange(of: prefs.chimeSoundName) { _, newValue in
                    Chime.play(newValue)
                }
            } header: {
                Text("Chime")
            } footer: {
                Text("Plays once when a to-do first appears, same batching as above. Never for something you added or undid yourself.")
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
        }
    }
}

/// The header sky is the only thing in the app with a look to configure, so this pane is
/// one section and is meant to stay that way.
@MainActor
private struct AppearancePane: View {
    @Bindable private var prefs = Preferences.shared
    @State private var resolving = false
    /// What the last Resolve did, in one line. Success names the place Open-Meteo picked,
    /// which is the only way to tell the right Springfield from the wrong one.
    @State private var resolveNote: String?

    var body: some View {
        Pane {
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

/// The shortcuts, and the two ways back to a clean slate.
@MainActor
private struct AboutPane: View {
    let store: Store
    @Bindable private var prefs = Preferences.shared
    @Environment(\.openWindow) private var openWindow
    @State private var confirmingReset = false
    @State private var captureDeleted = false

    var body: some View {
        Pane {
            Section("Keyboard shortcuts") {
                KeyboardShortcuts.Recorder("Open the panel from anywhere:", name: .togglePanel)
                LabeledContent("Open Sereno in its own window", value: "⌘⇧O")
            }

            Section {
                Toggle("Capture triage cases for debugging", isOn: $prefs.debugCaptureEnabled)
                    .onChange(of: prefs.debugCaptureEnabled) { captureDeleted = false }
                HStack {
                    Button("Delete captured data", role: .destructive, action: deleteCapture)
                        .pointerCursor()
                    Spacer()
                    Text(captureStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Debug capture")
            } footer: {
                // Not softened and not a tooltip, per this app's rule that a network- or
                // disk-write disclosure has to be said plainly, the same as ModelPane's.
                Text("When on, every conversation Sereno triages — its Slack messages and the to-do it produced — is written unencrypted, in plain text, to ~/Library/Application Support/Sereno/debug-captures.jsonl on this Mac, so a real failure can be replayed later instead of guessed at. Nothing here is ever uploaded, this only ever writes to that one file. Off by default. Delete removes the file immediately.")
            }

            Section {
                Button("Show onboarding again", action: showOnboarding)
                    .pointerCursor()
                Button("Reset Sereno", role: .destructive) { confirmingReset = true }
                    .pointerCursor()
            } header: {
                Text("Reset")
            } footer: {
                Text("Showing onboarding again costs nothing, it only reopens the first-run window. Resetting is the other thing entirely, so it asks first, and it also deletes any captured debug data and the credentials file.")
            }
        }
        .confirmationDialog("Reset Sereno?", isPresented: $confirmingReset) {
            Button("Reset Sereno", role: .destructive, action: reset)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Every to-do Sereno has collected is deleted, every setting goes back to its default, and ~/Library/Application Support/Sereno/credentials.json is deleted outright, taking the Slack token and any remote model API key with it. Nothing in Slack itself changes. This cannot be undone.")
        }
    }

    private var captureStatus: String {
        if captureDeleted { return "Deleted." }
        guard let bytes = store.debugCaptureFileSizeBytes else { return "Nothing captured yet." }
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func deleteCapture() {
        store.deleteDebugCapture()
        captureDeleted = true
    }

    /// Clearing the flag is not enough on its own. Nothing watches it after launch, and a
    /// user asking to see onboarding again means now, not at the next launch.
    private func showOnboarding() {
        Preferences.shared.hasCompletedOnboarding = false
        Foreground.present(onboardingWindowID) { openWindow(id: onboardingWindowID) }
    }

    /// Preferences.resetAll already clears hasCompletedOnboarding, so the call below is
    /// only about putting the window on screen rather than about the flag.
    private func reset() {
        store.resetAll()
        Preferences.shared.resetAll()
        // A completed browser round trip must not put a fresh token back after reset.
        SlackAuth.shared.cancelConnect()
        SlackAuth.shared.disconnect()
        // Preferences.resetAll() already put modelProvider back to .onDevice; this is the
        // credentials half of that same reset, same as the Slack disconnect two lines up.
        // The whole file goes, not each name in turn, so nothing is left on disk under a
        // name a later version might read.
        Credentials.deleteFile()
        showOnboarding()
    }
}

/// First run. There was none: the app has no Dock icon and opens no window, so everything
/// it needs to be told lived behind a gear in a popover the user had to find first, and a
/// fresh install showed a menu bar count over a list with no account attached to it.
///
/// Three steps, and every one of them can be walked out of. Both of the things it asks for
/// work just as well later from Settings, so neither is allowed to become a wall.
@MainActor
private struct Onboarding: View {
    @Bindable private var prefs = Preferences.shared
    /// Not @Bindable and not @State, for the reason SlackPane gives: this is the shared
    /// controller the whole app signs in through, and reading `state` here is what makes
    /// the second step change under the user the moment the browser hands the token back.
    private let slack = SlackAuth.shared
    @State private var step: Step = .what
    @Environment(\.dismiss) private var dismiss

    /// The sky at the hour the window opened, fixed rather than driven by a timeline. The
    /// header that follows the clock is the panel's, and this window is up for a minute.
    private let phase = SkyPhase.at(Date())

    /// Raw values so Back and Continue are arithmetic rather than a switch that has to be
    /// edited in two places when a step is added.
    private enum Step: Int, CaseIterable { case what, connect, role }

    var body: some View {
        VStack(spacing: 0) {
            banner
            stepContent
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24)
                .padding(.top, 20)
            Spacer(minLength: 12)
            Divider()
            controls
        }
        // Fixed, and sized for the longest step, so the window does not resize under the
        // pointer every time Continue is pressed.
        .frame(width: 480, height: 462)
    }

    private var banner: some View {
        ZStack {
            phase.gradient
            Sky(phase: phase)
            Text("Sereno")
                .font(.custom("SchibstedGrotesk-SemiBold", fixedSize: 21))
                .foregroundStyle(phase.ink)
        }
        .frame(height: 92)
    }

    /// Each step is a heading, prose, and at most one control. Anything more would be
    /// Settings, which is one Cmd+comma away for the rest of the app's life.
    @ViewBuilder private var stepContent: some View {
        switch step {
        case .what: whatStep
        case .connect: connectStep
        case .role: roleStep
        }
    }

    private var whatStep: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("What Sereno does").font(.headline)
            Text("It reads the conversations you are already in, works out which messages are actually waiting on a reply from you, and ranks them. The list lives in your menu bar.")
            Text("Sereno is a Slack helper, not a Slack alternative. Clicking a to-do opens that message in Slack. There is no replying from here and no drafted replies. Slack keeps the conversation.")
            Text("The ranking runs on Apple's on-device model. There is no Sereno server, and nothing about your messages leaves this Mac.")
            Text("Named after the serenos, the night watchmen of Spanish cities from 1715 to the 1970s, who called out the hour and the weather. Las dos y sereno. Two o'clock and clear.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var connectStep: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Connect Slack").font(.headline)
            Text("Sereno has nothing to show until an account is attached. It asks for read-only permission to the messages you can already see, and it cannot post anything. The token is kept unencrypted, in a file on this Mac only your account can read; Settings names the exact path.")
            slackControls
        }
    }

    /// The same three states Settings shows, in the same words. A sign-in that says nothing
    /// when it fails is a dead end wherever it happens, and here it is the first thing the
    /// user ever asked the app to do.
    @ViewBuilder private var slackControls: some View {
        switch slack.state {
        case .connecting:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Waiting for Slack in your browser…")
                Button("Cancel") { slack.cancelConnect() }
                    .pointerCursor()
            }
            Text("Approve Sereno in the tab that just opened. Sereno stops waiting after a couple of minutes.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .connected(let workspace, let userID):
            Label(workspace.map { "Connected to \($0)." } ?? "Connected.",
                  systemImage: "checkmark.circle.fill")
                .foregroundStyle(Brand.green)
            Text("Signed in as \(userID). You can disconnect at any time in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .disconnected, .failed:
            Button("Connect Slack") {
                Task { await slack.connect() }
            }
            .buttonStyle(.borderedProminent)
            .tint(Brand.aubergine)
            .pointerCursor()
            if case .failed(let reason) = slack.state {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(Brand.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var roleStep: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("What you do").font(.headline)
            Text("A message like \"Team, please complete the deployment doc\" names nobody, and this line is what lets the model decide whether it is yours. Measured on a real one: saying the role owned the API moved \"please read the rollout notes\" from the bottom of the list to the top.")
            TextField("Your role", text: $prefs.role,
                      prompt: Text("backend engineer, I own deployments and the public API"),
                      axis: .vertical)
                .lineLimit(3...5)
                .textFieldStyle(.roundedBorder)
            Text("Optional. Leave it empty and only the explicit signals count: DMs, mentions, and replies to you.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            if step != .what {
                Button("Back") {
                    withAnimation(.snappy(duration: 0.2)) { step = previous }
                }
                .pointerCursor()
            }
            Spacer()
            if step != .role {
                Button("Skip setup", action: finish)
                    .buttonStyle(.link)
                    .pointerCursor()
            }
            Button(step == .role ? "Done" : "Continue", action: advance)
                // Not on the last step. The role field takes Return as a newline, being a
                // vertical-axis TextField, and a default action there would race it.
                .keyboardShortcut(step == .role ? nil : KeyboardShortcut.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Brand.aubergine)
                .pointerCursor()
        }
        // Centred over the whole bar rather than placed in the row, so the dots stay in the
        // middle of the window whether or not Back is showing.
        .overlay { dots }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    /// Three is few enough that a progress bar would be more chrome than information, but
    /// with nothing at all the first step reads as open ended.
    private var dots: some View {
        HStack(spacing: 5) {
            ForEach(Step.allCases, id: \.rawValue) { each in
                Circle()
                    .fill(each == step ? Brand.aubergine : Color.secondary.opacity(0.3))
                    .frame(width: 5, height: 5)
            }
        }
    }

    private var previous: Step { Step(rawValue: step.rawValue - 1) ?? .what }

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            finish()
            return
        }
        withAnimation(.snappy(duration: 0.2)) { step = next }
    }

    /// Closing the window with its close button deliberately does not do this. Setup counts
    /// as done when it is finished or skipped, and Skip setup is on every step before the
    /// last one, where Done costs nothing to press.
    private func finish() {
        prefs.hasCompletedOnboarding = true
        dismiss()
    }
}

extension KeyboardShortcuts.Name {
    /// Default Cmd+Shift+T, so existing muscle memory from the old Carbon hotkey keeps
    /// working. User-editable from here on via the Recorder in Settings' About pane.
    static let togglePanel = Self("togglePanel", initial: .init(.t, modifiers: [.command, .shift]))
}

/// Cmd+Shift+T (default, user-editable) from any app opens the panel.
///
/// KeyboardShortcuts (github.com/sindresorhus/KeyboardShortcuts), not Carbon's
/// RegisterEventHotKey: same permission-free global-shortcut mechanism as the code this
/// replaced, but also user-editable, unlike a hardcoded Carbon registration a user could
/// never change or resolve a clash from. Confirmed only that it builds, links, and
/// survives ad-hoc codesigning in this app; whether the shortcut actually fires globally
/// needs a human -- see demoGlobalHotkey's doc comment.
///
/// MenuBarExtra still has no API to open its own window, so `openPanel`/`Tray.shared`
/// finds the NSStatusBarButton SwiftUI installed and clicks it, which does open the panel.
@MainActor
enum GlobalHotkey {
    static func install() {
        KeyboardShortcuts.onKeyUp(for: .togglePanel) { Tray.shared.toggle() }
    }

    /// Also the notification-click path, see Notify.ClickHandler, which passes no toggle:
    /// clicking a notification should show the panel, never shut one already up.
    ///
    /// Historical note, kept because it explains why this is now two lines: MenuBarExtra had
    /// no API to open its own window, so this used to click the status item and then order
    /// the window out, which left MenuBarExtra's own presented flag out of step and made the
    /// press after a close look dead. The tray has real show/hide, so none of that survives.
    /// The tray owns the panel now, so this is a real call instead of the old trick of
    /// walking NSStatusBarWindow's subviews for a control to `performClick` — MenuBarExtra
    /// had no API to open its own window, and this one does.
    static func openPanel(toggle: Bool = false) {
        if toggle { Tray.shared.toggle() } else if !Tray.shared.isOpen { Tray.shared.show() }
    }

}

/// Pins the one part of the shortcut that is checkable without a running event loop: the
/// default binding a fresh install registers. Whether it actually fires globally, and
/// whether a user's own rebinding round-trips through the Recorder, both need a human.
func demoGlobalHotkey() {
    let shortcut = KeyboardShortcuts.Name.togglePanel.initialShortcut
    assert(shortcut?.key == .t, "default shortcut must keep Cmd+Shift+T muscle memory")
    assert(shortcut?.modifiers == [.command, .shift])
    print("demoGlobalHotkey: PASS")
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

/// Plays a short system sound when a to-do is genuinely new. Configurable in the
/// Notifications pane; empty `Preferences.chimeSoundName` means off.
///
/// Deliberately its own tracker, not folded into Notify's `known`: `known` there is
/// recomputed from the CURRENT list on every change, so it forgets an id the moment the
/// item leaves `store.todos` -- harmless for a banner (a re-arriving id looks like a fresh
/// item, which is a mild annoyance, not a bug the banner cares about), but wrong for a
/// chime tied to "genuinely new": an Undo restoring a just-removed item would look
/// identical to a brand-new one and chime again. `everSeen` below only ever grows, so an
/// id stays "not new" forever once observed, even across a Remove/Undo round trip.
@MainActor
enum Chime {
    /// True when `new` holds a non-manual, non-done to-do whose id appears nowhere in
    /// `old`. Manual is excluded because the user is looking right at what they just
    /// typed; done is excluded because a reply-detected item finishing in the background
    /// is not something newly owed. Pure -- no NSSound, no static state -- so it is
    /// testable without audio. `old` is meant to be every to-do ever observed for this
    /// store (see `everSeen`/`sync` below), not merely the last snapshot: that distinction
    /// is what keeps an Undo restore silent even though the item briefly left the live list.
    static func newTodoAppeared(old: [TodoItem], new: [TodoItem]) -> Bool {
        let seenIDs = Set(old.map(\.id))
        return new.contains { !$0.isManual && !$0.done && !seenIDs.contains($0.id) }
    }

    /// Every to-do ever observed for this store. Only ever grows, see header comment.
    private static var everSeen: [TodoItem] = []

    static func start(_ store: Store) {
        everSeen = store.todos
        observe(store)
    }

    private static func observe(_ store: Store) {
        withObservationTracking {
            _ = store.todos
        } onChange: {
            Task { @MainActor in
                sync(store.todos)
                observe(store)
            }
        }
    }

    private static func sync(_ items: [TodoItem]) {
        if newTodoAppeared(old: everSeen, new: items) {
            play(Preferences.shared.chimeSoundName)
        }
        // Union, never replace, so a Remove can never make an id look new again on Undo.
        let knownIDs = Set(everSeen.map(\.id))
        everSeen.append(contentsOf: items.filter { !knownIDs.contains($0.id) })
    }

    /// System sounds macOS ships, enumerated so the picker matches what this machine
    /// actually has; the fixed list is only a fallback if the directory cannot be read.
    static var availableSounds: [String] {
        let fallback = ["Basso", "Blow", "Bottle", "Frog", "Funk", "Glass", "Hero", "Morse",
                         "Ping", "Pop", "Purr", "Sosumi", "Submarine", "Tink"]
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds") else {
            return fallback
        }
        let found = names.filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
        return found.isEmpty ? fallback : found
    }

    /// Plays `name` once, or nothing for "" (off) or a name NSSound cannot find. Used both
    /// for the real chime and the Settings picker's preview, so the preview is honest about
    /// what the user is actually choosing.
    static func play(_ name: String) {
        guard !name.isEmpty else { return }
        NSSound(named: name)?.play()
    }
}

/// The pure decision behind Chime: whether a to-do refresh should make a sound, and that
/// it never double-counts a batch. No NSSound here, everSeen bookkeeping in App is what
/// wires this into the live store; this only exercises the rule itself.
@MainActor
func demoChime() {
    func todo(_ id: String, manual: Bool = false, done: Bool = false) -> TodoItem {
        TodoItem(id: id, action: "Reply", priority: 3, reason: "", sender: "Sender", channel: nil,
                 date: Date(), permalink: nil, done: done, isManual: manual)
    }

    let loaded = [todo("a"), todo("b")]

    // App launch loading state.json: old and new are the same list, nothing to chime about.
    assert(!Chime.newTodoAppeared(old: loaded, new: loaded), "loading existing todos must not chime")

    // Refresh re-triaging a conversation: same id, fields rewritten, still not new.
    var updated = loaded[0]
    updated.action = "Reply urgently"
    assert(!Chime.newTodoAppeared(old: loaded, new: [updated, loaded[1]]),
           "a merged update to an existing row must not chime")

    // Remove then Undo: the live list briefly drops "a", but the caller's `old` (the
    // running union in Chime.sync) never does, so neither step chimes.
    let duringRemoval = [loaded[1]]
    assert(!Chime.newTodoAppeared(old: loaded, new: duringRemoval), "a Remove itself must not chime")
    assert(!Chime.newTodoAppeared(old: loaded, new: loaded), "Undo restoring it must not chime either")

    // Manual add: the user typed it and is looking right at it.
    assert(!Chime.newTodoAppeared(old: loaded, new: loaded + [todo("m", manual: true)]),
           "a manual task must not chime")

    // An item that arrives already done (reply detected in the background) is not newly owed.
    assert(!Chime.newTodoAppeared(old: loaded, new: loaded + [todo("d", done: true)]),
           "an item arriving already done must not chime")

    // A genuine batch of five: this only answers yes/no, so the caller (Chime.sync) plays
    // exactly one sound no matter how many arrived, same as Notify.batch.
    let five = (0..<5).map { todo("new\($0)") }
    assert(Chime.newTodoAppeared(old: loaded, new: loaded + five), "five genuinely new todos must chime")

    print("demoChime: PASS")
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

/// The app's mark, traced from `icon/sereno.svg` because SwiftUI cannot load an SVG. A
/// falling star: a stroked trail that fades into the night behind a solid head. Written
/// in the artwork's 1024-unit space and normalised against whatever rect it is handed,
/// so it is resolution independent at any frame.
///
/// Takes the phase because the artwork's near-white is right on a night sky and
/// invisible on a noon one.
///
/// Nothing draws this now: the header is the wordmark alone. Kept because the geometry
/// is the app icon's, and `demoMark` still checks it normalises to any rect.
private struct SerenoMark: View {
    let phase: SkyPhase

    var body: some View {
        ZStack {
            Part.trail.fill(trailGradient)
            Part.head.fill(phase.ink)
        }
        // Two shapes VoiceOver would otherwise read as two unlabelled images.
        .accessibilityElement()
        .accessibilityLabel("Sereno")
    }

    /// The SVG's own ramp, faint tail to bright head. Kept rather than flattened to one
    /// colour: the ground under it is a moving starfield, and a flat fill loses the
    /// direction the star is falling in. Its axis is the SVG's, converted out of that
    /// path's bounding box, which is what SVG measures a gradient against, into the
    /// 1024-unit canvas the shapes draw in.
    private var trailGradient: LinearGradient {
        let pale = phase.lightGround
        let cream = pale ? phase.ink : Color(red: 1.00, green: 0.94, blue: 0.84) // #FFEFD6
        let ivory = pale ? phase.ink : Color(red: 1.00, green: 0.97, blue: 0.93) // #FFF8EC
        return LinearGradient(
            stops: [
                .init(color: phase.ink.opacity(0.10), location: 0.00),
                .init(color: cream.opacity(0.72), location: 0.22),
                .init(color: ivory.opacity(0.97), location: 0.55),
                .init(color: phase.ink, location: 1.00),
            ],
            startPoint: UnitPoint(x: 0.403, y: 0.688),
            endPoint: UnitPoint(x: 0.587, y: 0.342)
        )
    }

    /// One shape per fill, since the trail carries a gradient and the head does not.
    /// The stroke is taken inside `path(in:)` rather than by a `.stroke` modifier so
    /// its 78-unit width scales with the rect like every other coordinate here.
    /// fileprivate rather than private so demoMark can measure the two paths.
    fileprivate struct Part: Shape {
        static let trail = Part(stroked: true)
        static let head = Part(stroked: false)
        let stroked: Bool

        func path(in rect: CGRect) -> Path {
            let s = min(rect.width, rect.height) / 1024
            func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: rect.minX + x * s, y: rect.minY + y * s)
            }
            var path = Path()
            if stroked {
                path.move(to: p(672, 336))
                path.addCurve(to: p(406, 326), control1: p(672, 244), control2: p(460, 226))
                path.addCurve(to: p(520, 514), control1: p(356, 420), control2: p(462, 480))
                path.addCurve(to: p(620, 690), control1: p(598, 558), control2: p(644, 610))
                path.addCurve(to: p(348, 718), control1: p(594, 778), control2: p(420, 792))
                return path.strokedPath(StrokeStyle(lineWidth: 78 * s, lineCap: .round))
            }
            // Sits exactly on the trail's start point, so it leads the trail instead of
            // looking stuck onto the letter. Both contours wind the same way, so the
            // disc and the glyph fill as one shape.
            path.addEllipse(in: CGRect(origin: p(638, 302), size: CGSize(width: 68 * s, height: 68 * s)))
            path.move(to: p(672, 268))
            path.addLines([p(681, 327), p(740, 336), p(681, 345),
                           p(672, 404), p(663, 345), p(604, 336), p(663, 327)])
            path.closeSubpath()
            return path
        }
    }
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

/// The mark is pure geometry, so what can break is the normalisation: an offset left in
/// 1024-unit space, or a stroke width that does not scale with the rect.
func demoMark() {
    func art(_ side: CGFloat) -> (trail: CGRect, head: CGRect) {
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return (SerenoMark.Part.trail.path(in: rect).boundingRect,
                SerenoMark.Part.head.path(in: rect).boundingRect)
    }

    let small = art(24), big = art(240)
    // Nothing spills out of the frame it was given, at either size.
    for box in [small.trail, small.head] {
        assert(box.minX >= 0 && box.minY >= 0 && box.maxX <= 24 && box.maxY <= 24)
    }
    // Ten times the rect is ten times the art, which is what resolution independent
    // means here. A hardcoded offset or lineWidth would fail this and not the one above.
    for (a, b) in [(small.trail, big.trail), (small.head, big.head)] {
        assert(abs(b.minX - a.minX * 10) < 0.01 && abs(b.minY - a.minY * 10) < 0.01)
        assert(abs(b.width - a.width * 10) < 0.01 && abs(b.height - a.height * 10) < 0.01)
    }
    // The head leads the trail, so it has to sit on the trail's start point, 672/336.
    assert(small.head.contains(CGPoint(x: 672 / 1024.0 * 24, y: 336 / 1024.0 * 24)))
    // The 78-unit stroke, taken inside path(in:), is what widens the trail past the
    // 348...672 the curve itself spans.
    assert(small.trail.width > (672 - 348) / 1024.0 * 24)
    print("demoMark: PASS trail \(small.trail.size), head \(small.head.size) in a 24pt frame")
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
/// What the tray actually hosts: the panel, plus the one thing that has to happen at launch
/// without anyone clicking.
///
/// First-run onboarding used to hang off `MenuBarRoot.onAppear`, because the menu bar label
/// was the only view SwiftUI instantiated on its own. With the tray owning the status item
/// there is no such view, and `Tray.install` is not a View so it has no `openWindow`. This
/// wrapper is that missing launch-time view: `Tray.install` forces one layout pass so the
/// body runs even though the panel has not been shown yet.
///
/// Probed before the migration: `@Environment(\.openWindow)` DOES resolve inside an
/// NSHostingView with no scene of its own, which is what makes this work at all.
private struct PanelRoot: View {
    let store: Store
    @Environment(\.openWindow) private var openWindow
    @State private var presented = false

    var body: some View {
        MenuContent(store: store)
            .onAppear {
                guard !presented, !Preferences.shared.hasCompletedOnboarding else { return }
                presented = true
                Foreground.present(onboardingWindowID) { openWindow(id: onboardingWindowID) }
            }
    }
}

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
    /// Not @Bindable and not @State, for the reason SlackPane gives: an @Observable
    /// read during body is tracked either way, and this is the shared controller the
    /// whole app signs in through. Reading `state` here is what makes a sign-in that
    /// finishes in Settings swap this panel over to the list with no refresh and no
    /// relaunch.
    private let slack = SlackAuth.shared

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

    /// The explicit height the popover's content asks for, or nil to size itself. Read
    /// in `panel`, which is what registers the @Observable dependency on the preference,
    /// so dragging the grip redraws this panel at the new height. Always nil in the
    /// window scene, which is resizable by its own frame and has no grip.
    /// Only `listCap` reads this now, and only to answer "has the user dragged a height".
    /// When they have, the panel's own frame bounds the list and the 400pt cap would fight
    /// it; when they have not, the cap is what stops a long list opening full-screen tall.
    /// Reading the preference registers the observation that redraws the list on a drag.
    private var panelHeight: CGFloat? {
        windowed ? nil : Preferences.shared.popoverHeight.map { CGFloat($0) }
    }

    /// The list's height cap. 400 is the popover's own limit on how far the list may
    /// grow the panel by itself; once a height is dragged the panel's height is decided
    /// and the list is the one thing that can absorb the difference, so the cap has to
    /// come off — leaving it on is what would put dead space above and below the content
    /// of a 600pt panel. Pure and static so demoTrayGeometry can check it without
    /// building a body. The window scene has always been uncapped.
    nonisolated static func listCap(windowed: Bool, panelHeight: CGFloat?) -> CGFloat {
        windowed || panelHeight != nil ? .infinity : 400
    }

    /// Done and snoozed items are not part of the list, the count, or the badge. The
    /// predicate itself lives in one place (`Store.visible`) and the badge reads the same
    /// one; nothing here keeps a copy of it.
    var items: [TodoItem] { store.visible }

    /// Gated on `state` alone and not on `hasToken`: hasToken reads a file off disk, and
    /// body runs on every store change and every animation frame. `state` already
    /// carries the token check, since SlackAuth's init seeds it from that same file.
    private var connected: Bool {
        if case .connected = slack.state { return true }
        return false
    }

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
            // fixedSize, so a panel shorter than its content takes the shortfall out of the
            // LIST (which scrolls, and has its own 72pt floor) instead of out of the sky
            // band. Without it SwiftUI squeezed the header to a purple sliver and the panel
            // looked headless — reported from the field with a stored height of 161 while
            // the live content needed ~321 because an error banner was up.
            header
                .fixedSize(horizontal: false, vertical: true)
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
                .fixedSize(horizontal: false, vertical: true)
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
                // THE height of the panel, and the only place one is set. nil is the
                // normal case and means the content sizes itself, which is also what
                // makes a to-do arriving while the panel is open grow it: MenuBarExtra
                // re-derives its window from the content continuously (measured — see
                // Foreground.panelHeight), so a taller content is a taller window. A
                // dragged height becomes an explicit one here instead, and .top so any
                // slack falls at the bottom rather than being split above the header.
                // Width only. The panel's FRAME is its height now — the tray sets it from
                // Tray.panelHeight and nothing here competes for it. This is the line that
                // used to fight MenuBarExtra for the height and lose.
                .frame(width: 360, alignment: .top)
                .background(Color(nsColor: .textBackgroundColor))
                // The bottom edge, made draggable. Overlaid rather than stacked so it
                // costs no layout height and cannot change the height asked for above.
                .overlay(alignment: .bottom) { PopoverResizeGrip() }
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
            // The title, the count and the gap after them, grouped so the drag gesture
            // can own exactly that region. The buttons sit outside this group and so are
            // never inside the gesture's view, which is what keeps them clickable.
            HStack(spacing: 7) {
                // Measured, not guessed: Schibsted Grotesk SemiBold at 15pt has an
                // x-height of 7.91 against the 8.06 of the 15pt bold system font this
                // replaced, and SemiBold is the lighter weight of the two, so 15.5
                // brings both the x-height and the stroke back to where they were.
                // fixedSize, not size: a wordmark must not grow with Dynamic Type.
                // The only brand-font text in the app; everything else stays on the
                // system font, which is what a macOS app should do.
                Text("Sereno")
                    .font(.custom("SchibstedGrotesk-SemiBold", fixedSize: 15.5))
                    .foregroundStyle(phase.ink)

                Text(!connected ? "not connected"
                     : items.isEmpty ? "all clear" : "\(items.count) to reply")
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
                    // `\.dismiss` is a no-op inside the tray's NSHostingView, which has no
                    // scene of its own, so the tray must be told directly. Kept alongside
                    // dismiss() because the same view is also the window's content, where
                    // dismiss() is the thing that closes it.
                    dismiss()
                    Tray.shared.hide()
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
            if !connected {
                // Alone, with no banner and no role hint above it. A refresh that could
                // not run leaves an error in the store, and the role hint asks for
                // something that only sharpens triage; neither may compete with the one
                // step that has to happen first.
                signIn
            } else {
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
            }
            // The popover is sized by its content, the window is not. With a list the
            // list itself absorbs the extra height, so this is only for the states that
            // draw one short block, which would otherwise float in the middle of the
            // window.
            if windowed && (!connected || items.isEmpty) { Spacer(minLength: 0) }
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
            //
            // minHeight is a floor, not a size, and it is the reported bug's fix: this
            // ScrollView is the ONLY compressible thing in the panel, so any height
            // shortfall lands entirely on it, and measured it goes to exactly 0.0 — a
            // header counting rows above no rows. Measured with NSHostingView at popover
            // frames of 135/161/169pt: without the floor the list gets 0.0 as soon as one
            // error banner shares the panel with the rows; with it, 72.0.
            //
            // 72 specifically: it is one section header plus one whole row, and it is the
            // largest floor that leaves every content ideal untouched (1, 3 and 12 rows,
            // and every banner combination the code can produce — 161/233/485/283/318/333
            // before and after). At 76 the 3-row ideal moves to 246, which would pad the
            // popover with dead space, so do not raise it without re-measuring.
            //
            // ponytail: what shortens the popover in the first place is not established
            // (see the note in `panel`). The floor makes the symptom impossible either way,
            // which is the part that can be fixed from inside SwiftUI.
            .frame(minHeight: 72, maxHeight: Self.listCap(windowed: windowed,
                                                          panelHeight: panelHeight))
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

    /// Sereno cannot see anything until Slack is connected, so this stands in for the
    /// whole list until it is. Deliberately not shaped like `empty` above: that one is a
    /// finished day, this one is a setup step, and reading them as the same thing is the
    /// bug this exists to prevent. Hence the link-blue chain link, the aubergine call to
    /// action and a paragraph, against the empty state's green tick and two calm lines.
    ///
    /// The action is SlackAuth.connect(), the same one Settings runs. There is nothing to
    /// configure first: the client_id is compiled in.
    @ViewBuilder private var signIn: some View {
        VStack(spacing: 9) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Brand.link.opacity(0.14))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "link")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Brand.link)
                }
            Text("Connect Slack").font(.headline)
            Text("Sereno reads the messages you can already see and works out which ones you still owe a reply to. Read-only, and the triage runs on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                // Three lines at 360pt. Without this the text is measured as one line
                // and truncated instead of wrapping.
                .fixedSize(horizontal: false, vertical: true)

            switch slack.state {
            case .connecting:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for Slack in your browser…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Cancel") { slack.cancelConnect() }
                        .font(.caption)
                        .buttonStyle(.plain)
                        .foregroundStyle(Brand.link)
                        .pointerCursor()
                }
            default:
                Button("Connect Slack") {
                    Task { await slack.connect() }
                }
                .buttonStyle(.borderedProminent)
                .tint(Brand.aubergine)
                .pointerCursor()
                // The panel is the whole app until this succeeds, so a failure that said
                // nothing would be a dead end. Same plain-language reason Settings shows.
                if case .failed(let reason) = slack.state {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(Brand.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 30)
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            Text(updated)
            Spacer()
            // Same present+openWindow pairing every other window in this file uses: an
            // LSUIElement app cannot own the foreground, so the window would otherwise
            // open behind whatever was frontmost.
            Button("History") {
                Foreground.present(historyWindowID) { openWindow(id: historyWindowID) }
            }
                .buttonStyle(.plain)
                .pointerCursor()
                .help("Completed to-dos, day by day")
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

/// The badge and the panel must never compute visibility differently. They are separate
/// views in separate scenes and each used to carry its own copy of the predicate, which is
/// how the badge came to sit over an empty list. This calls the two readers' OWN properties
/// rather than re-deriving the predicate, so it fails the moment either one stops going
/// through `Store.visible`.
@MainActor
func demoVisibleSelector() {
    let file = FileManager.default.temporaryDirectory
        .appendingPathComponent("sereno-visible-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    let store = Store(source: MockMessageSource(), fileURL: file)

    let urgent = store.addManual("Ship the release", priority: 1, detail: "")
    let open = store.addManual("Reply to Marta", priority: 4, detail: "")
    let finished = store.addManual("Already handled", priority: 2, detail: "")
    let later = store.addManual("Not yet", priority: 2, detail: "")
    store.markDone(finished)
    store.snooze(later, until: Date().addingTimeInterval(3600))

    assert(store.visible.map(\.id) == [urgent.id, open.id],
           "visible must drop done and snoozed items and rank what is left")

    // Constructing MenuContent is back, and it is the proof that one specific hang is gone.
    //
    // MenuContent holds `private let slack = SlackAuth.shared`, and SlackAuth's init used to
    // seed itself from the Keychain. In an unsigned harness binary that raises a permission
    // dialog nobody can see, and the demo hung on it forever — measured: SecurityAgent live,
    // the run stalled with no output, and it only started once real credentials had been
    // saved. That init now reads the credentials file instead (Credentials.swift), so the
    // rows are pinned by reading the view again rather than by trusting that
    // `MenuContent.items` stayed a one-line alias for the selector.
    assert(MenuContent(store: store).items.map(\.id) == store.visible.map(\.id),
           "the rows must read Store.visible, not a second copy of the predicate")
    assert(Tray.badgeCount(store) == store.visible.count,
           "the badge must count the selector, not a second copy of the predicate")

    // The badge's read also has to BE an observation dependency, which is precisely what
    // the plain Int handed across the Scene boundary was not. onChange fires only if
    // reading badgeCount touched an observed property of the store.
    // A box, because withObservationTracking's onChange is @Sendable and so cannot
    // mutate a captured local. Single-threaded here, hence @unchecked.
    final class Flag: @unchecked Sendable { var hit = false }
    let observed = Flag()
    _ = withObservationTracking { Tray.badgeCount(store) } onChange: { observed.hit = true }
    store.addManual("Something new", priority: 5, detail: "")
    assert(observed.hit, "reading the badge count must register an observation on the store")

    print("demoVisibleSelector: PASS badge \(Tray.badgeCount(store)) == visible \(store.visible.count)")
}

/// The bands must partition the priority range: exactly one band per priority, never two
/// and never none. A gap here is a way for the header to count rows the list then files
/// under no section and never draws, which is one of the shapes the reported bug could
/// have taken. Checked over a range wider than 1...5 because `effectivePriority` comes
/// from the model and from a user override, and neither is clamped.
func demoBands() {
    for priority in -2...8 {
        let matches = Band.allCases.filter { $0.contains(priority) }
        assert(matches.count == 1,
               "priority \(priority) landed in \(matches.count) bands, must be exactly 1")
    }
    let items = (1...5).map {
        TodoItem(id: "\($0)", action: "Reply", priority: $0, reason: "", detail: "", links: [],
                 sender: "Sender", channel: nil, date: Date(), permalink: nil)
    }
    // The exact grouping `list` does, so a row can never be built and then filed nowhere.
    let banded = Band.allCases.flatMap { band in items.filter { band.contains($0.effectivePriority) } }
    assert(banded.map(\.id).sorted() == items.map(\.id).sorted(),
           "every item must appear under exactly one band")
    print("demoBands: PASS \(items.count) items over \(Band.allCases.count) bands")
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
    /// The tray's panel is retained across opens rather than rebuilt, so this gate is what
    /// stops the starfield animating while the panel is hidden.
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
            if item.isManual { ManualMark() } else { Avatar(name: item.sender, avatarURL: item.avatarURL) }
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

/// Rounded-square initials, colored per sender, or the sender's real Slack photo when one
/// is known. The squircle plus a stable brand color per person is the most recognizable
/// thing Slack does, so the photo draws in the same shape and size and the initials are
/// both the loading state and the failure state, never a blank square.
private struct Avatar: View {
    let name: String
    var avatarURL: URL? = nil

    var body: some View {
        if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable()
                        .scaledToFill()
                        .frame(width: 30, height: 30)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    // .empty (still loading) and .failure both read as "no photo yet".
                    initialsBody
                }
            }
            .frame(width: 30, height: 30)
        } else {
            initialsBody
        }
    }

    private var initialsBody: some View {
        let palette = Brand.avatars[colorIndex]
        return RoundedRectangle(cornerRadius: 8, style: .continuous)
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
