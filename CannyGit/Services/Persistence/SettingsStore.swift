import Foundation

actor SettingsStore {
    let url: URL
    private var loaded = false
    private var lastRevision = -1
    var backupURL: URL { url.appendingPathExtension("backup") }

    init(url: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CannyGit/settings.json")) {
        self.url = url
    }

    func load() throws -> AppSettings {
        loaded = false
        guard FileManager.default.fileExists(atPath: url.path) else {
            loaded = true
            return AppSettings()
        }
        let settings = try decode(readSettings(at: url))
        loaded = true
        return settings
    }

    func save(_ settings: AppSettings, revision: Int) throws {
        guard loaded else { throw ExecutionError(message: "설정을 먼저 복구하거나 다시 읽어야 합니다.") }
        guard revision >= lastRevision else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(settings)
        guard encoded.count <= 8 * 1024 * 1024 else { throw ExecutionError(message: "설정 파일이 너무 큽니다.") }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let previous = try readSettings(at: url)
            _ = try decode(previous)
            try previous.write(to: backupURL, options: .atomic)
        }
        try encoded.write(to: url, options: .atomic)
        lastRevision = revision
    }

    func restoreBackup() throws -> AppSettings {
        let data = try readSettings(at: backupURL)
        _ = try decode(data)
        if FileManager.default.fileExists(atPath: url.path) {
            let recovery = url.deletingLastPathComponent().appendingPathComponent("settings.corrupt-\(UUID()).json")
            try FileManager.default.copyItem(at: url, to: recovery)
        }
        try data.write(to: url, options: .atomic)
        lastRevision = -1
        return try load()
    }

    private func readSettings(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 8 * 1024 * 1024 + 1) ?? Data()
        guard data.count <= 8 * 1024 * 1024 else { throw ExecutionError(message: "설정 파일이 너무 큽니다.") }
        return data
    }

    private func decode(_ data: Data) throws -> AppSettings {
        guard data.count <= 8 * 1024 * 1024 else { throw ExecutionError(message: "설정 파일이 너무 큽니다.") }
        var settings = try JSONDecoder().decode(AppSettings.self, from: data)
        guard (0...2).contains(settings.schemaVersion) else {
            throw ExecutionError(message: "지원하지 않는 설정 버전입니다. 파일을 보존하고 앱 버전을 확인하세요.")
        }
        // Version 0 stored repositories and selection only; new collections default to empty.
        settings.schemaVersion = 2
        guard Set(settings.repositories.map(\.id)).count == settings.repositories.count,
            Set(settings.repositories.map(\.commonDirectory)).count == settings.repositories.count
        else { throw ExecutionError(message: "설정에 중복된 저장소가 있습니다.") }
        return settings
    }
}
