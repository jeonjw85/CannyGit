import Foundation

struct AppSettings: Codable, Sendable {
    var schemaVersion = 2
    var repositories: [Repository] = []
    var worktreeIdentities: [WorktreeIdentity] = []
    var taskRules: [TaskRule] = []
    var taskPreferences: [WorktreeTaskPreferences] = []
    var taskGroups: [TaskGroupDefinition] = []
    var selectedRepositoryID: UUID?
    var selectedWorktreeID: UUID?
    var gitPath = "/usr/bin/git"
    var shellPath = TerminalLaunch.accountShell
    var editorPath = "/Applications/Visual Studio Code.app"

    init() {}

    enum CodingKeys: String, CodingKey {
        case schemaVersion, repositories, worktreeIdentities, taskRules, taskPreferences, taskGroups
        case selectedRepositoryID, selectedWorktreeID, gitPath, shellPath, editorPath
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        repositories = try values.decode([Repository].self, forKey: .repositories)
        worktreeIdentities = try values.decodeIfPresent([WorktreeIdentity].self, forKey: .worktreeIdentities) ?? []
        taskRules = try values.decodeIfPresent([TaskRule].self, forKey: .taskRules) ?? []
        taskPreferences = try values.decodeIfPresent([WorktreeTaskPreferences].self, forKey: .taskPreferences) ?? []
        taskGroups = try values.decodeIfPresent([TaskGroupDefinition].self, forKey: .taskGroups) ?? []
        selectedRepositoryID = try values.decodeIfPresent(UUID.self, forKey: .selectedRepositoryID)
        selectedWorktreeID = try values.decodeIfPresent(UUID.self, forKey: .selectedWorktreeID)
        gitPath = try values.decodeIfPresent(String.self, forKey: .gitPath) ?? gitPath
        shellPath = try values.decodeIfPresent(String.self, forKey: .shellPath) ?? shellPath
        editorPath = try values.decodeIfPresent(String.self, forKey: .editorPath) ?? editorPath
    }
}
