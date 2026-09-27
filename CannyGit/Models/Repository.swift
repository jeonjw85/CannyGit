import Foundation

struct Repository: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var path: String
    var commonDirectory: String
    var favorite = false
}

struct WorktreeIdentity: Codable, Sendable {
    var id: UUID
    var repositoryID: UUID
    var path: String
    var gitDirectory: String?
}

struct Worktree: Identifiable, Sendable {
    var id = UUID()
    var repositoryID: UUID
    var path: String
    var gitDirectory: String?
    var head: String?
    var branchRef: String?
    var isMain = false
    var isBare = false
    var isMissing = false
    var locked: String?
    var prunable: String?
    var status: GitStatusSnapshot?
    var error: String?

    var branch: String { branchRef.map { String($0.dropFirst("refs/heads/".count)) } ?? "detached HEAD" }
    var displayName: String { isBare ? "bare" : branch }
    var canExecute: Bool { !isBare && !isMissing && gitDirectory != nil }
}

struct GitFileChange: Identifiable, Sendable, Equatable {
    var path: String
    var originalPath: String?
    var index: Character
    var workingTree: Character
    var isUntracked = false
    var isConflict = false
    var submodule: String = "N..."
    var id: String { path }
}

struct GitStatusSnapshot: Sendable {
    var files: [GitFileChange] = []
    var ignored: [String] = []
    var head: String?
    var branch: String?
    var upstream: String?
    var ahead: Int?
    var behind: Int?
    var isUnborn = false
    var collectedAt = Date()
    var staged: Int { files.filter { !$0.isConflict && !$0.isUntracked && $0.index != "." }.count }
    var unstaged: Int { files.filter { !$0.isConflict && !$0.isUntracked && $0.workingTree != "." }.count }
    var untracked: Int { files.filter(\.isUntracked).count }
    var conflicts: Int { files.filter(\.isConflict).count }
    var isClean: Bool { files.isEmpty }
}

struct GitBranch: Identifiable, Sendable {
    let ref: String
    let commit: String
    var id: String { ref }
    var isLocal: Bool { ref.hasPrefix("refs/heads/") }
    var name: String { String(ref.dropFirst(isLocal ? 11 : 13)) }
}

struct RemovalPreview: Sendable {
    let worktree: Worktree
    let ignoredPaths: [String]
}
