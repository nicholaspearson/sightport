import Darwin
import Foundation

enum PodTerminalError: LocalizedError {
    case invalidTarget, launch

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Choose a pod, container, and shell to open a terminal."
        case .launch: return "Sightport could not start the local terminal for kubectl."
        }
    }
}

/// A live, interactive kubectl session. Output is delivered in order on a background worker.
/// The receiver can apply backpressure by returning after it has consumed a chunk.
public final class PodTerminalSession: Sendable {
    private let worker: TerminalWorker

    init(executable: URL, arguments: [String], environment: [String: String], columns: Int, rows: Int,
         onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        worker = try TerminalWorker(executable: executable, arguments: arguments, environment: environment,
                                    columns: columns, rows: rows, onOutput: onOutput, onExit: onExit)
        worker.start()
    }

    /// Returns false when disconnected or when accepting the entire paste would exceed the input buffer.
    @discardableResult public func send(_ data: Data) -> Bool { worker.send(data) }
    public func resize(columns: Int, rows: Int) { worker.resize(columns: columns, rows: rows) }
    public func close() { worker.stop() }

    deinit { worker.stop() }
}

private final class TerminalWorker: @unchecked Sendable {
    private let master: Int32
    private let pid: pid_t
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private let onOutput: @Sendable (Data) -> Void
    private let onExit: @Sendable (Int32) -> Void

    // Only input, pendingSize and stopping cross threads. Descriptor I/O and child reaping
    // belong to the single worker, apart from the nonblocking pipe used to wake it.
    private let lock = NSLock()
    private var input = Data()
    private var pendingSize: winsize?
    private var stopping = false
    private static let inputLimit = 1024 * 1024

    init(executable: URL, arguments: [String], environment: [String: String], columns: Int, rows: Int,
         onOutput: @escaping @Sendable (Data) -> Void, onExit: @escaping @Sendable (Int32) -> Void) throws {
        var wake = [Int32](repeating: -1, count: 2)
        guard pipe(&wake) == 0 else { throw PodTerminalError.launch }
        var descriptor: Int32 = -1
        var child: pid_t = -1
        do {
            try Self.configure(wake[0])
            try Self.configure(wake[1])
            var size = Self.size(columns: columns, rows: rows)
            let path = executable.path
            // Prepare every pointer before forkpty. The child goes directly from forkpty to execve.
            child = try withCStrings([path] + arguments) { argv in
                try withCStrings(environment.map { $0.key + "=" + $0.value }) { envp in
                    path.withCString { spawnInTerminal($0, argv, envp, &descriptor, &size) }
                }
            }
            guard child > 0 else { throw PodTerminalError.launch }
            try Self.configure(descriptor)
        } catch {
            if child > 0 {
                Self.disconnect(child)
                var status: Int32 = 0
                while waitpid(child, &status, 0) == -1 && errno == EINTR {}
            }
            if descriptor >= 0 { Darwin.close(descriptor) }
            Darwin.close(wake[0])
            Darwin.close(wake[1])
            throw error
        }
        self.master = descriptor
        self.pid = child
        self.wakeRead = wake[0]
        self.wakeWrite = wake[1]
        self.onOutput = onOutput
        self.onExit = onExit
    }

    func start() {
        DispatchQueue.global(qos: .userInitiated).async { self.run() }
    }

    func send(_ bytes: Data) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, bytes.count <= Self.inputLimit - input.count else { return false }
        input.append(bytes)
        wake()
        return true
    }

    func resize(columns: Int, rows: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { return }
        pendingSize = Self.size(columns: columns, rows: rows)
        wake()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { return }
        stopping = true
        wake()
    }

    private static func configure(_ descriptor: Int32) throws {
        let flags = fcntl(descriptor, F_GETFL)
        guard flags != -1, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) != -1,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) != -1 else { throw PodTerminalError.launch }
    }

    private static func size(columns: Int, rows: Int) -> winsize {
        winsize(ws_row: UInt16(clamping: max(1, rows)), ws_col: UInt16(clamping: max(1, columns)),
                ws_xpixel: 0, ws_ypixel: 0)
    }

    // Called under lock. A full pipe already guarantees a wakeup.
    private func wake() {
        var byte: UInt8 = 1
        _ = Darwin.write(wakeWrite, &byte, 1)
    }

    private func takeChanges() -> (stopping: Bool, hasInput: Bool, size: winsize?) {
        lock.lock()
        defer { pendingSize = nil; lock.unlock() }
        return (stopping, !input.isEmpty, pendingSize)
    }

    private func writeInput() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping, !input.isEmpty else { return }
        let count = input.withUnsafeBytes { Darwin.write(master, $0.baseAddress, min($0.count, 16_384)) }
        if count > 0 { input.removeFirst(count) }
    }

    private func run() {
        var buffer = [UInt8](repeating: 0, count: 16_384)
        var status: Int32 = 0
        var atEOF = false
        while true {
            let changes = takeChanges()
            if changes.stopping {
                Self.disconnect(pid)
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                break
            }
            let exited = waitpid(pid, &status, WNOHANG)
            if exited == pid {
                // Drain bytes queued before exit, even when the child was very short-lived.
                _ = readOutput(into: &buffer)
                break
            }
            if exited == -1 && errno != EINTR { status = 1 << 8; break }
            if var size = changes.size {
                _ = ioctl(master, TIOCSWINSZ, &size)
            }
            let events = Int16(POLLIN) | (changes.hasInput ? Int16(POLLOUT) : 0)
            var fds = [pollfd(fd: atEOF ? -1 : master, events: events, revents: 0),
                       pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            // A credential helper can retain the slave after kubectl exits. Reap the actual child
            // independently of PTY EOF, including while an otherwise idle terminal is attached.
            let ready = poll(&fds, nfds_t(fds.count), 500)
            if ready < 0 {
                if errno != EINTR { stop() }
                continue
            }
            if fds[1].revents != 0 {
                while Darwin.read(wakeRead, &buffer, buffer.count) > 0 {}
            }
            if fds[0].revents & Int16(POLLOUT) != 0 { writeInput() }
            if fds[0].revents & Int16(POLLIN | POLLHUP | POLLERR) != 0 {
                atEOF = readOutput(into: &buffer)
            }
        }
        lock.lock()
        stopping = true
        input.removeAll()
        Darwin.close(wakeWrite)
        lock.unlock()
        Darwin.close(wakeRead)
        Darwin.close(master)
        let signal = status & 0x7f
        onExit(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    private func readOutput(into buffer: inout [UInt8]) -> Bool {
        // Bound work per pass, allowing resize, input and close during sustained output.
        for _ in 0..<16 {
            let count = Darwin.read(master, &buffer, buffer.count)
            if count > 0 { onOutput(Data(buffer.prefix(count))); continue }
            if count == 0 { return true }
            if errno == EINTR { continue }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
        return false
    }

    private static func disconnect(_ child: pid_t) {
        // forkpty gives kubectl its own session and process group. Before login_tty has run,
        // that group may not exist yet. The PID is ours until this worker reaps it.
        if Darwin.kill(-child, SIGKILL) == -1 && errno == ESRCH { _ = Darwin.kill(child, SIGKILL) }
    }
}

private func withCStrings(_ strings: [String],
                          _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> pid_t) throws -> pid_t {
    var pointers: [UnsafeMutablePointer<CChar>?] = []
    defer { for pointer in pointers { free(pointer) } }
    for string in strings {
        guard let pointer = strdup(string) else { throw PodTerminalError.launch }
        pointers.append(pointer)
    }
    pointers.append(nil)
    return try pointers.withUnsafeMutableBufferPointer { try body($0.baseAddress!) }
}

// No Swift objects, allocations, or Foundation calls in the post-fork child of the app.
private func spawnInTerminal(_ path: UnsafePointer<CChar>,
                             _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                             _ envp: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>,
                             _ master: UnsafeMutablePointer<Int32>, _ size: UnsafeMutablePointer<winsize>) -> pid_t {
    let child = forkpty(master, nil, nil, size)
    if child == 0 {
        _ = execve(path, argv, envp)
        _exit(127)
    }
    return child
}
