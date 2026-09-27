import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var coordinator: ExecutionCoordinator?
    var model: DashboardModel?
    private var terminationPending = false

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !terminationPending else { return .terminateLater }
        if coordinator.hasActiveSession {
            let alert = NSAlert()
            alert.messageText = String(localized: "실행 중인 터미널을 정리하고 종료할까요?")
            let count = coordinator.entries.filter { $0.session.isActive }.count
                + (coordinator.session?.isActive == true ? 1 : 0) + coordinator.pendingLaunchCount
            let groups = coordinator.groups.runs.filter { coordinator.groups.canStop($0, execution: coordinator) }.count
            alert.informativeText = String(localized: "세션 \(count)개와 실행 그룹 \(groups)개를 정리합니다. 소유한 자식 작업도 함께 중지합니다.")
            alert.addButton(withTitle: String(localized: "중지하고 종료"))
            alert.addButton(withTitle: String(localized: "취소"))
            guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        }
        terminationPending = true
        Task {
            await model?.prepareForTermination()
            await model?.save()
            if let error = model?.saveError {
                await model?.cancelTermination()
                terminationPending = false
                sender.reply(toApplicationShouldTerminate: false)
                let alert = NSAlert()
                alert.messageText = String(localized: "설정을 저장하지 못했습니다")
                alert.informativeText = error
                alert.runModal()
                return
            }
            let ready = await coordinator.prepareToQuit()
            if !ready { await model?.cancelTermination() }
            terminationPending = false
            sender.reply(toApplicationShouldTerminate: ready)
        }
        return .terminateLater
    }
}
