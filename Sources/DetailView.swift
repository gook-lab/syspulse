import SwiftUI

// 버튼·구분선까지 SwiftUI 도형으로 그린다 — AppKit 컨트롤이 섞이면 ImageRenderer 스냅샷에 자리표시자로 찍힌다.
// 폭이 바뀌는 고정 창을 위해 줄 단위로 ViewThatFits 를 쓴다: 한 줄에 안 들어가면 두 줄로 접는다.

private enum Palette {
    static let user = Color.blue
    static let system = Color.red
    static let app = Color.blue
    static let wired = Color.orange
    static let compressed = Color.purple
    static let cached = Color.gray.opacity(0.55)
    static let track = Color.primary.opacity(0.08)
}

enum DetailMode {
    case popover, pinned
}

enum ListTab: String {
    case agents, strays, apps, worktrees
}

enum SortKey: String {
    case memory, cpu
}

struct DetailView: View {
    static let popoverWidth: CGFloat = 340
    static let twoColumnWidth: CGFloat = 640 // 이보다 넓으면 왼쪽 시스템 · 오른쪽 목록 두 열

    @ObservedObject var monitor: SystemMonitor
    var mode: DetailMode = .popover
    var tabOverride: ListTab?
    var previewConfirmFirstApp = false // 스냅샷 전용: 종료 확인 상태 줄을 하나 그린다
    var previewWidth: CGFloat? // 스냅샷 전용: 고정 창 폭 흉내
    @AppStorage("listTab") private var storedTab = ListTab.agents.rawValue
    @AppStorage("sortKey") private var storedSort = SortKey.memory.rawValue

    private var tab: ListTab { tabOverride ?? ListTab(rawValue: storedTab) ?? .agents }
    private var sort: SortKey { SortKey(rawValue: storedSort) ?? .memory }

    var body: some View {
        switch mode {
        case .popover:
            layout(width: previewWidth ?? Self.popoverWidth)
        case .pinned:
            GeometryReader { geo in
                ScrollView { layout(width: geo.size.width) }
            }
        }
    }

    @ViewBuilder
    private func layout(width: CGFloat) -> some View {
        if width >= Self.twoColumnWidth {
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) { systemColumn }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                VStack(alignment: .leading, spacing: 14) { listColumn }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .padding(16)
            .frame(width: width)
        } else {
            VStack(alignment: .leading, spacing: 14) {
                systemColumn
                Separator()
                listColumn
            }
            .padding(16)
            .frame(width: width)
        }
    }

    @ViewBuilder
    private var systemColumn: some View {
        HeaderView(monitor: monitor, mode: mode)
        if !monitor.alerts.isEmpty { AlertBanner(reasons: monitor.alerts) }
        Separator()
        CPUSection(monitor: monitor)
        Separator()
        MemorySection(monitor: monitor)
        Separator()
        UsageSection(usage: monitor.usage)
    }

    @ViewBuilder
    private var listColumn: some View {
        TabPicker(selection: tab, agentCount: monitor.sessions.count, waitingCount: monitor.waitingCount,
                  strayCount: monitor.strays.count, worktreeCount: monitor.worktrees.count,
                  sort: sort, onSelect: { storedTab = $0.rawValue },
                  onToggleSort: { storedSort = (sort == .memory ? SortKey.cpu : .memory).rawValue })
        switch tab {
        case .agents: AgentsSection(monitor: monitor, sort: sort, mode: mode)
        case .strays: StraysSection(monitor: monitor, sort: sort)
        case .apps: AppsSection(monitor: monitor, sort: sort, previewConfirmFirst: previewConfirmFirstApp)
        case .worktrees: WorktreesSection(monitor: monitor)
        }
        Separator()
        SettingsRow(monitor: monitor)
        FooterView(monitor: monitor)
    }
}

// MARK: - 머리 · 경고

private struct HeaderView: View {
    @ObservedObject var monitor: SystemMonitor
    let mode: DetailMode

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(monitor.hardware.chip).font(.headline)
                Text([monitor.hardware.coreSummary, "메모리 \(Format.capacity(monitor.hardware.totalMemory))",
                      monitor.hardware.osVersion].joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button { WindowController.shared.togglePinned() } label: {
                Image(systemName: mode == .pinned ? "pin.fill" : "pin")
            }
            .buttonStyle(IconButtonStyle(active: mode == .pinned))
            .help(mode == .pinned ? "고정 해제" : "화면에 고정 — 항상 위에 뜨는 창으로")
        }
    }
}

private struct AlertBanner: View {
    let reasons: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("여유 부족 — 에이전트를 더 띄우기 전에 정리하세요").font(.caption.weight(.semibold))
                ForEach(reasons, id: \.self) { reason in
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.15)))
    }
}

// MARK: - CPU · 메모리

private struct CPUSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(title: "CPU", value: Format.percent(monitor.cpu.total))
            Sparkline(values: monitor.cpuHistory, capacity: SystemMonitor.historyLength, color: Palette.user)
                .frame(height: 34)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { legend }
                VStack(alignment: .leading, spacing: 3) { legend }
            }
            CoreBars(values: monitor.cores).frame(height: 26)
            if monitor.loadAverage.count == 3 {
                Text("부하 평균 " + monitor.loadAverage.map { String(format: "%.2f", $0) }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    @ViewBuilder
    private var legend: some View {
        LegendItem(color: Palette.user, label: "사용자", value: Format.percent(monitor.cpu.user))
        LegendItem(color: Palette.system, label: "시스템", value: Format.percent(monitor.cpu.system))
        LegendItem(color: Palette.track, label: "유휴", value: Format.percent(monitor.cpu.idle))
    }
}

private struct MemorySection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        if let memory = monitor.memory {
            VStack(alignment: .leading, spacing: 8) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        title(memory)
                        Spacer(minLength: 4)
                        PressureBadge(pressure: memory.pressure)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        title(memory)
                        PressureBadge(pressure: memory.pressure)
                    }
                }
                MemoryBar(memory: memory).frame(height: 12)
                ViewThatFits(in: .horizontal) {
                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                        GridRow { appLegend(memory); wiredLegend(memory) }
                        GridRow { compressedLegend(memory); cachedLegend(memory) }
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        appLegend(memory)
                        wiredLegend(memory)
                        compressedLegend(memory)
                        cachedLegend(memory)
                    }
                }
                Text(swapLine(memory))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                Sparkline(values: monitor.memoryHistory, capacity: SystemMonitor.historyLength,
                          color: monitor.alerts.isEmpty ? .green : .orange)
                    .frame(height: 26)
            }
        }
    }

    private func title(_ memory: MemoryInfo) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            SectionTitle(title: "메모리", value: "가용 \(Format.bytes(memory.available))")
            Text("/ \(Format.capacity(memory.total))")
                .font(.callout).foregroundStyle(.secondary).monospacedDigit()
        }
        .fixedSize()
    }

    private func appLegend(_ m: MemoryInfo) -> some View {
        LegendItem(color: Palette.app, label: "앱", value: Format.bytes(m.app))
    }

    private func wiredLegend(_ m: MemoryInfo) -> some View {
        LegendItem(color: Palette.wired, label: "와이어드", value: Format.bytes(m.wired))
    }

    private func compressedLegend(_ m: MemoryInfo) -> some View {
        LegendItem(color: Palette.compressed, label: "압축", value: Format.bytes(m.compressed))
    }

    private func cachedLegend(_ m: MemoryInfo) -> some View {
        LegendItem(color: Palette.cached, label: "캐시된 파일", value: Format.bytes(m.cached))
    }

    private func swapLine(_ memory: MemoryInfo) -> String {
        var line = "사용 중 \(Format.bytes(memory.used)) · 스왑 \(Format.bytes(memory.swapUsed)) / \(Format.bytes(memory.swapTotal))"
        if monitor.swapWriteRate >= 1_048_576 { line += " · 쓰기 \(Format.rate(monitor.swapWriteRate))" }
        return line
    }
}

// MARK: - 구독 사용량

// Orca 상태 줄과 같은 꼴: 「Claude ▬ 17% 2h 20m · 주간 ▬ 82% 3d 2h」. 색은 claude-hud 의 페이스 기준.
// 세션을 많이 쓴 에이전트가 위(UsageReader 가 정렬), 3개를 넘으면 그 안에서 스크롤.
private struct UsageSection: View {
    static let visibleRows = 3
    let usage: [AgentUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("구독 사용량").font(.subheadline.weight(.semibold))
            if usage.count > Self.visibleRows {
                ScrollView(.vertical) { rows }.frame(height: 96)
            } else {
                rows
            }
            if let soonest {
                Text("\(soonest.agent) \(soonest.window.label): \(Format.dayHour(soonest.eta))쯤 소진 예상"
                     + (soonest.window.resetsAt.map { " (초기화 \(Format.dayHour($0)))" } ?? ""))
                    .help("지금까지의 사용 속도를 그대로 이어 갔을 때 한도 100% 에 닿는 시각")
                    .font(.caption2).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            if usage.isEmpty {
                Text("Orca 에 로그인하거나, Claude 는 claude-hud 설정 display.externalUsageWritePath 를 켜면 보입니다")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // 초기화 전에 한도에 닿을 창 중 가장 이른 것
    private var soonest: (agent: String, window: UsageWindow, eta: Date)? {
        usage.flatMap { agent in agent.windows.compactMap { w in w.projectedExhaustion.map { (agent.name, w, $0) } } }
            .min { $0.2 < $1.2 }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(usage) { agent in UsageRow(agent: agent) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// 앞의 두 창(세션·주간 등)은 막대·남은 시간까지, 그 뒤(Fable 주간 등)는 「Fable 0%」로 짧게
private struct UsageRow: View {
    let agent: AgentUsage

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { name; windows(extras: true); Spacer(minLength: 0); stale }
            HStack(spacing: 8) { name; windows(extras: true) }
                .opacity(staleText == nil ? 1 : 0.55)
                .help(staleText ?? "")
            // 짧은 창까지 안 들어가면 툴팁으로
            HStack(spacing: 8) { name; windows(extras: false) }
                .opacity(staleText == nil ? 1 : 0.55)
                .help(([staleText] + agent.windows.dropFirst(2).map { Optional("\($0.label) \(Int($0.usedPercent.rounded()))%") })
                    .compactMap { $0 }.joined(separator: " · "))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { name; stale }
                windows(extras: true)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) { name; stale }
                ForEach(agent.windows) { UsageWindowView(window: $0) }
            }
        }
        .font(.caption)
    }

    private var name: some View {
        Text(agent.name).fontWeight(.medium).frame(minWidth: 44, alignment: .leading).fixedSize()
    }

    private func windows(extras: Bool) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(agent.windows.prefix(extras ? agent.windows.count : 2).enumerated()), id: \.element.id) { index, window in
                if index > 0 { Text("·").foregroundStyle(.tertiary) }
                // 앞 창과 초기화 시각이 같으면(Cursor 의 모델 묶음) 남은 시간은 한 번만
                UsageWindowView(window: window, compact: index >= 2,
                                showsReset: index == 0 || !sameReset(window, agent.windows[index - 1]))
            }
        }
        .fixedSize()
    }

    private func sameReset(_ a: UsageWindow, _ b: UsageWindow) -> Bool {
        guard let x = a.resetsAt, let y = b.resetsAt else { return false }
        return abs(x.timeIntervalSince(y)) < 60
    }

    // 값이 15분 넘게 안 바뀌었으면 언제 값인지 붙인다 (Claude 는 Claude Code 상태 줄이 그려질 때만 갱신된다)
    private var staleText: String? {
        guard let reported = agent.reportedAt, Date().timeIntervalSince(reported) > 900 else { return nil }
        return Format.ago(reported)
    }

    @ViewBuilder
    private var stale: some View {
        if let staleText {
            Text(staleText).font(.caption2).foregroundStyle(.tertiary).fixedSize()
        }
    }
}

private struct UsageWindowView: View {
    let window: UsageWindow
    var compact = false
    var showsReset = true

    var body: some View {
        HStack(spacing: 4) {
            Text(window.label).foregroundStyle(.secondary)
            if !compact {
                QuotaBar(percent: window.isReset ? 0 : window.usedPercent, color: color).frame(width: 28, height: 5)
            }
            Text("\(Int(window.usedPercent.rounded()))%").monospacedDigit()
                .foregroundStyle(window.isReset ? Color.secondary : color == Palette.user ? Color.primary : color)
            if !compact && showsReset {
                Text(resetText).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .fixedSize()
        .help(help)
    }

    private var color: Color {
        switch window.pace {
        case .normal: Palette.user
        case .warning: .orange
        case .critical: .red
        }
    }

    private var resetText: String {
        guard let resetsAt = window.resetsAt else { return "" }
        return window.isReset ? "초기화됨" : Format.countdown(to: resetsAt)
    }

    private var help: String {
        var text = "\(window.label) 한도의 \(Int(window.usedPercent.rounded()))% 사용"
        if let resetsAt = window.resetsAt {
            text += " · " + resetsAt.formatted(date: .abbreviated, time: .shortened) + " 초기화"
        }
        switch window.pace {
        case .normal: break
        case .warning: text += " · 이 속도면 초기화 전에 90% 를 넘습니다"
        case .critical: text += window.usedPercent >= 90 ? " · 거의 다 썼습니다" : " · 이 속도면 초기화 전에 한도를 넘습니다"
        }
        return text
    }
}

private struct QuotaBar: View {
    let percent: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(color).frame(width: max(2, geo.size.width * min(percent, 100) / 100))
            }
        }
    }
}

// MARK: - 목록 탭

private struct TabPicker: View {
    let selection: ListTab
    let agentCount: Int
    let waitingCount: Int
    let strayCount: Int
    let worktreeCount: Int
    let sort: SortKey
    let onSelect: (ListTab) -> Void
    let onToggleSort: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { buttons(compact: false); Spacer(minLength: 4); sortButton }
            HStack(spacing: 2) { buttons(compact: true); Spacer(minLength: 2); sortButton }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2) { buttons(compact: true) }
                sortButton
            }
        }
    }

    private var sortButton: some View {
        Button(action: onToggleSort) {
            Label(sort == .memory ? "메모리순" : "CPU순", systemImage: "arrow.up.arrow.down")
        }
        .buttonStyle(TabButtonStyle(selected: false, compact: true))
        .help("메모리순 ↔ CPU순")
    }

    @ViewBuilder
    private func buttons(compact: Bool) -> some View {
        tabButton(.agents, title: (agentCount > 0 ? "에이전트 \(agentCount)" : "에이전트")
                  + (waitingCount > 0 ? " · 대기 \(waitingCount)" : ""), compact: compact)
        tabButton(.strays, title: strayCount > 0 ? "세션 밖 \(strayCount)" : "세션 밖", compact: compact)
        tabButton(.apps, title: "앱", compact: compact)
        tabButton(.worktrees, title: worktreeCount > 0 ? "워크트리 \(worktreeCount)" : "워크트리", compact: compact)
    }

    private func tabButton(_ tab: ListTab, title: String, compact: Bool) -> some View {
        Button(title) { onSelect(tab) }
            .buttonStyle(TabButtonStyle(selected: selection == tab, compact: compact))
    }
}

private struct AgentsSection: View {
    @ObservedObject var monitor: SystemMonitor
    let sort: SortKey
    let mode: DetailMode

    // 입력 대기가 맨 위, 그다음은 메모리순(SystemMonitor 가 이미 그 순서로 준다) 또는 CPU순
    private var sessions: [AgentSession] {
        let sorted = sort == .cpu ? monitor.sessions.sorted { $0.cpu > $1.cpu } : monitor.sessions
        let waiting = sorted.filter { activity(of: $0)?.needsInput == true }
        return waiting + sorted.filter { activity(of: $0)?.needsInput != true }
    }

    private func activity(of session: AgentSession) -> AgentActivity? {
        session.paneKey.flatMap { monitor.activities[$0] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.sessions.isEmpty {
                Text("실행 중인 에이전트(claude·codex)가 없습니다").font(.callout).foregroundStyle(.secondary)
            } else {
                summaryText.font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(sessions.prefix(8)) { session in
                    SessionRow(session: session, activity: activity(of: session), mode: mode)
                }
                if monitor.sessions.count > 8 {
                    Text("외 \(monitor.sessions.count - 8)개").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summaryText: Text {
        let waiting = monitor.waitingCount
        return Text(summary) + (waiting > 0 ? Text(" · 응답 대기 \(waiting)").foregroundColor(.orange) : Text(""))
    }

    private var summary: String {
        let total = monitor.sessions.reduce(UInt64(0)) { $0 + $1.total }
        let count = monitor.sessions.count
        let cpu = monitor.sessions.reduce(0) { $0 + $1.cpu }
        return "에이전트 \(count)개 · 합계 \(Format.bytes(total)) · 평균 \(Format.bytes(total / UInt64(count)))"
            + " · CPU \(Format.cpu(cpu))"
    }
}

// 끝난 worktree 정리 — 크기순. 잃을 게 없는 것(변경 0 · 원격에 없는 커밋 0 · 안에서 도는 프로세스 없음)만 「정리」.
private struct WorktreesSection: View {
    @ObservedObject var monitor: SystemMonitor

    private var rows: [WorktreeInfo] {
        monitor.worktrees.sorted { ($0.size ?? 0, $0.id) > ($1.size ?? 0, $1.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
            ForEach(rows.prefix(12)) { worktree in WorktreeRow(worktree: worktree, monitor: monitor) }
            if rows.count > 12 {
                Text("외 \(rows.count - 12)개").font(.caption).foregroundStyle(.secondary)
            }
            Text("「정리」는 git worktree remove 입니다 — 브랜치와 커밋은 그대로 남고, 변경이 있으면 git 이 거절합니다. git 이 무시하는 파일(node_modules · .env.local 등)은 폴더와 함께 지워집니다.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear { monitor.refreshWorktrees() }
    }

    private var summary: String {
        if monitor.worktrees.isEmpty {
            return monitor.worktreeScanning ? "worktree 를 찾는 중…" : "메인 말고 다른 worktree 가 없습니다"
        }
        let total = monitor.worktrees.compactMap(\.size).reduce(0, +)
        let removable = monitor.worktrees.filter(\.removable)
        let reclaim = removable.compactMap(\.size).reduce(0, +)
        var text = "\(monitor.worktrees.count)개 · \(Format.bytes(total)) · 정리 가능 \(removable.count)개 \(Format.bytes(reclaim))"
        if monitor.worktreeScanning { text += " · 크기 재는 중…" }
        return text
    }
}

private struct WorktreeRow: View {
    let worktree: WorktreeInfo
    @ObservedObject var monitor: SystemMonitor
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: worktree.missing ? "folder.badge.questionmark" : "folder")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 16)
                Text("\(worktree.repoName) · \(worktree.name)").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(worktree.size.map(Format.bytes) ?? "…").monospacedDigit()
                    .foregroundStyle(worktree.size == nil ? .tertiary : .primary)
                action
            }
            .font(.callout)
            detail.font(.caption2).lineLimit(1).truncationMode(.tail).padding(.leading, 22)
            if let error = monitor.worktreeErrors[worktree.id] {
                Text(error).font(.caption2).foregroundStyle(.red).padding(.leading, 22)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .help(worktree.id)
    }

    @ViewBuilder
    private var action: some View {
        if monitor.removingWorktrees.contains(worktree.id) {
            QuittingLabel(stalled: false, text: "정리 중…")
        } else if worktree.removable {
            // 두 번 눌러야 지운다 — 4초 안에 「확인」을 안 누르면 되돌아간다
            Button(confirming ? "확인" : "정리") {
                if confirming {
                    confirming = false
                    monitor.removeWorktree(worktree)
                } else {
                    confirming = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirming = false }
                }
            }
            .buttonStyle(PillButtonStyle(tint: confirming ? .red : .green))
        }
    }

    // 「3일 전 · feature/x · main 에 들어감」 / 남길 이유가 있으면 주황으로
    private var detail: Text {
        if worktree.missing { return Text("폴더 없음 — git 기록만 남음").foregroundColor(.secondary) }
        var parts: [Text] = []
        if let date = worktree.lastCommit { parts.append(Text(Format.ago(date).replacingOccurrences(of: " 값", with: ""))) }
        if let branch = worktree.branch { parts.append(Text(branch)) } else { parts.append(Text("브랜치 없음(detached)")) }
        if worktree.merged { parts.append(Text("기본 브랜치에 들어감")) }
        if worktree.changes > 0 { parts.append(Text("변경 \(worktree.changes)").foregroundColor(.orange)) }
        if worktree.unpushed > 0 { parts.append(Text("푸시 안 한 커밋 \(worktree.unpushed)").foregroundColor(.orange)) }
        if worktree.changes < 0 || worktree.unpushed < 0 { parts.append(Text("git 확인 실패").foregroundColor(.orange)) }
        if !worktree.busy.isEmpty { parts.append(Text("사용 중: " + worktree.busy.prefix(2).joined(separator: ", ")).foregroundColor(Palette.user)) }
        if worktree.locked { parts.append(Text("잠김").foregroundColor(.orange)) }
        return parts.dropFirst().reduce(parts.first ?? Text("")) { $0 + Text(" · ") + $1 }.foregroundColor(.secondary)
    }
}

private struct StraysSection: View {
    @ObservedObject var monitor: SystemMonitor
    let sort: SortKey

    private var strays: [StrayTree] {
        sort == .cpu ? monitor.strays.sorted { $0.cpu > $1.cpu } : monitor.strays
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.strays.isEmpty {
                Text("모든 dev 프로세스가 에이전트 세션에 연결돼 있습니다").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(strays.prefix(8)) { stray in StrayRow(stray: stray, monitor: monitor) }
            }
            Text("부모 에이전트도, 작업 폴더가 겹치는 세션도 찾지 못한 node·python 등입니다. 끝난 세션이 남긴 dev 서버일 수 있지만, 직접 띄운 서비스일 수도 있습니다.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// 누르면 그 세션의 Orca 탭(또는 띄운 앱)으로 간다 — SessionJump
private struct SessionRow: View {
    let session: AgentSession
    let activity: AgentActivity? // Orca 밖 세션은 nil
    let mode: DetailMode
    @State private var hovering = false

    var body: some View {
        Button {
            SessionJump.jump(to: session)
            if mode == .popover { WindowController.shared.closeMenuBarPopover() }
        } label: {
            content
        }
        .buttonStyle(RowButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        .help("눌러서 이 세션의 창·탭으로 이동")
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: statusSymbol.name).font(.caption).foregroundStyle(statusSymbol.color).frame(width: 16)
                    .help(statusHelp)
                Text(session.project).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                CPUText(cores: session.cpu)
                Text(Format.bytes(session.total)).monospacedDigit()
            }
            .font(.callout)
            detailText
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 22)
        }
    }

    // 「claude 791 MB ▲320 MB/10분 · 하위 19개 · vite, vitest, rea」 — 에이전트 자체가 계속 커지면 주황
    // 입력 대기 = 손(주황), 작업 중 = 터미널(파랑), 턴 끝남 = 체크(초록), Orca 밖 = 터미널(회색)
    private var statusSymbol: (name: String, color: Color) {
        switch activity?.state {
        case .waiting: ("hand.raised.fill", .orange)
        case .working: ("terminal", Palette.user)
        case .done: ("checkmark.circle", .green)
        default: ("terminal", .secondary)
        }
    }

    private var statusHelp: String {
        switch activity?.state {
        case .waiting(let reason): "\(reason) — 눌러서 그 탭으로"
        case .working: "작업 중"
        case .done: "턴을 마치고 다음 지시를 기다림"
        case .other(let raw): raw
        case nil: "Orca 밖 세션 — 상태를 알 수 없음"
        }
    }

    private var detailText: Text {
        var text = Text("")
        if case .waiting(let reason) = activity?.state {
            let since = activity?.since.map { " " + Format.lasting(since: $0) } ?? ""
            text = Text("\(reason)\(since) · ").foregroundColor(.orange)
        }
        text = text + Text(session.detailHead)
        if let trend = session.trend, abs(trend) >= 50 * 1_048_576 {
            let change = (trend > 0 ? " ▲" : " ▼") + Format.bytes(UInt64(abs(trend))) + "/\(session.trendMinutes)분"
            text = text + Text(change).foregroundColor(trend >= 200 * 1_048_576 ? .orange : .secondary)
        }
        if let tail = session.detailTail { text = text + Text(" · " + tail) }
        return text
    }
}

private struct StrayRow: View {
    let stray: StrayTree
    @ObservedObject var monitor: SystemMonitor
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                Text(stray.title).lineLimit(1).truncationMode(.middle)
                Text(stray.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            CPUText(cores: stray.cpu)
            Text(Format.bytes(stray.footprint)).monospacedDigit()
            if let progress = monitor.quitting["stray:\(stray.id)"] {
                QuittingLabel(stalled: progress.stalled)
            } else {
                confirmButton
            }
        }
        .font(.callout)
    }

    // 두 번 눌러야 끈다 — 4초 안에 「확인」을 누르지 않으면 되돌아간다
    private var confirmButton: some View {
        Button(confirming ? "확인" : "종료") {
            if confirming {
                confirming = false
                monitor.terminate(stray)
            } else {
                confirming = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) { confirming = false }
            }
        }
        .buttonStyle(PillButtonStyle(tint: confirming ? .red : nil))
    }
}

private struct AppsSection: View {
    @ObservedObject var monitor: SystemMonitor
    let sort: SortKey
    var previewConfirmFirst = false

    private var rows: [ProcessRow] {
        Array((sort == .cpu ? monitor.apps.sorted { $0.cpu > $1.cpu } : monitor.apps).prefix(8))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(rows) { row in
                AppRow(row: row, monitor: monitor, confirming: previewConfirmFirst && row.id == previewRowID)
            }
            Text("내 계정 프로세스 기준 · 같은 앱의 헬퍼와 같은 이름의 프로세스는 합산 · ⓧ 로 종료")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // 스냅샷 미리보기: 에이전트를 품은 앱(경고 문구가 보이는 줄) 우선
    private var previewRowID: String? {
        (rows.first { $0.killable && $0.hostedAgents > 0 } ?? rows.first { $0.killable })?.id
    }
}

private struct AppRow: View {
    let row: ProcessRow
    @ObservedObject var monitor: SystemMonitor
    @State private var confirming: Bool

    init(row: ProcessRow, monitor: SystemMonitor, confirming: Bool = false) {
        self.row = row
        self.monitor = monitor
        _confirming = State(initialValue: confirming)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                if let symbol = row.symbol {
                    Image(systemName: symbol).font(.caption).foregroundStyle(.secondary).frame(width: 16, height: 16)
                } else {
                    Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                }
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if row.count > 1 {
                    Text("×\(row.count)").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                CPUText(cores: row.cpu)
                Text(Format.bytes(row.footprint)).monospacedDigit()
                if progress != nil {
                    Spinner().frame(width: 14, height: 14)
                } else if row.killable {
                    Button { confirming.toggle() } label: {
                        Image(systemName: confirming ? "xmark.circle.fill" : "xmark.circle")
                    }
                    .buttonStyle(GlyphButtonStyle(tint: confirming ? .red : .secondary))
                    .help("종료")
                } else {
                    Color.clear.frame(width: 14, height: 14) // 끌 수 없는 줄도 크기 열을 맞춘다
                }
            }
            .font(.callout)
            .opacity(progress == nil ? 1 : 0.55)
            if let progress {
                quittingDetail(progress)
            } else if confirming && row.killable {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        message
                        Spacer(minLength: 4)
                        actions
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        message
                        HStack(spacing: 6) { actions }
                    }
                }
                .padding(.leading, 24)
            }
        }
    }

    private var progress: QuitProgress? { monitor.quitting[row.id] }

    @ViewBuilder
    private func quittingDetail(_ progress: QuitProgress) -> some View {
        if progress.stalled && !progress.force {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 6) { stalledMessage; Spacer(minLength: 4); forceButton }
                VStack(alignment: .leading, spacing: 4) { stalledMessage; forceButton }
            }
            .padding(.leading, 24)
        } else {
            Text(progress.stalled ? "아직 남아 있습니다 — 권한 밖 프로세스일 수 있습니다"
                 : progress.force ? "강제 종료 중…" : "종료 중…")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.leading, 24)
        }
    }

    private var stalledMessage: some View {
        Text("응답이 없습니다 — 저장 확인 창이 떠 있을 수 있습니다")
            .font(.caption2).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var forceButton: some View {
        Button("강제 종료") { monitor.quit(row, force: true) }.buttonStyle(PillButtonStyle(tint: .red))
    }

    private var message: some View {
        Text(confirmMessage)
            .font(.caption2).foregroundStyle(row.hostedAgents > 0 ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var actions: some View {
        Button("강제 종료") { act(force: true) }.buttonStyle(PillButtonStyle(tint: .red))
        Button("종료") { act(force: false) }.buttonStyle(PillButtonStyle(tint: .orange))
    }

    private var confirmMessage: String {
        if row.hostedAgents > 0 { return "이 앱 안에서 에이전트 \(row.hostedAgents)개가 돕니다 — 같이 끝납니다" }
        return row.bundlePath != nil ? "앱을 종료합니다 (⌘Q 와 같음)" : "프로세스 \(row.count)개를 종료합니다"
    }

    private func act(force: Bool) {
        confirming = false
        monitor.quit(row, force: force)
    }
}

// MARK: - 설정 · 꼬리

private struct SettingsRow: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    threshold
                    Spacer(minLength: 6)
                    waitingButton
                    loginButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) { threshold }
                    HStack(spacing: 5) { waitingButton; loginButton }
                }
            }
            if let error = monitor.loginError {
                Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.caption)
    }

    @ViewBuilder
    private var threshold: some View {
        Text("알림: 가용").foregroundStyle(.secondary)
        Button("−") { monitor.adjustThreshold(by: -1) }.buttonStyle(PillButtonStyle())
        Text("\(monitor.alertThresholdGB) GB").monospacedDigit()
        Button("+") { monitor.adjustThreshold(by: 1) }.buttonStyle(PillButtonStyle())
        Text("미만").foregroundStyle(.secondary)
    }

    private var waitingButton: some View {
        Button(monitor.notifyWaiting ? "대기 알림 ✓" : "대기 알림") { monitor.toggleNotifyWaiting() }
            .buttonStyle(PillButtonStyle(tint: monitor.notifyWaiting ? .green : nil))
            .help("Orca 에이전트가 승인·질문에 멈추면 알림")
    }

    private var loginButton: some View {
        Button(monitor.launchAtLogin ? "로그인 시 실행 ✓" : "로그인 시 실행") {
            monitor.toggleLaunchAtLogin()
        }
        .buttonStyle(PillButtonStyle(tint: monitor.launchAtLogin ? .green : nil))
    }
}

private struct FooterView: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                status
                Spacer()
                buttons
            }
            VStack(alignment: .leading, spacing: 8) {
                status
                HStack(spacing: 8) { buttons }
            }
        }
        .buttonStyle(PillButtonStyle())
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let boot = monitor.bootDate {
                Text("부팅 후 \(Format.uptime(since: boot))")
            }
            Text("열 상태 \(Format.thermal(ProcessInfo.processInfo.thermalState))")
        }
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize()
    }

    @ViewBuilder
    private var buttons: some View {
        Button("활성 상태 보기") {
            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
        }
        Button("종료") { NSApplication.shared.terminate(nil) }
    }
}

// MARK: - 작은 부품

private struct SectionTitle: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
        }
    }
}

// 코어 하나를 넘게 쓰면(100% 이상) 주황, 거의 안 쓰면 흐리게
private struct CPUText: View {
    let cores: Double

    var body: some View {
        Text(Format.cpu(cores))
            .font(.caption).monospacedDigit()
            .foregroundStyle(cores >= 1 ? Color.orange : Color.secondary.opacity(cores >= 0.01 ? 1 : 0.5))
            .frame(minWidth: 34, alignment: .trailing)
    }
}

private struct LegendItem: View {
    let color: Color
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label).foregroundStyle(.secondary)
            Text(value).monospacedDigit()
        }
        .font(.caption)
        .fixedSize()
    }
}

private struct PressureBadge: View {
    let pressure: MemoryPressure?

    var body: some View {
        let (label, color): (String, Color) = switch pressure {
        case .normal: ("압박 정상", .green)
        case .warning: ("압박 경고", .yellow)
        case .critical: ("압박 위험", .red)
        case nil: ("압박 모름", .gray)
        }
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label)
        }
        .font(.caption2.weight(.medium))
        .padding(.horizontal, 7).padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.15)))
        .fixedSize()
    }
}

private struct Separator: View {
    var body: some View {
        Rectangle().fill(Color.primary.opacity(0.1)).frame(height: 1)
    }
}

struct Sparkline: View {
    let values: [Double]
    let capacity: Int
    let color: Color

    var body: some View {
        GeometryReader { geo in
            let points = points(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: 4).fill(Palette.track.opacity(0.6))
                if points.count > 1, let first = points.first, let last = points.last {
                    Path { path in
                        path.move(to: CGPoint(x: first.x, y: geo.size.height))
                        path.addLines(points)
                        path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                        path.closeSubpath()
                    }
                    .fill(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.03)],
                                         startPoint: .top, endPoint: .bottom))
                    Path { $0.addLines(points) }.stroke(color, lineWidth: 1.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }

    // 최신 값이 오른쪽 끝에 오도록 오른쪽 정렬
    private func points(in size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(max(capacity - 1, 1))
        let offset = CGFloat(capacity - values.count) * step
        return values.enumerated().map { index, value in
            CGPoint(x: offset + CGFloat(index) * step,
                    y: size.height * (1 - CGFloat(min(max(value, 0), 1))))
        }
    }
}

private struct CoreBars: View {
    let values: [Double]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(values.indices, id: \.self) { index in
                GeometryReader { geo in
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(Palette.track)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color(for: values[index]))
                            .frame(height: max(2, geo.size.height * CGFloat(values[index])))
                    }
                }
            }
        }
    }

    private func color(for load: Double) -> Color {
        load < 0.6 ? Palette.user : load < 0.85 ? .orange : .red
    }
}

private struct MemoryBar: View {
    let memory: MemoryInfo

    var body: some View {
        GeometryReader { geo in
            let total = Double(max(memory.total, 1))
            let segments: [(UInt64, Color)] = [
                (memory.app, Palette.app), (memory.wired, Palette.wired),
                (memory.compressed, Palette.compressed), (memory.cached, Palette.cached),
            ]
            HStack(spacing: 0) {
                ForEach(segments.indices, id: \.self) { index in
                    Rectangle().fill(segments[index].1)
                        .frame(width: geo.size.width * min(Double(segments[index].0) / total, 1))
                }
                Spacer(minLength: 0)
            }
            .background(Palette.track)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
    }
}

private struct PillButtonStyle: ButtonStyle {
    var tint: Color?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.medium))
            .foregroundStyle(tint ?? .primary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill((tint ?? .primary).opacity(configuration.isPressed ? 0.25 : 0.12)))
            .contentShape(Capsule())
            .fixedSize()
    }
}

private struct GlyphButtonStyle: ButtonStyle {
    let tint: Color

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .opacity(configuration.isPressed ? 0.5 : 1)
            .frame(width: 14, height: 14)
            .contentShape(Rectangle())
    }
}

private struct TabButtonStyle: ButtonStyle {
    let selected: Bool
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font((compact ? Font.caption : .subheadline).weight(selected ? .semibold : .regular))
            .foregroundStyle(selected ? .primary : .secondary)
            .padding(.horizontal, compact ? 7 : 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(selected ? 0.14 : configuration.isPressed ? 0.08 : 0)))
            .contentShape(Capsule())
            .fixedSize()
    }
}

// AppKit 진행 표시기는 스냅샷에 자리표시자로 찍혀서 도형으로 그린다
private struct Spinner: View {
    var body: some View {
        TimelineView(.animation) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9
            Circle().trim(from: 0, to: 0.7)
                .stroke(Color.secondary, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
                .padding(1)
        }
    }
}

private struct QuittingLabel: View {
    let stalled: Bool
    var text = "종료 중…"

    var body: some View {
        HStack(spacing: 5) {
            Spinner().frame(width: 12, height: 12)
            Text(stalled ? "응답 없음" : text).font(.caption).foregroundStyle(stalled ? .orange : .secondary)
        }
        .fixedSize()
    }
}

private struct RowButtonStyle: ButtonStyle {
    let hovering: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(configuration.isPressed ? 0.12 : hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
            .padding(.horizontal, -6).padding(.vertical, -3)
    }
}

private struct IconButtonStyle: ButtonStyle {
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(active ? Color.accentColor : .secondary)
            .frame(width: 26, height: 26)
            .background(Circle().fill(Color.primary.opacity(configuration.isPressed ? 0.2 : 0.08)))
            .contentShape(Circle())
    }
}
