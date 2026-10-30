import AppKit

// 에이전트 구독 사용량(5시간 세션 · 주간 · 월간). 토큰을 직접 다루지 않는다.
// 1순위 Orca: `orca account list --json` 의 rateLimits — Orca 상태 줄과 같은 값 (Claude·Codex·Cursor 와
//   Gemini·Kimi·Grok 등 Orca 에 로그인한 에이전트 전부). Orca 가 없거나 빠진 에이전트는 아래 로컬 파일로 채운다.
// - Claude: Claude Code 가 상태 줄(statusline)에 넘기는 rate_limits 를 claude-hud 가 파일로 저장한 것
//   (claude-hud 설정 display.externalUsageWritePath). 경로는 defaults 의 claudeUsagePath 로 바꿀 수 있다.
// - Codex: 세션 로그(rollout-*.jsonl)의 마지막 rate_limits 이벤트. ~/.codex 와 Orca 가 쓰는 Codex 홈을 함께 본다.

struct UsageWindow: Identifiable, Sendable {
    enum Pace { case normal, warning, critical }

    let id: String
    let label: String
    let usedPercent: Double
    let resetsAt: Date?
    let length: TimeInterval // 창 길이 (5시간 · 7일)

    var isReset: Bool { resetsAt.map { $0 < Date() } ?? false } // 초기화 시각이 지났으면 값이 낡았다

    // claude-hud 와 같은 기준: 지금 속도를 초기화 시각까지 늘렸을 때 한도의 90% 이상이면 주의, 넘으면 위험.
    // 10% 미만은 이른 시점의 투영이 크게 튀어서(5분에 3% → 180%) 보지 않는다.
    var pace: Pace {
        if usedPercent >= 90 { return .critical }
        guard usedPercent >= 10, let resetsAt else { return .normal }
        let remaining = resetsAt.timeIntervalSinceNow
        guard remaining > 0, remaining < length else { return .normal }
        let projected = usedPercent / ((length - remaining) / length)
        return projected > 100 ? .critical : projected >= 90 ? .warning : .normal
    }
}

struct AgentUsage: Identifiable, Sendable {
    let id: String
    let name: String
    let windows: [UsageWindow]
    let reportedAt: Date?

    // 정렬 기준: 5시간 세션 사용률, 세션 창이 없으면(Cursor 등) 가장 높은 창
    var rank: Double {
        windows.first { $0.id == "session" || $0.id == "five_hour" || $0.id == "primary" }?.usedPercent
            ?? windows.map(\.usedPercent).max() ?? 0
    }
}

enum UsageReader {
    static let defaultClaudePath = "~/.claude/plugins/claude-hud/usage-snapshot.json"

    // 세션을 많이 쓴 에이전트가 위로
    static func read() -> [AgentUsage] {
        var agents = orca()
        for local in [claude(), codex()].compactMap({ $0 }) where !agents.contains(where: { $0.id == local.id }) {
            agents.append(local)
        }
        return agents.sorted { $0.rank > $1.rank }
    }

    // MARK: Orca

    private static let orcaCLI: String? = {
        let bundled = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.stablyai.orca")?
            .appendingPathComponent("Contents/Resources/bin/orca").path
        return bundled.flatMap { FileManager.default.isExecutableFile(atPath: $0) ? $0 : nil }
    }()

    private static let providerNames = [
        "claude": "Claude", "codex": "Codex", "cursor": "Cursor", "gemini": "Gemini", "kimi": "Kimi",
        "grok": "Grok", "minimax": "MiniMax", "antigravity": "Antigravity", "zcode": "ZCode", "opencodeGo": "OpenCode Go",
    ]

    static func orca() -> [AgentUsage] {
        guard let cli = orcaCLI, let data = CLI.run(cli, ["account", "list", "--json"], timeout: 4),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let limits = result["rateLimits"] as? [String: Any] else { return [] }
        return limits.compactMap { key, value -> AgentUsage? in
            guard let provider = value as? [String: Any], provider["status"] as? String == "ok" else { return nil }
            let windows = orcaWindows(provider)
            guard !windows.isEmpty else { return nil }
            return AgentUsage(id: key, name: providerNames[key] ?? key.capitalized, windows: windows,
                              reportedAt: (provider["updatedAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) })
        }
    }

    // session · weekly · (모델별) xxxWeekly · monthly 순. buckets(Cursor 의 모델 묶음)가 있으면 monthly 대신 쓴다.
    private static func orcaWindows(_ provider: [String: Any]) -> [UsageWindow] {
        func window(_ id: String, _ label: String, _ raw: Any?) -> UsageWindow? {
            guard let raw = raw as? [String: Any], let used = (raw["usedPercent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (raw["windowMinutes"] as? NSNumber)?.doubleValue ?? 0
            let reset = (raw["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
            return UsageWindow(id: id, label: label, usedPercent: used, resetsAt: reset, length: minutes * 60)
        }
        var windows = [window("session", "세션", provider["session"]), window("weekly", "주간", provider["weekly"])]
        for key in provider.keys.sorted() where key.hasSuffix("Weekly") {
            windows.append(window(key, String(key.dropLast(6)).capitalized, provider[key]))
        }
        if let buckets = provider["buckets"] as? [[String: Any]], !buckets.isEmpty {
            for bucket in buckets {
                let name = bucket["name"] as? String ?? "?"
                let label = name == "Cursor Models" ? "자체 모델" : name == "Other Models" ? "기타 모델" : name
                windows.append(window("bucket:" + name, label, bucket))
            }
        } else {
            windows.append(window("monthly", "월간", provider["monthly"]))
        }
        return windows.compactMap { $0 }
    }

    // MARK: Claude

    static func claude() -> AgentUsage? {
        let path = UserDefaults.standard.string(forKey: "claudeUsagePath") ?? defaultClaudePath
        guard let data = FileManager.default.contents(atPath: (path as NSString).expandingTildeInPath),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        func window(_ key: String, _ label: String, _ length: TimeInterval) -> UsageWindow? {
            guard let window = json[key] as? [String: Any],
                  let used = (window["used_percentage"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(id: key, label: label, usedPercent: used,
                               resetsAt: (window["resets_at"] as? String).flatMap(parseDate), length: length)
        }
        // 모델별 주간 창(Fable 등)이 함께 오면 덧붙인다: [{ display_name, utilization, resets_at }]
        let scoped = (json["model_scoped"] as? [[String: Any]] ?? []).compactMap { entry -> UsageWindow? in
            guard let name = entry["display_name"] as? String,
                  let used = (entry["utilization"] as? NSNumber)?.doubleValue else { return nil }
            return UsageWindow(id: "scoped:" + name, label: name, usedPercent: used,
                               resetsAt: (entry["resets_at"] as? String).flatMap(parseDate), length: week)
        }
        let windows = [window("five_hour", "세션", fiveHours), window("seven_day", "주간", week)].compactMap { $0 } + scoped
        guard !windows.isEmpty else { return nil }
        return AgentUsage(id: "claude", name: "Claude", windows: windows,
                          reportedAt: (json["updated_at"] as? String).flatMap(parseDate))
    }

    private static let fiveHours: TimeInterval = 5 * 3600
    private static let week: TimeInterval = 7 * 86_400

    // MARK: Codex

    static func codex() -> AgentUsage? {
        let home = NSHomeDirectory()
        let orca = home + "/Library/Application Support/orca"
        var roots = [home + "/.codex/sessions", orca + "/codex-runtime-home/home/sessions"]
        if let accounts = try? FileManager.default.contentsOfDirectory(atPath: orca + "/codex-accounts") {
            roots += accounts.map { "\(orca)/codex-accounts/\($0)/home/sessions" }
        }

        // 세션 로그는 날짜 폴더(YYYY/MM/DD)에 쌓인다 — 오늘·어제 폴더에서 최근에 쓰인 파일만 본다
        var files: [(path: String, modified: Date)] = []
        for root in roots {
            for dayOffset in 0...1 {
                let day = Calendar.current.dateComponents([.year, .month, .day],
                                                          from: Date().addingTimeInterval(-86_400 * Double(dayOffset)))
                let dir = String(format: "%@/%04d/%02d/%02d", root, day.year ?? 0, day.month ?? 0, day.day ?? 0)
                for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
                where name.hasPrefix("rollout-") && name.hasSuffix(".jsonl") {
                    let path = dir + "/" + name
                    let modified = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
                    files.append((path, modified ?? .distantPast))
                }
            }
        }

        let latest = files.sorted { $0.modified > $1.modified }.prefix(4)
            .compactMap { lastRateLimits(in: $0.path) }
            .max { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
        guard let latest else { return nil }
        let windows = ["primary", "secondary"].compactMap { key -> UsageWindow? in
            guard let window = latest.limits[key] as? [String: Any],
                  let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
            let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
            let label = minutes == 300 ? "세션" : minutes == 10_080 ? "주간" : "\(minutes / 60)시간"
            let reset = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            return UsageWindow(id: key, label: label, usedPercent: used, resetsAt: reset,
                               length: TimeInterval(minutes) * 60)
        }
        return windows.isEmpty ? nil : AgentUsage(id: "codex", name: "Codex", windows: windows,
                                                  reportedAt: latest.timestamp)
    }

    // 로그는 수 MB 까지 커지므로 끝부분 512 KB 만 읽어 뒤에서부터 찾는다
    private static func lastRateLimits(in path: String) -> (timestamp: Date?, limits: [String: Any])? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let chunk: UInt64 = 512 * 1024
        try? handle.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").reversed()
        where line.contains("\"rate_limits\"") {
            guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let limits = findRateLimits(in: object) else { continue }
            return ((object["timestamp"] as? String).flatMap(parseDate), limits)
        }
        return nil
    }

    private static func findRateLimits(in value: Any) -> [String: Any]? {
        guard let object = value as? [String: Any] else { return nil }
        if let limits = object["rate_limits"] as? [String: Any] { return limits }
        for child in object.values {
            if let found = findRateLimits(in: child) { return found }
        }
        return nil
    }

    // MARK: 날짜

    private static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}

// 짧은 CLI 호출. 끝나지 않으면 timeout 초 뒤 끊는다. 성공(종료 코드 0)이면 표준 출력, 아니면 nil.
enum CLI {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 5) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        guard (try? process.run()) != nil else { return nil }
        var data = Data()
        let reader = DispatchQueue.global(qos: .utility)
        let finishedReading = DispatchSemaphore(value: 0)
        reader.async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            finishedReading.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        _ = finishedReading.wait(timeout: .now() + 1)
        return process.terminationStatus == 0 ? data : nil
    }
}
