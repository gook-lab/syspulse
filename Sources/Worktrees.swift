import Foundation

// 끝난 worktree 를 찾아 디스크를 되찾는다. 판정은 git 이 준 값만 쓰고, 지우는 건 `git worktree remove`
// (--force 없이 — 변경이 남아 있으면 git 이 거절한다)로만 한다. 브랜치는 건드리지 않는다.
struct WorktreeInfo: Identifiable, Sendable {
    let id: String // worktree 경로
    let repo: String // 메인 worktree 경로
    let branch: String?
    var size: UInt64?
    let lastCommit: Date?
    let changes: Int // git status 줄 수 (추적 안 하는 파일 포함, 무시 파일 제외). -1 = 확인 실패
    let unpushed: Int // 어느 원격에도 없는 커밋 수. -1 = 확인 실패
    let merged: Bool // 기본 브랜치에 들어감
    let busy: [String] // 안에서 도는 에이전트·dev 프로세스
    let locked: Bool
    let missing: Bool // 폴더가 이미 없음 (git 기록만 남음)

    var name: String { (id as NSString).lastPathComponent }
    var repoName: String { (repo as NSString).lastPathComponent }

    // 지워도 잃을 게 없는 것만: 변경 0 · 원격에 없는 커밋 0 · 안에서 도는 프로세스 없음 · 잠기지 않음
    var removable: Bool { !locked && busy.isEmpty && (missing || (changes == 0 && unpushed == 0)) }
}

enum WorktreeScanner {
    private static let git = "/usr/bin/git"

    // 폴더가 속한 저장소의 메인 worktree 경로
    static func repoRoot(of directory: String) -> String? {
        guard let data = CLI.run(git, ["-C", directory, "rev-parse", "--path-format=absolute", "--git-common-dir"]),
              let common = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              common.hasSuffix("/.git") else { return nil }
        return String(common.dropLast(5))
    }

    // 메인을 뺀 worktree 목록. 크기는 measureSizes 로 따로 잰다(오래 걸린다).
    static func scan(repos: [String], busyPaths: [(path: String, name: String)]) -> [WorktreeInfo] {
        repos.flatMap { repo -> [WorktreeInfo] in
            let base = defaultBranch(repo)
            return entries(repo).dropFirst().map { entry in
                let path = entry.path
                let busy = busyPaths.filter { $0.path == path || $0.path.hasPrefix(path + "/") }.map(\.name)
                guard !entry.missing else {
                    return WorktreeInfo(id: path, repo: repo, branch: entry.branch, size: 0, lastCommit: nil, changes: 0,
                                        unpushed: 0, merged: false, busy: busy, locked: entry.locked, missing: true)
                }
                return WorktreeInfo(
                    id: path, repo: repo, branch: entry.branch, size: nil,
                    lastCommit: text(["-C", path, "log", "-1", "--format=%ct"]).flatMap(Double.init)
                        .map { Date(timeIntervalSince1970: $0) },
                    changes: text(["-C", path, "status", "--porcelain"]).map { $0.isEmpty ? 0 : $0.split(separator: "\n").count } ?? -1,
                    unpushed: text(["-C", path, "rev-list", "--count", "HEAD", "--not", "--remotes"]).flatMap { Int($0) } ?? -1,
                    merged: base.map { CLI.run(git, ["-C", path, "merge-base", "--is-ancestor", "HEAD", $0]) != nil } ?? false,
                    busy: busy, locked: entry.locked, missing: false)
            }
        }
    }

    static func measureSize(_ path: String) -> UInt64? {
        guard let output = CLI.run("/usr/bin/du", ["-sk", path], timeout: 120).flatMap({ String(data: $0, encoding: .utf8) }),
              let kilobytes = output.split(separator: "\t").first.flatMap({ UInt64($0) }) else { return nil }
        return kilobytes * 1024
    }

    // 실패하면 git 의 오류 메시지
    static func remove(_ worktree: WorktreeInfo) -> String? {
        let arguments = worktree.missing ? ["-C", worktree.repo, "worktree", "prune"]
                                         : ["-C", worktree.repo, "worktree", "remove", worktree.id]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "git 을 실행하지 못했습니다" }
        let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return process.terminationStatus == 0 ? nil : message.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct Entry {
        var path = ""
        var branch: String?
        var locked = false
        var missing = false
    }

    private static func entries(_ repo: String) -> [Entry] {
        guard let porcelain = text(["-C", repo, "worktree", "list", "--porcelain"]) else { return [] }
        return porcelain.components(separatedBy: "\n\n").compactMap { block in
            var entry = Entry()
            for line in block.split(separator: "\n") {
                if line.hasPrefix("worktree ") { entry.path = String(line.dropFirst(9)) }
                if line.hasPrefix("branch ") { entry.branch = String(line.dropFirst(7)).replacingOccurrences(of: "refs/heads/", with: "") }
                if line.hasPrefix("locked") { entry.locked = true }
                if line.hasPrefix("prunable") { entry.missing = true }
            }
            return entry.path.isEmpty ? nil : entry
        }
    }

    // origin/HEAD 가 가리키는 기본 브랜치 (없으면 origin/main → main)
    private static func defaultBranch(_ repo: String) -> String? {
        if let head = text(["-C", repo, "symbolic-ref", "--short", "refs/remotes/origin/HEAD"]) { return head }
        for candidate in ["origin/main", "origin/master", "main", "master"]
        where CLI.run(git, ["-C", repo, "rev-parse", "--verify", "--quiet", candidate]) != nil {
            return candidate
        }
        return nil
    }

    private static func text(_ arguments: [String]) -> String? {
        CLI.run(git, arguments, timeout: 20).flatMap { String(data: $0, encoding: .utf8) }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
