import Darwin

// dev 서버 포트 지도 — 앱 밖 프로세스의 TCP LISTEN 소켓을 libproc 으로 읽는다 (lsof 를 띄우지 않는다).
// 같은 포트를 다른 worktree 의 서버가 잡고 있는 혼선(5173 이 어느 브랜치냐)을 보려는 것.
struct ListeningPort: Identifiable, Sendable {
    let port: Int
    let pid: pid_t
    let start: UInt64
    let name: String // 「node · vite」
    let cwd: String?
    let owner: String? // 이 서버를 띄운 에이전트 세션
    var branch: String?

    var id: String { "\(port)-\(pid)" }
    var place: String? { cwd.map(AgentAnalysis.projectLabel) }
}

enum PortScanner {
    // 작업 폴더가 / 인 것(rapportd 같은 시스템·보안 데몬)은 dev 서버가 아니라 뺀다
    static func scan(_ records: [ProcessRecord], owners: [pid_t: String]) -> [ListeningPort] {
        records.filter { $0.appBundle == nil }.flatMap { record -> [ListeningPort] in
            let ports = listeningPorts(of: record.pid)
            guard !ports.isEmpty, let cwd = Metrics.workingDirectory(of: record.pid), cwd != "/" else { return [] }
            return ports.map { port in
                ListeningPort(port: port, pid: record.pid, start: record.startSeconds,
                              name: AgentAnalysis.shortName(record.label), cwd: cwd, owner: owners[record.pid])
            }
        }
        .sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    // IPv4·IPv6 로 같은 포트를 두 번 여는 경우가 많아 Set 으로 합친다
    static func listeningPorts(of pid: pid_t) -> [Int] {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, bytes) }
        guard used > 0 else { return [] }
        var ports = Set<Int>()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == SOCKINFO_TCP,
                  info.psi.soi_proto.pri_tcp.tcpsi_state == TSI_S_LISTEN else { continue }
            // 포트는 네트워크 바이트 순서로 int 아래 16비트에 들어 있다
            let raw = info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport
            ports.insert(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: raw))))
        }
        return ports.sorted()
    }
}
