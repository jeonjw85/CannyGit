import Foundation
import Observation

@MainActor
@Observable
final class TaskCatalogModel {
    private let detector = TaskDetector()
    private var generations: [UUID: UUID] = [:]
    private(set) var reports: [UUID: DetectionReport] = [:]
    private(set) var errors: [UUID: String] = [:]
    private(set) var loading: Set<UUID> = []

    func refresh(worktree: Worktree, preferences: WorktreeTaskPreferences?) async {
        guard worktree.canExecute else { return }
        let generation = UUID()
        generations[worktree.id] = generation
        loading.insert(worktree.id)
        defer { if generations[worktree.id] == generation { loading.remove(worktree.id) } }
        do {
            let report = try await detector.detect(root: URL(fileURLWithPath: worktree.path),
                directory: preferences?.directory ?? ".", preferredManager: preferences?.packageManager)
            guard generations[worktree.id] == generation else { return }
            reports[worktree.id] = report
            errors.removeValue(forKey: worktree.id)
        } catch {
            guard generations[worktree.id] == generation else { return }
            errors[worktree.id] = error.localizedDescription
        }
    }

    func forget(_ worktreeID: UUID) {
        generations.removeValue(forKey: worktreeID)
        reports.removeValue(forKey: worktreeID)
        errors.removeValue(forKey: worktreeID)
        loading.remove(worktreeID)
    }
}
