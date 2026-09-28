import Foundation

// The editable IME document is the text that has not been sent to the shell yet.
// Holding it here lets an input method replace committed syllables without
// asking the terminal to erase bytes it already delivered.
struct TerminalInputBuffer {
    private(set) var text = ""
    private(set) var selection = NSRange(location: 0, length: 0)
    private(set) var marked = NSRange(location: NSNotFound, length: 0)

    var isComposing: Bool { marked.location != NSNotFound && marked.length > 0 }

    mutating func mark(_ value: String, selection selected: NSRange, replacement: NSRange) {
        let range = replacementRange(replacement)
        text = (text as NSString).replacingCharacters(in: range, with: value)
        if value.isEmpty {
            marked = NSRange(location: NSNotFound, length: 0)
            selection = NSRange(location: range.location, length: 0)
            return
        }
        marked = NSRange(location: range.location, length: (value as NSString).length)
        let offset = min(max(0, selected.location), marked.length)
        selection = NSRange(location: marked.location + offset,
            length: min(max(0, selected.length), marked.length - offset))
    }

    mutating func commit(_ value: String, replacement: NSRange) {
        let range = replacementRange(replacement)
        text = (text as NSString).replacingCharacters(in: range, with: value)
        selection = NSRange(location: range.location + (value as NSString).length, length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
    }

    mutating func cancelMarkedText() {
        guard marked.location != NSNotFound else { return }
        text = (text as NSString).replacingCharacters(in: marked, with: "")
        selection = NSRange(location: marked.location, length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
    }

    // NSTextInputClient's unmarkText finalizes the composition; the text stays.
    mutating func finalizeMarkedText() {
        guard marked.location != NSNotFound else { return }
        selection = NSRange(location: NSMaxRange(marked), length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
    }

    mutating func flush() -> String {
        let pending = text
        text = ""
        selection = NSRange(location: 0, length: 0)
        marked = NSRange(location: NSNotFound, length: 0)
        return pending
    }

    func substring(_ range: NSRange, actual: NSRangePointer?) -> NSAttributedString? {
        let source = text as NSString
        guard range.location >= 0, range.location < source.length, range.length > 0 else { return nil }
        let clamped = NSRange(location: range.location, length: min(range.length, source.length - range.location))
        actual?.pointee = clamped
        return NSAttributedString(string: source.substring(with: clamped))
    }

    private func replacementRange(_ requested: NSRange) -> NSRange {
        let length = (text as NSString).length
        let fallback = marked.location == NSNotFound ? selection : marked
        let range = requested.location == NSNotFound ? fallback : requested
        guard range.location >= 0, range.location <= length,
            range.length >= 0, range.length <= length - range.location else { return NSRange(location: length, length: 0) }
        return range
    }
}
