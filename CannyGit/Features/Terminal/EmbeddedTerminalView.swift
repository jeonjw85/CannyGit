import AppKit
import SwiftTerm

@MainActor
final class EmbeddedTerminalView: TerminalView {
    var requestInitialFocus = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if requestInitialFocus, let window {
            requestInitialFocus = false
            window.makeFirstResponder(self)
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}
