import Darwin
import Foundation
import Network

public enum PeerProcess {
    public static func appName(forExecutable path: String) -> String? {
        path.split(separator: "/").first { $0.hasSuffix(".app") }.map { String($0.dropLast(4)) }
    }

    public static func appName(of connection: NWConnection) -> String? {
        guard let pid = pid(of: connection), let path = executablePath(of: pid) else { return nil }
        return appName(forExecutable: path)
    }

    public static func pid(of connection: NWConnection) -> pid_t? {
        guard let path = connection.currentPath,
              case let .hostPort(_, client)? = path.remoteEndpoint,
              case let .hostPort(_, server)? = path.localEndpoint
        else { return nil }
        return owner(ofClientPort: client.rawValue, serverPort: server.rawValue)
    }

    static func owner(ofClientPort client: UInt16, serverPort server: UInt16) -> pid_t? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let found = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        for pid in pids.prefix(Int(max(found, 0))) where pid > 0 && ownsSocket(pid, local: client, remote: server) {
            return pid
        }
        return nil
    }

    private static func ownsSocket(_ pid: pid_t, local: UInt16, remote: UInt16) -> Bool {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return false }
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &descriptors, Int32(descriptors.count * MemoryLayout<proc_fdinfo>.size))
        guard bytes > 0 else { return false }
        for descriptor in descriptors.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.size) where descriptor.proc_fdtype == PROX_FDTYPE_SOCKET {
            var info = socket_fdinfo()
            let read = proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
            guard read == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
            let tcp = info.psi.soi_proto.pri_tcp.tcpsi_ini
            if port(tcp.insi_lport) == local, port(tcp.insi_fport) == remote { return true }
        }
        return false
    }

    private static func port(_ value: Int32) -> UInt16 {
        UInt16(bigEndian: UInt16(truncatingIfNeeded: value))
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Int(proc_pidpath(pid, &buffer, UInt32(buffer.count)))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(length).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
