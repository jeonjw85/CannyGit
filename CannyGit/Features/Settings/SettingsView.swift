import SwiftUI

struct SettingsView: View {
    @Bindable var model: DashboardModel
    @AppStorage("appearance") private var appearance = "system"
    @AppStorage("terminalFontSize") private var fontSize = 13.0
    @AppStorage("optionAsMetaKey") private var optionAsMetaKey = false

    var body: some View {
        Form {
            ToolSettingsView(model: model)
            Section("모양") {
                Picker("테마", selection: $appearance) {
                    Text("시스템").tag("system")
                    Text("라이트").tag("light")
                    Text("다크").tag("dark")
                }
                Stepper("터미널 글자 크기: \(Int(fontSize))", value: $fontSize, in: 9...28)
                Toggle("Option 키를 Meta 키로 사용", isOn: $optionAsMetaKey)
            }
            Section("실행과 로그") {
                Text("창을 닫아도 세션은 유지됩니다. 앱 종료 시에는 실행 중인 세션을 함께 정리합니다.")
                Text("작업 로그: 실행별 5 MiB / 전체 50 MiB. 완료된 작업 탭은 최근 20개를 유지합니다.")
                Text("설정은 Application Support/CannyGit에 저장합니다. 비밀 환경 변수 값과 실행 중인 PID는 저장하지 않습니다.")
            }.font(.caption)
            Section("라이선스") {
                Text("SwiftTerm 1.19.0 · MIT License").font(.caption)
                Link("SwiftTerm 라이선스", destination: URL(string: "https://github.com/migueldeicaza/SwiftTerm/blob/v1.19.0/LICENSE")!)
            }
        }
        .formStyle(.grouped).frame(width: 620, height: 660)
    }
}
