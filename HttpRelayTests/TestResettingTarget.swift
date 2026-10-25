import Foundation
import Darwin
import Network

/// A target that accepts a connection and then breaks it.
///
/// A reset is a failure the proxy has to survive: the tunnel was up, so
/// the client must not get an error status line any more - it may only
/// get the end of the connection.
final class TestResettingTarget {
    let port: UInt16
    private let listenFD: Int32
    private let queue = DispatchQueue(label: "com.httprelay.test.resetting-target")

    static func start() throws -> TestResettingTarget {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestError("socket() failed") }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw TestError("bind() failed")
        }
        guard listen(fd, 4) == 0 else {
            close(fd)
            throw TestError("listen() failed")
        }

        var listening = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &listening) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw TestError("getsockname() failed")
        }

        let target = TestResettingTarget(listenFD: fd, port: UInt16(bigEndian: listening.sin_port))
        target.startAccepting()
        return target
    }

    private init(listenFD: Int32, port: UInt16) {
        self.listenFD = listenFD
        self.port = port
    }

    /// Accepts one connection, sends a few bytes and then resets it.
    private func startAccepting() {
        queue.async { [listenFD] in
            let client = accept(listenFD, nil, nil)
            guard client >= 0 else { return }
            // Give the proxy the time to set the tunnel up and to tell the
            // client that it is up.
            Thread.sleep(forTimeInterval: 0.5)
            // Bytes the target sends reach the client through the tunnel.
            let bytes = Array("hello".utf8)
            _ = bytes.withUnsafeBufferPointer { pointer in
                write(client, pointer.baseAddress, pointer.count)
            }
            Thread.sleep(forTimeInterval: 0.2)
            // SO_LINGER with a timeout of zero turns the close into a
            // reset, which is a failure and not an orderly end.
            var lingerOption = linger(l_onoff: 1, l_linger: 0)
            setsockopt(client, SOL_SOCKET, SO_LINGER, &lingerOption, socklen_t(MemoryLayout<linger>.size))
            close(client)
        }
    }

    func stop() {
        close(listenFD)
    }
}
