# SysPulse

메뉴 막대에 CPU 사용률과 가용 메모리를 띄우는 macOS 앱입니다. 누르면 코어별 부하·메모리 구성, Claude·Codex 구독 사용량과 함께, 에이전트 세션별·앱별로 메모리·CPU 를 얼마나 쓰는지 보여 주고 바로 정리할 수 있습니다. Orca 로 에이전트를 여러 개 돌릴 때 하나 더 띄울 여유가 있는지 가늠하려고 만들었습니다.

## 설치 — 에이전트에게 링크로

Claude Code·Codex 에게 "https://github.com/gook-lab/syspulse/blob/main/INSTALL.md 보고 SysPulse 설치해줘"라고 하면 됩니다. 절차와 막히는 곳은 [INSTALL.md](INSTALL.md), 버전별 변경 내용은 [CHANGELOG.md](CHANGELOG.md) 에 있습니다.

## 빌드 · 설치 — swiftc 단일 스크립트

Xcode 프로젝트 없이 `swiftc` 로 바로 `.app` 을 만듭니다 (macOS 14 이상, Xcode Command Line Tools 필요). 애플 실리콘·인텔 공용(universal) 바이너리로 묶습니다.

```bash
./build.sh                  # build/SysPulse.app
./build.sh install          # ~/Applications 로 복사 후 실행
ARCHS=arm64 ./build.sh      # 한 아키텍처만 (개발 중 빠른 빌드)
build/SysPulse.app/Contents/MacOS/SysPulse --self-test  # 판정 규칙 확인 (build.sh 가 빌드마다 돌리고, 실패하면 멈춤)

# 화면을 PNG 로 저장 (화면 녹화 권한 없이 UI 확인용)
build/SysPulse.app/Contents/MacOS/SysPulse --snapshot out.png [--tab agents|strays|apps|worktrees|ports] [--width 250] [--light]
# 접은 단락(cpu · memory · usage · list), 여유 부족 경고(기준 GB), Orca 응답 없음 표시를 미리 보기
build/SysPulse.app/Contents/MacOS/SysPulse --snapshot out.png -collapsed.cpu YES -alertAvailableGB 40 --orca-failing

# 에이전트 줄 클릭과 같은 이동을 한 번 해 보기 (pid = claude·codex 프로세스)
build/SysPulse.app/Contents/MacOS/SysPulse --jump <pid>

# 스냅샷에 업데이트 배너 미리보기 · 워크트리 「목록 복사」 내용을 파일로
build/SysPulse.app/Contents/MacOS/SysPulse --snapshot out.png --tab worktrees --preview-update --copy-worktrees list.md

# 아이콘 다시 그리기
swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Dock 아이콘 없이 메뉴 막대에만 상주합니다(`LSUIElement`). 2초마다 갱신하며 상주 비용은 CPU 0% 안팎, 메모리 80~100 MB 정도입니다. 직접 빌드한 앱은 다운로드 격리 속성이 없어 Gatekeeper 경고 없이 실행됩니다.

## 화면 구성 — 메뉴 막대 · 팝오버 · 고정 창

- 메뉴 막대: 두 줄(위 CPU %, 아래 가용 GB). 경고 중에는 주황, 메모리 압박이 「위험」이면 빨강으로 바뀝니다.
- 팝오버: CPU·메모리(가용 / 총량)·구독 사용량 아래에 탭 다섯 개(에이전트 · 세션 밖 · 앱 · 워크트리 · 포트)를 둡니다. 앞의 세 탭은 오른쪽에서 메모리순·CPU순을 바꿉니다.
- 머리 줄 오른쪽에 버전·업데이트 상태가 늘 보입니다. 새 커밋이 있으면 「⬇ 업데이트 N」(누르면 설치), 없으면 「v1.14 ✓」(누르면 다시 확인), 확인에 실패하면 「v1.14 ⚠︎」와 이유를 보여 줍니다.
- CPU · 메모리 · 구독 사용량 단락은 제목 줄을 눌러 접고 펼칩니다. 접어도 제목 줄의 핵심 값(CPU %, 가용 GB, 맨 위 에이전트 사용률)과 소진 예상 경고는 남고, 단락마다 상태를 기억합니다.
- 목록도 탭 왼쪽 ›로 접습니다. 접힌 채 탭을 누르면 다시 펼칩니다.
- 팝오버가 화면보다 길어지면 화면 높이에서 멈추고 안쪽을 스크롤합니다.
- 고정 창: 팝오버 오른쪽 위 📌 로 항상 위에 뜨는 창으로 바꿉니다. 모든 Space 에 따라오고, 위치·고정 여부를 기억합니다. 폭에 맞춰 배치가 바뀝니다 — 좁으면(최소 240pt) 줄을 접고, 640pt 이상이면 왼쪽 시스템 · 오른쪽 목록 두 열이 됩니다.

## 수치 출처 — 활성 상태 보기 기준

| 항목 | 출처 | 계산 |
|---|---|---|
| CPU | `host_processor_info` 코어별 틱 | 2초 간격 틱 차이. 사용자 = user + nice |
| 사용 중 메모리 | `host_statistics64(HOST_VM_INFO64)` | 앱(internal − purgeable) + 와이어드 + 압축 |
| 가용 메모리 | 〃 | 총량 − 사용 중. 캐시된 파일은 바로 비워지므로 가용에 넣습니다 |
| 메모리 압박 | `kern.memorystatus_vm_pressure_level` | 1 정상 · 2 경고 · 4 위험 |
| 스왑 | `vm.swapusage`, `vm_statistics64.swapouts` | 사용 / 전체, 쓰기 속도(최근 3회 평균) |
| 프로세스 메모리 | `proc_pid_rusage` 의 `ri_phys_footprint` | 활성 상태 보기 「메모리」 열과 같은 값 |
| 프로세스 CPU | `proc_pid_rusage` 의 user + system 시간 | 2초 간격 차이 ÷ 경과 시간. 코어 하나를 다 쓰면 100% (활성 상태 보기와 같은 표기). 값은 mach 틱이라 timebase 로 ns 로 바꿉니다 |

## 에이전트 세션 묶음 — 부모 프로세스 · 작업 폴더

`claude`·`codex` 프로세스마다 한 줄씩, 그 세션이 띄운 프로세스까지 합쳐 메모리·CPU 를 보여 줍니다. 이름은 작업 폴더에서 정합니다(`my-app · feature-login` 처럼 worktree 이름까지). 에이전트 프로세스 자체가 최근 10분 동안 50 MB 넘게 늘거나 줄면 `▲320 MB/10분` 처럼 붙이고, 200 MB 넘게 늘면 주황으로 바꿉니다(2분 넘게 쌓여야 나옵니다).

1. 부모를 따라 올라가 닿는 에이전트가 주인입니다. MCP 서버, Bash 로 띄운 vite·vitest 가 여기에 들어갑니다.
2. 부모가 launchd 로 바뀐(백그라운드로 띄운) node·python 등은 작업 폴더가 세션 폴더 안이거나, 인자에 그 세션의 Claude 스크래치패드 경로(`/tmp/claude-<uid>/<프로젝트 슬러그>/`)가 있으면 그 세션의 「분리」 프로세스로 붙입니다.
3. 끝까지 주인을 못 찾은 것만 「세션 밖」 탭에 남깁니다. 끝난 세션이 남긴 dev 서버일 수도, 직접 띄운 서비스일 수도 있어서 「종료 → 확인」 두 번을 눌러야 끕니다.

Orca 의 터미널은 Orca 앱이 아니라 별도 데몬(`Orca Terminal Host`)에 붙어 있습니다. 그래서 Orca 앱을 꺼도 에이전트는 살아 있습니다.

## 입력 대기 표시 — Orca agentWait

에이전트를 여러 개 돌리면 승인·질문에 멈춘 세션을 늦게 알아채는 데서 시간이 가장 많이 샙니다. Orca 가 판정한 상태(`orca worktree ps --agent-wait --json`)를 읽어 세션 줄에 붙입니다. 에이전트 프로세스의 환경 변수 `ORCA_AGENT_PANE` 이 Orca 의 패인 키와 같아서 둘을 바로 잇습니다.

- 손 아이콘(주황): 사람만 답할 수 있는 프롬프트에 멈춤(`agentWait`). 「선택 대기 3분째」처럼 이유와 경과 시간을 붙이고, 목록 맨 위로 올립니다.
- 터미널(파랑): 작업 중 · 체크(초록): 턴을 마치고 다음 지시를 기다림 · 터미널(회색): Orca 밖 세션이라 상태를 모름
- 메뉴 막대 숫자 왼쪽에 대기 수 배지, 탭 이름에 「대기 N」을 띄웁니다. 줄을 누르면 그 탭으로 갑니다.
- 새로 대기에 들어간 세션마다 한 번 알림을 보냅니다(팝오버 아래 「대기 알림」으로 끄고 켭니다).
- Orca CLI 호출은 한 번에 CPU 0.2초 정도라 무작정 자주 부르지 않습니다. 에이전트가 대기에 들어가거나 턴을 마치면 CPU 가 떨어지고 다시 일하면 오르므로, Orca 세션의 바쁨(CPU 5% 이상)↔한가함(1% 미만)이 바뀌면 8초 안에 한 번, 그 밖에는 1분마다 부릅니다. 그 사이 값은 직전 판정을 유지해 깜빡임을 막습니다. Orca 세션이 없으면 부르지 않습니다.
- Orca 가 응답하지 않거나 출력 형식이 바뀌어 상태를 못 읽으면, 직전 값을 그대로 두고 에이전트 목록 위에 「Orca 응답 없음 — 입력 대기 표시·알림은 N분 전 값」을 주황으로 띄웁니다. 대기 알림이 조용히 꺼진 걸 모르고 기다리는 일을 막으려는 것입니다.
- Orca 를 못 찾으면 1분마다 다시 찾습니다(앱을 켠 뒤 Orca 를 설치하거나 옮겨도 다시 켤 필요 없음).

## worktree 정리 — 잃을 게 없는 것만 git worktree remove

에이전트마다 worktree 를 만들다 보면 node_modules 째로 수백 MB 씩 쌓입니다(2026-10-30 기준 41개, 11.4 GB). 「워크트리」 탭은 메인을 뺀 worktree 를 크기순으로 보여 줍니다.

- 저장소: 지금 도는 에이전트의 작업 폴더가 속한 저장소 + Orca 에 등록된 저장소 + 전에 본 저장소
- 줄마다 마지막 커밋 시점, 브랜치, 기본 브랜치에 들어갔는지, 변경 수, 원격에 없는 커밋 수, 그 안에서 도는 에이전트·dev 프로세스를 붙입니다. 남길 이유는 주황, 사용 중은 파랑입니다.
- 「정리」는 변경 0 · 원격에 없는 커밋 0 · 안에서 도는 프로세스 없음 · 잠기지 않음일 때만 나오고, 두 번 눌러야 실행합니다. 실행은 `git worktree remove`(--force 없음)라 판정이 틀려도 변경이 있으면 git 이 거절합니다. 브랜치와 커밋은 그대로 남고, git 이 무시하는 파일(node_modules · .env.local 등)은 폴더와 함께 지워집니다.
- 폴더가 이미 없는 worktree 는 `git worktree prune` 으로 기록만 지웁니다.
- 마지막 커밋이 24시간 안이면 「최근 작업」으로 보고 정리 대상에서 뺍니다.
- 크기(`du`)는 백그라운드에서 잽니다(41개에 30초 안팎). 켤 때와 30분마다, 탭을 열 때(2분 지났으면) 다시 봅니다.
- 「목록 복사」는 경로·브랜치·크기·변경·푸시 안 한 커밋·사용 중·정리 가능을 Markdown 표로 클립보드에 넣습니다. Claude 에 붙여 「정리해도 되는 걸 골라 줘」처럼 검토를 맡길 수 있습니다.

## 포트 지도 — LISTEN 소켓 · worktree · 브랜치

「포트」 탭은 지금 TCP 포트를 열고 있는 dev 서버를 보여 줍니다. worktree 마다 vite 를 띄우다 보면 5173 이 어느 브랜치의 서버인지 헷갈리는 일이 잦아서 만들었습니다.

- `lsof` 를 띄우지 않고 libproc(`PROC_PIDLISTFDS` → `PROC_PIDFDSOCKETINFO`)으로 앱 밖 프로세스의 LISTEN 소켓을 10초마다 읽습니다. 작업 폴더가 `/` 인 시스템·보안 데몬은 뺍니다.
- 줄마다 프로세스 이름, 띄운 에이전트 세션(없으면 「세션 밖」 주황), worktree 이름과 브랜치를 붙입니다(브랜치는 1분마다 다시 읽어 `git switch` 를 따라갑니다). 같은 포트를 둘 이상이 열고 있으면 포트 번호를 주황으로 표시합니다.
- 줄을 누르면 `http://localhost:<포트>` 를 엽니다.

## 업데이트 — 소스 폴더 git fetch

`build.sh` 가 빌드할 때 Info.plist 에 버전(`1.<커밋 수>`), 커밋, 소스 폴더를 적어 둡니다. 앱은 켠 뒤 20초, 그다음 30분마다, 그리고 팝오버를 열 때(마지막 확인이 10분 넘었으면) 그 폴더에서 `git fetch` 해 설치된 커밋 뒤로 새 커밋이 있는지 봅니다. 앱에 들어가는 파일(`Sources` · `Resources` · `Info.plist` · `build.sh`)이 바뀐 커밋만 세므로, 문서만 고친 커밋으로는 알리지 않습니다.

- 새 커밋이 있으면 머리 줄의 「업데이트 N」과 함께 그 아래 「업데이트가 있습니다 — 새 커밋 N개」 배너와 커밋 제목을 띄우고, 원격 커밋마다 한 번 알림을 보냅니다. 배너의 「변경 내용」은 [CHANGELOG.md](CHANGELOG.md) 를 엽니다.
- 「업데이트」를 누르면 그 폴더에서 `git pull --ff-only && ./build.sh install` 을 돌립니다. 스크립트가 `pkill -a` 로 지금 앱을 끄고 새 빌드를 띄웁니다(`-a` 가 없으면 macOS pkill 은 자기를 띄운 앱을 조상 프로세스라며 건너뜁니다). 그래도 앱이 살아 있으면 새 앱을 띄울 셸을 남기고 스스로 끝납니다. 실패하면 배너 자리에 이유가 빨갛게 남으며, 전체 기록은 `~/Library/Logs/SysPulse-update.log` 에 있습니다.
- 소스 폴더에 로컬 수정이 있어 fast-forward 가 안 되면 업데이트하지 않습니다.
- 소스 폴더를 지웠거나 옮겨 업데이트할 수 없으면 자동 확인 때도 머리 줄 아래에 빨갛게 「INSTALL.md 링크로 다시 설치하세요」를 남깁니다. 네트워크처럼 일시적인 실패는 직접 확인할 때만 보여 줍니다.
- `build.sh` 가 빌드 직후 `--self-test`(worktree 정리 판정, 사용량 페이스·소진 예상, Orca 응답 해석, 정리 후보)를 돌리고 실패하면 설치하지 않으므로, 깨진 판정이 업데이트로 깔리지 않습니다.

## 세션 줄 클릭 — 창·탭으로 이동

줄을 누르면 그 세션이 도는 곳으로 갑니다. 누를 때 그 프로세스의 환경 변수에서 아래 키만 읽고, 나머지(토큰 등)는 읽는 즉시 버립니다.

| 띄운 곳 | 읽는 키 | 동작 |
|---|---|---|
| Orca | `ORCA_TERMINAL_HANDLE`, `ORCA_AGENT_PANE`, `ORCA_CLI_BIN_DIR` | `orca terminal switch` 로 그 탭을 앞으로 가져오고 Orca 를 띄웁니다. Orca 를 다시 켜서 핸들이 바뀌었으면 탭·패인 id 로 찾아 다시 시도합니다 |
| VS Code · Cursor · Windsurf · Zed | `__CFBundleIdentifier` | 작업 폴더를 열어 그 폴더의 창으로 갑니다 |
| Terminal · iTerm | `__CFBundleIdentifier` + 프로세스의 tty | AppleScript 로 그 tty 의 탭을 고르고 앞으로 가져옵니다. 처음 한 번 「자동화」 권한을 묻고, 거절하면 앱만 앞으로 옵니다 |
| 그 밖 | `__CFBundleIdentifier` | 앱만 앞으로 옵니다 |

## 구독 사용량 — claude-hud 스냅샷 · Codex 세션 로그

Orca 상태 줄처럼 5시간 세션 · 주간 한도를 `세션 ▬ 18% 2h 12m · 주간 ▬ 82% 3d 2h` 로 보여 줍니다. 토큰이나 비공개 API 를 쓰지 않고, 각 CLI 가 로컬에 남긴 값만 1분마다 읽습니다.

| 대상 | 출처 | 준비 |
|---|---|---|
| Claude | `~/.claude/plugins/claude-hud/usage-snapshot.json` — Claude Code 가 상태 줄에 넘기는 `rate_limits` 를 claude-hud 가 저장한 파일 | claude-hud 설정(`~/.claude/plugins/claude-hud/config.json`)에 `"display": { "externalUsageWritePath": "~/.claude/plugins/claude-hud/usage-snapshot.json" }`. 경로를 바꿨으면 `defaults write lab.gook.syspulse claudeUsagePath <경로>` |
| Codex | 세션 로그 `rollout-*.jsonl` 의 마지막 `rate_limits` (오늘·어제 폴더) | 없음. `~/.codex/sessions` 와 Orca 의 Codex 홈(`~/Library/Application Support/orca/codex-accounts/*/home/sessions`)을 함께 봅니다 |

- 지금 속도면 초기화 전에 한도에 닿는 창이 있으면, 가장 이른 것을 「Claude 주간: 10/31(토) 오전 6시쯤 소진 예상 (초기화 11/2(월) 오후 2시)」처럼 아래에 적습니다. 사용률 ÷ 지난 시간을 그대로 이어 간 단순 투영입니다.
- 색은 claude-hud 의 페이스 기준을 따릅니다. 지금 속도를 초기화 시각까지 늘렸을 때 한도의 90% 이상이면 주황, 넘으면 빨강이고, 90% 이상 썼으면 늘 빨강입니다(10% 미만은 보지 않습니다).
- Claude 값은 Claude Code 상태 줄이 그려질 때만, Codex 값은 Codex 가 응답할 때만 바뀝니다. 15분 넘게 그대로면 「2시간 전 값」을 붙이거나(자리가 없으면 줄을 흐리게) 알립니다. 초기화 시각이 지난 창은 「초기화됨」으로 표시합니다.

## 앱 목록 — 묶음 규칙 · 종료

- `.app` 안의 실행 파일은 가장 바깥 앱으로 합칩니다(Chrome 헬퍼 수십 개 → `Google Chrome` 한 줄).
- 그 밖은 `argv[0]` 이름으로 묶고, `node`·`bun`·`python`·`npm` 은 패키지·스크립트 이름을 붙입니다(`node · vite`, `npm · server-memory`). `claude` 는 실행 파일이 버전 폴더라 경로 이름으로는 구분되지 않습니다.
- 줄 끝 ⓧ → 「종료」(⌘Q 와 같은 정상 종료) 또는 「강제 종료」. 앱이 아닌 묶음은 프로세스마다 SIGTERM/SIGKILL 을 보내며, 그 사이 PID 가 재사용됐으면 건너뜁니다.
- 에이전트를 품은 앱(조상에 그 앱 프로세스가 있는 경우)은 확인 단계에서 "에이전트 N개가 같이 끝납니다"라고 경고합니다.
- `claude`·`codex`, 셸(`zsh`·`login` 등), `/System`·`/usr` 의 시스템 프로세스, SysPulse 자신과 그 조상에는 ⓧ 를 두지 않습니다.
- 내 계정 프로세스만 읽힙니다. `WindowServer`·`kernel_task` 같은 시스템 프로세스는 권한 밖이라 빠집니다.

## 여유 부족 경고 — 가용 · 압박 · 스왑 쓰기

다음 중 하나면 팝오버 위에 배너를 띄우고 메뉴 막대 숫자 색을 바꿉니다. 경고가 새로 시작될 때 알림 센터로도 알립니다(15분에 한 번까지, 첫 알림 때 권한을 묻습니다).

- 가용 메모리가 기준(기본 4 GB, 팝오버 아래 −/+ 로 조절) 미만
- 메모리 압박 「경고」·「위험」
- 스왑 쓰기가 초당 20 MB 이상 — macOS 는 스왑 파일을 필요할 때마다 늘려서 사용 비율은 늘 높게 나오므로, 비율 대신 쓰기 속도로 봅니다

배너 아래에는 정리 후보를 붙입니다. 지금 일하지 않는 세션(Orca 가 「턴 마침」으로 본 것, Orca 밖이면 에이전트 프로세스 CPU 1% 미만)을 메모리 큰 순으로 셋, 「40분째 쉼」처럼 쉰 시간과 함께 보여 주고, 누르면 그 탭으로 갑니다. 입력 대기 세션은 사람 답을 기다리는 중이라 뺍니다. 세션 밖 프로세스가 200 MB 를 넘으면 합계도 한 줄 띄웁니다. 경고 알림에도 첫 후보를 적습니다.

## 노치 있는 맥 — 메뉴 막대 자리

메뉴 막대 오른쪽이 노치까지 차 있으면, macOS 는 새로 붙은 항목을 노치 뒤·왼쪽으로 밀어 그리지 않습니다. 실행 2초 뒤 어느 화면 메뉴 막대에서도 SysPulse 가 보이지 않으면 안내 창을 띄웁니다(외장 모니터 메뉴 막대에 보이면 띄우지 않습니다). 안내 창에서 바로 고정 창으로 열 수 있습니다.

- 시스템 설정 → 메뉴 막대 → 「메뉴 막대에 허용」에서 SysPulse 를 켜고, 안 쓰는 앱을 끕니다.
- 또는 ⌘ 를 누른 채 다른 아이콘을 메뉴 막대 밖으로 끌어냅니다.

보이게 되면 ⌘-드래그로 SysPulse 를 원하는 자리로 옮길 수 있습니다.
