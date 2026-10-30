import AppKit
import Combine
import ServiceManagement
import UserNotifications

struct ProcessRow: Identifiable {
    let id: String
    let name: String
    let footprint: UInt64
    let members: [(pid: pid_t, start: UInt64)]
    let bundlePath: String?
    let killable: Bool
    let hostedAgents: Int // 이 묶음 안(조상)에서 도는 에이전트 수 — Orca 를 끄면 그 터미널의 에이전트도 끝난다
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

    let hardware = Metrics.hardware()
    let bootDate = Metrics.bootDate()

    private let notifies: Bool
    private var lastTicks: [CoreTicks] = []
    private var lastSwapOut: (bytes: UInt64, time: Date)?
    private var swapRates: [Double] = []
    private var lastNotified: Date?
    private var icons: [String: NSImage] = [:]
    private var timer: Timer?

    init(autoStart: Bool = true) {
        let saved = UserDefaults.standard.integer(forKey: Self.thresholdKey)
        alertThresholdGB = saved > 0 ? saved : 4
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

        let records = Metrics.processes()
        apps = appRows(records)
        (sessions, strays) = AgentAnalysis.analyze(records)
        loadAverage = Metrics.loadAverage()
        evaluateAlerts()
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
        return MenuBarLabel.image(lines: ["\(percent)%", available], width: 5, tint: tint)
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
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "SysPulse — 메모리 여유 부족"
            content.body = body
            content.sound = .default
            UNUserNotificationCenter.current()
                .add(UNNotificationRequest(identifier: "syspulse.alert", content: content, trigger: nil))
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            MainActor.assumeIsolated { self?.sample() }
        }
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
        var members: [(pid: pid_t, start: UInt64)] = []
    }

    private func appRows(_ records: [ProcessRecord]) -> [ProcessRow] {
        var groups: [String: AppGroup] = [:]
        var keyOfPid: [pid_t: String] = [:]
        for record in records {
            let key = record.appBundle ?? "proc:" + record.label
            groups[key, default: AppGroup(first: record)].footprint += record.footprint
            groups[key]?.members.append((record.pid, record.startSeconds))
            keyOfPid[record.pid] = key
        }
        let hosted = Self.hostedAgentCounts(records, keyOfPid: keyOfPid)
        let protected = Self.ownAncestry()
        return groups.sorted { $0.value.footprint > $1.value.footprint }.prefix(8).map { key, group in
            ProcessRow(id: key, name: group.first.label, footprint: group.footprint, members: group.members,
                       bundlePath: group.first.appBundle,
                       killable: Self.isKillable(group.first) && !group.members.contains { protected.contains($0.pid) },
                       hostedAgents: hosted[key] ?? 0,
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
    static func image(lines: [String], width characters: Int, tint: NSColor? = nil) -> NSImage {
        let font = NSFont.monospacedSystemFont(ofSize: 9, weight: .semibold)
        let color = tint ?? .black
        let strings = lines.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: color]) }
        let lineHeight = ceil(font.ascender - font.descender)
        let charWidth = NSAttributedString(string: "0", attributes: [.font: font]).size().width
        let width = ceil(max(charWidth * CGFloat(characters), strings.map { $0.size().width }.max() ?? 0))
        let image = NSImage(size: NSSize(width: width, height: lineHeight * CGFloat(lines.count)), flipped: true) { _ in
            for (index, line) in strings.enumerated() {
                line.draw(at: NSPoint(x: width - line.size().width, y: CGFloat(index) * lineHeight))
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
