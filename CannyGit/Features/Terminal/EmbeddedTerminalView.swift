import AppKit
import SwiftTerm

@MainActor
final class EmbeddedTerminalView: TerminalView {
    var requestInitialFocus = false
    private var accessibilityUpdatePending = false
    private var inputBuffer: TerminalInputBuffer?
    private var flushScheduled = false
    private lazy var outputAccessibility = TerminalOutputAccessibility(view: self)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { inputBuffer = nil }
        if requestInitialFocus, let window {
            requestInitialFocus = false
            window.makeFirstResponder(self)
            #if DEBUG
            if ProcessInfo.processInfo.environment["CANNYGIT_TEST_SETTINGS"] != nil,
                let source = ProcessInfo.processInfo.environment["CANNYGIT_TEST_INPUT_SOURCE"] {
                inputContext?.selectedKeyboardInputSource = source
            }
            #endif
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        finalizeInput()
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }

    // The IME document is only text that has not reached the shell yet. Sending
    // eagerly makes macOS erase committed syllables byte by byte through the PTY,
    // which corrupts UTF-8 and breaks candidate conversion such as Hanja.
    private func flushInput() {
        guard inputBuffer?.isComposing != true else { return }
        guard let pending = inputBuffer?.flush(), !pending.isEmpty else { return }
        super.insertText(pending, replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            self.flushInput()
        }
    }

    private func finalizeInput() {
        if inputBuffer?.isComposing == true { inputBuffer?.cancelMarkedText() }
        flushInput()
    }

    override func selectedRange() -> NSRange {
        inputBuffer?.selection ?? NSRange(location: 0, length: 0)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let text = (string as? NSAttributedString)?.string ?? string as? String else { return }
        if inputBuffer == nil { inputBuffer = TerminalInputBuffer() }
        inputBuffer?.commit(text, replacement: replacementRange)
        // Clear SwiftTerm's marked-text overlay without sending yet. The bytes
        // go out on flush so a later input-method replacement still fits inside
        // the unflushed IME document.
        super.unmarkText()
        scheduleFlush()
    }
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard let text = (string as? NSAttributedString)?.string ?? string as? String else { return }
        if inputBuffer == nil { inputBuffer = TerminalInputBuffer() }
        inputBuffer?.mark(text, selection: selectedRange, replacement: replacementRange)
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
    }
    override func markedRange() -> NSRange { inputBuffer?.marked ?? super.markedRange() }
    override func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        if let inputBuffer { return inputBuffer.substring(range, actual: actualRange) }
        return super.attributedSubstring(forProposedRange: range, actualRange: actualRange)
    }
    override func unmarkText() {
        inputBuffer?.finalizeMarkedText()
        super.unmarkText()
        scheduleFlush()
    }
    override func paste(_ sender: Any) {
        finalizeInput()
        super.paste(sender)
    }
    func userInputWillSend(_ data: ArraySlice<UInt8>) {
        // A direct key send must reach the shell after the pending text, never
        // before it, and must not inherit composing syllables as raw bytes.
        if inputBuffer?.isComposing == true {
            if data.contains(where: { $0 == 0x09 || $0 == 0x0d || $0 == 0x0a }) {
                inputBuffer?.finalizeMarkedText()
            } else if data.contains(where: { $0 < 0x20 || $0 == 0x7f }) {
                inputBuffer?.cancelMarkedText()
            }
        }
        flushInput()
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { String(localized: "터미널") }
    override func accessibilityChildren() -> [Any]? { [outputAccessibility] }

    func accessibilityOutputChanged() {
        guard window != nil, NSWorkspace.shared.isVoiceOverEnabled, !accessibilityUpdatePending else { return }
        accessibilityUpdatePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.accessibilityUpdatePending = false
            NSAccessibility.post(element: self.outputAccessibility, notification: .valueChanged)
        }
    }

    // Read the rendered viewport, not raw ANSI output or the entire scrollback.
    fileprivate var visibleText: String {
        let terminal = getTerminal()
        return (0..<terminal.rows).compactMap {
            terminal.getLine(row: $0)?.translateToString(trimRight: true, skipNullCellsFollowingWide: true,
                                                       characterProvider: { terminal.getCharacter(for: $0) })
        }.joined(separator: "\n")
    }
}

// Keep output accessibility separate from NSTextInputClient's IME document.
private final class TerminalOutputAccessibility: NSAccessibilityElement {
    private let state: TerminalAccessibilityState

    @MainActor init(view: EmbeddedTerminalView) {
        state = TerminalAccessibilityState(view: view)
        super.init()
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(String(localized: "터미널"))
        setAccessibilityIdentifier("terminalContent")
        setAccessibilityParent(view)
    }

    override func accessibilityFrame() -> NSRect { MainActor.assumeIsolated { [state] in state.view?.accessibilityFrame() ?? .zero } }
    override func accessibilityValue() -> Any? { visibleText }
    override func accessibilitySelectedText() -> String? { MainActor.assumeIsolated { [state] in state.view?.getSelection() ?? "" } }
    override func accessibilitySelectedTextRange() -> NSRange {
        MainActor.assumeIsolated { [state] in state.selectedTextRange }
    }
    override func accessibilityInsertionPointLineNumber() -> Int { MainActor.assumeIsolated { [state] in state.view?.getTerminal().getCursorLocation().y ?? 0 } }
    override func accessibilityNumberOfCharacters() -> Int { (visibleText as NSString).length }
    override func accessibilityVisibleCharacterRange() -> NSRange {
        NSRange(location: 0, length: accessibilityNumberOfCharacters())
    }
    override func accessibilityString(for range: NSRange) -> String? {
        let text = visibleText as NSString
        guard range.location >= 0, range.location <= text.length,
            range.length >= 0, range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }
    override func accessibilityRange(forLine line: Int) -> NSRange {
        let lines = visibleText.components(separatedBy: "\n")
        guard lines.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let start = lines.prefix(line).reduce(0) { $0 + ($1 as NSString).length + 1 }
        return NSRange(location: start, length: (lines[line] as NSString).length)
    }
    override func accessibilityLine(for index: Int) -> Int {
        let text = visibleText as NSString
        guard index >= 0, index <= text.length else { return NSNotFound }
        return text.substring(to: index).filter { $0 == "\n" }.count
    }
    private var visibleText: String { MainActor.assumeIsolated { [state] in state.view?.visibleText ?? "" } }
}

@MainActor
private final class TerminalAccessibilityState {
    weak var view: EmbeddedTerminalView?
    init(view: EmbeddedTerminalView) { self.view = view }

    var selectedTextRange: NSRange {
        guard let view else { return NSRange(location: NSNotFound, length: 0) }
        let text = view.visibleText as NSString
        if let selection = view.getSelection() { return text.range(of: selection) }
        let terminal = view.getTerminal(), cursor = terminal.getCursorLocation()
        let lines = view.visibleText.components(separatedBy: "\n")
        guard lines.indices.contains(cursor.y) else { return NSRange(location: text.length, length: 0) }
        let start = lines.prefix(cursor.y).reduce(0) { $0 + ($1 as NSString).length + 1 }
        let prefix = terminal.getLine(row: cursor.y)?.translateToString(startCol: 0, endCol: min(cursor.x, terminal.cols),
            skipNullCellsFollowingWide: true, characterProvider: { terminal.getCharacter(for: $0) }) ?? ""
        return NSRange(location: start + min((prefix as NSString).length, (lines[cursor.y] as NSString).length), length: 0)
    }
}
