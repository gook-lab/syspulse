import AppKit
import Darwin

// 커널에서 직접 읽는 수치들. 계산식은 활성 상태 보기(Activity Monitor)와 맞춘다.

struct CoreTicks {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32

    static let zero = CoreTicks(user: 0, system: 0, idle: 0, nice: 0)
}

struct CPULoad {
    var user: Double
    var system: Double
    var idle: Double
    var total: Double { user + system }

    static let idleLoad = CPULoad(user: 0, system: 0, idle: 1)
}

enum MemoryPressure {
    case normal, warning, critical
}

struct MemoryInfo {
    var total: UInt64
    var app: UInt64
    var wired: UInt64
    var compressed: UInt64
    var cached: UInt64
    var swapUsed: UInt64
    var swapTotal: UInt64
    var swapOutBytes: UInt64 // 부팅 후 누적 — 두 시점 차이로 스왑 쓰기 속도를 낸다
    var pressure: MemoryPressure?

    // 활성 상태 보기의 「사용된 메모리」 = 앱 + 와이어드 + 압축
    var used: UInt64 { app + wired + compressed }
    // 캐시된 파일은 필요하면 바로 비워지므로 가용에 포함한다
    var available: UInt64 { total > used ? total - used : 0 }
}

struct HardwareInfo {
    var chip: String
    var coreSummary: String
    var osVersion: String
    var totalMemory: UInt64
}

struct ProcessRecord {
    let pid: pid_t
    let ppid: pid_t
    let startSeconds: UInt64 // PID 재사용 확인용
    let footprint: UInt64
    let cpuNanos: UInt64 // 부팅 후 누적 CPU 시간 (user + system)
    let path: String
    let appBundle: String?
    let args: [String] // 앱 밖 프로세스만 읽는다
    let command: String // argv[0] 이름 (앱은 앱 이름)
    let label: String // 묶음 이름: 앱 이름 또는 「node · vite」
    var cpu: Double = 0 // 직전 샘플 이후 사용률 (코어 1개 = 1.0) — SystemMonitor 가 채운다

    var started: Date { Date(timeIntervalSince1970: TimeInterval(startSeconds)) }
}

enum Metrics {
    static let host = mach_host_self()

    // MARK: CPU

    static func coreTicks() -> [CoreTicks] {
        var cpuCount: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(host, PROCESSOR_CPU_LOAD_INFO, &cpuCount, &info, &infoCount) == KERN_SUCCESS,
              let info else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: info)),
                          vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride))
        }
        return (0..<Int(cpuCount)).map { i in
            let base = i * Int(CPU_STATE_MAX)
            func tick(_ state: Int32) -> UInt32 { UInt32(bitPattern: info[base + Int(state)]) }
            return CoreTicks(user: tick(CPU_STATE_USER), system: tick(CPU_STATE_SYSTEM),
                             idle: tick(CPU_STATE_IDLE), nice: tick(CPU_STATE_NICE))
        }
    }

    static func sum(_ ticks: [CoreTicks]) -> CoreTicks {
        ticks.reduce(.zero) {
            CoreTicks(user: $0.user &+ $1.user, system: $0.system &+ $1.system,
                      idle: $0.idle &+ $1.idle, nice: $0.nice &+ $1.nice)
        }
    }

    // 틱은 누적 카운터라 두 시점의 차이로 사용률을 낸다 (32비트 넘침은 &- 로 흡수)
    static func load(from prev: CoreTicks, to cur: CoreTicks) -> CPULoad {
        let user = Double(cur.user &- prev.user) + Double(cur.nice &- prev.nice)
        let system = Double(cur.system &- prev.system)
        let idle = Double(cur.idle &- prev.idle)
        let total = user + system + idle
        guard total > 0 else { return .idleLoad }
        return CPULoad(user: user / total, system: system / total, idle: idle / total)
    }

    static func loadAverage() -> [Double] {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) == 3 ? loads : []
    }

    // MARK: 메모리

    static func memory() -> MemoryInfo? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return nil }

        let page = UInt64(vm_kernel_page_size)
        let anonymous = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)

        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 { swap = xsw_usage() }

        let pressure: MemoryPressure? = sysctlInt("kern.memorystatus_vm_pressure_level").map {
            $0 >= 4 ? .critical : $0 >= 2 ? .warning : .normal
        }

        return MemoryInfo(
            total: ProcessInfo.processInfo.physicalMemory,
            app: (anonymous > purgeable ? anonymous - purgeable : 0) * page,
            wired: UInt64(stats.wire_count) * page,
            compressed: UInt64(stats.compressor_page_count) * page,
            cached: (UInt64(stats.external_page_count) + purgeable) * page,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            swapOutBytes: stats.swapouts * page,
            pressure: pressure)
    }

    // MARK: 프로세스

    // 내 계정 프로세스만 읽힌다 (WindowServer·kernel_task 같은 시스템 프로세스는 권한 밖)
    static func processes() -> [ProcessRecord] {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let listed = pids.withUnsafeMutableBufferPointer {
            Int(proc_listallpids($0.baseAddress, Int32($0.count * MemoryLayout<pid_t>.stride)))
        }

        var records: [ProcessRecord] = []
        var pathBuf = [CChar](repeating: 0, count: 4096)
        var nameBuf = [CChar](repeating: 0, count: 256)
        var argBuf = [UInt8](repeating: 0, count: max(sysctlInt("kern.argmax") ?? 0, 262_144))
        for pid in pids.prefix(min(max(listed, 0), capacity)) where pid > 0 {
            guard let usage = usage(of: pid), let bsd = bsdInfo(of: pid),
                  proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count)) > 0 else { continue }
            let path = string(from: pathBuf)

            if let bundle = outermostAppBundle(in: path) {
                let name = String((bundle as NSString).lastPathComponent.dropLast(4))
                records.append(ProcessRecord(pid: pid, ppid: pid_t(bsd.pbi_ppid), startSeconds: bsd.pbi_start_tvsec,
                                             footprint: usage.footprint, cpuNanos: usage.cpuNanos,
                                             path: path, appBundle: bundle, args: [],
                                             command: name, label: name))
                continue
            }
            let args = normalizedArguments(arguments(of: pid, buffer: &argBuf) ?? [])
            let fallback = proc_name(pid, &nameBuf, UInt32(nameBuf.count)) > 0
                ? string(from: nameBuf) : basename(path)
            let described = describe(args: args)
            records.append(ProcessRecord(pid: pid, ppid: pid_t(bsd.pbi_ppid), startSeconds: bsd.pbi_start_tvsec,
                                         footprint: usage.footprint, cpuNanos: usage.cpuNanos,
                                         path: path, appBundle: nil, args: args,
                                         command: described?.command ?? fallback,
                                         label: stripVersion(described?.label ?? fallback)))
        }
        return records
    }

    // ri_user_time·ri_system_time 은 나노초가 아니라 mach 틱이다 (애플 실리콘 1틱 = 125/3 ns, 실측 확인)
    static let nanosPerTick: Double = {
        var info = mach_timebase_info()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom)
    }()

    static func usage(of pid: pid_t) -> (footprint: UInt64, cpuNanos: UInt64)? {
        var usage = rusage_info_v4()
        let ok = withUnsafeMutablePointer(to: &usage) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) == 0
            }
        }
        guard ok, usage.ri_phys_footprint > 0 else { return nil }
        let ticks = usage.ri_user_time + usage.ri_system_time
        return (usage.ri_phys_footprint, UInt64(Double(ticks) * nanosPerTick))
    }

    static func bsdInfo(of pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? info : nil
    }

    static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) {
            String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    // .app 안의 실행 파일은 가장 바깥 .app 으로 묶는다 (Chrome 헬퍼 → Google Chrome)
    static func outermostAppBundle(in path: String) -> String? {
        guard let range = path.range(of: ".app/") else { return nil }
        return String(path[..<range.lowerBound]) + ".app"
    }

    // MARK: 프로세스 이름 — argv 기반

    // claude 는 실행 파일이 버전 폴더(~/.local/share/claude/versions/2.1.x)라 argv[0] 을 써야 「claude」가 된다.
    // node·bun 은 세션마다 vite·vitest·MCP 서버가 따로 떠서, 스크립트 이름까지 붙여야 무엇이 먹는지 보인다.
    static let interpreters: Set<String> = ["node", "bun", "deno", "python", "python3", "ruby"]
    static let runners: Set<String> = ["npm", "npx", "pnpm", "yarn", "bunx"]
    private static let runnerVerbs: Set<String> = ["exec", "run", "dlx", "x", "start"]

    static func describe(args: [String]) -> (command: String, label: String)? {
        guard let first = args.first, !first.isEmpty else { return nil }
        var command = basename(first)
        var rest = args.dropFirst()
        // node …/bin/pnpm exec vite → pnpm 으로 본다
        if interpreters.contains(command), let script = rest.first(where: { !$0.hasPrefix("-") }),
           runners.contains(basename(script)) {
            command = basename(script)
            rest = rest.drop(while: { $0 != script }).dropFirst()
        }
        if runners.contains(command) {
            let target = rest.first { !$0.hasPrefix("-") && !runnerVerbs.contains($0) }
            return (command, target.map { "\(command) · \(packageName($0))" } ?? command)
        }
        guard interpreters.contains(command) else { return (command, command) }
        return (command, scriptName(in: rest).map { "\(command) · \($0)" } ?? command)
    }

    // process.title 로 argv 를 덮어쓴 프로세스(npm exec …)는 argv[0] 한 칸에 공백으로 이어져 있다
    static func normalizedArguments(_ args: [String]) -> [String] {
        guard let first = args.first, first.contains(" "),
              !first.prefix(while: { $0 != " " }).contains("/") else { return args }
        return first.split(separator: " ").map(String.init) + args.dropFirst().filter { !$0.isEmpty }
    }

    static func scriptName(in args: ArraySlice<String>) -> String? {
        if args.contains("-e") || args.contains("--eval") { return "eval" } // node -e '…' 는 코드 문자열이라 이름이 없다
        // node_modules 안의 스크립트는 패키지 이름으로 (.bin/../vite/bin/vite.js → vite)
        for arg in args where arg.contains("node_modules/") {
            let path = (arg as NSString).standardizingPath
            guard let range = path.range(of: "node_modules/", options: .backwards) else { continue }
            let parts = path[range.upperBound...].split(separator: "/").map(String.init)
            guard let head = parts.first else { continue }
            if head == ".bin" || head.hasPrefix("@"), parts.count > 1 { return parts[1] }
            return head
        }
        if let index = args.firstIndex(of: "-m"), args.index(after: index) < args.endIndex {
            return args[args.index(after: index)]
        }
        guard let script = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
        // index.js · server.js 처럼 흔한 이름이면 의미 있는 상위 폴더 이름을 쓴다
        let generic: Set<String> = ["index", "main", "server", "cli", "app"]
        let skip: Set<String> = ["dist", "lib", "src", "bin", "build", "out"]
        var components = (script as NSString).pathComponents
        let base = ((components.last ?? script) as NSString).deletingPathExtension
        guard generic.contains(base), components.count > 1 else { return basename(script) }
        components.removeLast()
        while let dir = components.last,
              skip.contains(dir) || dir.first?.isNumber == true || dir == "/" { components.removeLast() }
        return components.last ?? basename(script)
    }

    // @modelcontextprotocol/server-memory@2025.1 → server-memory
    static func packageName(_ spec: String) -> String {
        basename(stripVersion(spec))
    }

    // npx 가 띄운 MCP 서버는 이름 끝에 @버전이 붙는다 (server-x@2025.12.18 → server-x)
    static func stripVersion(_ name: String) -> String {
        guard let at = name.lastIndex(of: "@"), at != name.startIndex,
              name[name.index(after: at)...].first?.isNumber == true else { return name }
        return String(name[..<at])
    }

    // KERN_PROCARGS2 = [argc: Int32][실행 경로\0][\0 패딩][argv[0]\0 argv[1]\0 …]
    static func arguments(of pid: pid_t, buffer: inout [UInt8]) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args
    }

    // 환경 변수 중 keys 에 든 것만 돌려준다. 나머지(토큰·키 등)는 문자열로 만들지도 않고 버린다.
    // argv 뒤에 "KEY=VALUE" 가 빈 문자열이 나올 때까지 이어진다 (KERN_PROCARGS2).
    static func environment(of pid: pid_t, keys: Set<String>) -> [String: String] {
        var buffer = [UInt8](repeating: 0, count: sysctlInt("kern.argmax") ?? 1 << 20)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = buffer.count
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [:] }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var index = 4
        while index < size, buffer[index] != 0 { index += 1 }
        while index < size, buffer[index] == 0 { index += 1 }
        for _ in 0..<argc {
            while index < size, buffer[index] != 0 { index += 1 }
            index += 1
        }
        let prefixes = keys.map { (key: $0, bytes: Array(($0 + "=").utf8)) }
        var found: [String: String] = [:]
        while index < size, buffer[index] != 0 {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            let entry = buffer[start..<index]
            if let match = prefixes.first(where: { entry.starts(with: $0.bytes) }) {
                found[match.key] = String(decoding: entry.dropFirst(match.bytes.count), as: UTF8.self)
            }
            index += 1
        }
        return found
    }

    // MARK: 하드웨어

    static func hardware() -> HardwareInfo {
        let logical = ProcessInfo.processInfo.activeProcessorCount
        var levels: [String] = []
        for level in 0..<(sysctlInt("hw.nperflevels") ?? 0) {
            guard let cores = sysctlInt("hw.perflevel\(level).physicalcpu") else { continue }
            let name = sysctlString("hw.perflevel\(level).name") ?? "L\(level)"
            let short = ["Performance": "P", "Efficiency": "E"][name] ?? name
            levels.append("\(short) \(cores)")
        }
        let cores = levels.count > 1 ? "\(logical)코어 (\(levels.joined(separator: " · ")))" : "\(logical)코어"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return HardwareInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Mac",
            coreSummary: cores,
            osVersion: "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            totalMemory: ProcessInfo.processInfo.physicalMemory)
    }

    static func bootDate() -> Date? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(tv.tv_sec))
    }

    // MARK: sysctl · 문자열

    static func sysctlInt(_ name: String) -> Int? {
        var value: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return size == 4 ? Int(Int32(truncatingIfNeeded: value)) : Int(value)
    }

    static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return string(from: buf)
    }

    static func string(from buf: [CChar]) -> String {
        buf.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }

    static func basename(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }
}
