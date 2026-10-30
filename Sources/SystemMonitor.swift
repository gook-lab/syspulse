import AppKit
import Combine
import ServiceManagement
import UserNotifications

// 종료를 누른 뒤 실제로 꺼질 때까지의 상태 — 줄에 「종료 중…」을 띄우는 데 쓴다
struct QuitProgress {
    let token = UUID()
    let force: Bool
    let started = Date()
    var stalled = false // 정상 종료가 한참 안 끝남 (저장 확인 창 등) → 강제 종료를 권한다
}

struct ProcessRow: Identifiable {
    let id: String
    let name: String
    let footprint: UInt64
    let cpu: Double
    let members: [(pid: pid_t, start: UInt64)]
    let bundlePath: String?
    let killable: Bool
    let hostedAgents: Int // 이 묶음 안(조상)에서 도는 에이전트 수 — 그 앱을 끄면 에이전트도 끝난다
    let symbol: String? // 실행 파일 아이콘이 의미 없는 줄(claude 등)은 SF Symbol 로
    let icon: NSImage

    var count: Int { members.count }
}

@MainActor
final class SystemMonitor: ObservableObject {
    static let shared = SystemMonitor()
    static let interval: TimeInterval = 2
    static let historyLength = 60 // 2초 × 60 = 최근 2분
    private static let swapAlertRate = 20.0 * 1_048_576 // 초당 20 MB 넘게 스왑에 쓰면 경고
    private static let thresholdKey = "alertAvailableGB"
    private static let notifyWaitingKey = "notifyWaiting"

    @Published private(set) var cpu = CPULoad.idleLoad
    @Published private(set) var cores: [Double] = []
    @Published private(set) var cpuHistory: [Double] = []
    @Published private(set) var memory: MemoryInfo?
    @Published private(set) var memoryHistory: [Double] = []
    @Published private(set) var swapWriteRate: Double = 0 // bytes/s, 최근 3회 평균
    @Published private(set) var loadAverage: [Double] = []
    @Published private(set) var apps: [ProcessRow] = []
    @Published private(set) var sessions: [AgentSession] = []
    @Published private(set) var strays: [StrayTree] = []
    @Published private(set) var alerts: [String] = []
    @Published private(set) var alertThresholdGB: Int
    @Published private(set) var loginError: String?
    @Published private(set) var usage: [AgentUsage] = []
    @Published private(set) var quitting: [String: QuitProgress] = [:]
    @Published private(set) var activities: [String: AgentActivity] = [:] // Orca 패인 키 → 상태
    @Published private(set) var notifyWaiting: Bool
    private var paneKeys: [String: String] = [:] // 세션 키 → 패인 키 ("" = Orca 밖) // 키: 앱 줄 id 또는 "stray:<pid>"

    let hardware = Metrics.hardware()
    let bootDate = Metrics.bootDate()

    private let notifies: Bool
    private var lastTicks: [CoreTicks] = []
    private var lastSwapOut: (bytes: UInt64, time: Date)?
    private var swapRates: [Double] = []
    private var lastNotified: Date?
    private var icons: [String: NSImage] = [:]
    private var timer: Timer?
    private var lastCPU: [pid_t: (start: UInt64, nanos: UInt64)] = [:]
    private var lastCPUSample: Date?
    private var samples = 0
    private var agentHistory: [String: [(time: Date, footprint: UInt64)]] = [:]
    private static let trendWindow: TimeInterval = 600 // 최근 10분
    private static let trendMinimumSpan: TimeInterval = 120 // 2분은 쌓여야 추세로 본다

    init(autoStart: Bool = true) {
        let saved = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        alertThresholdGB = saved > 0 ? saved : 4
        notifyWaiting = UserDefaults.standard.object(forKey: Self.notifyWaitingKey) as? Bool ?? true
        notifies = autoStart
        sample()
        guard autoStart else { return }
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }

    func sample() {
        let ticks = Metrics.coreTicks()
        if !ticks.isEmpty, ticks.count == lastTicks.count {
            cores = zip(lastTicks, ticks).map { Metrics.load(from: $0, to: $1).total }
            cpu = Metrics.load(from: Metrics.sum(lastTicks), to: Metrics.sum(ticks))
            append(cpu.total, to: &cpuHistory)
        }
        lastTicks = ticks

        if let info = Metrics.memory() {
            memory = info
            append(Double(info.used) / Double(max(info.total, 1)), to: &memoryHistory)
            updateSwapRate(info.swapOutBytes)
        }

        var records = Metrics.processes()
        applyCPU(&records)
        apps = appRows(records)
        var analysis = AgentAnalysis.analyze(records)
        applyTrends(&analysis.sessions)
        (sessions, strays) = analysis
        attachPaneKeys()
        loadAverage = Metrics.loadAverage()
        if samples % 15 == 0, notifies { refreshUsage() } // 사용량은 30초마다, Orca CLI 를 부르니 백그라운드에서
        if samples % 5 == 0, notifies { refreshActivity() } // 입력 대기는 10초마다
        samples += 1
        evaluateAlerts()
    }

    // MARK: 프로세스 CPU · 세션 추세

    // 누적 CPU 시간의 두 시점 차이 ÷ 실제 경과 시간. PID 가 재사용됐으면(시작 시각 다름) 새로 센다.
    private func applyCPU(_ records: inout [ProcessRecord]) {
        let now = Date()
        let elapsed = lastCPUSample.map { now.timeIntervalSince($0) * 1e9 } ?? 0
        var next: [pid_t: (start: UInt64, nanos: UInt64)] = [:]
        for index in records.indices {
            let record = records[index]
            if elapsed > 0, let prev = lastCPU[record.pid], prev.start == record.startSeconds,
               record.cpuNanos >= prev.nanos {
                records[index].cpu = Double(record.cpuNanos - prev.nanos) / elapsed
            }
            next[record.pid] = (record.startSeconds, record.cpuNanos)
        }
        lastCPU = next
        lastCPUSample = now
    }

    // 하위 프로세스(vitest 등)는 떴다 사라지며 출렁이므로, 에이전트 프로세스 자체의 메모리로 추세를 본다
    private func applyTrends(_ sessions: inout [AgentSession]) {
        let now = Date()
        var next: [String: [(time: Date, footprint: UInt64)]] = [:]
        for index in sessions.indices {
            let session = sessions[index]
            var history = (agentHistory[session.key] ?? []).filter {
                now.timeIntervalSince($0.time) <= Self.trendWindow
            }
            history.append((now, session.agentFootprint))
            if let oldest = history.first, now.timeIntervalSince(oldest.time) >= Self.trendMinimumSpan {
                sessions[index].trend = Int64(session.agentFootprint) - Int64(oldest.footprint)
                sessions[index].trendMinutes = Int(now.timeIntervalSince(oldest.time) / 60)
            }
            next[session.key] = history
        }
        agentHistory = next
    }

    // MARK: 메뉴 막대 라벨

    var menuBarTitle: String {
        let available = memory.map { Format.gigabytesShort($0.available) } ?? "–"
        return "CPU \(Format.percent(cpu.total)) · \(available)"
    }

    // 노치 있는 맥은 메뉴 막대 자리가 좁다 — 위 CPU %, 아래 가용 메모리 두 줄 (약 27pt).
    // 경고 중에는 주황(압박 위험이면 빨강)으로 칠한다.
    var menuBarImage: NSImage {
        let percent = Int((min(max(cpu.total, 0), 1) * 100).rounded())
        let available = memory.map { String(format: "%.1fG", Double($0.available) / 1_073_741_824) } ?? "–"
        let tint: NSColor? = alerts.isEmpty ? nil : memory?.pressure == .critical ? .systemRed : .systemOrange
        return MenuBarLabel.image(lines: ["\(percent)%", available], width: 5, tint: tint, badge: waitingCount)
    }

    var waitingCount: Int { activities.values.filter(\.needsInput).count }

    // MARK: 에이전트 입력 대기

    // 에이전트 프로세스의 ORCA_AGENT_PANE 을 한 번만 읽어 둔다 (세션 키 = pid + 시작 시각)
    private func attachPaneKeys() {
        let live = Set(sessions.map(\.key))
        paneKeys = paneKeys.filter { live.contains($0.key) }
        for index in sessions.indices {
            let key = sessions[index].key
            if paneKeys[key] == nil {
                paneKeys[key] = Metrics.environment(of: sessions[index].id, keys: ["ORCA_AGENT_PANE"])["ORCA_AGENT_PANE"] ?? ""
            }
            sessions[index].paneKey = paneKeys[key].flatMap { $0.isEmpty ? nil : $0 }
        }
    }

    private func refreshActivity() {
        DispatchQueue.global(qos: .utility).async {
            let activities = ActivityReader.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.apply(activities) }
            }
        }
    }

    // 새로 대기에 들어간 에이전트만 알린다 (같은 대기 동안 한 번)
    private func apply(_ next: [String: AgentActivity]) {
        let newlyWaiting = next.values.filter { $0.needsInput && activities[$0.paneKey]?.needsInput != true }
        activities = next
        guard notifyWaiting, notifies else { return }
        for activity in newlyWaiting {
            guard case .waiting(let reason) = activity.state else { continue }
            let project = sessions.first { $0.paneKey == activity.paneKey }?.project ?? activity.worktree
            Self.post(title: "SysPulse — 에이전트 응답 대기", body: "\(project) · \(activity.agentType) — \(reason)")
        }
    }

    func toggleNotifyWaiting() {
        notifyWaiting.toggle()
        UserDefaults.standard.set(notifyWaiting, forKey: Self.notifyWaitingKey)
    }

    // 스냅샷 전용
    func readActivityNow() {
        activities = ActivityReader.read()
    }

    // 스냅샷 전용: Orca 세션 둘째 줄을 입력 대기로 바꿔 모양 확인
    func previewWaiting() {
        guard let pane = sessions.compactMap(\.paneKey).dropFirst().first, let current = activities[pane] else { return }
        activities[pane] = AgentActivity(paneKey: pane, state: .waiting("선택 대기"), since: Date().addingTimeInterval(-180),
                                         worktree: current.worktree, agentType: current.agentType)
    }

    // MARK: 경고

    func adjustThreshold(by delta: Int) {
        alertThresholdGB = min(max(alertThresholdGB + delta, 1), 32)
        UserDefaults.standard.set(alertThresholdGB, forKey: Self.thresholdKey)
        evaluateAlerts()
    }

    private func evaluateAlerts() {
        var reasons: [String] = []
        if let memory {
            if Double(memory.available) < Double(alertThresholdGB) * 1_073_741_824 {
                reasons.append("가용 \(Format.bytes(memory.available)) — 기준 \(alertThresholdGB) GB 미만")
            }
            switch memory.pressure {
            case .warning: reasons.append("메모리 압박 경고")
            case .critical: reasons.append("메모리 압박 위험")
            default: break
            }
        }
        if swapWriteRate > Self.swapAlertRate {
            reasons.append("스왑 쓰기 \(Format.rate(swapWriteRate)) — 메모리가 모자라 디스크로 내보내는 중")
        }

        let started = alerts.isEmpty && !reasons.isEmpty
        alerts = reasons
        if started, notifies { notify(reasons) }
    }

    // 경고가 새로 시작될 때만, 15분에 한 번까지
    private func notify(_ reasons: [String]) {
        if let lastNotified, Date().timeIntervalSince(lastNotified) < 15 * 60 { return }
        lastNotified = Date()
        var body = reasons.joined(separator: "\n")
        if let heaviest = sessions.first {
            body += "\n가장 큰 에이전트: \(heaviest.project) \(Format.bytes(heaviest.total))"
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { Self.post(title: "SysPulse — 메모리 여유 부족", body: body) }
    }

    // 알림 센터 권한은 Apple 개발자 서명이 없는 빌드(ad-hoc)에서 거절될 수 있다 (UNErrorDomain 1,
    // 권한 창도 안 뜬다). 그때는 osascript 로 띄운다 — 알림이 「스크립트 편집기」 이름으로 온다.
    nonisolated private static func post(title: String, body: String) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            FileHandle.standardError.write(Data(
                "[syspulse:notify] granted=\(granted) error=\(error.map { String(describing: $0) } ?? "-")\n".utf8))
            guard granted else {
                if error != nil { postWithScript(title: title, body: body) }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }

    nonisolated private static func postWithScript(title: String, body: String) {
        func quoted(_ text: String) -> String {
            "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "display notification \(quoted(body)) with title \(quoted(title)) sound name \"default\""]
        try? process.run()
    }

    private func updateSwapRate(_ bytes: UInt64) {
        let now = Date()
        if let last = lastSwapOut, bytes >= last.bytes {
            let elapsed = now.timeIntervalSince(last.time)
            if elapsed > 0 { swapRates = (swapRates + [Double(bytes - last.bytes) / elapsed]).suffix(3) }
        }
        lastSwapOut = (bytes, now)
        swapWriteRate = swapRates.isEmpty ? 0 : swapRates.reduce(0, +) / Double(swapRates.count)
    }

    // MARK: 세션 밖 프로세스 종료

    func terminate(_ stray: StrayTree) {
        AgentAnalysis.terminate(stray)
        track("stray:\(stray.id)", members: stray.members, force: false)
    }

    // 0.4초마다 묶음의 프로세스가 남았는지 본다. 다 꺼지면 바로 다시 샘플해 줄을 지운다.
    // 정상 종료는 8초(강제는 5초) 넘게 남아 있으면 stalled, 60초가 지나면 추적을 그만둔다.
    private func track(_ key: String, members: [(pid: pid_t, start: UInt64)], force: Bool) {
        let progress = QuitProgress(force: force)
        quitting[key] = progress
        poll(key, members: members, token: progress.token)
    }

    private func poll(_ key: String, members: [(pid: pid_t, start: UInt64)], token: UUID) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, var progress = self.quitting[key], progress.token == token else { return }
                let alive = members.contains { Metrics.bsdInfo(of: $0.pid)?.pbi_start_tvsec == $0.start }
                let elapsed = Date().timeIntervalSince(progress.started)
                if !alive || elapsed > 60 {
                    self.quitting[key] = nil
                    self.sample()
                    return
                }
                if !progress.stalled, elapsed > (progress.force ? 5 : 8) {
                    progress.stalled = true
                    self.quitting[key] = progress
                }
                self.poll(key, members: members, token: token)
            }
        }
    }

    private func refreshUsage() {
        DispatchQueue.global(qos: .utility).async {
            let usage = UsageReader.read()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.usage = usage }
            }
        }
    }

    // 스냅샷 전용: 메인 스레드가 잠들어 있어 백그라운드 결과를 못 받으니 바로 읽는다
    func readUsageNow() {
        usage = UsageReader.read()
    }

    // 스냅샷 전용: 종료 중 줄 모양 확인
    func previewQuitting(_ key: String, stalled: Bool) {
        var progress = QuitProgress(force: false)
        progress.stalled = stalled
        quitting[key] = progress
    }

    // MARK: 앱 · 프로세스 종료

    // 앱은 ⌘Q 와 같은 정상 종료(강제면 forceTerminate). 앱으로 안 잡히는 묶음은 프로세스마다 SIGTERM/SIGKILL.
    func quit(_ row: ProcessRow, force: Bool) {
        var handled = false
        if let bundle = row.bundlePath {
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL.path == bundle
            }
            for app in running where force ? app.forceTerminate() : app.terminate() { handled = true }
        }
        if !handled {
            for member in row.members.reversed()
            where Metrics.bsdInfo(of: member.pid)?.pbi_start_tvsec == member.start {
                kill(member.pid, force ? SIGKILL : SIGTERM)
            }
        }
        track(row.id, members: row.members, force: force)
    }

    // MARK: 로그인 시 실행

    var launchAtLogin: Bool { SMAppService.mainApp.status == .enabled }

    func toggleLaunchAtLogin() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            loginError = nil
        } catch {
            loginError = "로그인 항목 변경 실패: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    // MARK: 내부

    private struct AppGroup {
        var first: ProcessRecord
        var footprint: UInt64 = 0
        var cpu: Double = 0
        var members: [(pid: pid_t, start: UInt64)] = []
    }

    private func appRows(_ records: [ProcessRecord]) -> [ProcessRow] {
        var groups: [String: AppGroup] = [:]
        var keyOfPid: [pid_t: String] = [:]
        for record in records {
            let key = record.appBundle ?? "proc:" + record.label
            groups[key, default: AppGroup(first: record)].footprint += record.footprint
            groups[key]?.members.append((record.pid, record.startSeconds))
            groups[key]?.cpu += record.cpu
            keyOfPid[record.pid] = key
        }
        let hosted = Self.hostedAgentCounts(records, keyOfPid: keyOfPid)
        let protected = Self.ownAncestry()
        // 정렬(메모리·CPU)은 화면에서 고른다 — 작은 묶음은 미리 걸러 둔다
        let candidates = groups.filter { $0.value.footprint >= 20 * 1_048_576 || $0.value.cpu >= 0.01 }
        return candidates.sorted { $0.value.footprint > $1.value.footprint }.prefix(40).map { key, group in
            ProcessRow(id: key, name: group.first.label, footprint: group.footprint, cpu: group.cpu,
                       members: group.members,
                       bundlePath: group.first.appBundle,
                       killable: Self.isKillable(group.first) && !group.members.contains { protected.contains($0.pid) },
                       hostedAgents: hosted[key] ?? 0,
                       symbol: AgentAnalysis.isAgent(group.first) ? "terminal" : nil,
                       icon: icon(for: group.first.appBundle ?? group.first.path))
        }
    }

    // 에이전트·셸·시스템 프로세스·SysPulse 자신은 목록에서 끄지 않는다
    private static let shells: Set<String> = ["zsh", "bash", "sh", "fish", "login", "tmux", "screen", "sshd"]

    private static func isKillable(_ record: ProcessRecord) -> Bool {
        if let bundle = record.appBundle {
            return !bundle.hasPrefix("/System/") && bundle != Bundle.main.bundlePath
        }
        if AgentAnalysis.isAgent(record) || shells.contains(record.command) { return false }
        return !["/System/", "/usr/", "/bin/", "/sbin/", "/Library/Apple/"].contains { record.path.hasPrefix($0) }
    }

    // SysPulse 를 띄운 조상(터미널에서 실행했을 때의 셸 등)은 보호한다
    private static func ownAncestry() -> Set<pid_t> {
        var pids: Set<pid_t> = [getpid()]
        var pid = getppid()
        while pid > 1, pids.insert(pid).inserted, let info = Metrics.bsdInfo(of: pid) { pid = pid_t(info.pbi_ppid) }
        return pids
    }

    private static func hostedAgentCounts(_ records: [ProcessRecord], keyOfPid: [pid_t: String]) -> [String: Int] {
        let byPid = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        var counts: [String: Int] = [:]
        for agent in records where AgentAnalysis.isAgent(agent) {
            var keys = Set<String>()
            var pid = agent.ppid
            while pid > 1, keys.count < 64, let record = byPid[pid] {
                if let key = keyOfPid[pid] { keys.insert(key) }
                pid = record.ppid
            }
            for key in keys { counts[key, default: 0] += 1 }
        }
        return counts
    }

    private func append(_ value: Double, to history: inout [Double]) {
        history.append(value)
        if history.count > Self.historyLength { history.removeFirst(history.count - Self.historyLength) }
    }

    private func icon(for path: String) -> NSImage {
        if let cached = icons[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        icons[path] = image
        return image
    }
}

enum MenuBarLabel {
    // width: 고정 글자 수 — 값이 9% ↔ 10% 로 바뀌어도 항목 폭이 흔들리지 않게 한다
    // badge: 입력 대기 에이전트 수 — 숫자 왼쪽에 채운 원 + 숫자를 비워 그린다 (템플릿 그대로라 메뉴 막대 색을 따른다)
    static func image(lines: [String], width characters: Int, tint: NSColor? = nil, badge: Int = 0) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let color = tint ?? .black
        let strings = lines.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color]) }
        let lineHeight = ceil(font.ascender - font.descender)
        let charWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        let textWidth = ceil(max(charWidth * CGFloat(characters), strings.map { $0.size().width }.max() ?? 0))
        let height = lineHeight * CGFloat(lines.count)
        let diameter: CGFloat = badge > 0 ? 13 : 0
        let gap: CGFloat = badge > 0 ? 3 : 0
        let width = diameter + gap + textWidth
        let image = NSImage(size: NSSize(width: width, height: height), flipped: true) { _ in
            for (index, line) in strings.enumerated() {
                line.draw(at: NSPoint(x: width - line.size().width, y: CGFloat(index) * lineHeight))
            }
            if badge > 0 {
                let circle = NSRect(x: 0, y: (height - diameter) / 2, width: diameter, height: diameter)
                (tint ?? .black).setFill()
                NSBezierPath(ovalIn: circle).fill()
                let number = NSAttributedString(string: badge > 9 ? "9+" : "\(badge)", attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: badge > 9 ? 7 : 9, weight: .bold),
                    .foregroundColor: NSColor.black])
                let size = number.size()
                NSGraphicsContext.current?.compositingOperation = .destinationOut
                number.draw(at: NSPoint(x: circle.midX - size.width / 2, y: circle.midY - size.height / 2))
                NSGraphicsContext.current?.compositingOperation = .sourceOver
            }
            return true
        }
        image.isTemplate = tint == nil // 평소엔 메뉴 막대 밝기(라이트·다크·틴트)에 맞춰 색이 바뀐다
        return image
    }
}

enum Format {
    private static let gib = 1_073_741_824.0
    private static let mib = 1_048_576.0

    static func bytes(_ value: UInt64) -> String {
        let v = Double(value)
        return v >= 1000 * mib ? String(format: "%.1f GB", v / gib) : String(format: "%.0f MB", v / mib)
    }

    // 총 메모리처럼 딱 떨어지는 값은 소수점 없이 (36 GB)
    static func capacity(_ value: UInt64) -> String {
        let gb = Double(value) / gib
        return gb.rounded() == gb ? String(format: "%.0f GB", gb) : String(format: "%.1f GB", gb)
    }

    static func gigabytesShort(_ value: UInt64) -> String {
        String(format: "%.1fG", Double(value) / gib)
    }

    static func rate(_ bytesPerSecond: Double) -> String {
        String(format: "%.0f MB/s", bytesPerSecond / mib)
    }

    // 활성 상태 보기와 같은 표기: 코어 하나를 다 쓰면 100%, 여러 코어면 100% 를 넘는다
    static func cpu(_ cores: Double) -> String {
        "\(Int((max(cores, 0) * 100).rounded()))%"
    }

    static func percent(_ ratio: Double) -> String {
        "\(Int((min(max(ratio, 0), 1) * 100).rounded()))%"
    }

    static func uptime(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        let days = minutes / 1440, hours = minutes / 60 % 24, mins = minutes % 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(mins)분" }
        return "\(mins)분"
    }

    static func age(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "방금 시작" }
        if minutes < 60 { return "\(minutes)분 전 시작" }
        if minutes < 1440 { return "\(minutes / 60)시간 전 시작" }
        return "\(minutes / 1440)일 전 시작"
    }

    // 초기화까지 남은 시간 — Orca 상태 줄처럼 짧게 (2h 20m · 3d 2h · 45m)
    static func countdown(to date: Date) -> String {
        let minutes = max(Int(date.timeIntervalSinceNow / 60), 0)
        let days = minutes / 1440, hours = minutes / 60 % 24, mins = minutes % 60
        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 { return "\(hours)h \(mins)m" }
        return "\(mins)m"
    }

    // 상태가 이어진 시간 — 「3분째」
    static func lasting(since date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "방금" }
        if minutes < 60 { return "\(minutes)분째" }
        return "\(minutes / 60)시간째"
    }

    // 「10/31(토) 오전 6시」
    static func dayHour(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ko_KR")
        formatter.dateFormat = "M/d(E) a h시"
        return formatter.string(from: date)
    }

    static func ago(_ date: Date) -> String {
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 60 { return "\(minutes)분 전 값" }
        if minutes < 1440 { return "\(minutes / 60)시간 전 값" }
        return "\(minutes / 1440)일 전 값"
    }

    static func thermal(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "정상"
        case .fair: "약간 높음"
        case .serious: "높음"
        case .critical: "위험"
        @unknown default: "알 수 없음"
        }
    }
}
