import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A blocking stream socket (Unix domain) used for QEMU's VNC and QMP
/// channels. Reads happen on one background thread; writes may come from
/// any thread.
public final class UnixSocket: @unchecked Sendable {
    public enum SocketError: Error, Equatable {
        case pathTooLong
        case system(String)
        case closed
    }

    private let fd: Int32
    private let writeLock = NSLock()
    private var buffer = [UInt8]()
    private var bufferStart = 0
    private var isClosed = false

    /// Wraps an existing connected descriptor (used by tests with socketpair).
    public init(descriptor: Int32) {
        fd = descriptor
        #if canImport(Darwin)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    public static func connect(path: String) throws -> UnixSocket {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }

        #if canImport(Darwin)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { throw SocketError.system(String(cString: strerror(errno))) }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin_connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result == 0 else {
            let message = String(cString: strerror(errno))
            _ = systemClose(fd)
            throw SocketError.system(message)
        }
        return UnixSocket(descriptor: fd)
    }

    deinit {
        close()
    }

    public func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { return }
        isClosed = true
        shutdown(fd, Int32(SHUT_RDWR))
        _ = systemClose(fd)
    }

    /// Reads exactly `count` bytes (blocking).
    public func read(_ count: Int) throws -> [UInt8] {
        while buffer.count - bufferStart < count {
            if bufferStart > 0 && bufferStart == buffer.count {
                buffer.removeAll(keepingCapacity: true)
                bufferStart = 0
            }
            var chunk = [UInt8](repeating: 0, count: max(65_536, count))
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                throw SocketError.closed
            }
            buffer.append(contentsOf: chunk[0..<n])
        }
        let out = Array(buffer[bufferStart..<(bufferStart + count)])
        bufferStart += count
        if bufferStart > 1 << 20 {
            buffer.removeFirst(bufferStart)
            bufferStart = 0
        }
        return out
    }

    /// Reads exactly `count` bytes straight into `destination`.
    public func read(into destination: UnsafeMutableRawPointer, count: Int) throws {
        var copied = 0
        let available = min(buffer.count - bufferStart, count)
        if available > 0 {
            buffer.withUnsafeBytes { src in
                destination.copyMemory(from: src.baseAddress! + bufferStart, byteCount: available)
            }
            bufferStart += available
            copied = available
        }
        while copied < count {
            let n = recv(fd, destination + copied, count - copied, 0)
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                throw SocketError.closed
            }
            copied += n
        }
    }

    /// Reads until (and including) `delimiter`.
    public func readLine(delimiter: UInt8 = 0x0a, limit: Int = 16 << 20) throws -> [UInt8] {
        var line = [UInt8]()
        while true {
            let byte = try read(1)[0]
            line.append(byte)
            if byte == delimiter { return line }
            if line.count > limit { throw SocketError.system("line too long") }
        }
    }

    public func write(_ bytes: [UInt8]) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        guard !isClosed else { throw SocketError.closed }
        var sent = 0
        while sent < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress! + sent, bytes.count - sent, 0) }
            if n <= 0 {
                if n < 0 && errno == EINTR { continue }
                throw SocketError.closed
            }
            sent += n
        }
    }

    /// Creates a connected pair (for tests).
    public static func pair() throws -> (UnixSocket, UnixSocket) {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        #else
        let result = socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, &fds)
        #endif
        guard result == 0 else { throw SocketError.system(String(cString: strerror(errno))) }
        return (UnixSocket(descriptor: fds[0]), UnixSocket(descriptor: fds[1]))
    }
}

// Disambiguate from the instance methods named `connect` / `close`.
@inline(__always)
private func Darwin_connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 {
    #if canImport(Darwin)
    return Darwin.connect(fd, address, length)
    #else
    return Glibc.connect(fd, address, length)
    #endif
}

@inline(__always)
private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    return Darwin.close(fd)
    #else
    return Glibc.close(fd)
    #endif
}
