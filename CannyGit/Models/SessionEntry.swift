import Foundation
import Observation

@MainActor
@Observable
final class SessionEntry: Identifiable {
    let id: UUID
    let repositoryID: UUID
    let worktreeID: UUID
    let title: String
    let task: TaskDefinition?
    let session: TerminalSession
    let groupRunID: UUID?
    let startedAt = Date()
    var endedAt: Date?
    var ports: [PortObservation] = []
    var portError: String?
    var conflictError: String?
    var portsCheckedAt: Date?
    var conflictsCheckedAt: Date?
    var conflicts: [PortObservation] = []
    var urlCandidates: [URL] = []
    var logTruncated = false

    var status: RunStatus {
        if session.phase == .starting { return .preparing }
        if session.phase == .stopping { return .stopping }
        if session.isActive { return .running }
        if session.phase == .failed { return .failed }
        if session.wasStopped { return .stopped }
        if session.exit == .code(0) { return task?.kind == .once ? .succeeded : .exited }
        return .failed
    }

    init(repositoryID: UUID, worktreeID: UUID, title: String, task: TaskDefinition?, session: TerminalSession, groupRunID: UUID? = nil) {
        self.id = session.id
        self.repositoryID = repositoryID
        self.worktreeID = worktreeID
        self.title = title
        self.task = task
        self.session = session
        self.groupRunID = groupRunID
    }

    var resultDescription: String {
        if let error = session.errorMessage, session.phase == .failed { return error }
        if session.phase == .stopping { return String(localized: "정리 중") }
        if session.phase == .starting { return String(localized: "시작 중") }
        if session.isActive {
            return session.exit != nil ? String(localized: "자식 프로세스 정리 대기")
                : (ports.isEmpty ? String(localized: "실행 중") : String(localized: "실행 중 · LISTEN 확인"))
        }
        if session.wasStopped {
            switch session.exit {
            case .code(let code): return String(localized: "사용자 중지 · 종료 코드 \(code)")
            case .signal(let signal): return String(localized: "사용자 중지 · 신호 \(signal)")
            default: return String(localized: "사용자 중지")
            }
        }
        switch session.exit {
        case .code(let code):
            if code == 0 && task?.kind == .server { return String(localized: "서버 종료 · 코드 0") }
            return code == 0 ? String(localized: "완료 · 종료 0") : String(localized: "종료 코드 \(code)")
        case .signal(let signal): return String(localized: "신호 \(signal)로 종료")
        default: return String(localized: "실행 실패")
        }
    }
}
