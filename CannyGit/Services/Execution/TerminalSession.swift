import AppKit
import Darwin
import Observation
import SwiftTerm
#if SWIFT_PACKAGE
import CannyPTY
#endif

@MainActor
@Observable
final class TerminalSession: Identifiable {
    enum Phase { case starting, running, stopping, exited, failed }

    let id = UUID()
    let configuration: TerminalLaunch
    let terminalView: TerminalView
    private(set) var phase: Phase = .starting
    private(set) var isActive = true
    private(set) var pid: Int32?
    private(set) var exit: ProcessExit?
    private(set) var ownedPIDs: [Int32] = []
    private(set) var ownedIdentities: [ProcessIdentity] = []
    private(set) var errorMessage: String?
    private(set) var wasStopped = false

    @ObservationIgnored private(set) var output = OutputTail()
    @ObservationIgnored private var descriptor: Int32 = -1
    @ObservationIgnored private var reader: DispatchSourceRead?
    @ObservationIgnored private var writer: DispatchSourceWrite?
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var exitSource: DispatchSourceProcess?
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Void, Error>?
    @ObservationIgnored private var supervisor: ProcessSupervisor?
    @ObservationIgnored private var reachedEOF = false
    @ObservationIgnored private var started = false
    @ObservationIgnored private var confirmedEmpty = false
    @ObservationIgnored var onOutput: ((ArraySlice<UInt8>) -> Void)?
    @ObservationIgnored var onCompletion: ((TerminalSession) -> Void)?

    init(configuration: TerminalLaunch, focusOnPresentation: Bool = false) {
        self.configuration = configuration
        let view = EmbeddedTerminalView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 500),
            font: .monospacedSystemFont(ofSize: 13, weight: .regular),
            options: TerminalOptions(cols: 80, rows: 24, scrollback: 10_000)
        )
        view.requestInitialFocus = focusOnPresentation
        // Native macOS text input (including Unicode Hex Input) uses Option.
        // Meta behavior remains an explicit user preference on the host view.
        view.optionAsMetaKey = false
        terminalView = view
        terminalView.terminalDelegate = self
    }

    func start() async {
        guard !started else { return }
        started = true
        do {
            let launch = try await PTYLauncher.launch(configuration)
            descriptor = launch.descriptor
            pid = launch.pid
            // The launcher captures identity before allowing exec, so this also
            // works when UI scheduling resumes after a fast child has exited.
            supervisor = ProcessSupervisor(root: launch.identity)
            installSources(pid: launch.pid, fd: launch.descriptor)
            phase = .running
            if wasStopped { pendingInput.removeAll() }
            else { flushInput() }
            let terminal = terminalView.getTerminal()
            resize(columns: terminal.cols, rows: terminal.rows)
            monitor = Task { [weak self] in
                while let self, self.isActive, !Task.isCancelled {
                    self.reap()
                    let exitedBeforeQuery = self.exit != nil
                    do {
                        if self.supervisor != nil {
                            _ = try await self.refreshOwnedProcesses()
                        } else if self.exit == nil {
                            throw ExecutionError(message: "시작한 프로세스의 소유 정보를 확인할 수 없습니다.")
                        }
                        // If exit arrived during the scan, collect again after
                        // reaping before concluding that no orphaned child exists.
                        if exitedBeforeQuery { self.finishIfReady() }
                    } catch {
                        self.errorMessage = error.localizedDescription
                    }
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
            if wasStopped { try await stop() }
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
            if pid == nil {
                isActive = false
                onCompletion?(self)
            }
        }
    }

    func stop(timing: StopTiming = StopTiming()) async throws {
        guard isActive else { return }
        wasStopped = true
        if let stopTask { return try await stopTask.value }
        // start() honors this flag once the background exec handshake completes.
        if pid == nil { return }
        phase = .stopping
        let group = descriptor >= 0 ? tcgetpgrp(descriptor) : -1
        let task = Task {
            guard let supervisor else {
                throw ExecutionError(message: "프로세스 소유 정보를 확인할 수 없어 중지하지 못했습니다.")
            }
            try await supervisor.stop(foregroundGroup: group > 0 ? group : nil, timing: timing)
            let deadline = ContinuousClock.now + .seconds(2)
            while isActive && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            guard !isActive else {
                throw ExecutionError(message: "프로세스 종료 또는 PTY의 마지막 출력을 기다리고 있습니다.")
            }
        }
        stopTask = task
        defer { stopTask = nil }
        do {
            try await task.value
        } catch {
            errorMessage = error.localizedDescription
            if isActive { phase = .running }
            throw error
        }
    }

    func send(_ data: Data) {
        guard isActive, descriptor >= 0 || phase == .starting else { return }
        // Keep a large paste bounded; do not silently drop a partial command.
        guard pendingInput.count + data.count <= 1024 * 1024 else {
            errorMessage = "입력 대기열이 가득 찼습니다. 붙여넣기 크기를 줄여 다시 시도하세요."
            return
        }
        pendingInput.append(data)
        flushInput()
    }

    func refreshOwnedProcesses() async throws -> [ProcessIdentity] {
        guard let supervisor else { return [] }
        let identities = try await supervisor.members().map(\.identity)
        ownedIdentities = identities
        ownedPIDs = identities.map(\.pid)
        confirmedEmpty = identities.isEmpty
        return identities
    }

    func resize(columns: Int, rows: Int) {
        guard descriptor >= 0 else { return }
        if cg_pty_resize(descriptor, UInt16(clamping: columns), UInt16(clamping: rows)) != 0 {
            errorMessage = ExecutionError.system("터미널 크기 변경 실패").localizedDescription
        }
    }

    private func installSources(pid: Int32, fd: Int32) {
        // The fd is nonblocking and each event reads at most 32 KiB. No read or
        // wait on the main queue can wait for the child; delivery is backpressured
        // by the terminal consuming one chunk before the next event is serviced.
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readOutput() }
        }
        source.setCancelHandler { close(fd) }
        reader = source
        source.activate()

        let exitSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        exitSource.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.reap() }
        }
        self.exitSource = exitSource
        exitSource.activate()
    }

    private func readOutput() {
        var bytes = [UInt8](repeating: 0, count: 32 * 1024)
        let count = Darwin.read(descriptor, &bytes, bytes.count)
        if count > 0 {
            let chunk = bytes[..<count]
            output.append(chunk)
            onOutput?(chunk)
            terminalView.feed(byteArray: chunk)
        } else if count == 0 || (count < 0 && errno == EIO) {
            closeReader()
        } else if errno != EAGAIN && errno != EINTR {
            errorMessage = ExecutionError.system("터미널 출력 읽기 실패").localizedDescription
            closeReader()
            Task { try? await stop() }
        }
    }

    private func closeReader() {
        reachedEOF = true
        writer?.cancel()
        writer = nil
        reader?.cancel()
        reader = nil
        descriptor = -1
        pendingInput.removeAll()
    }

    private func flushInput() {
        guard descriptor >= 0, !pendingInput.isEmpty else { return }
        let count = pendingInput.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        if count > 0 { pendingInput.removeFirst(count) }
        if count < 0 && errno != EAGAIN && errno != EINTR {
            errorMessage = ExecutionError.system("터미널 입력 전달 실패").localizedDescription
            pendingInput.removeAll()
        }
        if pendingInput.isEmpty {
            writer?.cancel()
            writer = nil
        } else if writer == nil {
            // A separate descriptor lets each dispatch source close only after
            // its own cancellation handler, including EOF during a large paste.
            let writeFD = fcntl(descriptor, F_DUPFD_CLOEXEC, 0)
            guard writeFD >= 0 else {
                errorMessage = ExecutionError.system("터미널 입력 대기 실패").localizedDescription
                pendingInput.removeAll()
                return
            }
            let source = DispatchSource.makeWriteSource(fileDescriptor: writeFD, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.flushInput() }
            }
            source.setCancelHandler { close(writeFD) }
            writer = source
            source.activate()
        }
    }

    private func reap() {
        guard exit == nil, let pid else { return }
        var status: Int32 = 0
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid {
            exit = ProcessExit(waitStatus: status)
        } else if result < 0 && errno != EINTR {
            exit = .unavailable
            errorMessage = ExecutionError.system("종료 상태 조회 실패").localizedDescription
        } else {
            return
        }
        exitSource?.cancel()
        exitSource = nil
        // Ownership polling, not the root's exit, decides when cleanup is done.
    }

    private func finishIfReady() {
        guard exit != nil, reachedEOF, confirmedEmpty else { return }
        isActive = false
        phase = .exited
        monitor?.cancel()
        monitor = nil
        onCompletion?(self)
    }
}

// AppKit invokes these methods on the main thread. SwiftTerm 1.x is compiled
// in Swift 5 mode and does not express that isolation on its delegate protocol.
extension TerminalSession: @preconcurrency TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        resize(columns: newCols, rows: newRows)
    }

    func send(source: TerminalView, data: ArraySlice<UInt8>) {
        (source as? EmbeddedTerminalView)?.userInputWillSend(data)
        send(Data(data))
    }
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        (source as? EmbeddedTerminalView)?.accessibilityOutputChanged()
    }

    func clipboardCopy(source: TerminalView, content: Data) {
        guard let text = String(data: content, encoding: .utf8) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
