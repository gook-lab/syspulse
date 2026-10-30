import AppKit

// 업데이트 확인 — 빌드할 때 Info.plist 에 적어 둔 소스 폴더에서 git fetch 하고, 설치된 커밋 뒤로 새 커밋이 있는지 본다.
// 업데이트는 그 폴더에서 `git pull --ff-only && ./build.sh install` — 스크립트가 지금 앱을 끄고 새 빌드를 띄운다.
enum UpdateCheck: Sendable {
    case upToDate
    case available(UpdateInfo)
    case failed(String, quiet: Bool) // quiet = 자동 확인 때는 드러내지 않는 일시 실패(네트워크 등)
}

struct UpdateInfo: Sendable, Equatable {
    let behind: Int // 설치된 커밋 뒤로 새로 들어온 커밋 수
    let subjects: [String] // 최근 것부터 최대 3개
    let remoteHead: String
}

enum Updater {
    private static let info = Bundle.main.infoDictionary ?? [:]
    static let version = info["CFBundleShortVersionString"] as? String ?? "?"
    static let commit = info["SysPulseCommit"] as? String
    static let sourceDir = info["SysPulseSourceDir"] as? String
    static let logPath = NSHomeDirectory() + "/Library/Logs/SysPulse-update.log"
    private static let git = "/usr/bin/git"

    static var shortCommit: String { commit.map { String($0.prefix(7)) } ?? "개발 빌드" }

    static let reinstallHint = "INSTALL.md 링크로 다시 설치하세요"

    static func check() -> UpdateCheck {
        guard let dir = sourceDir, let commit else { return .failed("개발 빌드 — 소스 폴더를 모릅니다", quiet: true) }
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            return .failed("소스 폴더(\(dir))가 없어 업데이트할 수 없습니다 — \(reinstallHint)", quiet: false)
        }
        guard CLI.run(git, ["-C", dir, "fetch", "--quiet", "origin"], timeout: 30) != nil else {
            return .failed("git fetch 실패 — 네트워크나 저장소 접근을 확인하세요", quiet: true)
        }
        let upstream = text(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) ?? "origin/main"
        guard let head = text(dir, ["rev-parse", upstream]),
              let behind = text(dir, ["rev-list", "--count", "\(commit)..\(upstream)"]).flatMap({ Int($0) }) else {
            return .failed("설치된 커밋을 소스 폴더에서 찾지 못했습니다 — \(reinstallHint)", quiet: false)
        }
        guard behind > 0 else { return .upToDate }
        let subjects = text(dir, ["log", "--format=%s", "-3", "\(commit)..\(upstream)"])?
            .split(separator: "\n").map(String.init) ?? []
        return .available(UpdateInfo(behind: behind, subjects: subjects, remoteHead: head))
    }

    // 성공하면 build.sh 가 이 앱을 끈다. 그래도 살아 있으면(옛 build.sh 는 pkill 이 앱을 건너뛰었다) 새 앱을 띄울 셸을
    // 남기고 스스로 끝낸다. completion 은 실패했을 때만 불린다 (로그 마지막 줄을 넘긴다)
    static func install(completion: @escaping @Sendable (String) -> Void) {
        guard let dir = sourceDir else { return completion("업데이트 실패 — 개발 빌드라 소스 폴더를 모릅니다") }
        guard FileManager.default.fileExists(atPath: dir + "/.git") else {
            return completion("업데이트 실패 — 소스 폴더(\(dir))가 없습니다. \(reinstallHint)")
        }
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            { echo "== $(date) 업데이트"; cd \(quoted) && git pull --ff-only && ARCHS="$(uname -m)" ./build.sh install; } \
            >> '\(logPath)' 2>&1
            """]
        process.terminationHandler = { finished in
            if finished.terminationStatus == 0 { return relaunch() }
            let tail = (try? String(contentsOfFile: logPath, encoding: .utf8))?
                .split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            completion("업데이트 실패 (종료 코드 \(finished.terminationStatus)) — \(tail) · 로그 ~/Library/Logs/SysPulse-update.log")
        }
        do { try process.run() } catch { completion("업데이트 실패 — 시작하지 못했습니다: \(error.localizedDescription)") }
    }

    private static func relaunch() {
        let app = NSHomeDirectory() + "/Applications/SysPulse.app"
        let opener = Process()
        opener.executableURL = URL(fileURLWithPath: "/bin/bash")
        opener.arguments = ["-c", "sleep 1; open '\(app)'"]
        try? opener.run()
        DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
    }

    private static func text(_ dir: String, _ arguments: [String]) -> String? {
        CLI.run(git, ["-C", dir] + arguments, timeout: 15).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
