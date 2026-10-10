import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A small HTTP server that listens on the loopback interface only, so Apple's player can fetch an HLS stream that
/// this app is producing itself. It answers one request per connection.
nonisolated final class LocalHTTPServer: @unchecked Sendable {

    nonisolated struct Request: Sendable, Equatable {
        let method: String
        let path: String
        /// Header names are lower-cased.
        let headers: [String: String]
    }

    nonisolated struct Response: Sendable {
        var status: Int
        var contentType: String
        var body: Data
        var headers: [String: String] = [:]

        static func text(_ status: Int, _ message: String) -> Response {
            Response(status: status, contentType: "text/plain; charset=utf-8", body: Data(message.utf8))
        }
    }

    nonisolated enum ServerError: Error, Equatable {
        case socket(Int32)
        case bind(Int32)
    }

    typealias Handler = @Sendable (Request) -> Response

    private let handler: Handler
    private let lock = NSLock()
    private var running = false
    private var accepting = false
    private var listener: Int32 = -1

    /// The handler may take its time (it can hold a request until a playlist exists); each connection has its own thread.
    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Starts listening on a free port of 127.0.0.1 and returns it.
    func start() throws -> Int {
        let descriptor = socket(AF_INET, Self.streamType, 0)
        guard descriptor >= 0 else { throw ServerError.socket(errno) }
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &enabled, socklen_t(MemoryLayout<Int32>.size))
        Self.suppressSignals(on: descriptor)

        var address = sockaddr_in()
        #if canImport(Darwin)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        inet_pton(AF_INET, "127.0.0.1", &address.sin_addr)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.bind(code)
        }
        guard listen(descriptor, 16) == 0 else {
            let code = errno
            close(descriptor)
            throw ServerError.bind(code)
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &assigned) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        let port = Int(UInt16(bigEndian: assigned.sin_port))

        lock.lock()
        running = true
        accepting = true
        self.listener = descriptor
        lock.unlock()
        Thread.detachNewThread { [self] in acceptLoop(descriptor) }
        return port
    }

    /// Stops accepting connections; requests already being answered finish.
    func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    /// Whether the thread that takes new connections is still going. It ends when the server is stopped, or when the
    /// listening socket is gone: the system can take it from an app that has been suspended.
    var isAccepting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    /// The listening socket, so a test can take it away as the system might.
    var listenerDescriptor: Int32 {
        lock.lock()
        defer { lock.unlock() }
        return listener
    }

    // MARK: - Connections

    private func acceptLoop(_ listener: Int32) {
        // True while the socket is still ours to close. Once the system has taken it, its number may be in use for
        // something else, which closing it would break.
        var owned = true
        loop: while isRunning {
            // Waiting with a timeout, not blocking in accept(), is what lets stop() end this loop on every platform.
            var watched = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&watched, 1, 250)
            if ready < 0 {
                if errno == EINTR { continue }
                owned = false
                break
            }
            guard ready > 0 else { continue }
            // A socket that has been closed or has failed is reported as ready for ever, so it would be spun on.
            if watched.revents & Int16(truncatingIfNeeded: POLLNVAL | POLLERR | POLLHUP) != 0 {
                owned = false
                break
            }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                switch errno {
                case EBADF, EINVAL, ENOTSOCK:
                    owned = false
                    break loop
                case EMFILE, ENFILE, ENOBUFS, ENOMEM:
                    Thread.sleep(forTimeInterval: 0.1)   // nothing to give the connection; waiting is better than spinning
                default:
                    break
                }
                continue
            }
            Self.suppressSignals(on: client)
            Self.setTimeouts(on: client, seconds: 15)
            DispatchQueue.global(qos: .userInitiated).async { [self] in serve(client) }
        }
        if owned { close(listener) }
        lock.lock()
        accepting = false
        lock.unlock()
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        guard let request = Self.readRequest(from: client) else { return }
        let response = handler(request)
        Self.write(response, to: client, headOnly: request.method == "HEAD")
    }

    // MARK: - Wire format

    /// Reads up to the end of the request headers; the body of a GET is empty.
    static func readRequest(from client: Int32) -> Request? {
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\r\n\r\n".utf8)
        while received.range(of: terminator) == nil {
            let count = recv(client, &buffer, buffer.count, 0)
            if count <= 0 { return nil }
            received.append(contentsOf: buffer[0..<count])
            if received.count > 16 * 1024 { return nil }
        }
        return parse(received)
    }

    /// The request line and headers of a request.
    static func parse(_ data: Data) -> Request? {
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // Any query string is dropped: the routes don't use one.
        let path = String(requestLine[1]).split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? "/"
        return Request(method: String(requestLine[0]).uppercased(), path: path, headers: headers)
    }

    /// The bytes of a response: status line, headers, then the body unless `headOnly`.
    static func serialize(_ response: Response, headOnly: Bool) -> Data {
        var head = "HTTP/1.1 \(response.status) \(reason(for: response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Content-Length: \(response.body.count)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n"
        for (name, value) in response.headers.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if !headOnly { data.append(response.body) }
        return data
    }

    private static func write(_ response: Response, to client: Int32, headOnly: Bool) {
        let data = serialize(response, headOnly: headOnly)
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var sent = 0
            while sent < raw.count {
                let count = send(client, base + sent, raw.count - sent, sendFlags)
                if count < 0 {
                    if errno == EINTR { continue }
                    return
                }
                if count == 0 { return }
                sent += count
            }
        }
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 404: return "Not Found"
        case 416: return "Range Not Satisfiable"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        case 504: return "Gateway Timeout"
        default: return "Status \(status)"
        }
    }

    // MARK: - Platform differences

    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    private static let sendFlags: Int32 = 0
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    private static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif

    /// Writing to a closed connection must fail with an error, not end the app with SIGPIPE.
    private static func suppressSignals(on descriptor: Int32) {
        #if canImport(Darwin)
        var enabled: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    private static func setTimeouts(on descriptor: Int32, seconds: Int) {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
}
