import Foundation
import Testing
@testable import CannyGit

struct SettingsAndDetectionTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("canny-settings-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func persistenceBackupCorruptionMigrationAndRevisions() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var settings = try await store.load()
        settings.repositories = [Repository(name: "original", path: "/repo", commonDirectory: "/repo/.git")]
        try await store.save(settings, revision: 1)
        settings.repositories[0].name = "updated"
        try await store.save(settings, revision: 3)
        var stale = settings
        stale.repositories[0].name = "stale"
        try await store.save(stale, revision: 2)
        #expect(try await SettingsStore(url: url).load().repositories[0].name == "updated")
        let broken = Data("{broken".utf8)
        try broken.write(to: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        await #expect(throws: (any Error).self) { try await store.save(settings, revision: 4) }
        #expect(try Data(contentsOf: url) == broken)
        let recovered = try await store.restoreBackup()
        #expect(recovered.repositories[0].name == "original")
        settings.schemaVersion = 0
        try JSONEncoder().encode(settings).write(to: url)
        #expect(try await SettingsStore(url: url).load().schemaVersion == 2)
        settings.schemaVersion = 99
        let future = try JSONEncoder().encode(settings)
        try future.write(to: url)
        await #expect(throws: (any Error).self) { try await store.load() }
        #expect(try Data(contentsOf: url) == future)
    }

    @Test func detectorPreservesArgumentsAndOverrides() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("package.json")
        try Data(#"{"scripts":{"dev":"serve","test; echo unexpected":"echo safe","$install":"$hidden"},"packageManager":"pnpm@9"}"#.utf8).write(to: file)
        try Data().write(to: root.appendingPathComponent("yarn.lock"))
        let detector = TaskDetector()
        let conflicted = try await detector.detect(root: root, directory: ".", preferredManager: nil)
        #expect(conflicted.candidates.allSatisfy { $0.needsPackageManager })
        let report = try await detector.detect(root: root, directory: ".", preferredManager: "npm")
        #expect(Set(report.candidates.map(\.id)).count == report.candidates.count)
        let candidate = try #require(report.candidates.first { $0.definition.name == "test; echo unexpected" })
        #expect(candidate.definition.command == .executable("npm", ["run", "--", "test; echo unexpected"]))
        let repositoryID = UUID(), worktreeID = UUID()
        var edited = candidate.definition
        edited.command = .shell("echo user-edited")
        let rule = TaskRule(repositoryID: repositoryID, definition: edited)
        try Data(#"{"scripts":{"test; echo unexpected":"echo changed"}}"#.utf8).write(to: file)
        let changed = try await detector.detect(root: root, directory: ".", preferredManager: "npm")
        let merged = TaskCatalog.merge(changed, rules: [rule], repositoryID: repositoryID, worktreeID: worktreeID)
        #expect(merged.first { $0.id == edited.id }?.definition.command == edited.command)
        #expect(merged.first { $0.id == edited.id }?.notice == String(localized: "탐지 원본이 변경되었습니다. 저장한 명령은 유지됩니다."))
        let other = TaskCatalog.merge(report, rules: [], repositoryID: repositoryID, worktreeID: worktreeID)
        #expect(other.contains { $0.definition.name == "$install" })
    }

    @Test func oversizedSaveKeepsTheLastReadableSettings() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let store = SettingsStore(url: url)
        var settings = try await store.load()
        try await store.save(settings, revision: 1)
        let original = try Data(contentsOf: url)
        settings.editorPath = String(repeating: "x", count: 8 * 1024 * 1024)
        await #expect(throws: (any Error).self) { try await store.save(settings, revision: 2) }
        #expect(try Data(contentsOf: url) == original)
        #expect(try await SettingsStore(url: url).load().editorPath != settings.editorPath)
    }

    @Test func staticPresetsDoNotEvaluateManifestsAndRejectEscapingDirectory() async throws {
        let root = try folder()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("fatalError(\"must not run\")".utf8).write(to: root.appendingPathComponent("Package.swift"))
        try Data().write(to: root.appendingPathComponent("go.mod"))
        try Data().write(to: root.appendingPathComponent("Cargo.toml"))
        let report = try await TaskDetector().detect(root: root, directory: ".", preferredManager: nil)
        #expect(report.candidates.count == 7)
        #expect(throws: (any Error).self) { try TaskDetector.directory(root: root, relative: "..") }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())
        #expect(throws: (any Error).self) { try TaskDetector.directory(root: root, relative: "outside") }
    }

    @Test @MainActor func logBoundsAndIPv6URLs() throws {
        let logs = TaskLogStore(perRunLimit: 10, totalLimit: 15)
        let first = UUID(), second = UUID()
        logs.append(Array("abcdefghij".utf8)[...], to: first)
        logs.append(Array("klmnopqrst".utf8)[...], to: second)
        #expect(logs.totalBytes <= 15)
        #expect(logs.isTruncated(first))
        #expect(String(decoding: logs.data(for: second), as: UTF8.self) == "klmnopqrst")
        logs.append(Array("01234567890123456789".utf8)[...], to: second)
        #expect(logs.data(for: second).count <= 10 && logs.isTruncated(second))
        let ports = try PortService.parse(Data("p123\0cfixture\0\nf4\0n[::1]:4321\0\nf5\0n*:8000\0\n".utf8))
        #expect(ports.count == 2)
        #expect(ports[0].browserURL(scheme: "http")?.absoluteString == "http://[::1]:4321")
        #expect(ports[1].browserURL(scheme: "https")?.absoluteString == "https://localhost:8000")
        #expect(ports[0].browserURL(scheme: "file") == nil)
    }
}
