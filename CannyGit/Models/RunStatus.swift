import Foundation

enum RunStatus: String, Sendable {
    case preparing, running, stopping, succeeded, failed, stopped, exited

    var title: String {
        switch self {
        case .preparing: String(localized: "준비 중")
        case .running: String(localized: "실행 중")
        case .stopping: String(localized: "중지 중")
        case .succeeded: String(localized: "성공")
        case .failed: String(localized: "실패")
        case .stopped: String(localized: "사용자 중지")
        case .exited: String(localized: "종료")
        }
    }

    var symbol: String {
        switch self {
        case .preparing: "hourglass"
        case .running: "play.circle.fill"
        case .stopping: "pause.circle"
        case .succeeded: "checkmark.circle.fill"
        case .failed: "xmark.octagon.fill"
        case .stopped: "stop.circle"
        case .exited: "checkmark.circle"
        }
    }
}

struct TaskResultSummary: Sendable {
    let sessionID: UUID
    let status: RunStatus
    let detail: String
    let startedAt: Date
    let endedAt: Date
    var duration: String { RunDuration.format(endedAt.timeIntervalSince(startedAt)) }
}

enum RunDuration {
    static func format(_ duration: TimeInterval) -> String {
        let seconds = max(0, Int(duration))
        if seconds < 60 { return String(localized: "\(seconds)초") }
        if seconds < 3600 { return String(localized: "\(seconds / 60)분 \(seconds % 60)초") }
        return String(localized: "\(seconds / 3600)시간 \((seconds % 3600) / 60)분")
    }
}
