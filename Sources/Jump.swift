import AppKit

// 에이전트 줄을 누르면 그 세션이 도는 창·탭으로 간다.
// - Orca: 세션 환경 변수의 터미널 핸들로 `orca terminal switch` — 그 탭까지 앞으로 온다
// - Terminal · iTerm: 에이전트 프로세스의 tty 를 가진 탭을 AppleScript 로 고른다 (처음 한 번 자동화 권한을 묻는다)
// - 그 밖: 세션을 띄운 앱(__CFBundleIdentifier)을 앞으로. VS Code 류 편집기는 작업 폴더 창을 연다
// 환경 변수는 누를 때 한 번, 아래 키만 읽는다.
enum SessionJump {
    private static let keys: Set<String> = [
        "ORCA_TERMINAL_HANDLE", "ORCA_AGENT_PANE", "ORCA_CLI_BIN_DIR", "__CFBundleIdentifier",
    ]
    private static let orcaBundle = "com.stablyai.orca"
    // 폴더를 열면 그 폴더의 기존 창으로 가는 편집기
    private static let folderEditors: Set<String> = [
        "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf", "dev.zed.Zed",
    ]

    static func jump(to session: AgentSession) {
        jump(pid: session.id, cwd: session.cwd)
    }

    static func jump(pid: pid_t, cwd: String) {
        let env = Metrics.environment(of: pid, keys: keys)
        FileHandle.standardError.write(Data("[syspulse:jump] pid=\(pid) host=\(env.keys.sorted().joined(separator: ","))\n".utf8))
        if let handle = env["ORCA_TERMINAL_HANDLE"] {
            let cli = (env["ORCA_CLI_BIN_DIR"] ?? appURL(orcaBundle)?.appendingPathComponent("Contents/Resources/bin").path)
                .map { $0 + "/orca" }
            // 탭 id:패인 id — Orca 를 다시 켜서 핸들이 바뀌었으면 이걸로 찾는다
            let pane = env["ORCA_AGENT_PANE"]?.split(separator: ":").map(String.init)
            DispatchQueue.global(qos: .userInitiated).async {
                if let cli { switchOrca(cli: cli, handle: handle, pane: pane) }
                DispatchQueue.main.async { activate(orcaBundle, folder: nil) }
            }
            return
        }
        if let bundle = env["__CFBundleIdentifier"] {
            if let script = terminalScript(bundle: bundle, pid: pid), runAppleScript(script) { return }
            activate(bundle, folder: folderEditors.contains(bundle) ? cwd : nil)
        }
    }

    // 프로세스의 제어 터미널 → "/dev/ttys003"
    private static func tty(of pid: pid_t) -> String? {
        guard let info = Metrics.bsdInfo(of: pid), info.e_tdev != UInt32(bitPattern: -1),
              let name = devname(dev_t(bitPattern: info.e_tdev), S_IFCHR) else { return nil }
        return "/dev/" + String(cString: name)
    }

    private static func terminalScript(bundle: String, pid: pid_t) -> String? {
        guard let tty = tty(of: pid) else { return nil }
        switch bundle {
        case "com.apple.Terminal":
            return """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return true
                      end if
                    end repeat
                  end repeat
                end tell
                return false
                """
        case "com.googlecode.iterm2":
            return """
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if tty of s is "\(tty)" then
                          tell w to select
                          tell t to select
                          tell s to select
                          activate
                          return true
                        end if
                      end repeat
                    end repeat
                  end repeat
                end tell
                return false
                """
        default:
            return nil
        }
    }

    // 탭을 찾아 골랐으면 true. 권한 거절·못 찾음이면 false → 앱만 앞으로
    private static func runAppleScript(_ source: String) -> Bool {
        var error: NSDictionary?
        let result = NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { FileHandle.standardError.write(Data("[syspulse:jump] applescript \(error)\n".utf8)) }
        return result?.booleanValue == true
    }

    private static func switchOrca(cli: String, handle: String, pane: [String]?) {
        if run(cli, ["terminal", "switch", "--terminal", handle, "--json"]) != nil { return }
        guard let pane, pane.count == 2,
              let data = run(cli, ["terminal", "list", "--json"]),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let result = json["result"] as? [String: Any],
              let terminals = result["terminals"] as? [[String: Any]],
              let match = terminals.first(where: { $0["tabId"] as? String == pane[0] && $0["leafId"] as? String == pane[1] }),
              let fresh = match["handle"] as? String else { return }
        _ = run(cli, ["terminal", "switch", "--terminal", fresh, "--json"])
    }

    private static func run(_ path: String, _ arguments: [String]) -> Data? {
        let data = CLI.run(path, arguments)
        FileHandle.standardError.write(Data("[syspulse:jump] \(arguments.prefix(2).joined(separator: " ")) ok=\(data != nil)\n".utf8))
        return data
    }

    private static func appURL(_ bundle: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle)
    }

    private static func activate(_ bundle: String, folder: String?) {
        guard let url = appURL(bundle) else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        if let folder {
            NSWorkspace.shared.open([URL(fileURLWithPath: folder)], withApplicationAt: url, configuration: configuration)
        } else {
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }
}
