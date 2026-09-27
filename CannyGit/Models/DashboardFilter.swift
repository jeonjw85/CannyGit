import Foundation

enum DashboardFilter: String, CaseIterable, Identifiable {
    case all, running, failed, changed, unavailable
    var id: Self { self }
    var title: String {
        switch self {
        case .all: String(localized: "전체")
        case .running: String(localized: "실행 중")
        case .failed: String(localized: "최근 작업 실패")
        case .changed: String(localized: "변경 있음")
        case .unavailable: String(localized: "접근·조회 오류")
        }
    }
}
