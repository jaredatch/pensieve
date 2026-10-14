import Darwin
import Foundation

enum SocketError: LocalizedError {
    case pathTooLong(String)
    case system(String, Int32)
    case timeout, disconnected, oversized

    var errorDescription: String? {
        switch self {
        case let .pathTooLong(path): "Socket path exceeds the macOS 104-byte limit: \(path)"
        case let .system(operation, code): "\(operation): \(String(cString: strerror(code)))"
        case .timeout: "Socket deadline expired"
        case .disconnected: "Socket disconnected"
        case .oversized: "Socket message exceeds its size limit"
        }
    }
}

/// Synchronous socket I/O. Deadlines cover a complete frame, including trickled bytes.
enum SocketTransport {
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        guard !path.utf8.contains(0), path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw SocketError.pathTooLong(path)
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: Array(path.utf8) + [0])
        }
        return address
    }

    static func descriptor() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.system("socket", errno) }
        var enabled: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0,
              fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            close(descriptor)
            throw SocketError.system("configure socket", code)
        }
        return descriptor
    }

    static func connect(to path: String, timeout: TimeInterval = 5) throws -> Int32 {
        var address = try address(path)
        let descriptor = try descriptor()
        do {
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            if result != 0 {
                guard errno == EINPROGRESS else { throw SocketError.system("connect \(path)", errno) }
                try wait(descriptor, events: Int16(POLLOUT), deadline: deadline(after: timeout))
                var code: Int32 = 0
                var size = socklen_t(MemoryLayout<Int32>.size)
                guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &code, &size) == 0, code == 0 else {
                    throw SocketError.system("connect \(path)", code == 0 ? errno : code)
                }
            }
            return descriptor
        } catch { close(descriptor); throw error }
    }

    static func deadline(after seconds: TimeInterval) -> TimeInterval {
        ProcessInfo.processInfo.systemUptime + seconds
    }

    static func wait(_ descriptor: Int32, events: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SocketError.timeout }
            var item = pollfd(fd: descriptor, events: events, revents: 0)
            let result = poll(&item, 1, Int32(min(remaining * 1_000 + 1, Double(Int32.max))))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw SocketError.system("poll", errno) }
            guard result > 0 else { throw SocketError.timeout }
            if item.revents & events != 0 { return }
            throw SocketError.disconnected
        }
    }

    static func readFrame(_ descriptor: Int32, limit: Int, timeout: TimeInterval) throws -> Data {
        let expires = deadline(after: timeout)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            try wait(descriptor, events: Int16(POLLIN), deadline: expires)
            // Leave the next frame in the stream when several arrive in one kernel read.
            let available = recv(descriptor, &buffer, buffer.count, MSG_PEEK)
            if available < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard available > 0 else { throw SocketError.disconnected }
            let frameBytes = buffer.prefix(available).firstIndex(of: 10).map { $0 + 1 } ?? available
            let count = recv(descriptor, &buffer, frameBytes, 0)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw SocketError.disconnected }
            if let end = buffer.prefix(count).firstIndex(of: 10) {
                guard result.count + end <= limit else { throw SocketError.oversized }
                result.append(contentsOf: buffer.prefix(end))
                return result
            }
            guard result.count + count <= limit else { throw SocketError.oversized }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    static func writeFrame<T: Encodable>(_ value: T, to descriptor: Int32, timeout: TimeInterval) throws {
        var bytes = try JSONEncoder().encode(value)
        bytes.append(10)
        let expires = deadline(after: timeout)
        try bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(descriptor, events: Int16(POLLOUT), deadline: expires)
                let count = send(descriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset, 0)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw SocketError.disconnected }
                offset += count
            }
        }
    }
}
