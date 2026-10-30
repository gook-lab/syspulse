import Foundation

// `SysPulse --self-test` — 화면만 봐서는 고장을 알기 어려운 판정 규칙을 고정 샘플로 확인한다.
// build.sh 가 빌드 직후 돌리고, 실패하면 설치하지 않는다 (업데이트 버튼으로 깨진 빌드가 깔리는 것도 막는다).
enum SelfTest {
    static func run() -> Int32 {
        var failures: [String] = []
        func expect(_ ok: Bool, _ name: String) {
            if !ok { failures.append(name) }
        }

        // worktree 정리 가능 판정
        let old = Date().addingTimeInterval(-3 * 86_400)
        func worktree(changes: Int = 0, unpushed: Int = 0, busy: [String] = [], locked: Bool = false,
                      missing: Bool = false, last: Date? = old) -> WorktreeInfo {
            WorktreeInfo(id: "/r/wt", repo: "/r", branch: "b", size: 1, lastCommit: last, changes: changes,
                         unpushed: unpushed, merged: true, busy: busy, locked: locked, missing: missing)
        }
        expect(worktree().removable, "worktree: 깨끗하고 오래된 것은 정리 가능")
        expect(!worktree(changes: 1).removable, "worktree: 변경이 있으면 정리 불가")
        expect(!worktree(changes: -1).removable, "worktree: git 확인 실패면 정리 불가")
        expect(!worktree(unpushed: 2).removable, "worktree: 푸시 안 한 커밋이 있으면 정리 불가")
        expect(!worktree(unpushed: -1).removable, "worktree: 푸시 여부 확인 실패면 정리 불가")
        expect(!worktree(busy: ["claude"]).removable, "worktree: 안에서 도는 프로세스가 있으면 정리 불가")
        expect(!worktree(locked: true).removable, "worktree: 잠긴 것은 정리 불가")
        expect(!worktree(last: Date().addingTimeInterval(-3600)).removable, "worktree: 24시간 안 커밋은 정리 불가")
        expect(worktree(changes: 5, missing: true).removable, "worktree: 폴더가 없으면 기록만 정리 가능")
        expect(!worktree(busy: ["vite"], missing: true).removable, "worktree: 폴더가 없어도 사용 중이면 불가")

        // 사용량 페이스 · 소진 예상 (5시간 창의 절반이 지남)
        let fiveHours: TimeInterval = 5 * 3600
        func window(_ used: Double, remaining: TimeInterval = fiveHours / 2) -> UsageWindow {
            UsageWindow(id: "s", label: "세션", usedPercent: used, resetsAt: Date().addingTimeInterval(remaining),
                        length: fiveHours)
        }
        expect(window(5).pace == .normal, "사용량: 10% 미만은 페이스를 보지 않음")
        expect(window(30).pace == .normal, "사용량: 절반 지점 30% → 정상")
        expect(window(46).pace == .warning, "사용량: 절반 지점 46% → 투영 92% 주의")
        expect(window(60).pace == .critical, "사용량: 절반 지점 60% → 투영 120% 위험")
        expect(window(92).pace == .critical, "사용량: 90% 이상은 위험")
        expect(window(40).projectedExhaustion == nil, "사용량: 초기화 전에 안 닿으면 소진 예상 없음")
        let eta = window(60).projectedExhaustion.map { $0.timeIntervalSinceNow } ?? -1
        expect(abs(eta - 6000) < 5, "사용량: 60% 는 약 6000초 뒤 소진 (\(Int(eta)))")
        expect(window(60, remaining: -10).isReset, "사용량: 초기화 시각이 지나면 낡은 값")

        let reset = AgentUsage(id: "a", name: "A", windows: [window(80, remaining: -10)], reportedAt: nil)
        let live = AgentUsage(id: "b", name: "B", windows: [window(20)], reportedAt: nil)
        expect(live.rank > reset.rank, "사용량: 초기화된 세션 창은 정렬에서 0")

        // Orca account list → 사용량
        let resetMs = (Date().timeIntervalSince1970 + 3600) * 1000
        let accounts: [String: Any] = ["rateLimits": [
            "claude": ["status": "ok",
                       "session": ["usedPercent": 17, "windowMinutes": 300, "resetsAt": resetMs],
                       "weekly": ["usedPercent": 82, "windowMinutes": 10_080, "resetsAt": resetMs],
                       "fableWeekly": ["usedPercent": 3, "windowMinutes": 10_080]],
            "cursor": ["status": "ok", "buckets": [["name": "Cursor Models", "usedPercent": 1],
                                                   ["name": "Other Models", "usedPercent": 0]]],
            "gemini": ["status": "unavailable"],
        ]]
        let usage = UsageReader.parseOrca(accounts)
        let claude = usage.first { $0.id == "claude" }
        expect(usage.count == 2, "Orca 사용량: 상태 ok 인 것만 (\(usage.count))")
        expect(claude?.windows.map(\.label) == ["세션", "주간", "Fable"], "Orca 사용량: Claude 창 순서")
        expect(claude?.windows.first?.length == 5 * 3600, "Orca 사용량: 창 길이(분 → 초)")
        expect(usage.first { $0.id == "cursor" }?.windows.map(\.label) == ["자체", "기타"], "Orca 사용량: Cursor 묶음")
        expect(UsageReader.parseOrca([:]).isEmpty, "Orca 사용량: rateLimits 가 없으면 빈 목록")

        // Orca worktree ps → 입력 대기
        let ps: [String: Any] = ["worktrees": [[
            "repo": "app", "displayName": "main",
            "agents": [
                ["paneKey": "t1:l1", "state": "waiting", "agentWait": ["source": "hook", "reason": NSNull()],
                 "stateStartedAt": 1_700_000_000_000.0, "agentType": "claude"],
                ["paneKey": "t2:l1", "state": "working",
                 "agentWait": ["source": "prompt-text", "reason": "codex-interactive-prompt"]],
                ["paneKey": "t3:l1", "state": "working", "agentWait": NSNull()],
                ["paneKey": "t4:l1", "state": "done"],
                ["state": "working"],
            ],
        ]]]
        let activities = ActivityReader.parse(ps)
        expect(activities?.count == 4, "Orca 상태: 패인 키 없는 에이전트는 뺀다")
        expect(activities?["t1:l1"]?.state == .waiting("응답 대기"), "Orca 상태: 이유 없는 대기")
        expect(activities?["t2:l1"]?.state == .waiting("선택 대기"), "Orca 상태: codex-* 이유 토큰")
        expect(activities?["t3:l1"]?.state == .working, "Orca 상태: agentWait null 은 대기 아님")
        expect(activities?["t4:l1"]?.state == .done, "Orca 상태: 턴 마침")
        expect(activities?["t1:l1"]?.worktree == "app · main", "Orca 상태: worktree 이름")
        expect(ActivityReader.parse(["error": "x"]) == nil, "Orca 상태: 형식이 다르면 실패(nil)")

        // 정리 후보
        func session(_ pid: pid_t, _ mb: UInt64, cpu: Double, pane: String?) -> AgentSession {
            var s = AgentSession(id: pid, kind: "claude", project: "p\(pid)", cwd: "/", start: 1,
                                 agentFootprint: mb * 1_048_576, agentCPU: cpu, children: [])
            s.paneKey = pane
            return s
        }
        let candidates = CleanupAdvisor.candidates(
            [session(1, 500, cpu: 0, pane: "t4:l1"), session(2, 900, cpu: 0.3, pane: "t3:l1"),
             session(3, 800, cpu: 0, pane: "t1:l1"), session(4, 700, cpu: 0.001, pane: nil),
             session(5, 600, cpu: 0.2, pane: nil)],
            activities: activities ?? [:])
        expect(candidates.map(\.session.id) == [4, 1], "정리 후보: 쉬는 세션만 메모리순 (\(candidates.map(\.session.id)))")

        // 목록 복사
        let report = WorktreeReport.markdown([WorktreeInfo(
            id: "/r/a|b", repo: "/r", branch: nil, size: nil, lastCommit: nil, changes: 0, unpushed: 0,
            merged: false, busy: [], locked: false, missing: false)])
        expect(report.contains("/r/a\\|b"), "목록 복사: 표 안의 | 는 이스케이프")

        if failures.isEmpty {
            print("self-test ok")
            return 0
        }
        for failure in failures { print("FAIL \(failure)") }
        return 1
    }
}
