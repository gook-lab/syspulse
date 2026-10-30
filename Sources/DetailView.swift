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
    case agents, strays, apps
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

    private var tab: ListTab { tabOverride ?? ListTab(rawValue: storedTab) ?? .agents }

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
    }

    @ViewBuilder
    private var listColumn: some View {
        TabPicker(selection: tab, agentCount: monitor.sessions.count, strayCount: monitor.strays.count) {
            storedTab = $0.rawValue
        }
        switch tab {
        case .agents: AgentsSection(monitor: monitor)
        case .strays: StraysSection(monitor: monitor)
        case .apps: AppsSection(monitor: monitor, previewConfirmFirst: previewConfirmFirstApp)
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

// MARK: - 목록 탭

private struct TabPicker: View {
    let selection: ListTab
    let agentCount: Int
    let strayCount: Int
    let onSelect: (ListTab) -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) { buttons(compact: false); Spacer(minLength: 0) }
            HStack(spacing: 2) { buttons(compact: true); Spacer(minLength: 0) }
        }
    }

    @ViewBuilder
    private func buttons(compact: Bool) -> some View {
        tabButton(.agents, title: agentCount > 0 ? "에이전트 \(agentCount)" : "에이전트", compact: compact)
        tabButton(.strays, title: strayCount > 0 ? "세션 밖 \(strayCount)" : "세션 밖", compact: compact)
        tabButton(.apps, title: "앱", compact: compact)
    }

    private func tabButton(_ tab: ListTab, title: String, compact: Bool) -> some View {
        Button(title) { onSelect(tab) }
            .buttonStyle(TabButtonStyle(selected: selection == tab, compact: compact))
    }
}

private struct AgentsSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.sessions.isEmpty {
                Text("실행 중인 에이전트(claude·codex)가 없습니다").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(summary).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(monitor.sessions.prefix(8)) { session in SessionRow(session: session) }
                if monitor.sessions.count > 8 {
                    Text("외 \(monitor.sessions.count - 8)개").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var summary: String {
        let total = monitor.sessions.reduce(UInt64(0)) { $0 + $1.total }
        let count = monitor.sessions.count
        return "에이전트 \(count)개 · 합계 \(Format.bytes(total)) · 평균 \(Format.bytes(total / UInt64(count)))"
    }
}

private struct StraysSection: View {
    @ObservedObject var monitor: SystemMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if monitor.strays.isEmpty {
                Text("모든 dev 프로세스가 에이전트 세션에 연결돼 있습니다").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(monitor.strays.prefix(8)) { stray in StrayRow(stray: stray, monitor: monitor) }
            }
            Text("부모 에이전트도, 작업 폴더가 겹치는 세션도 찾지 못한 node·python 등입니다. 끝난 세션이 남긴 dev 서버일 수 있지만, 직접 띄운 서비스일 수도 있습니다.")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SessionRow: View {
    let session: AgentSession

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 6) {
                Image(systemName: "terminal").font(.caption).foregroundStyle(.secondary).frame(width: 16)
                Text(session.project).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.bytes(session.total)).monospacedDigit()
            }
            .font(.callout)
            Text(session.detail)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 22)
        }
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
            Text(Format.bytes(stray.footprint)).monospacedDigit()
            // 두 번 눌러야 끈다 — 4초 안에 「확인」을 누르지 않으면 되돌아간다
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
        .font(.callout)
    }
}

private struct AppsSection: View {
    @ObservedObject var monitor: SystemMonitor
    var previewConfirmFirst = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(monitor.apps) { row in
                AppRow(row: row, monitor: monitor, confirming: previewConfirmFirst && row.id == previewRowID)
            }
            Text("내 계정 프로세스 기준 · 같은 앱의 헬퍼와 같은 이름의 프로세스는 합산 · ⓧ 로 종료")
                .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // 스냅샷 미리보기: 에이전트를 품은 앱(경고 문구가 보이는 줄) 우선
    private var previewRowID: String? {
        (monitor.apps.first { $0.killable && $0.hostedAgents > 0 } ?? monitor.apps.first { $0.killable })?.id
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
                Image(nsImage: row.icon).resizable().frame(width: 16, height: 16)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                if row.count > 1 {
                    Text("×\(row.count)").foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(Format.bytes(row.footprint)).monospacedDigit()
                if row.killable {
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
            if confirming && row.killable {
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
                    loginButton
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) { threshold }
                    loginButton
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
