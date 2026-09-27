import SwiftUI

extension RunStatus {
    var color: Color {
        switch self {
        case .preparing, .running: .blue
        case .stopping: .orange
        case .succeeded: .green
        case .failed: .red
        case .stopped, .exited: .secondary
        }
    }
}

struct StatusBadge: View {
    let status: RunStatus
    var body: some View {
        Label(status.title, systemImage: status.symbol)
            .font(.caption).foregroundStyle(status.color)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(status.color.opacity(0.1), in: Capsule())
    }
}

struct TaskScopeBadge: View {
    let scope: TaskSettingsScope
    var body: some View {
        Text(scope.title).font(.caption2).foregroundStyle(scope == .worktree ? .orange : .secondary)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(.quaternary, in: Capsule())
    }
}
