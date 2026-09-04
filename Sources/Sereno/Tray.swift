import SwiftUI
import AppKit
import OSLog

/// The menu bar status item and the panel that drops from it, both owned outright.
///
/// WHY THIS FILE EXISTS. The panel used to be a `MenuBarExtra` and its height could not be
/// made adjustable. Measured on the owner's machine across one continuous drag: every
/// `setFrame` took effect, and every following line still reported the previous height, so
/// MenuBarExtra re-derives its window's size from the content continuously and wins every
/// time. Five fixes were built on top of that — a top anchor, a pin that only moved the
/// origin, a flag so the pin would not fight itself, a room measurement that had become a
/// feedback loop, whole-point rounding, and a `setFrame` that agreed with SwiftUI one step
/// early. Each was correct about the previous symptom and wrong about the cause. None could
/// win, because the size was never ours.
///
/// Here the frame is uncontested: AppKit places the window where we say, and SwiftUI draws
/// into whatever size it is given. No anchor, no pin, no rounding treaty.
///
/// Everything that decides geometry is a `nonisolated static` pure function taking a screen
/// rect rather than reading `NSScreen`, so `demoTrayGeometry` can check it headlessly. What
/// no assert can check is whether the live panel is placed by those functions at all, so
/// `show()` stays a thin call over `panelFrame` with nothing computed inline, and logs one
/// line a human can compare against the demo's expectations.
private let log = Logger(subsystem: "com.rhystart.sereno", category: "tray")

/// A borderless panel that can still take keyboard focus.
///
/// `canBecomeKey` is false by default for a borderless window, which would leave the compose
/// field untypable — the whole reason this override exists. Probed before the migration:
/// with it, `makeFirstResponder` succeeds and the panel takes key on demand while
/// `becomesKeyOnlyIfNeeded` keeps it from stealing focus from the frontmost app just by
/// being shown.
final class SerenoPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    /// Main belongs to a document window. A dropdown taking main would put this app's menu
    /// bar over whatever the user was actually working in.
    override var canBecomeMain: Bool { false }

    /// Esc closes the panel, handled here rather than with a key monitor: `cancelOperation`
    /// is the responder-chain hook AppKit already routes Esc to.
    override func cancelOperation(_ sender: Any?) { Tray.shared.hide() }
}

@MainActor
final class Tray {
    static let shared = Tray()
    private init() {}

    /// The gap between the menu bar item and the panel's top edge.
    nonisolated static let gap: CGFloat = 5
    /// The panel's fixed width. Height is adjustable, width is not: the row layout is tuned
    /// for this measure, and a free width would mean every row reflowing gracefully from 300
    /// to 700 for no real gain in a menu bar dropdown.
    nonisolated static let width: CGFloat = 360
    /// The smallest a drag may leave the panel.
    ///
    /// Was 161, which was measured on a BARE panel: header, two dividers, footer and the
    /// list's own 72pt floor. That number is wrong in the field, because this app almost
    /// always has an error banner up — the owner's log shows 148 rate-limit failures against
    /// 5 successes in eight hours — and a banner plus the role hint is another ~84pt of
    /// incompressible chrome. A panel at 161 with a banner showing had nowhere to take the
    /// shortfall from but the sky band, which collapsed to a sliver and looked headless.
    ///
    /// 240 = header 44 + dividers 2 + footer 30 + banner 50 + the list's 72 floor, rounded
    /// up. A stored height below it is clamped up on read, so the field's stuck 161 heals
    /// itself on the next open rather than needing the preference cleared by hand.
    nonisolated static let minimumHeight: CGFloat = 240

    // MARK: - Pure geometry, all checkable without a screen

    /// How far down the screen the panel may reach before it would run off the bottom.
    /// Beyond this the list scrolls, which is what the ScrollView is for.
    nonisolated static func room(buttonMinY: CGFloat, screenMinY: CGFloat,
                                gap: CGFloat = Tray.gap) -> CGFloat {
        buttonMinY - gap - screenMinY
    }

    /// The height to give the panel. `manual` is the dragged preference, `content` the
    /// height the SwiftUI content asks for when nothing has been dragged.
    ///
    /// WHOLE POINTS, always, and this is the only place the number is decided. Fractional
    /// heights were the old flicker: a mouse delta gives 190.23, the window rounds to 191,
    /// the layout recomputes from 190.23 and lands somewhere else again. One integral number
    /// everywhere leaves nothing to disagree about.
    ///
    /// When the floor and the room disagree the SCREEN wins: the bottom of a panel taller
    /// than the screen cannot be reached to drag it back. A room of zero or less means "no
    /// screen to measure", which must not collapse the panel, so only the floor applies.
    nonisolated static func panelHeight(manual: Double?, content: CGFloat, room: CGFloat,
                                        minimum: CGFloat = Tray.minimumHeight) -> CGFloat {
        let wanted = max(manual.map { CGFloat($0) } ?? content, minimum)
        guard room > 0 else { return wanted.rounded() }
        return min(wanted, room).rounded()
    }

    /// Where the panel goes: hanging from the button, clamped inside the screen.
    ///
    /// `button` and `screen` are both in screen coordinates and passed in rather than read,
    /// which is what makes this testable AND what keeps a second display working — the
    /// caller passes the button's OWN screen. Reading `NSScreen.main` here instead is the
    /// multi-display bug, and `demoTrayGeometry` asserts against a negative-origin rect
    /// specifically to catch anyone reintroducing it.
    nonisolated static func panelFrame(button: NSRect, size: NSSize, screen: NSRect,
                                       gap: CGFloat = Tray.gap) -> NSRect {
        let centred = button.midX - size.width / 2
        // A status item near the right edge would otherwise hang off the screen.
        let x = min(max(centred, screen.minX), max(screen.minX, screen.maxX - size.width))
        // The top is clamped too, and THAT is the fullscreen bug: reported as the sky band
        // cut off above the screen, and only ever while another app was fullscreen. There
        // the menu bar is hidden, so the status button's own y and the screen's visible
        // frame no longer agree, and `button.minY - gap` can land ABOVE the usable area.
        // Clamping x alone was never enough; it just never showed with the menu bar up.
        let top = min(button.minY - gap, screen.maxY)
        // If holding that top would push the bottom off, give up height rather than
        // position: a panel hanging off the bottom edge cannot be dragged back.
        let height = min(size.height, max(0, top - screen.minY))
        return NSRect(x: x, y: top - height, width: size.width, height: height)
    }

    /// The badge's number. Goes through `Store.visible` so the tray, the panel's header and
    /// the list can never disagree about what counts as outstanding.
    nonisolated static func badgeCount(_ store: Store) -> Int {
        MainActor.assumeIsolated { store.visible.count }
    }

    // MARK: - The status item and the panel

    private var statusItem: NSStatusItem?
    private var panel: SerenoPanel?
    private var hosting: NSHostingView<AnyView>?
    private var clickMonitor: Any?
    private var store: Store?

    var isOpen: Bool { panel?.isVisible == true }

    /// The panel's height as it stands, which is the only correct seed for a resize drag.
    ///
    /// The drag used to seed from `Foreground.panelHeight()`, which returns nil when no
    /// height has been stored, then from a window reference the tray no longer populates,
    /// and so fell through to the FLOOR. Every drag therefore started from 161 whatever the
    /// panel actually was, wrote 161 plus the delta, and collapsed it. Measured in the
    /// field: `manual=271` followed by `manual=161` on every line after.
    var currentHeight: CGFloat {
        panel?.frame.height
            ?? Preferences.shared.popoverHeight.map { CGFloat($0) }
            ?? Tray.minimumHeight
    }

    /// Called once at launch. Nothing in SwiftUI instantiates itself now that the app has no
    /// menu bar scene, so this is the app's only launch-time code path — which is also why
    /// first-run onboarding is triggered from here.
    func install(store: Store, content: @escaping () -> AnyView) {
        self.store = store
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(buttonClicked)
        item.button?.sendAction(on: [.leftMouseUp])
        statusItem = item
        observeBadge()

        let panel = SerenoPanel(
            contentRect: NSRect(x: 0, y: 0, width: Tray.width, height: Tray.minimumHeight),
            // .nonactivatingPanel cannot be added after construction.
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        // Must exceed the .floating level Foreground.applyWindowTraits gives the Sereno
        // window, or a window pinned above other apps would cover this panel.
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        // The app never activates, so deactivation carries no meaning here; the click
        // monitor owns dismissal instead.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // An identifier keeps this panel out of Foreground.managed by construction, so the
        // activation-policy bookkeeping for the real windows cannot pick it up.
        panel.identifier = NSUserInterfaceItemIdentifier("sereno-tray-panel")

        let host = NSHostingView(rootView: content())
        // We own the shape now; MenuBarExtra used to draw it.
        host.wantsLayer = true
        host.layer?.cornerRadius = 12
        host.layer?.cornerCurve = .continuous
        host.layer?.masksToBounds = true
        panel.contentView = host
        hosting = host
        self.panel = panel
        // Force one layout pass so the hosted view's body runs now, before the panel has
        // ever been shown. PanelRoot's onAppear is the app's only launch-time hook — it is
        // what opens first-run onboarding — and without this it would not fire until the
        // user clicked the tray, which is exactly when onboarding is too late to be useful.
        host.layoutSubtreeIfNeeded()
    }

    @objc private func buttonClicked() { toggle() }

    func toggle() { isOpen ? hide() : show() }

    /// Deliberately thin: every number comes from a pure function that a demo checks, and
    /// nothing is computed inline. The one log line is what a human compares against the
    /// demo's expectations, because no assert can prove the live panel is placed by these
    /// functions at all.
    func show() {
        guard let panel, let host = hosting,
              let button = statusItem?.button,
              let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.frame)
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = Tray.panelHeight(
            manual: Preferences.shared.popoverHeight,
            content: host.fittingSize.height,
            room: Tray.room(buttonMinY: buttonRect.minY, screenMinY: screen.minY)
        )
        let frame = Tray.panelFrame(button: buttonRect,
                                    size: NSSize(width: Tray.width, height: height),
                                    screen: screen)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        // The status item stays lit while the panel is up, which is what every native menu
        // bar control does and what tells you at a glance which icon the panel belongs to.
        // MenuBarExtra did this for us; owning the status item means owning this too.
        button.highlight(true)
        addClickMonitor()
        log.info("""
            tray shown frame=\(NSStringFromRect(frame), privacy: .public) \
            button=\(NSStringFromRect(buttonRect), privacy: .public) \
            screen=\(NSStringFromRect(screen), privacy: .public) \
            manual=\(Preferences.shared.popoverHeight ?? -1, privacy: .public)
            """)
    }

    func hide() {
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        removeClickMonitor()
    }

    /// The grip's only writer. Clamps, stores, and re-places the panel from the button, so
    /// the top edge is recomputed every time and no anchor state exists to drift.
    func setHeight(_ wanted: CGFloat) {
        guard let panel, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let buttonRect = buttonWindow.convertToScreen(button.frame)
        let screen = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let height = Tray.panelHeight(
            manual: Double(wanted),
            content: hosting?.fittingSize.height ?? Tray.minimumHeight,
            room: Tray.room(buttonMinY: buttonRect.minY, screenMinY: screen.minY)
        )
        guard abs(height - panel.frame.height) > 0.5 else { return }
        Preferences.shared.popoverHeight = Double(height)
        panel.setFrame(Tray.panelFrame(button: buttonRect,
                                       size: NSSize(width: Tray.width, height: height),
                                       screen: screen), display: true)
    }

    /// Double-clicking the grip: forget the dragged height and fit the content again.
    func clearHeight() {
        Preferences.shared.popoverHeight = nil
        guard isOpen else { return }
        show()
    }

    // MARK: - Dismissal

    /// One global mouse monitor. A global monitor never sees this app's own events, so a
    /// click inside the panel and a click on the status item both fall through with no
    /// hit-testing, while a click into any other app dismisses. Mouse-down monitors need no
    /// Accessibility permission, unlike the keyboard ones.
    private func addClickMonitor() {
        guard clickMonitor == nil else { return }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func removeClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    // MARK: - The badge


    /// No SwiftUI body means no automatic observation, so the dependency is re-armed by hand
    /// after every change. Forgetting this is a badge that silently stops counting.
    private func observeBadge() {
        withObservationTracking {
            updateBadge()
        } onChange: {
            Task { @MainActor [weak self] in self?.observeBadge() }
        }
    }


    private func updateBadge() {
        guard let store, let button = statusItem?.button else { return }
        let count = Tray.badgeCount(store)
        button.image = Tray.trayImage(count: count)
        button.attributedTitle = Tray.trayTitle(count: count) ?? NSAttributedString(string: "")
        button.imagePosition = count > 0 ? .imageLeading : .imageOnly
    }

    /// The tray glyph, as a TEMPLATE image.
    ///
    /// It used to be `isTemplate = false` with a hardcoded black-or-white fill, so it could
    /// carry a red count capsule. That was the wrong trade, and highlighting the button made
    /// it visibly wrong: a hardcoded dark glyph sits on a dark highlight and disappears. A
    /// template image is drawn by AppKit in whatever colour the context needs — light bar,
    /// dark bar, a wallpaper-tinted bar, reduce-transparency, and the highlight — which is
    /// why every native menu bar item is one.
    ///
    /// The count moved out of the image and onto the button's `attributedTitle` in
    /// `labelColor`, for the same reason: the system then owns its colour in every one of
    /// those states, instead of us guessing two of them.
    static func trayImage(count: Int) -> NSImage {
        let renderer = ImageRenderer(content: TrayGlyph(count: count))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = true
        return image
    }

    /// The count, as text beside the glyph. `labelColor` is the whole point: it resolves
    /// against the menu bar's actual appearance and against the highlight, which a baked
    /// colour cannot. Monospaced digits so the item does not jiggle as the number changes.
    nonisolated static func trayTitle(count: Int) -> NSAttributedString? {
        guard count > 0 else { return nil }
        return NSAttributedString(string: " \(count)", attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
    }
}

/// Exactly what the old MenuBarExtra label drew, moved rather than redesigned: the migration
/// should not change how the menu bar looks.
/// Drawn in BLACK regardless of the menu bar. That is not a bug: a template image uses only
/// its alpha channel, so the colour here is ignored and AppKit paints the shape to suit the
/// bar it lands in. Filled when something is waiting, outlined when nothing is, which is a
/// difference you can read at a glance without counting.
///
/// ponytail: still an SF Symbol. Sereno has its own mark — the S as a falling star's trail,
/// already vector code in `SerenoMark` — and nothing draws it anywhere in the app. The menu
/// bar is exactly where a distinctive mark earns its keep, and swapping it in is the next
/// step; `SerenoMark` is `private` to App.swift today.
private struct TrayGlyph: View {
    let count: Int

    var body: some View {
        Image(systemName: count > 0 ? "tray.full.fill" : "tray")
            .font(.system(size: 14))
            .foregroundStyle(.black)
            .padding(.horizontal, 1)
    }
}

// MARK: - Runnable check

/// Geometry only, which is all that can honestly be checked here.
///
/// What this CANNOT cover, and no assert can: whether the live panel is actually placed by
/// `panelFrame`, whether the click monitor dismisses it, whether the compose field takes
/// focus. `Tray.show()` is kept thin over these functions so that reading its one log line
/// against these expectations is a real comparison, and a previous version of this app
/// shipped a check that passed while the panel was visibly broken — the mitigation is
/// structural, not another assert.
func demoTrayGeometry() {
    // A menu bar button in the middle of a 1440x900 screen whose menu bar is 24pt tall.
    let screen = NSRect(x: 0, y: 0, width: 1440, height: 876)
    let button = NSRect(x: 700, y: 876, width: 30, height: 24)

    // The top edge hangs exactly `gap` below the button, at every height.
    for height in [161.0, 320.0, 700.0] as [CGFloat] {
        let frame = Tray.panelFrame(button: button, size: NSSize(width: 360, height: height),
                                    screen: screen)
        assert(frame.maxY == button.minY - Tray.gap,
               "top edge must hang under the button, got \(frame.maxY) for height \(height)")
        assert(frame.height == height, "the requested height must survive placement")
    }

    // Centred under the button when there is room either side.
    let centred = Tray.panelFrame(button: button, size: NSSize(width: 360, height: 300),
                                  screen: screen)
    assert(centred.midX == button.midX, "centred on the button, got \(centred.midX)")

    // Clamped at both edges rather than hanging off. A status item sits near the RIGHT edge
    // on most machines, so this is the common case, not the exotic one.
    let rightEdge = Tray.panelFrame(button: NSRect(x: 1420, y: 876, width: 30, height: 24),
                                    size: NSSize(width: 360, height: 300), screen: screen)
    assert(rightEdge.maxX == screen.maxX, "flush to the right edge, got \(rightEdge.maxX)")
    let leftEdge = Tray.panelFrame(button: NSRect(x: 2, y: 876, width: 30, height: 24),
                                   size: NSSize(width: 360, height: 300), screen: screen)
    assert(leftEdge.minX == screen.minX, "flush to the left edge, got \(leftEdge.minX)")

    // Never outside, anywhere along the bar.
    for x in stride(from: -50.0, through: 1490.0, by: 37.0) {
        let frame = Tray.panelFrame(button: NSRect(x: x, y: 876, width: 30, height: 24),
                                    size: NSSize(width: 360, height: 300), screen: screen)
        assert(frame.minX >= screen.minX && frame.maxX <= screen.maxX,
               "panel escaped the screen at button x=\(x): \(frame)")
    }

    // A display to the LEFT of the main one has a negative origin. This is the assert that
    // catches someone reintroducing NSScreen.main instead of the button's own screen.
    let leftDisplay = NSRect(x: -1920, y: -200, width: 1920, height: 1080)
    let onLeft = Tray.panelFrame(button: NSRect(x: -400, y: 700, width: 30, height: 24),
                                 size: NSSize(width: 360, height: 400), screen: leftDisplay)
    assert(leftDisplay.contains(onLeft),
           "a panel on a negative-origin display must stay on it, got \(onLeft)")

    // Height: the content decides when nothing has been dragged.
    let room = Tray.room(buttonMinY: 876, screenMinY: 0)
    assert(room == 871, "room is the drop from the button to the screen floor, got \(room)")
    assert(Tray.panelHeight(manual: nil, content: 300, room: room) == 300,
           "no dragged height means fit the content")
    assert(Tray.panelHeight(manual: 480, content: 300, room: room) == 480,
           "a dragged height wins over the content")
    assert(Tray.panelHeight(manual: 10, content: 300, room: room) == Tray.minimumHeight,
           "the floor stops a drag leaving an unusable panel")
    assert(Tray.panelHeight(manual: 4000, content: 300, room: room) == room,
           "the screen caps it, got \(Tray.panelHeight(manual: 4000, content: 300, room: room))")
    // Screen beats the floor: the bottom of an over-tall panel cannot be reached to drag back.
    assert(Tray.panelHeight(manual: 4000, content: 300, room: 120) == 120,
           "room wins over the floor when they disagree")
    // No screen to measure must not collapse the panel.
    assert(Tray.panelHeight(manual: 400, content: 300, room: 0) == 400,
           "an unmeasurable screen still honours a request above the floor")
    assert(Tray.panelHeight(manual: 10, content: 300, room: -5) == Tray.minimumHeight,
           "an unmeasurable screen still honours the floor")
    // Whole points, and clamping a clamped value is stable — that is what makes the stored
    // preference safe to reuse on a different screen after a relaunch.
    let once = Tray.panelHeight(manual: 190.23, content: 300, room: room)
    assert(once == once.rounded(), "heights are whole points, got \(once)")
    assert(Tray.panelHeight(manual: Double(once), content: 300, room: room) == once,
           "re-clamping must be stable")

    // A manual height far beyond the room must still leave the panel on the screen.
    let tall = Tray.panelHeight(manual: 5000, content: 300, room: room)
    let tallFrame = Tray.panelFrame(button: button, size: NSSize(width: 360, height: tall),
                                    screen: screen)
    assert(tallFrame.minY >= screen.minY,
           "an over-tall panel must not run off the bottom, got \(tallFrame)")

    // THE FULLSCREEN CASE, reported from the field: "it happens only when another app is
    // fullscreen". With the menu bar hidden the button's y and the screen's visible frame
    // stop agreeing, so the requested top can sit above the usable area. Clamping x alone
    // let the panel's header run off the top of the screen.
    let above = Tray.panelFrame(button: NSRect(x: 700, y: 1200, width: 30, height: 24),
                                size: NSSize(width: 360, height: 400), screen: screen)
    assert(above.maxY <= screen.maxY,
           "a button above the visible frame must not push the panel off the top, got \(above)")
    assert(above.minY >= screen.minY, "and not off the bottom either, got \(above)")
    assert(screen.contains(above), "the whole panel stays on the screen, got \(above)")

    // A screen so short that the panel cannot fit gives up HEIGHT, never position: a panel
    // hanging off the bottom edge has no grip left to drag it back with.
    let shallow = NSRect(x: 0, y: 0, width: 1440, height: 300)
    let squeezed = Tray.panelFrame(button: NSRect(x: 700, y: 300, width: 30, height: 24),
                                   size: NSSize(width: 360, height: 900), screen: shallow)
    assert(shallow.contains(squeezed), "a panel taller than the screen is trimmed, got \(squeezed)")
    assert(squeezed.maxY == shallow.maxY - Tray.gap || squeezed.maxY <= shallow.maxY,
           "the top still hangs under the button where it can")

    print("demoTrayGeometry: PASS room \(room), floor \(Tray.minimumHeight)")
}
