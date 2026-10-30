import Foundation

// Orca 가 보는 에이전트 상태 — `orca worktree ps --agent-wait --json`.
// 승인·질문처럼 사람만 답할 수 있는 프롬프트에 멈추면 agentWait 에 {source, reason} 이 채워진다
// (null = 확인했고 대기 아님, 필드 없음 = 확인 못 함). 패인 키(탭 id:패인 id)는 에이전트 프로세스의
// 환경 변수 ORCA_AGENT_PANE 과 같아서 세션 줄에 바로 붙일 수 있다.
struct AgentActivity: Sendable {
    enum State: Sendable, Equatable {
        case waiting(String) // 사람 입력 대기 — 이유
        case working
        case done // 턴을 마치고 다음 지시를 기다림
        case other(String)
    }

    let paneKey: String
    let state: State
    let since: Date?
    let worktree: String
    let agentType: String

    var needsInput: Bool {
        if case .waiting = state { return true }
        return false
    }
}

enum ActivityReader {
    static func read() -> [String: AgentActivity] {
        guard let worktrees = Orca.result(["worktree", "ps", "--agent-wait", "--json"])?["worktrees"] as? [[String: Any]]
        else { return [:] }
        var activities: [String: AgentActivity] = [:]
        for worktree in worktrees {
            let name = [worktree["repo"] as? String, worktree["displayName"] as? String]
                .compactMap { $0 }.joined(separator: " · ")
            for agent in worktree["agents"] as? [[String: Any]] ?? [] {
                guard let pane = agent["paneKey"] as? String else { continue }
                let raw = agent["state"] as? String ?? ""
                let state: AgentActivity.State
                if let wait = agent["agentWait"] as? [String: Any] {
                    state = .waiting(reasonText(wait["reason"] as? String))
                } else if raw == "waiting" || raw == "blocked" {
                    state = .waiting(reasonText(nil))
                } else if raw == "working" {
                    state = .working
                } else if raw == "done" {
                    state = .done
                } else {
                    state = .other(raw)
                }
                activities[pane] = AgentActivity(
                    paneKey: pane, state: state,
                    since: (agent["stateStartedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) },
                    worktree: name, agentType: agent["agentType"] as? String ?? "agent")
            }
        }
        return activities
    }

    // Orca 의 대기 이유 토큰 → 짧은 한국어. 옛 호스트는 codex-* 로 보내므로 접두어를 떼고 본다.
    private static func reasonText(_ reason: String?) -> String {
        guard let reason else { return "응답 대기" }
        let key = reason.replacingOccurrences(of: "codex-", with: "agent-")
        switch key {
        case "agent-interactive-prompt": return "선택 대기"
        case "agent-update-prompt": return "업데이트 확인 대기"
        case "agent-trust-workspace": return "폴더 신뢰 확인 대기"
        case "agent-cwd-prompt": return "폴더 확인 대기"
        case "agent-hooks-review-prompt": return "훅 검토 대기"
        default: return "응답 대기 (\(reason))"
        }
    }
}
