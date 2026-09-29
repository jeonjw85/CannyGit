import SwiftUI
import SwiftTerm

struct TerminalProbeView: View {
    @Bindable var coordinator: ExecutionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "terminal.fill").font(.title)
                VStack(alignment: .leading) {
                    Text("CannyGit").font(.title2.bold())
                    Text("0단계 · 터미널과 프로세스 수명 검증").foregroundStyle(.secondary)
                }
                Spacer()
                Button("폴더 선택", systemImage: "folder") { coordinator.chooseDirectory() }
                    .disabled(coordinator.hasActiveSession)
            }
            Text(coordinator.directory.path)
                .font(.callout.monospaced()).textSelection(.enabled)
                .accessibilityLabel("작업 디렉터리")
            HStack {
                TextField("셸 실행 경로", text: $coordinator.shell)
                    .frame(width: 220)
                TextField("실행 명령 · 비워 두면 대화형 셸", text: $coordinator.command)
            }
            .textFieldStyle(.roundedBorder)
            .disabled(coordinator.hasActiveSession || coordinator.isQuitting)

            HStack {
                Button("시작", systemImage: "play.fill") { Task { await coordinator.start() } }
                    .disabled(coordinator.hasActiveSession || coordinator.isQuitting)
                Button("중지", systemImage: "stop.fill") { Task { await coordinator.stop() } }
                    .disabled(!coordinator.hasActiveSession || coordinator.session?.phase == .stopping)
                Spacer()
                if let session = coordinator.session {
                    status(session)
                    if let pid = session.pid {
                        Text("PID \(pid) · 소유 프로세스 \(session.ownedPIDs.count)개")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            if let message = coordinator.errorMessage ?? coordinator.session?.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red).textSelection(.enabled)
            }
            Group {
                if let session = coordinator.session {
                    TerminalHost(session: session).id(session.id)
                } else {
                    ContentUnavailableView(
                        "터미널 검증 준비", systemImage: "terminal",
                        description: Text("폴더 선택 후 시작. 한글 입력, vim, 크기 변경, 작업 종료 확인")
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .frame(minWidth: 800, minHeight: 560)
    }

    @ViewBuilder private func status(_ session: TerminalSession) -> some View {
        switch session.phase {
        case .starting: Text("시작 중")
        case .running: Text(session.exit == nil ? "실행 중" : "자식 프로세스 / 출력 종료 대기")
        case .stopping: Text("정리 중")
        case .failed: Text("시작 실패")
        case .exited:
            switch session.exit {
            case .code(let code): Text("종료 코드 \(code)")
            case .signal(let signal): Text("신호 \(signal)로 종료")
            default: Text("종료 상태 확인 실패")
            }
        }
    }
}

struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    var fontSize: CGFloat = 13
    var optionAsMetaKey = false

    func makeNSView(context: Context) -> TerminalView { session.terminalView }
    func updateNSView(_ view: TerminalView, context: Context) {
        if view.font.pointSize != fontSize { view.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
        view.optionAsMetaKey = optionAsMetaKey
    }
}
