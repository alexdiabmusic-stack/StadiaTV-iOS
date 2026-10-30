import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A minimal HTTP/1.1 server bound to 127.0.0.1: the thin adapter between the engine and AVPlayer.
///
/// AVPlayer only plays HLS from URLs, so the engine's reserve is served as a local live
/// playlist plus segments. The socket accepts loopback connections only, every path carries an
/// unguessable token, and nothing provider-related (URLs, credentials, headers) is ever exposed.
/// Requests are served on their own threads so a playlist request may wait for content.
nonisolated final class LoopbackHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let path: String
        let headers: [String: String]
    }

    struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var cacheControl = "no-cache"

        static func notFound() -> Response { Response(status: 404, contentType: "text/plain", body: Data("Not Found".utf8)) }
        static func unavailable() -> Response { Response(status: 503, contentType: "text/plain", body: Data("Unavailable".utf8)) }
    }

    enum ServerError: Error { case socket(Int32), bind(Int32), listen(Int32) }

    typealias Handler = @Sendable (Request) -> Response

    private let handler: Handler
    private let lock = NSLock()
    private var listenSocket: Int32 = -1
    private var clientSockets: Set<Int32> = []
    private var running = false
    private var boundPort: UInt16 = 0
    /// Called when the listening socket had to be rebuilt (iOS reclaims sockets of suspended apps).
    var onPortChange: (@Sendable (UInt16) -> Void)?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    var port: UInt16 {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    /// Binds and starts accepting. Returns the port (ephemeral unless `preferredPort` is free).
    @discardableResult
    func start(preferredPort: UInt16 = 0) throws -> UInt16 {
        let socket = try Self.makeListeningSocket(port: preferredPort)
        let port = Self.localPort(of: socket)
        lock.lock()
        listenSocket = socket
        boundPort = port
        running = true
        lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop() }
        thread.name = "BannerTV.StreamEngine.accept"
        thread.start()
        return port
    }

    func stop() {
        lock.lock()
        running = false
        let socket = listenSocket
        listenSocket = -1
        let clients = clientSockets
        clientSockets.removeAll()
        lock.unlock()
        if socket >= 0 {
            _ = shutdown(socket, Int32(SHUT_RDWR))
            _ = close(socket)
        }
        for client in clients { _ = shutdown(client, Int32(SHUT_RDWR)) }
    }

    // MARK: - Accepting

    private func acceptLoop() {
        while true {
            lock.lock()
            let isRunning = running
            let socket = listenSocket
            lock.unlock()
            guard isRunning else { return }
            guard socket >= 0 else {
                rebuildListener()
                continue
            }
            var descriptor = pollfd(fd: socket, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 1000)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                rebuildListener()
                continue
            }
            if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 {
                rebuildListener()
                continue
            }
            let client = accept(socket, nil, nil)
            if client < 0 {
                if errno == EINTR || errno == EAGAIN || errno == ECONNABORTED { continue }
                rebuildListener()
                continue
            }
            Self.configureClient(client)
            lock.lock()
            clientSockets.insert(client)
            lock.unlock()
            let thread = Thread { [weak self] in
                self?.serve(client)
                _ = close(client)
            }
            thread.name = "BannerTV.StreamEngine.client"
            thread.start()
        }
    }

    /// The listening socket died (the app was suspended and iOS reclaimed it): bind again,
    /// on the same port if possible so existing playlist URLs stay valid.
    private func rebuildListener() {
        lock.lock()
        guard running else { lock.unlock(); return }
        let old = listenSocket
        let oldPort = boundPort
        listenSocket = -1
        lock.unlock()
        if old >= 0 { _ = close(old) }
        var newSocket: Int32?
        for attempt in 0..<20 {
            if let socket = try? Self.makeListeningSocket(port: attempt < 10 ? oldPort : 0) {
                newSocket = socket
                break
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        guard let socket = newSocket else { return }
        let port = Self.localPort(of: socket)
        lock.lock()
        guard running else {
            lock.unlock()
            _ = close(socket)
            return
        }
        listenSocket = socket
        boundPort = port
        let notify = onPortChange
        lock.unlock()
        if port != oldPort { notify?(port) }
    }

    // MARK: - Serving

    private func serve(_ client: Int32) {
        defer {
            lock.lock()
            clientSockets.remove(client)
            lock.unlock()
        }
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            // Read one request head.
            var headerEnd: Int?
            while headerEnd == nil {
                if let end = Self.headerTerminator(in: buffer) { headerEnd = end; break }
                guard buffer.count < 64 * 1024 else { return }
                let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, $0.count, 0) }
                guard count > 0 else { return }
                buffer.append(contentsOf: chunk[0..<count])
            }
            guard let end = headerEnd,
                  let request = Self.parseRequest(Array(buffer[0..<end])) else { return }
            buffer.removeFirst(end + 4)
            // Requests from AVPlayer carry no body; skip one if a client sends it anyway.
            if let length = request.headers["content-length"].flatMap(Int.init), length > 0 {
                var remaining = length - min(length, buffer.count)
                buffer.removeFirst(min(length, buffer.count))
                while remaining > 0 {
                    let count = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress, min($0.count, remaining), 0) }
                    guard count > 0 else { return }
                    remaining -= count
                }
            }

            var response: Response
            if request.method == "GET" || request.method == "HEAD" {
                response = handler(request)
            } else {
                response = Response(status: 405, contentType: "text/plain", body: Data())
            }
            let keepAlive = request.headers["connection"]?.lowercased() != "close"
            guard Self.write(response, to: client, request: request, keepAlive: keepAlive), keepAlive else { return }
        }
    }

    private static func write(_ response: Response, to client: Int32, request: Request, keepAlive: Bool) -> Bool {
        var status = response.status
        var body = response.body
        var extraHeaders = ""
        if status == 200, let range = request.headers["range"].flatMap({ byteRange($0, length: body.count) }) {
            status = 206
            extraHeaders += "Content-Range: bytes \(range.lowerBound)-\(range.upperBound - 1)/\(body.count)\r\n"
            body = body.subdata(in: range)
        }
        var head = "HTTP/1.1 \(status) \(reason(status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Cache-Control: \(response.cacheControl)\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += extraHeaders
        head += keepAlive ? "Connection: keep-alive\r\n\r\n" : "Connection: close\r\n\r\n"
        guard sendAll(Data(head.utf8), to: client) else { return false }
        if request.method == "HEAD" || body.isEmpty { return true }
        return sendAll(body, to: client)
    }

    private static func sendAll(_ data: Data, to client: Int32) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                #if canImport(Darwin)
                let sent = send(client, base + offset, raw.count - offset, 0)
                #else
                let sent = send(client, base + offset, raw.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if sent < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += sent
            }
            return true
        }
    }

    // MARK: - Parsing

    static func headerTerminator(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4)
        where bytes[index] == 13 && bytes[index + 1] == 10 && bytes[index + 2] == 13 && bytes[index + 3] == 10 {
            return index
        }
        return nil
    }

    static func parseRequest(_ head: [UInt8]) -> Request? {
        let text = String(decoding: head, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        var path = String(requestLine[1])
        if let query = path.firstIndex(of: "?") { path = String(path[..<query]) }
        return Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers)
    }

    /// `bytes=a-b`, `bytes=a-` or `bytes=-n` against a body of `length` bytes.
    static func byteRange(_ header: String, length: Int) -> Range<Int>? {
        guard length > 0, header.lowercased().hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst(6).split(separator: ",").first.map(String.init) ?? ""
        let parts = spec.split(separator: "-", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 else { return nil }
        if parts[0].isEmpty, let suffix = Int(parts[1]), suffix > 0 {
            return max(0, length - suffix)..<length
        }
        guard let start = Int(parts[0]), start < length else { return nil }
        let end = Int(parts[1]).map { min($0, length - 1) } ?? (length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 503: return "Service Unavailable"
        default: return "Status"
        }
    }

    // MARK: - Sockets

    private static func makeListeningSocket(port: UInt16) throws -> Int32 {
        #if canImport(Darwin)
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        let socket = Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard socket >= 0 else { throw ServerError.socket(errno) }
        var reuse: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            _ = close(socket)
            throw ServerError.bind(code)
        }
        guard listen(socket, 32) == 0 else {
            let code = errno
            _ = close(socket)
            throw ServerError.listen(code)
        }
        return socket
    }

    private static func localPort(of socket: Int32) -> UInt16 {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket, $0, &length) }
        }
        return result == 0 ? UInt16(bigEndian: address.sin_port) : 0
    }

    private static func configureClient(_ client: Int32) {
        var on: Int32 = 1
        #if canImport(Darwin)
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = setsockopt(client, Int32(IPPROTO_TCP), TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))
        // Idle keep-alive connections are dropped after a minute; AVPlayer reconnects as needed.
        var timeout = timeval(tv_sec: 60, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var sendTimeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
