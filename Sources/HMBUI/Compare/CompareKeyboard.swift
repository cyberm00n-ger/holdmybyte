// Compare's single-letter keys (Docs/SPEC.md §2.8): Z, \ (hold or tap), D, Y, I, ← →, Esc.
// A local event monitor sees the keys before the main menu, which `\` needs: holding requires the key-up, which a
// menu key equivalent never delivers. It only acts while the canvas's window is key, no sheet is attached and no
// text field is being edited, so the same keys keep working everywhere else. On ISO keyboards (German layout:
// `\` is ⌥⇧7), the key left of Return (key code 42, `#`) works as `\` too.
import AppKit
import HMBModel

@MainActor final class CompareKeyboard {
    private var monitor: Any?
    private var resignObserver: (any NSObjectProtocol)?
    private var originalPress: (keyCode: UInt16, started: Bool, at: ContinuousClock.Instant)?

    static let backslashKeyCode: UInt16 = 42
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let escape: UInt16 = 53

    func install(model: AppModel, proxy: CompareCanvasProxy) {
        remove()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self, weak model] event in
            // Local monitors run on the main thread.
            nonisolated(unsafe) let unsafeEvent = event
            let consumed = MainActor.assumeIsolated {
                guard let self, let model else { return false }
                return self.handle(unsafeEvent, model: model, proxy: proxy)
            }
            return consumed ? nil : event
        }
        // Holding `\` while the window stops being key (⌘-Tab, a click elsewhere): the key-up goes to another
        // window, so end the hold here instead of leaving the original shown.
        resignObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: nil,
                                                                queue: .main) { [weak self, weak model] note in
            nonisolated(unsafe) let window = note.object as AnyObject?
            MainActor.assumeIsolated {
                guard let self, let model, self.originalPress != nil, window === proxy.window else { return }
                self.originalPress = nil
                model.compareOriginalHoldInterrupted()
            }
        }
    }

    func remove() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        monitor = nil
        resignObserver = nil
        originalPress = nil
    }

    /// Returns true when the event was consumed.
    func handle(_ event: NSEvent, model: AppModel, proxy: CompareCanvasProxy) -> Bool {
        guard let window = proxy.window, event.window === window, window.isKeyWindow, window.attachedSheet == nil,
              !(window.firstResponder is NSText), model.state.compare != nil else { return false }
        if event.type == .keyUp {
            guard let press = originalPress, press.keyCode == event.keyCode else { return false }
            originalPress = nil
            let held = ContinuousClock.now - press.at
            model.compareOriginalKeyUp(heldFor: Double(held.components.seconds) + Double(held.components.attoseconds) / 1e18,
                                       pressStarted: press.started)
            return true
        }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let characters = event.charactersIgnoringModifiers ?? ""
        if event.characters == "\\" || (event.keyCode == Self.backslashKeyCode && modifiers.isEmpty) {
            if event.isARepeat { return true }
            // A new (non-repeat) press while a hold is still showing means its key-up was lost: end that hold first.
            model.compareOriginalHoldInterrupted()
            originalPress = (event.keyCode, model.compareOriginalKeyDown(), .now)
            return true
        }
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case Self.leftArrow: model.stepCompare(by: -1); return true
        case Self.rightArrow: model.stepCompare(by: 1); return true
        case Self.escape: model.closeCompare(); return true
        default: break
        }
        switch characters.lowercased() {
        case "z":
            Self.toggleZoom(model: model, proxy: proxy, atCursor: true)
        case "d":
            model.toggleCompareDifferences()
        case "y":
            model.toggleCompareMode()
        case "i":
            model.toggleCompareInspector()
        default:
            return false
        }
        return true
    }

    /// Fit → 100 % at the cursor (or the centre when the cursor is outside the canvas); 100 % → Fit.
    static func toggleZoom(model: AppModel, proxy: CompareCanvasProxy, atCursor: Bool, point: CGPoint? = nil) {
        guard let compare = model.state.compare else { return }
        guard compare.zoom == .fit, let geometry = proxy.geometry else { return model.toggleCompareZoom() }
        var anchor = point ?? (atCursor ? proxy.cursor : nil)
        if let a = anchor, !CGRect(origin: .zero, size: geometry.viewSize).contains(a) { anchor = nil }
        model.toggleCompareZoom(center: geometry.centerForZoomIn(at: anchor, fitCenter: compare.zoomCenter))
    }
}
