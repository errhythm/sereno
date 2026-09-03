import Foundation
import Observation

/// User settings, stored in UserDefaults. Small key-value stuff only, the todo list
/// itself lives in state.json via Store.
///
/// One shared instance because these are process-wide preferences and threading a
/// dependency through every view and the Store for six booleans buys nothing.
/// ponytail: singleton. If this ever needs per-window or test isolation, take an
/// instance in the initialisers that read it.
@MainActor
@Observable
final class Preferences {
    static let shared = Preferences()

    private let store: UserDefaults

    init(store: UserDefaults = .standard) {
        self.store = store
        role = store.string(forKey: Key.role) ?? ""
        storedRefreshMinutes = min(max(store.object(forKey: Key.refreshMinutes) as? Int ?? 5, 1), 240)
        notifyNewItems = store.object(forKey: Key.notifyNewItems) as? Bool ?? true
        notifySnoozeWake = store.object(forKey: Key.notifySnoozeWake) as? Bool ?? true
        countBroadcast = store.object(forKey: Key.countBroadcast) as? Bool ?? false
        countNameMentions = store.object(forKey: Key.countNameMentions) as? Bool ?? true
        storedSnoozeHours = min(max(store.object(forKey: Key.snoozeHours) as? Int ?? 3, 1), 23)
        storedMorningHour = min(max(store.object(forKey: Key.morningHour) as? Int ?? 9, 0), 23)
        windowAlwaysOnTop = store.object(forKey: Key.windowAlwaysOnTop) as? Bool ?? true
        weatherEnabled = store.object(forKey: Key.weatherEnabled) as? Bool ?? false
        weatherCity = store.string(forKey: Key.weatherCity) ?? ""
        weatherLatitude = store.object(forKey: Key.weatherLatitude) as? Double
        weatherLongitude = store.object(forKey: Key.weatherLongitude) as? Double
        roleHintDismissed = store.object(forKey: Key.roleHintDismissed) as? Bool ?? false
        hasCompletedOnboarding = store.object(forKey: Key.hasCompletedOnboarding) as? Bool ?? false
        popoverHeight = store.object(forKey: Key.popoverHeight) as? Double
        modelProvider = RemoteModelProvider(rawValue: store.string(forKey: Key.modelProvider) ?? "") ?? .onDevice
        remoteModelID = store.string(forKey: Key.remoteModelID) ?? ""
        customBaseURLString = store.string(forKey: Key.customBaseURLString) ?? ""
    }

    /// What the user does, in their own words. Passed to the model so it can judge whether
    /// an unaddressed channel message like "Team, please complete the deployment doc" is
    /// theirs to act on. Empty means the model has no basis for that call, so it should
    /// lean on the explicit addressing signals instead.
    var role: String { didSet { store.set(role, forKey: Key.role) } }

    /// How often to look for new work, in minutes. The badge is only as truthful as this.
    /// Clamped in the setter so a bad value cannot wedge the timer. Note: clamping must not
    /// assign to the property inside its own didSet, @Observable routes that back through
    /// the generated setter and recurses until the stack dies.
    private var storedRefreshMinutes: Int
    var refreshMinutes: Int {
        get { storedRefreshMinutes }
        set {
            storedRefreshMinutes = min(max(newValue, 1), 240)
            store.set(storedRefreshMinutes, forKey: Key.refreshMinutes)
        }
    }

    var notifyNewItems: Bool { didSet { store.set(notifyNewItems, forKey: Key.notifyNewItems) } }
    var notifySnoozeWake: Bool { didSet { store.set(notifySnoozeWake, forKey: Key.notifySnoozeWake) } }

    /// Whether @channel and @here create tasks. Off by default: a broadcast is addressed to
    /// a room's membership, not to a person, and in a busy channel it is pure noise.
    var countBroadcast: Bool { didSet { store.set(countBroadcast, forKey: Key.countBroadcast) } }

    /// Whether a plain-text mention of the user's name counts. On by default, but this is
    /// the one signal that invents obligations, so it is worth being able to switch off.
    var countNameMentions: Bool { didSet { store.set(countNameMentions, forKey: Key.countNameMentions) } }

    /// "Snooze for N hours".
    private var storedSnoozeHours: Int
    var snoozeHours: Int {
        get { storedSnoozeHours }
        set {
            storedSnoozeHours = min(max(newValue, 1), 23)
            store.set(storedSnoozeHours, forKey: Key.snoozeHours)
        }
    }

    /// The hour "until tomorrow morning" wakes an item, 24-hour clock.
    private var storedMorningHour: Int
    var morningHour: Int {
        get { storedMorningHour }
        set {
            storedMorningHour = min(max(newValue, 0), 23)
            store.set(storedMorningHour, forKey: Key.morningHour)
        }
    }

    /// Whether the standalone window floats above other apps. On by default because a
    /// glanceable panel is the point, but it is the user's call: an always-on-top window
    /// that cannot be sent behind anything is genuinely annoying on a small screen.
    var windowAlwaysOnTop: Bool { didSet { store.set(windowAlwaysOnTop, forKey: Key.windowAlwaysOnTop) } }

    /// Whether the header sky reflects real weather. Off by default because it means talking
    /// to a third party. Nothing leaves this machine while it is off.
    var weatherEnabled: Bool { didSet { store.set(weatherEnabled, forKey: Key.weatherEnabled) } }

    /// City the user typed, resolved once through Open-Meteo's geocoder into the coordinates
    /// below. We send a place name and coordinates, never anything about Slack.
    /// Open-Meteo needs no API key and no account, which is why it is used here: WeatherKit
    /// requires a provisioning profile that an ad-hoc signed app cannot carry.
    var weatherCity: String { didSet { store.set(weatherCity, forKey: Key.weatherCity) } }

    /// Cached coordinates for `weatherCity`, so the geocoder is called once, not per refresh.
    /// nil means the city has not been resolved yet.
    var weatherLatitude: Double? {
        didSet { store.set(weatherLatitude, forKey: Key.weatherLatitude) }
    }
    var weatherLongitude: Double? {
        didSet { store.set(weatherLongitude, forKey: Key.weatherLongitude) }
    }

    /// Whether the user has dismissed the "tell Sereno your role" hint. Off by default so
    /// the hint shows once; set the moment they dismiss it or fill the role in, and it
    /// never comes back. Not surfaced in Settings: it is bookkeeping, not a preference.
    var roleHintDismissed: Bool { didSet { store.set(roleHintDismissed, forKey: Key.roleHintDismissed) } }

    /// Separates a fresh install from a user who has already dismissed setup, because an
    /// accessory app has no ordinary launch window where first-run guidance can live.
    var hasCompletedOnboarding: Bool { didSet { store.set(hasCompletedOnboarding, forKey: Key.hasCompletedOnboarding) } }

    /// The popover height the user dragged its bottom edge to, in points, as a CONTENT
    /// height: the panel asks its content to be this tall and MenuBarExtra sizes the
    /// window from that. nil means the user never dragged one, and then the content sizes
    /// itself. There is no second mechanism — setting the window's frame was measured
    /// being overwritten a moment later, so it was removed (see Foreground.panelHeight).
    ///
    /// Stored already clamped, by the only writer, `Foreground.setPopoverHeight`: the
    /// limits — never taller than the screen has room for, never shorter than the chrome
    /// plus one row — need the live window and its screen. Reading it back applies the
    /// same clamp again, which is stable, so a value stored on a big screen cannot come
    /// back as an impossible one on a small screen. Clamping HERE is what is ruled out:
    /// clamping inside a didSet would have to assign to the property it fired from, and
    /// @Observable routes that back through the generated setter and recurses until the
    /// stack dies (see refreshMinutes for the shape that needs the explicit setter).
    var popoverHeight: Double? { didSet { store.set(popoverHeight, forKey: Key.popoverHeight) } }

    /// True only when the user opted in AND we have somewhere to ask about.
    var canFetchWeather: Bool {
        weatherEnabled && weatherLatitude != nil && weatherLongitude != nil
    }

    /// Which model triages a conversation. On-device by default: a user who never opens
    /// Settings must never trigger a network call, and the on-device path is the only one
    /// wired into Triage today (see RemoteModel.swift's header comment for the wiring this
    /// still needs). A plain didSet, not the explicit-setter shape refreshMinutes uses:
    /// there is nothing to clamp here, `RemoteModelProvider` is a closed Swift enum, and an
    /// invalid stored rawValue can only arise from decoding old UserDefaults data, which is
    /// handled once in init above, not on every set.
    var modelProvider: RemoteModelProvider { didSet { store.set(modelProvider.rawValue, forKey: Key.modelProvider) } }

    /// The model id the user typed, e.g. an OpenRouter slug. Plain string, not a picker:
    /// OpenRouter's catalog, including its free models, changes too often to hardcode.
    var remoteModelID: String { didSet { store.set(remoteModelID, forKey: Key.remoteModelID) } }

    /// Base URL for `.custom` only; `.openRouter` uses RemoteModel.openRouterBaseURL, a
    /// fixed constant, not a preference. Empty and unread while `.custom` is not selected.
    var customBaseURLString: String { didSet { store.set(customBaseURLString, forKey: Key.customBaseURLString) } }

    /// Addressing signals the user has switched off. Detection still records every signal,
    /// this only decides which ones are allowed to create a task.
    var ignoredSignals: Set<Addressing> {
        var ignored: Set<Addressing> = []
        if !countBroadcast { ignored.insert(.broadcast) }
        if !countNameMentions { ignored.insert(.nameMentioned) }
        return ignored
    }

    /// Restores in-memory defaults while also removing their stored values, so a reset
    /// leaves no old preference behind for a later launch to recover.
    func resetAll() {
        Key.all.forEach(store.removeObject)
        role = ""
        storedRefreshMinutes = 5
        notifyNewItems = true
        notifySnoozeWake = true
        countBroadcast = false
        countNameMentions = true
        storedSnoozeHours = 3
        storedMorningHour = 9
        windowAlwaysOnTop = true
        weatherEnabled = false
        weatherCity = ""
        weatherLatitude = nil
        weatherLongitude = nil
        roleHintDismissed = false
        hasCompletedOnboarding = false
        popoverHeight = nil
        modelProvider = .onDevice
        remoteModelID = ""
        customBaseURLString = ""
        // The assignments above run didSet and write defaults back, so this second sweep
        // is what leaves the UserDefaults domain clean after a reset. The API key is not
        // touched here: it lives in the Keychain, not UserDefaults, and RemoteModelKeychain
        // owns clearing it (App.swift's reset flow calls it alongside SlackAuth.disconnect()).
        Key.all.forEach(store.removeObject)
    }

    private enum Key {
        static let role = "role"
        static let refreshMinutes = "refreshMinutes"
        static let notifyNewItems = "notifyNewItems"
        static let notifySnoozeWake = "notifySnoozeWake"
        static let countBroadcast = "countBroadcast"
        static let countNameMentions = "countNameMentions"
        static let snoozeHours = "snoozeHours"
        static let morningHour = "morningHour"
        static let windowAlwaysOnTop = "windowAlwaysOnTop"
        static let weatherEnabled = "weatherEnabled"
        static let weatherCity = "weatherCity"
        static let weatherLatitude = "weatherLatitude"
        static let weatherLongitude = "weatherLongitude"
        static let roleHintDismissed = "roleHintDismissed"
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let popoverHeight = "popoverHeight"
        static let modelProvider = "modelProvider"
        static let remoteModelID = "remoteModelID"
        static let customBaseURLString = "customBaseURLString"

        static let all = [
            role, refreshMinutes, notifyNewItems, notifySnoozeWake, countBroadcast,
            countNameMentions, snoozeHours, morningHour, windowAlwaysOnTop, weatherEnabled,
            weatherCity, weatherLatitude, weatherLongitude, roleHintDismissed, hasCompletedOnboarding,
            popoverHeight, modelProvider, remoteModelID, customBaseURLString
        ]
    }
}

@MainActor
func demoPreferences() {
    let suiteName = "SerenoDemo-\(UUID().uuidString)"
    let suite = UserDefaults(suiteName: suiteName)!
    defer { suite.removePersistentDomain(forName: suiteName) }
    let prefs = Preferences(store: suite)

    // Defaults the app depends on.
    assert(prefs.refreshMinutes == 5, "refresh should default to 5 minutes, not a day")
    assert(prefs.notifyNewItems)
    assert(!prefs.countBroadcast, "@channel must not create tasks by default")
    assert(prefs.countNameMentions)
    assert(!prefs.roleHintDismissed, "the role hint should show until dismissed")
    assert(!prefs.hasCompletedOnboarding, "onboarding should begin incomplete")
    assert(prefs.popoverHeight == nil, "no manual height means the content sizes itself")
    assert(prefs.ignoredSignals == [.broadcast])
    assert(prefs.modelProvider == .onDevice, "a user who never opens Settings must stay on-device")
    assert(prefs.remoteModelID.isEmpty)
    assert(prefs.customBaseURLString.isEmpty)

    // Clamping, so a bad value cannot wedge the refresh timer.
    prefs.refreshMinutes = 0
    assert(prefs.refreshMinutes == 1)
    prefs.refreshMinutes = 9999
    assert(prefs.refreshMinutes == 240)
    prefs.morningHour = 30
    assert(prefs.morningHour == 23)

    // Round trip through UserDefaults.
    prefs.role = "backend engineer, I own deployments"
    prefs.countNameMentions = false
    prefs.hasCompletedOnboarding = true
    let reloaded = Preferences(store: suite)
    assert(reloaded.role == "backend engineer, I own deployments")
    assert(!reloaded.countNameMentions)
    assert(reloaded.hasCompletedOnboarding)
    assert(reloaded.ignoredSignals == [.broadcast, .nameMentioned])

    // Remote model choice round-trips like any other preference. The API key never does:
    // it is not stored here at all, see RemoteModelKeychain.
    prefs.modelProvider = .openRouter
    prefs.remoteModelID = "meta-llama/llama-3.3-70b-instruct:free"
    let reloadedProvider = Preferences(store: suite)
    assert(reloadedProvider.modelProvider == .openRouter)
    assert(reloadedProvider.remoteModelID == "meta-llama/llama-3.3-70b-instruct:free")
    prefs.modelProvider = .custom
    prefs.customBaseURLString = "http://localhost:1234/v1/chat/completions"
    assert(Preferences(store: suite).customBaseURLString == "http://localhost:1234/v1/chat/completions")
    // An old UserDefaults domain with no modelProvider key must default to on-device, not
    // decode a garbage rawValue into some arbitrary case.
    suite.removeObject(forKey: "modelProvider")
    assert(Preferences(store: suite).modelProvider == .onDevice)

    // The dragged popover height has to survive a relaunch, and clearing it has to put
    // content sizing back in charge rather than leave a stale number behind.
    prefs.popoverHeight = 420
    assert(Preferences(store: suite).popoverHeight == 420, "a dragged height must persist")
    prefs.popoverHeight = nil
    assert(Preferences(store: suite).popoverHeight == nil, "clearing it must return to content sizing")

    assert(prefs.windowAlwaysOnTop, "the window should float by default")
    prefs.windowAlwaysOnTop = false
    assert(!Preferences(store: suite).windowAlwaysOnTop, "the choice must persist")
    prefs.windowAlwaysOnTop = true

    // Weather is opt-in and inert until a city resolves, so nothing leaves the machine
    // just because the toggle got flipped.
    assert(!prefs.weatherEnabled, "weather must be off until the user asks for it")
    assert(!prefs.canFetchWeather)
    prefs.weatherEnabled = true
    assert(!prefs.canFetchWeather, "opting in is not enough, there must be a resolved city")
    prefs.weatherCity = "Dhaka"
    prefs.weatherLatitude = 23.8103
    prefs.weatherLongitude = 90.4125
    assert(prefs.canFetchWeather)
    let back = Preferences(store: suite)
    assert(back.weatherCity == "Dhaka" && back.canFetchWeather)

    prefs.snoozeHours = 99
    prefs.morningHour = 30
    prefs.popoverHeight = 500
    prefs.resetAll()
    assert(prefs.role.isEmpty && prefs.refreshMinutes == 5 && prefs.notifyNewItems && prefs.notifySnoozeWake)
    assert(!prefs.countBroadcast && prefs.countNameMentions && prefs.snoozeHours == 3 && prefs.morningHour == 9)
    assert(prefs.windowAlwaysOnTop && !prefs.weatherEnabled && prefs.weatherCity.isEmpty)
    assert(prefs.weatherLatitude == nil && prefs.weatherLongitude == nil && !prefs.roleHintDismissed)
    assert(!prefs.hasCompletedOnboarding && prefs.ignoredSignals == [.broadcast])
    assert(prefs.popoverHeight == nil)
    assert(prefs.modelProvider == .onDevice && prefs.remoteModelID.isEmpty && prefs.customBaseURLString.isEmpty,
           "reset must fall back to on-device, never leave a remote provider selected")
    let reset = Preferences(store: suite)
    assert(reset.role.isEmpty && reset.refreshMinutes == 5 && reset.notifyNewItems && reset.notifySnoozeWake)
    assert(!reset.countBroadcast && reset.countNameMentions && reset.snoozeHours == 3 && reset.morningHour == 9)
    assert(reset.windowAlwaysOnTop && !reset.weatherEnabled && reset.weatherCity.isEmpty)
    assert(reset.weatherLatitude == nil && reset.weatherLongitude == nil && !reset.roleHintDismissed)
    assert(!reset.hasCompletedOnboarding && reset.ignoredSignals == [.broadcast])
    assert(reset.popoverHeight == nil)
    assert(reset.modelProvider == .onDevice && reset.remoteModelID.isEmpty && reset.customBaseURLString.isEmpty)

    print("demoPreferences: PASS")
}
