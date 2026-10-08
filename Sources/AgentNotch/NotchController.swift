import AppKit
import Combine
import SwiftUI

/// Borderless panel that sits over the menu bar at the notch, on every Space and over
/// full-screen apps. It only takes keyboard focus when you open it with the hotkey, and being
/// non-activating, even then the app in front stays in front.
final class NotchPanel: NSPanel {
    /// True while opened with the hotkey.
    var acceptsKeyboard = false
    var onKey: ((NotchKey) -> Bool)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 8)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { acceptsKeyboard }
    override var canBecomeMain: Bool { false }

    override func keyDown(with event: NSEvent) {
        let key: NotchKey?
        switch Int(event.keyCode) {
        case 126: key = .up
        case 125: key = .down
        case 36, 76: key = .return
        case 53: key = .escape
        case 51, 117: key = .delete
        default: key = event.charactersIgnoringModifiers?.lowercased().first.map(NotchKey.character)
        }
        // Unhandled keys are dropped quietly rather than beeping.
        if let key { _ = onKey?(key) }
    }

    override func sendEvent(_ event: NSEvent) {
        if [.leftMouseDown, .leftMouseUp].contains(event.type) {
            Log.debug("panel got \(event.type == .leftMouseDown ? "mouse down" : "mouse up") at \(event.locationInWindow), key=\(isKeyWindow)")
        }
        super.sendEvent(event)
    }

    /// Borderless windows may cover the menu bar; don't let AppKit push the panel down.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// Buttons react on the first click even though the panel never becomes key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
final class NotchController {
    /// The panel is sized for the largest state; only the drawn shape takes clicks.
    static let panelSize = CGSize(width: 780, height: 560)

    private let model: NotchModel
    private let panel = NotchPanel()
    private var screen: NSScreen?
    private var timer: Timer?
    private var outsideTicks = 0
    private var screenTicks = 0
    private var observers: [NSObjectProtocol] = []
    private var keyboard: AnyCancellable?

    init(model: NotchModel) {
        self.model = model
        let host = FirstMouseHostingView(rootView: NotchRootView().environmentObject(model))
        host.sizingOptions = []
        panel.contentView = host
        layout(on: NotchController.screenUnderCursor() ?? NotchGeometry.preferredScreen())
        panel.orderFrontRegardless()

        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout(on: NotchController.screenUnderCursor() ?? NotchGeometry.preferredScreen()) }
        })

        // Hotkey mode: take keystrokes while open, hand them back when closed or clicked away from.
        panel.onKey = { [weak model] key in
            MainActor.assumeIsolated { model?.handleKey(key) ?? false }
        }
        keyboard = model.$keyboardOpen.removeDuplicates().sink { [weak self] open in
            MainActor.assumeIsolated { self?.setKeyboard(open) }
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: panel, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Log.debug("panel lost keyboard focus (keyboardOpen=\(self?.model.keyboardOpen == true))")
                if self?.model.keyboardOpen == true { self?.model.closePanel() }
            }
        })

        // Polling the cursor at 10 Hz is the one approach that works for a non-activating panel
        // over the menu bar, whichever app is in front, and costs next to nothing.
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.trackMouse() }
        }
    }

    private func setKeyboard(_ open: Bool) {
        Log.debug("keyboard \(open ? "open" : "closed"), panel key before: \(panel.isKeyWindow)")
        if open {
            // Open on the screen you're working on.
            if let target = NotchController.screenUnderCursor(), target != screen { layout(on: target) }
            panel.acceptsKeyboard = true
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.acceptsKeyboard = false
            if panel.isKeyWindow {
                // Ordering out gives keyboard focus back to the app in front.
                panel.orderOut(nil)
                panel.orderFrontRegardless()
            }
        }
    }

    static func screenUnderCursor() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) }
    }

    private func layout(on target: NSScreen?) {
        guard let screen = target else { return }
        self.screen = screen
        model.geometry = NotchGeometry(screen: screen)
        let size = NotchController.panelSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                           width: size.width, height: size.height)
        panel.setFrame(frame, display: true)
    }

    /// The notch lives on the screen you're working on: move it when the cursor has stayed on
    /// another screen for a moment, unless you're in the middle of using it.
    private func followCursorAcrossScreens(_ point: NSPoint) {
        guard let target = NSScreen.screens.first(where: { NSMouseInRect(point, $0.frame, false) }),
              target != screen, !model.hovering, !model.keyboardOpen else {
            screenTicks = 0
            return
        }
        screenTicks += 1
        if screenTicks >= 3 {
            screenTicks = 0
            Log.debug("moving to \(target.localizedName)")
            layout(on: target)
        }
    }

    /// The area the shape currently covers, in screen coordinates.
    private func hotRect() -> NSRect {
        var size = model.shapeSize
        if size == .zero { size = CGSize(width: model.geometry.width, height: model.geometry.height) }
        return topCentred(size)
    }

    /// Where hovering can begin: the notch itself (plus its status ears when they're showing),
    /// never the open panel. A card that drops open under a resting cursor must not count as a
    /// hover, or the panel stays open, catching clicks, after the card is answered.
    private func notchRect() -> NSRect {
        let geometry = model.geometry
        let ears = model.board.isActive(at: Date()) ? 2 * Metrics.earWidth : 0
        return topCentred(CGSize(width: geometry.width + ears + 2 * Metrics.flare, height: geometry.height))
    }

    /// A rect hanging from the top centre of the notch screen. Reaches 2pt above the edge: the
    /// cursor's y can equal maxY at the very top.
    private func topCentred(_ size: CGSize) -> NSRect {
        guard let screen else { return .zero }
        return NSRect(x: screen.frame.midX - size.width / 2, y: screen.frame.maxY - size.height,
                      width: size.width, height: size.height + 2)
    }

    /// Geometry snapshot for `GET /debug/state` (debug builds of the log only).
    func debugState() -> [String: String] {
        [
            "mode": "\(model.mode)",
            "hovering": "\(model.hovering)",
            "shapeSize": "\(model.shapeSize)",
            "hotRect": "\(hotRect())",
            "notchRect": "\(notchRect())",
            "mouse": "\(NSEvent.mouseLocation)",
            "panelFrame": "\(panel.frame)",
            "ignoresMouseEvents": "\(panel.ignoresMouseEvents)",
            "keyboardOpen": "\(model.keyboardOpen)",
            "panelIsKey": "\(panel.isKeyWindow)",
            "screenName": screen?.localizedName ?? "-",
            "screen": "\(screen?.frame ?? .zero)",
        ]
    }

    private func trackMouse() {
        let point = NSEvent.mouseLocation
        followCursorAcrossScreens(point)
        let overShape = hotRect().insetBy(dx: -2, dy: -2).contains(point)
        // Clicks land on whatever is drawn (cards included); everywhere else passes through.
        panel.ignoresMouseEvents = !overShape

        if model.hovering {
            if overShape {
                outsideTicks = 0
            } else {
                // A short grace period so the panel doesn't snap shut when the cursor grazes the edge.
                outsideTicks += 1
                if outsideTicks >= 3 {
                    Log.debug("cursor left the panel")
                    model.setHovering(false)
                }
            }
        } else if notchRect().contains(point) {
            Log.debug("cursor entered the notch")
            outsideTicks = 0
            model.setHovering(true)
        }
    }
}
