import Foundation

// 업데이트 확인 — 빌드할 때 Info.plist 에 적어 둔 소스 폴더에서 git fetch 하고, 설치된 커밋 뒤로 새 커밋이 있는지 본다.
// 업데이트는 그 폴더에서 `git pull --ff-only && ./build.sh install` — 스크립트가 지금 앱을 끄고 새 빌드를 띄운다.
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

    // nil = 새 커밋 없음 또는 확인 불가(소스 폴더 없음 · 네트워크 실패)
    static func check() -> UpdateInfo? {
        guard let dir = sourceDir, let commit, FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
        guard CLI.run(git, ["-C", dir, "fetch", "--quiet", "origin"], timeout: 30) != nil else { return nil }
        let upstream = text(dir, ["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"]) ?? "origin/main"
        guard let head = text(dir, ["rev-parse", upstream]),
              let behind = text(dir, ["rev-list", "--count", "\(commit)..\(upstream)"]).flatMap({ Int($0) }),
              behind > 0 else { return nil }
        let subjects = text(dir, ["log", "--format=%s", "-3", "\(commit)..\(upstream)"])?
            .split(separator: "\n").map(String.init) ?? []
        return UpdateInfo(behind: behind, subjects: subjects, remoteHead: head)
    }

    // 성공하면 build.sh 가 이 앱을 끄므로 completion 은 실패했을 때만 불린다 (로그 마지막 줄을 넘긴다)
    static func install(completion: @escaping @Sendable (String) -> Void) {
        guard let dir = sourceDir else { return completion("소스 폴더를 모릅니다 — 개발 빌드") }
        let quoted = "'" + dir.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", """
            { echo "== $(date) 업데이트"; cd \(quoted) && git pull --ff-only && ARCHS="$(uname -m)" ./build.sh install; } \
            >> '\(logPath)' 2>&1
            """]
        process.terminationHandler = { finished in
            let tail = (try? String(contentsOfFile: logPath, encoding: .utf8))?
                .split(separator: "\n").suffix(2).joined(separator: " ") ?? ""
            completion("업데이트 실패 (종료 코드 \(finished.terminationStatus)) — \(tail)")
        }
        do { try process.run() } catch { completion("업데이트를 시작하지 못했습니다: \(error.localizedDescription)") }
    }

    private static func text(_ dir: String, _ arguments: [String]) -> String? {
        CLI.run(git, ["-C", dir] + arguments, timeout: 15).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
