import Foundation

struct PortObservation: Identifiable, Hashable, Sendable {
    var pid: Int32
    var processName: String
    var host: String
    var port: Int
    var id: String { "\(pid):\(host):\(port)" }

    func browserURL(scheme: String) -> URL? {
        guard ["http", "https"].contains(scheme) else { return nil }
        let address = ["*", "0.0.0.0", "::"].contains(host) ? "localhost" : host
        return URL(string: "\(scheme)://\(address.contains(":") ? "[\(address)]" : address):\(port)")
    }
}

actor PortService {
    private let runner: CommandRunner
    init(runner: CommandRunner = CommandRunner()) { self.runner = runner }

    func observe(_ identities: [ProcessIdentity]) async throws -> [PortObservation] {
        guard !identities.isEmpty else { return [] }
        let pids = Set(identities.map(\.pid)).sorted().map(String.init).joined(separator: ",")
        let observations = try await query(["-a", "-p", pids, "-iTCP", "-sTCP:LISTEN"])
        let valid = Set(identities.filter { ProcessSnapshot.read($0.pid)?.identity == $0 }.map(\.pid))
        return observations.filter { valid.contains($0.pid) }
    }

    func conflicts(ports: [Int]) async throws -> [PortObservation] {
        guard !ports.isEmpty else { return [] }
        guard ports.allSatisfy({ (1...65535).contains($0) }) else { throw ExecutionError(message: "포트 범위가 올바르지 않습니다.") }
        return try await query(["-iTCP:" + ports.map(String.init).joined(separator: ","), "-sTCP:LISTEN"])
    }

    private func query(_ arguments: [String]) async throws -> [PortObservation] {
        let result = try await runner.run(ProcessRequest(executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-F0pcn"] + arguments, timeout: .seconds(5), outputLimit: 1024 * 1024))
        if result.status == 1 && result.stdout.isEmpty && result.stderr.isEmpty { return [] }
        guard result.status == 0 else {
            throw ExecutionError(message: "포트 조회 실패: \(String(decoding: result.stderr, as: UTF8.self))")
        }
        return try Self.parse(result.stdout)
    }

    static func parse(_ data: Data) throws -> [PortObservation] {
        var pid: Int32?
        var name = ""
        var result: Set<PortObservation> = []
        for raw in data.split(separator: 0) {
            let field = raw.drop(while: { $0 == 10 })
            guard let type = field.first else { continue }
            let value = try GitParser.text(field.dropFirst())
            switch type {
            case 112:
                guard let number = Int32(value) else { throw ExecutionError(message: "포트 조회 결과의 PID가 올바르지 않습니다.") }
                pid = number
                name = ""
            case 99: name = value
            case 110:
                guard let pid, let separator = value.lastIndex(of: ":"),
                    let port = Int(value[value.index(after: separator)...]), (1...65535).contains(port)
                else { throw ExecutionError(message: "리스닝 주소를 해석할 수 없습니다.") }
                let host = String(value[..<separator]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                result.insert(PortObservation(pid: pid, processName: name, host: host, port: port))
            default: break
            }
        }
        return result.sorted { ($0.port, $0.pid, $0.host) < ($1.port, $1.pid, $1.host) }
    }
}
