import Foundation

@MainActor
final class TaskLogStore {
    private struct Chunk { let sequence: Int; var data: Data }
    private final class Buffer {
        var chunks: [Chunk] = []
        var count = 0
        var truncated = false
    }
    let perRunLimit: Int
    let totalLimit: Int
    private var sequence = 0
    private var buffers: [UUID: Buffer] = [:]
    private(set) var totalBytes = 0
    var onTruncation: ((UUID) -> Void)?

    init(perRunLimit: Int = 5 * 1024 * 1024, totalLimit: Int = 50 * 1024 * 1024) {
        precondition(perRunLimit > 0 && totalLimit > 0)
        self.perRunLimit = perRunLimit
        self.totalLimit = totalLimit
    }

    func append(_ data: ArraySlice<UInt8>, to id: UUID) {
        guard !data.isEmpty else { return }
        let buffer = buffers[id] ?? Buffer()
        if !buffer.truncated && data.count > perRunLimit {
            buffer.truncated = true
            onTruncation?(id)
        }
        var remaining = data.suffix(perRunLimit)
        // Coalesce tiny writes as well as bounding byte counts. Otherwise a
        // stream of single-byte writes would retain millions of Data objects.
        let blockSize = min(32 * 1024, perRunLimit)
        while !remaining.isEmpty {
            if buffer.chunks.isEmpty || buffer.chunks.last!.data.count == blockSize {
                sequence += 1
                buffer.chunks.append(Chunk(sequence: sequence, data: Data()))
            }
            let index = buffer.chunks.count - 1
            let count = min(remaining.count, blockSize - buffer.chunks[index].data.count)
            buffer.chunks[index].data.append(contentsOf: remaining.prefix(count))
            buffer.count += count
            totalBytes += count
            remaining = remaining.dropFirst(count)
        }
        buffers[id] = buffer
        while (buffers[id]?.count ?? 0) > perRunLimit { discardOldest(id) }
        while totalBytes > totalLimit {
            guard let oldest = buffers.filter({ !$0.value.chunks.isEmpty })
                .min(by: { $0.value.chunks[0].sequence < $1.value.chunks[0].sequence })?.key else { break }
            discardOldest(oldest)
        }
    }

    func data(for id: UUID) -> Data {
        buffers[id]?.chunks.reduce(into: Data()) { $0.append($1.data) } ?? Data()
    }

    func isTruncated(_ id: UUID) -> Bool { buffers[id]?.truncated == true }

    func remove(_ id: UUID) {
        if let buffer = buffers.removeValue(forKey: id) { totalBytes -= buffer.count }
    }

    private func discardOldest(_ id: UUID) {
        guard let buffer = buffers[id], !buffer.chunks.isEmpty else { return }
        let count = buffer.chunks.removeFirst().data.count
        buffer.count -= count
        if !buffer.truncated {
            buffer.truncated = true
            onTruncation?(id)
        }
        totalBytes -= count
        buffers[id] = buffer
    }
}
