# Sereno

A macOS menu bar app that turns Slack messages you owe a reply to into a ranked to-do list,
using the on-device Apple Intelligence model. Named after the *serenos*, the night watchmen of
Spanish cities from 1715 to the 1970s, who called out the hour and the weather: *"Las dos y
sereno"*, two o'clock and clear. Hence the starry header and the "Todo sereno" empty state.

## The one rule that shapes everything

**Sereno is a Slack helper, not a Slack alternative.** Its job is to NOTICE what you owe, RANK
it, and put you one click from the right message in Slack. Slack keeps the conversation.

Deliberately rejected on that basis, do not re-propose:
- replying from the app (`chat.postMessage`)
- AI-drafted replies
- scheduled send (`chat.scheduleMessage`)
- showing full thread context in-app

## Layout

```
Sources/Sereno/
  Models.swift        contracts: SlackMessage, TodoItem, MessageSource, Addressing, Identity
  Addressing.swift    deterministic "is this for me" detection, 47 asserts
  Triage.swift        Apple Intelligence: conversation -> ranked task
  Store.swift         state, merge rules, refresh timer, undo, Reminders export
  Preferences.swift   UserDefaults-backed settings
  Weather.swift       Open-Meteo fetch + WMO mapping
  MockMessageSource.swift  fixtures, stands in for the Slack client
  App.swift           all UI: menu bar popover, window, Settings, sky, notifications
  SlackAuth.swift     PKCE OAuth + Keychain (in progress)
icon/sereno.svg       the S is a falling star's trail; Sereno.icns is generated from it
```

Identifier `com.rhystart.sereno`. State in `~/Library/Application Support/Sereno/state.json`.
Settings in UserDefaults. Slack token in Keychain, service `com.rhystart.sereno`.

## Verify

```bash
swift build          # must be 0 errors AND 0 warnings
bash build.sh        # produces Sereno.app, ad-hoc signed, LSUIElement
/usr/bin/log show --last 10m --predicate 'subsystem == "com.rhystart.sereno"' --style compact
```

`log` is a zsh builtin, so use `/usr/bin/log`.

Demos are plain `assert` functions, no test framework: `demo`, `demoMockSource`,
`demoAutoComplete`, `demoAddressing`, `demoStoreMerge`, `demoPreferences`, `demoRefreshTimer`,
`demoSky`, `demoWeather`, `demoNotifyBatch`, `demoAddressingFilter`, `demoSlackSource`. The repo has exactly one
`@main` (App.swift), so run them from a throwaway SwiftPM package under `/private/tmp` that
copies the sources and supplies its own entry point, then delete it.

## The core design principle, learned the hard way

**If the model can get something plausibly wrong, constrain it structurally or check it
deterministically. Never merely ask.** Four things follow this rule, and each one was a bug
first:

| Concern | How it is enforced |
|---|---|
| Links | `NSDataDetector` over the message text. The model never emits a URL. |
| Identifiers | `actionInventsIdentifier` rejects a task naming `MR !41` unless the source text does. |
| Action shape | Schema-constrained `verb` enum plus a separate required `topic`, composed in Swift. |
| Priority | Model picks a semantic category; Swift maps it to 1...5. |
| "Is this mine" | `Addressing` computed in Swift from the message and identity. |

## Traps. Every one of these cost real debugging time.

### Apple Intelligence / FoundationModels
- **`@Generable` needs full Xcode.** Its macro plugin ships with Xcode, not Command Line
  Tools. Use `DynamicGenerationSchema` if the toolchain may be CLT-only.
- **Concrete few-shot examples get copied verbatim.** A prompt listing `"Approve deploy PR"` as
  an example produced that exact action on 7 unrelated conversations. The prompt went 2663 ->
  948 chars and got *better*. Keep examples abstract; never use a string that could pass as a
  real answer. There is an assert locking the prompt length for this reason.
- **The model anchors on the first enum label it reads.** Categories listed most-urgent-first
  collapsed everything onto the first label. Listing them **least-urgent-first** produced a
  real spread. Do not reorder them.
- **The phrase "by end of day" trips Apple's guardrail.** Measured: 5 failures in 12 runs with
  it, 0 in 24 without. It silently forces fallbacks. Do not reintroduce it.
- **Numeric scales do not work; semantic labels do.** Asking for priority 1-5 directly gave
  11 of 13 conversations priority 1. Asking for a category and mapping in Swift gave a real
  spread.
- **Only one process can hold the model session.** A second gets `ModelManagerError 1008` and
  silently falls back. Quit the app before running model tests. Do NOT `pkill -f Sereno`
  broadly, it kills an Xcode debug session too (that produces `Thread 1: signal SIGTERM`).
- **`UNUserNotificationCenter.current()` traps** in a process with no bundle identifier, which
  is any bare binary. Guard it.

### SwiftUI on macOS 26
- **`@Observable` + a `didSet` that assigns to its own property recurses forever** through the
  generated setter and segfaults. Clamp in an explicit setter over a private stored property.
- **Scene modifiers repeatedly did not do what their names imply.** Three separate bugs:
  - `.windowLevel()` fought a runtime `NSWindow.level`, giving 19 where the code set 3.
  - `.windowBackgroundDragBehavior(.enabled)` does **not** set `isMovableByWindowBackground`,
    so the window could not be moved at all.
  - `.windowResizability(.contentSize)` left `styleMask` at 0 with no `.resizable`.
  In each case the fix was to read the real `NSWindow` and set the AppKit property. Do not
  re-add a modifier and assume it is sufficient.
- **Views hold value copies.** A row with `let item: TodoItem` reads a stale snapshot, which
  made the priority picker look completely dead. Resolve the live value from the store by id.
- **`.swipeActions` only works inside a `List`.** This app uses `ScrollView` + `LazyVStack`
  for the one-card-per-band design, so swipe must be hand-rolled with `DragGesture`. Note a
  two-finger trackpad swipe produces scroll events, not drag events.
- **An `LSUIElement` accessory app cannot own the foreground.** Windows open behind other apps
  until you switch `NSApp.setActivationPolicy(.regular)`, activate, then revert on last close.
- **Match windows by scene identifier, not class.** The popover reported `SPRoundedWindow` on
  one run and `MenuBarExtraWindow` on another. Its real identity: identifier `nil`, level 101.
- **`NSApp.sendAction(showSettingsWindow:)` returns `true` and opens nothing.** Find the app
  menu item by its Cmd+, key equivalent and perform it.
- **`Logger` redacts interpolations by default, but `error.localizedDescription` came through
  in the clear.** A FoundationModels error can quote the prompt, which contains message text.
  Mark it `privacy: .private` explicitly.

### Rendering and verification
- A render harness under `scratchpad/render` rasterises views with `ImageRenderer` so a design
  can be looked at. `List`, `ScrollView`, `Form`, `TextField`, `Picker`, `Stepper`, `Material`
  and `.glass` do not draw under it; dark mode renders text white-on-white, so reason about
  light mode. Canvas draws but captures one arbitrary frame.
- **Never drive synthetic keyboard or mouse input.** An agent once typed into the user's live
  browser session. Verify by building and running code, and say plainly what needs a human.

### Slack
- **You may not put "Slack" in the product name.** `"X for Slack"` is allowed; `"Slack X"` is
  not. That is why this is not called SlackTriage.
- **PKCE is required for a desktop redirect.** `http://localhost:PORT/callback` is only treated
  as a desktop redirect if PKCE is enabled, which is a **one-way** change to the Slack app.
  With PKCE there is no `client_secret`, which is correct since anything in a Mac binary is
  extractable.
- **Pick a redirect port below 49152.** That is the macOS ephemeral floor
  (`net.inet.ip.portrange.first`); above it the OS can hand your port to anything. Sereno uses
  **47823**, bound to `127.0.0.1` only. Slack matches `redirect_uri` exactly, so never silently
  fall back to another port.
- Desktop redirects cannot request bot scopes. Use `user_scope`, all read-only.
- **WeatherKit is unusable here.** It needs an entitlement, which needs a provisioning profile,
  which an ad-hoc signed app cannot carry. Hence Open-Meteo, which needs no key.

## Behaviour worth not breaking

- **Conversation, not message, is the unit.** A follow-up escalates the existing task rather
  than creating a duplicate. "Hi" then "review it within the hour" is one task at priority 1.
- **Empty `addressing` means "unknown, let the model judge"**, not "drop it". `"Team, please
  complete the deployment doc"` has no signals and must survive. Only a non-empty but
  impersonal set (broadcast-only, or everything ignored) is filtered out. This also makes a
  forgetful Slack client safe: no signals means everything comes through.
- **The merge rules protect user intent.** A follow-up rewrites the model's fields, reopens
  `done` and clears `userPriority`/`snoozedUntil`. A previously failed item is re-triaged while
  preserving those. A good item is never rewritten under the user. Manual items are never
  touched.
- **`Preferences.role`** is what lets the model judge unaddressed channel messages. Measured:
  setting it moved a "please read the rollout notes" message from priority 5 to 1 because the
  role claimed ownership of the API.
- Priority is **1, 2, 4, 5**. There is no 3: `questionAsked` never fired in any run, because a
  question aimed at you *is* a direct request. A rung with no exclusive territory cannot be
  applied consistently.

## Known open items

- Stage-2 split has a grounding guard that never fired in 66 runs, so it is proven only by its
  unit asserts.
- Occasional determinism wobble under concurrency ("Reply Lunch" vs "Reply lunch"), traced to
  the model, not the code.
- Whether the window physically drags, and whether its resize edges are grabbable, both need a
  human. A borderless window has no frame border and the outer 12pt is transparent content.
- `SlackMessageSource` is wired in. `App.swift` hands `Store` a `LiveMessageSource`, which
  checks the Keychain per call, uses Slack when a token exists, and reports `notConnected`
  when it does not. Only demos construct `MockMessageSource`, and `Store.init` has no mock
  default, so production cannot serve fixtures. State files from before the schema-version
  migration drop non-manual todos on load.
