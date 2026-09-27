import Foundation

enum TaskCommand: Codable, Equatable, Sendable {
    case executable(String, [String])
    case shell(String)

    var display: String {
        switch self {
        case .shell(let command): command
        case .executable(let executable, let arguments):
            ([executable] + arguments).map(Self.quote).joined(separator: " ")
        }
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

enum TaskKind: String, Codable, CaseIterable, Sendable {
    case once, server
    var title: String { self == .once ? String(localized: "일회성 작업") : String(localized: "서버") }
}

struct TaskDefinition: Codable, Identifiable, Equatable, Sendable {
    var id: String = UUID().uuidString
    var name: String
    var command: TaskCommand
    var directory = "."
    var kind: TaskKind = .once
    var source: String?
    var sourceFingerprint: String?
    var environmentReferences: [String: String] = [:]
    var expectedPorts: [Int] = []
    var serverURL = ""
}

struct TaskRule: Codable, Identifiable, Sendable {
    var id = UUID()
    var repositoryID: UUID
    var worktreeID: UUID?
    var definition: TaskDefinition
    var hidden = false
}

enum TaskSettingsScope: Sendable {
    case detected, repository, worktree
    var title: String {
        switch self {
        case .detected: String(localized: "자동 탐지")
        case .repository: String(localized: "저장소 공통")
        case .worktree: String(localized: "워크트리 전용")
        }
    }
}

struct TaskCandidate: Identifiable, Sendable {
    var definition: TaskDefinition
    var notice: String?
    var needsPackageManager = false
    var isCustomized = false
    var scope: TaskSettingsScope = .detected
    var id: String { definition.id }
}

struct DetectionReport: Sendable {
    var candidates: [TaskCandidate] = []
    var notices: [String] = []
    var packageManagers: [String] = []
    var fingerprint = ""
}

struct WorktreeTaskPreferences: Codable, Sendable {
    var worktreeID: UUID
    var directory = "."
    var packageManager: String?
}
