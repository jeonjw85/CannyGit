import Foundation

enum DiffScope: String, CaseIterable, Identifiable, Sendable {
    case working, staged
    var id: Self { self }
    var title: String { self == .staged ? "Staged" : "Unstaged" }
}

struct DiffDocument: Sendable {
    var text: String
    var notice: String?
}
