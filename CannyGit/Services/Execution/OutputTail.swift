import Foundation

// Diagnostic output only. Fixed storage also bounds newline-free output.
struct OutputTail {
    private var bytes: [UInt8]
    private var cursor = 0
    private(set) var count = 0
    private(set) var totalBytes = 0

    init(capacity: Int = 64 * 1024) {
        precondition(capacity > 0)
        bytes = [UInt8](repeating: 0, count: capacity)
    }

    mutating func append(_ data: ArraySlice<UInt8>) {
        totalBytes += data.count
        for byte in data.suffix(bytes.count) {
            bytes[cursor] = byte
            cursor = (cursor + 1) % bytes.count
            count = min(count + 1, bytes.count)
        }
    }

    var data: Data {
        if count < bytes.count { return Data(bytes.prefix(count)) }
        return Data(bytes[cursor...] + bytes[..<cursor])
    }
}
