import CryptoKit
import Foundation

actor TaskDetector {
    static let managers = ["npm", "pnpm", "yarn", "bun"]

    func detect(root: URL, directory: String, preferredManager: String?) throws -> DetectionReport {
        let folder = try Self.directory(root: root, relative: directory)
        var report = DetectionReport()
        var fingerprint = Data()
        let managerFiles = [
            "package-lock.json": "npm", "npm-shrinkwrap.json": "npm", "pnpm-lock.yaml": "pnpm",
            "yarn.lock": "yarn", "bun.lock": "bun", "bun.lockb": "bun",
        ]
        let present = managerFiles.keys.sorted().filter { FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path) }
        var choices = Set(present.compactMap { managerFiles[$0] })
        fingerprint.append(Data(present.joined(separator: "\n").utf8))
        let manifest = folder.appendingPathComponent("package.json")
        if FileManager.default.fileExists(atPath: manifest.path) {
            let handle = try FileHandle(forReadingFrom: manifest)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: 1024 * 1024 + 1) ?? Data()
            guard data.count <= 1024 * 1024 else { throw ExecutionError(message: "package.json이 읽기 한도를 초과했습니다.") }
            fingerprint.append(data)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ExecutionError(message: "package.json의 최상위 값은 객체여야 합니다.")
            }
            if let declared = json["packageManager"] as? String,
                let name = declared.split(separator: "@").first.map(String.init), Self.managers.contains(name) {
                choices.insert(name)
            }
            let manager: String?
            if let preferredManager, Self.managers.contains(preferredManager) { manager = preferredManager }
            else { manager = choices.count <= 1 ? (choices.first ?? "npm") : nil }
            report.packageManagers = choices.sorted()
            if manager == nil { report.notices.append(String(localized: "패키지 매니저 단서가 충돌합니다. 사용할 실행기를 선택하세요.")) }
            if json["scripts"] != nil && !(json["scripts"] is [String: String]) {
                throw ExecutionError(message: "package.json scripts에는 문자열 명령만 사용할 수 있습니다.")
            }
            let scripts = json["scripts"] as? [String: String] ?? [:]
            for key in scripts.keys.sorted() {
                let content = scripts[key]!
                let definition = TaskDefinition(
                    id: Self.taskID("package-script", directory, key), name: key,
                    command: .executable(manager ?? "npm", ["run", "--", key]), directory: directory,
                    kind: ["dev", "start", "serve", "watch"].contains(key) ? .server : .once,
                    source: manifest.path, sourceFingerprint: Self.digest(Data(content.utf8))
                )
                report.candidates.append(TaskCandidate(definition: definition, notice: content, needsPackageManager: manager == nil))
            }
            report.candidates.append(TaskCandidate(definition: TaskDefinition(
                id: Self.taskID("package-install", directory, ""), name: String(localized: "의존성 설치"),
                command: .executable(manager ?? "npm", ["install"]), directory: directory, source: manifest.path
            ), needsPackageManager: manager == nil))
        }
        let presets: [(String, String, [[String]])] = [
            ("Cargo.toml", "cargo", [["build"], ["test"], ["check"]]),
            ("go.mod", "go", [["build", "./..."], ["test", "./..."]]),
            ("Package.swift", "swift", [["build"], ["test"]]),
        ]
        for (file, executable, commands) in presets where FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path) {
            fingerprint.append(Data(file.utf8))
            for arguments in commands {
                report.candidates.append(TaskCandidate(definition: TaskDefinition(
                    id: Self.taskID(file, directory, arguments[0]), name: "\(executable) \(arguments[0])",
                    command: .executable(executable, arguments), directory: directory,
                    source: folder.appendingPathComponent(file).path
                )))
            }
        }
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent("pyproject.toml").path) {
            report.notices.append(String(localized: "Python 프로젝트입니다. 사용할 실행기와 작업 명령을 직접 등록하세요."))
        }
        report.fingerprint = Self.digest(fingerprint)
        return report
    }

    static func directory(root: URL, relative: String) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.utf8.contains(0) else {
            throw ExecutionError(message: "작업 디렉터리는 워크트리 기준 상대 경로여야 합니다.")
        }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let folder = base.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard (folder.path == base.path || folder.path.hasPrefix(base.path + "/")),
            FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue
        else { throw ExecutionError(message: "작업 디렉터리가 없거나 워크트리 바깥을 가리킵니다.") }
        return folder
    }

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func taskID(_ source: String, _ directory: String, _ command: String) -> String {
        [source, directory, command].map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }
}

enum TaskCatalog {
    static func merge(_ report: DetectionReport, rules: [TaskRule], repositoryID: UUID, worktreeID: UUID) -> [TaskCandidate] {
        var effective: [String: TaskRule] = [:]
        for rule in rules where rule.repositoryID == repositoryID && rule.worktreeID == nil {
            effective[rule.definition.id] = rule
        }
        for rule in rules where rule.repositoryID == repositoryID && rule.worktreeID == worktreeID {
            effective[rule.definition.id] = rule
        }
        var candidates = report.candidates
        var hidden: Set<String> = []
        for index in candidates.indices {
            guard let rule = effective.removeValue(forKey: candidates[index].id) else { continue }
            let changed = rule.definition.sourceFingerprint != candidates[index].definition.sourceFingerprint
            var definition = rule.definition
            definition.source = candidates[index].definition.source
            candidates[index] = TaskCandidate(
                definition: definition,
                notice: changed ? String(localized: "탐지 원본이 변경되었습니다. 저장한 명령은 유지됩니다.") : String(localized: "사용자 설정"),
                isCustomized: true, scope: rule.worktreeID == nil ? .repository : .worktree
            )
            if rule.hidden { hidden.insert(rule.definition.id) }
        }
        for rule in effective.values where !rule.hidden {
            candidates.append(TaskCandidate(definition: rule.definition,
                notice: rule.definition.source == nil ? nil : String(localized: "탐지 원본이 없거나 탐지 디렉터리가 변경되었습니다."),
                isCustomized: true, scope: rule.worktreeID == nil ? .repository : .worktree))
        }
        return candidates.filter { !hidden.contains($0.id) }.sorted { $0.definition.name.localizedStandardCompare($1.definition.name) == .orderedAscending }
    }
}
