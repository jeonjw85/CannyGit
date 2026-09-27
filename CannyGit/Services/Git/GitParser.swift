import Foundation

enum GitParser {
    static func text(_ bytes: some Collection<UInt8>) throws -> String {
        guard let value = String(bytes: bytes, encoding: .utf8) else {
            throw ExecutionError(message: "Git 경로 또는 출력을 UTF-8로 표현할 수 없습니다.")
        }
        return value
    }

    static func line(_ data: Data) throws -> String {
        guard data.last == 10 else { throw malformed() }
        return try text(data.dropLast())
    }

    static func worktrees(_ data: Data, repositoryID: UUID) throws -> [Worktree] {
        guard data.last == 0 else { throw malformed() }
        var result: [Worktree] = []
        var record: Worktree?
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            if field.isEmpty {
                if var item = record {
                    guard item.isBare || item.head != nil else { throw malformed() }
                    item.isMain = result.isEmpty
                    result.append(item)
                    record = nil
                }
                continue
            }
            let pair = field.split(separator: 32, maxSplits: 1, omittingEmptySubsequences: false)
            let key = try text(pair[0])
            let value = pair.count == 2 ? try text(pair[1]) : ""
            if key == "worktree" {
                guard record == nil, value.hasPrefix("/") else { throw malformed() }
                record = Worktree(repositoryID: repositoryID, path: value)
            } else {
                guard record != nil else { throw malformed() }
                switch key {
                case "HEAD": record?.head = value
                case "branch":
                    guard value.hasPrefix("refs/heads/") else { throw malformed() }
                    record?.branchRef = value
                case "bare": record?.isBare = true
                case "detached": record?.branchRef = nil
                case "locked": record?.locked = value
                case "prunable": record?.prunable = value
                default: break
                }
            }
        }
        guard record == nil, !result.isEmpty else { throw malformed() }
        return result
    }

    static func status(_ data: Data) throws -> GitStatusSnapshot {
        guard !data.isEmpty, data.last == 0 else { throw malformed() }
        let records = data.split(separator: 0)
        var result = GitStatusSnapshot()
        var index = 0
        var sawHead = false
        var sawBranch = false
        while index < records.count {
            let record = records[index]
            index += 1
            guard let type = record.first else { continue }
            if type == 35 {
                let header = try text(record)
                if header.hasPrefix("# branch.oid ") {
                    sawHead = true
                    let value = String(header.dropFirst(13))
                    result.isUnborn = value == "(initial)"
                    result.head = result.isUnborn ? nil : value
                } else if header.hasPrefix("# branch.head ") {
                    sawBranch = true
                    let value = String(header.dropFirst(14))
                    result.branch = value == "(detached)" ? nil : value
                } else if header.hasPrefix("# branch.upstream ") {
                    result.upstream = String(header.dropFirst(18))
                } else if header.hasPrefix("# branch.ab ") {
                    let counts = header.dropFirst(12).split(separator: " ")
                    guard counts.count == 2, counts[0].hasPrefix("+"), counts[1].hasPrefix("-"),
                        let ahead = Int(counts[0]), let behind = Int(counts[1]), ahead >= 0, behind <= 0 else { throw malformed() }
                    result.ahead = ahead
                    result.behind = abs(behind)
                }
            } else if type == 63 || type == 33 {
                guard record.count >= 3, record[record.index(after: record.startIndex)] == 32 else { throw malformed() }
                let path = try text(record.dropFirst(2))
                if type == 33 { result.ignored.append(path) }
                else { result.files.append(GitFileChange(path: path, index: "?", workingTree: "?", isUntracked: true)) }
            } else if type == 49 || type == 50 || type == 117 {
                let fieldCount = type == 49 ? 8 : (type == 50 ? 9 : 10)
                let fields = record.split(separator: 32, maxSplits: fieldCount, omittingEmptySubsequences: false)
                guard fields.count == fieldCount + 1 else { throw malformed() }
                let xy = Array(try text(fields[1]))
                guard xy.count == 2 else { throw malformed() }
                var file = GitFileChange(
                    path: try text(fields[fieldCount]), index: xy[0], workingTree: xy[1],
                    isConflict: type == 117, submodule: try text(fields[2])
                )
                if type == 50 {
                    guard index < records.count else { throw malformed() }
                    file.originalPath = try text(records[index])
                    index += 1
                }
                result.files.append(file)
            } else {
                // An unknown record could represent a dirty file. Never report clean.
                throw malformed()
            }
        }
        guard sawHead, sawBranch else { throw malformed() }
        return result
    }

    static func branches(_ data: Data) throws -> [GitBranch] {
        try data.split(separator: 10).map { record in
            let values = record.split(separator: 0, omittingEmptySubsequences: false)
            guard values.count == 3, values[2].isEmpty else { throw malformed() }
            return GitBranch(ref: try text(values[0]), commit: try text(values[1]))
        }
    }

    private static func malformed() -> ExecutionError {
        ExecutionError(message: "Git 출력 형식을 해석할 수 없습니다. 조회 결과를 사용하지 않습니다.")
    }
}
