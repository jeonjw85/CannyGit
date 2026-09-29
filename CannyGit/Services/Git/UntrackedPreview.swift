import Darwin
import Foundation

enum UntrackedPreview {
    static func read(root: String, path: String, limit: Int = 512 * 1024) throws -> DiffDocument {
        let parts = try components(path)
        var directory = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw ExecutionError.system("워크트리 열기 실패") }
        defer { close(directory) }
        for part in parts.dropLast() {
            let next = openat(directory, part, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
            guard next >= 0 else { throw ExecutionError.system("파일 경로 열기 실패") }
            close(directory)
            directory = next
        }
        let name = parts.last!
        var info = stat()
        guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw ExecutionError.system("파일 정보 조회 실패") }
        if info.st_mode & S_IFMT == S_IFLNK {
            var bytes = [UInt8](repeating: 0, count: 64 * 1024)
            let count = readlinkat(directory, name, &bytes, bytes.count)
            guard count >= 0, count < bytes.count else { throw ExecutionError.system("심볼릭 링크 읽기 실패") }
            return DiffDocument(text: try GitParser.text(bytes.prefix(count)), notice: String(localized: "심볼릭 링크 대상 경로입니다. 대상 파일 내용은 읽지 않습니다."))
        }
        if info.st_mode & S_IFMT == S_IFDIR {
            return DiffDocument(text: "", notice: String(localized: "미추적 파일 확장 후 개별 파일 선택"))
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw ExecutionError(message: "일반 파일만 미리 볼 수 있습니다.") }
        let fd = openat(directory, name, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ExecutionError.system("파일 읽기 실패") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw ExecutionError(message: "파일 형식이 바뀌었습니다. 다시 조회")
        }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            return DiffDocument(text: "", notice: String(localized: "미리 보기 한도 초과. 에디터에서 확인"))
        }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            return DiffDocument(text: "", notice: String(localized: "바이너리 또는 UTF-8이 아닌 파일입니다."))
        }
        return DiffDocument(text: text, notice: String(localized: "미추적 파일의 읽기 전용 내용입니다."))
    }

    static func components(_ path: String) throws -> [String] {
        let parts = path.split(separator: "/").map(String.init)
        guard !path.hasPrefix("/"), !path.utf8.contains(0), !parts.isEmpty,
            !parts.contains(".."), !parts.contains(".") else {
            throw ExecutionError(message: "워크트리 기준 파일 경로가 올바르지 않습니다.")
        }
        return parts
    }
}
