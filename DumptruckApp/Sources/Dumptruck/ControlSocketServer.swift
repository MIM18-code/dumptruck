import Darwin
import Foundation

/// A Unix domain socket that carries AppControl requests. Local only: no
/// network listener, the socket file is mode 0600, and a peer whose user id
/// differs from ours is refused before a byte is read. One request per
/// connection: the client writes one JSON object and a newline, the server
/// answers with one JSON object and a newline, then closes.
///
/// Where it lives, strongest claim first: DUMPTRUCK_CONTROL_SOCKET, then
/// DUMPTRUCK_HOME/control.sock (the QA copy and the checks set that), then
/// ~/Library/Application Support/Dumptruck/control.sock. `dumptruck/ctl.py`
/// resolves the same way.
final class ControlSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (Data) async -> Data

    enum StartError: Error, CustomStringConvertible {
        case pathTooLong(String)
        case notASocket(String)
        case inUse(String)
        case system(String, Int32)

        var description: String {
            switch self {
            case .pathTooLong(let path):
                return "control socket path is longer than a Unix socket allows: \(path)"
            case .notASocket(let path):
                return "something other than a socket is at \(path); leaving it alone"
            case .inUse(let path):
                return "another Dumptruck is already answering on \(path)"
            case .system(let call, let code):
                return "\(call) failed: \(String(cString: strerror(code)))"
            }
        }
    }

    /// Largest request read. A request is a command and a path or two.
    static let maxRequestBytes = 64 * 1024
    /// Connections served at once. The accept loop waits for a free slot,
    /// so a burst of clients cannot use up the app's file descriptors.
    static let maxConnections = 8

    let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var boundInode: ino_t = 0
    private let slots = DispatchSemaphore(value: ControlSocketServer.maxConnections)

    init(path: String, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    static func defaultPath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let explicit = environment["DUMPTRUCK_CONTROL_SOCKET"], !explicit.isEmpty {
            return explicit
        }
        if let home = environment["DUMPTRUCK_HOME"], !home.isEmpty {
            return (home as NSString).appendingPathComponent("control.sock")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first?.path ?? (NSHomeDirectory() + "/Library/Application Support")
        return base + "/Dumptruck/control.sock"
    }

    func start() throws {
        let maxPath = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1
        guard path.utf8.count <= maxPath else { throw StartError.pathTooLong(path) }
        let parent = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(
            atPath: parent, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try clearStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw StartError.system("socket", errno) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        Self.noSigPipe(fd)
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw StartError.system("bind", code)
        }
        guard chmod(path, 0o600) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("chmod", code)
        }
        guard listen(fd, 16) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw StartError.system("listen", code)
        }
        var info = stat()
        lock.lock()
        listenFD = fd
        boundInode = lstat(path, &info) == 0 ? info.st_ino : 0
        lock.unlock()

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "Dumptruck control socket"
        thread.start()
    }

    /// Closes the listener and removes the socket file, if it is still ours.
    func stop() {
        lock.lock()
        let fd = listenFD
        let inode = boundInode
        listenFD = -1
        lock.unlock()
        guard fd >= 0 else { return }
        shutdown(fd, SHUT_RDWR)
        close(fd)
        var info = stat()
        if lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    /// A socket file left by a crashed run is removed; one a live app
    /// answers on is not, and neither is anything that is not a socket.
    private func clearStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard (info.st_mode & S_IFMT) == S_IFSOCK else { throw StartError.notASocket(path) }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        guard probe >= 0 else { throw StartError.system("socket", errno) }
        defer { close(probe) }
        var address = Self.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(probe, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if connected == 0 { throw StartError.inUse(path) }
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            slots.wait()
            let client = accept(fd, nil, nil)
            if client < 0 {
                let code = errno
                slots.signal()
                lock.lock()
                let closed = listenFD != fd
                lock.unlock()
                if closed { return }
                // Out of descriptors or an aborted connection: wait and keep
                // listening rather than leave a bound socket nobody answers.
                if code == EINTR || code == ECONNABORTED || code == EMFILE || code == ENFILE {
                    if code != EINTR { usleep(100_000) }
                    continue
                }
                return
            }
            // Strong on purpose: the worker holds a slot, and a semaphore
            // freed below its starting count aborts the process.
            DispatchQueue.global(qos: .userInitiated).async { self.serve(client) }
        }
    }

    /// Every connection ends here: its descriptor closes and its slot frees.
    private func finish(_ client: Int32) {
        close(client)
        slots.signal()
    }

    private func serve(_ client: Int32) {
        _ = fcntl(client, F_SETFD, FD_CLOEXEC)
        // Fails with EINVAL when the peer has already hung up, which is
        // why every write below also passes MSG_NOSIGNAL. A SIGPIPE here
        // would end the app, transfers and all.
        Self.noSigPipe(client)
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else {
            Self.write(client, Data(#"{"ok":false,"error":"Refused: another user."}"#.utf8))
            finish(client)
            return
        }
        guard let request = Self.readRequest(client) else {
            Self.write(client, Data(#"{"ok":false,"error":"The request was empty, too large, or never ended with a newline."}"#.utf8))
            finish(client)
            return
        }
        let handler = self.handler
        Task {
            let reply = await handler(request)
            // A send can block up to the timeout on a slow reader; keep it
            // off the Swift task pool the app's own work runs on.
            DispatchQueue.global(qos: .userInitiated).async {
                Self.write(client, reply)
                self.finish(client)
            }
        }
    }

    private static func readRequest(_ client: Int32) -> Data? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while data.count <= maxRequestBytes {
            let count = read(client, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count <= 0 { break }
            data.append(buffer, count: count)
            if let newline = data.firstIndex(of: 0x0A) {
                return data.prefix(upTo: newline)
            }
        }
        // A client that wrote its request and shut down its side without a
        // newline still gets an answer.
        return data.isEmpty || data.count > maxRequestBytes ? nil : data
    }

    private static func write(_ client: Int32, _ data: Data) {
        var payload = data
        payload.append(0x0A)
        payload.withUnsafeBytes { raw in
            guard var base = raw.baseAddress else { return }
            var left = raw.count
            while left > 0 {
                let sent = send(client, base, left, MSG_NOSIGNAL)
                if sent < 0, errno == EINTR { continue }
                if sent <= 0 { return }
                base = base.advanced(by: sent)
                left -= sent
            }
        }
    }

    private static func noSigPipe(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            let bytes = Array(path.utf8)
            raw.copyBytes(from: bytes.prefix(raw.count - 1))
        }
        return address
    }
}

/// The running app's control socket. Started once the app has finished
/// launching (AppDelegate), never by an AppModel a check builds.
@MainActor
enum ControlChannel {
    private static var server: ControlSocketServer?
    private(set) static var startError: String?

    static func start(model: AppModel) {
        guard server == nil else { return }
        let env = ProcessInfo.processInfo.environment
        if env["DUMPTRUCK_CONTROL_SOCKET"] == "off" { return }
        let control = AppControl(model: model)
        let candidate = ControlSocketServer(path: ControlSocketServer.defaultPath(environment: env)) { data in
            await control.handle(data)
        }
        do {
            try candidate.start()
            server = candidate
        } catch {
            startError = "\(error)"
            NSLog("Dumptruck control socket: %@", "\(error)")
        }
    }

    static func stop() {
        server?.stop()
        server = nil
    }
}
