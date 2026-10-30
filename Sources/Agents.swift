import Foundation

// 에이전트(claude·codex) 세션 단위로 프로세스를 묶는다.
// - 부모를 따라 올라가 닿는 에이전트가 주인 (MCP 서버, Bash 로 띄운 vite 등)
// - launchd 밑으로 떨어진 dev 프로세스는 작업 폴더·스크래치패드 경로로 주인을 다시 찾는다
//   (백그라운드로 띄운 dev 서버는 살아 있는 세션 것이어도 부모가 launchd 로 바뀐다)
// - 끝까지 주인을 못 찾은 것만 「세션 밖」으로 남긴다

struct AgentSession: Identifiable {
    let id: pid_t
    let kind: String
    let project: String
    let cwd: String
    let agentFootprint: UInt64
    var children: [ProcessRecord]
    var detachedCount = 0

    var total: UInt64 { children.reduce(agentFootprint) { $0 + $1.footprint } }

    // 「claude 620 MB · 하위 9개(분리 1) · rea, vite, server-memory」 — 이름 목록은 잘려도 되게 맨 뒤에
    var detail: String {
        let head = "\(kind) \(Format.bytes(agentFootprint))"
        guard !children.isEmpty else { return head }
        var sizes: [String: UInt64] = [:]
        for child in children { sizes[AgentAnalysis.shortName(child.label), default: 0] += child.footprint }
        let top = sizes.sorted { $0.value > $1.value }.prefix(3).map(\.key)
        let count = "하위 \(children.count)개" + (detachedCount > 0 ? "(분리 \(detachedCount))" : "")
        return [head, count, top.joined(separator: ", ")].joined(separator: " · ")
    }
}

struct StrayTree: Identifiable {
    let id: pid_t
    let name: String
    let project: String?
    let port: Int?
    let started: Date
    let footprint: UInt64
    let members: [(pid: pid_t, start: UInt64)] // 루트가 먼저

    var title: String { port.map { "\(name) :\($0)" } ?? name }

    var subtitle: String {
        var parts: [String] = []
        if let project { parts.append(project) }
        parts.append(Format.age(since: started))
        if members.count > 1 { parts.append("프로세스 \(members.count)개") }
        return parts.joined(separator: " · ")
    }
}

enum AgentAnalysis {
    static let agentCommands: Set<String> = ["claude", "codex", "gemini", "opencode", "aider"]
    private static let devCommands = Metrics.interpreters.union(Metrics.runners)
        .union(["esbuild", "tsx", "vite", "chrome-headless-shell"])

    static func analyze(_ records: [ProcessRecord]) -> (sessions: [AgentSession], strays: [StrayTree]) {
        var children: [pid_t: [ProcessRecord]] = [:]
        for record in records { children[record.ppid, default: []].append(record) }

        func descendants(of pid: pid_t, stopAtAgents: Bool) -> [ProcessRecord] {
            var result: [ProcessRecord] = []
            var stack = children[pid] ?? []
            while let record = stack.popLast() {
                if stopAtAgents, isAgent(record) { continue } // 하위 에이전트는 자기 세션으로 따로 센다
                result.append(record)
                stack.append(contentsOf: children[record.pid] ?? [])
            }
            return result
        }

        var sessions = records.filter(isAgent).map { agent in
            let cwd = Metrics.workingDirectory(of: agent.pid) ?? ""
            return AgentSession(id: agent.pid, kind: agent.command, project: projectLabel(cwd), cwd: cwd,
                                agentFootprint: agent.footprint,
                                children: descendants(of: agent.pid, stopAtAgents: true))
        }

        var strays: [StrayTree] = []
        let roots = records.filter { $0.ppid == 1 && $0.appBundle == nil && devCommands.contains($0.command) }
        for root in roots {
            let tree = [root] + descendants(of: root.pid, stopAtAgents: false)
            guard !tree.contains(where: isAgent) else { continue }
            let cwd = Metrics.workingDirectory(of: root.pid) ?? ""
            let text = ([cwd] + tree.flatMap(\.args)).joined(separator: " ")

            if let owner = owner(cwd: cwd, text: text, sessions: sessions) {
                sessions[owner].children += tree
                sessions[owner].detachedCount += 1
                continue
            }
            let heaviest = tree.max { $0.footprint < $1.footprint } ?? root
            strays.append(StrayTree(
                id: root.pid,
                name: shortName(heaviest.label),
                project: cwd.isEmpty || cwd == "/" ? nil : projectLabel(cwd),
                port: port(in: tree.flatMap(\.args)),
                started: root.started,
                footprint: tree.reduce(0) { $0 + $1.footprint },
                members: tree.map { ($0.pid, $0.startSeconds) }))
        }
        return (sessions.sorted { $0.total > $1.total }, strays.sorted { $0.footprint > $1.footprint })
    }

    static func isAgent(_ record: ProcessRecord) -> Bool {
        record.appBundle == nil && agentCommands.contains(record.command)
    }

    // 1) Claude 스크래치패드(/tmp/claude-<uid>/<프로젝트 슬러그>/…)가 인자에 있으면 그 프로젝트 세션
    // 2) 작업 폴더가 세션 작업 폴더 안이면 그 세션 (더 깊은 쪽 우선)
    private static func owner(cwd: String, text: String, sessions: [AgentSession]) -> Int? {
        var best: (index: Int, score: Int)?
        for (index, session) in sessions.enumerated() where !session.cwd.isEmpty {
            var score = 0
            if text.contains("/claude-"), text.contains("/" + slug(session.cwd) + "/") {
                score = 100_000 + session.cwd.count
            } else if cwd == session.cwd || cwd.hasPrefix(session.cwd + "/") {
                score = session.cwd.count
            }
            if score > (best?.score ?? 0) { best = (index, score) }
        }
        return best?.index
    }

    // Claude Code 가 프로젝트 경로를 폴더 이름으로 바꾸는 규칙: 영숫자 밖은 모두 「-」
    static func slug(_ path: String) -> String {
        String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    // 작업 폴더 → 「sonix_docs · ml-3426」 같은 이름
    static func projectLabel(_ path: String) -> String {
        guard !path.isEmpty else { return "작업 폴더 모름" }
        if path == NSHomeDirectory() { return "~" }
        if path.hasPrefix("/private/tmp/claude-") || path.hasPrefix("/tmp/claude-") { return "스크래치패드" }
        for marker in ["/.claude/worktrees/", "/.worktrees/", "/.git-worktrees/"] {
            guard let range = path.range(of: marker) else { continue }
            let repo = Metrics.basename(String(path[..<range.lowerBound]))
            let tree = path[range.upperBound...].split(separator: "/").first.map(String.init)
            return tree.map { "\(repo) · \($0)" } ?? repo
        }
        if let range = path.range(of: "/orca/workspaces/") {
            return path[range.upperBound...].split(separator: "/").prefix(2).joined(separator: " · ")
        }
        return Metrics.basename(path)
    }

    // 「node · vite」 → 「vite」
    static func shortName(_ label: String) -> String {
        label.components(separatedBy: " · ").last ?? label
    }

    static func port(in args: [String]) -> Int? {
        for (index, arg) in args.enumerated() {
            if arg.hasPrefix("--port="), let port = Int(arg.dropFirst(7)) { return port }
            if arg == "--port" || arg == "-p", index + 1 < args.count, let port = Int(args[index + 1]) { return port }
        }
        return nil
    }

    // 자식부터 SIGTERM. 그 사이 PID 가 다른 프로세스에 재사용됐으면 건너뛴다.
    static func terminate(_ stray: StrayTree) {
        for member in stray.members.reversed()
        where Metrics.bsdInfo(of: member.pid)?.pbi_start_tvsec == member.start {
            kill(member.pid, SIGTERM)
        }
    }
}
