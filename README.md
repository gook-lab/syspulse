# SysPulse

메뉴 막대에 CPU 사용률과 가용 메모리를 띄우는 macOS 앱입니다. 누르면 코어별 부하·메모리 구성, Claude·Codex 구독 사용량과 함께, 에이전트 세션별·앱별로 메모리·CPU 를 얼마나 쓰는지 보여 주고 바로 정리할 수 있습니다. Orca 로 에이전트를 여러 개 돌릴 때 하나 더 띄울 여유가 있는지 가늠하려고 만들었습니다.

## 설치 — 에이전트에게 링크로

Claude Code·Codex 에게 "https://github.com/gook-lab/syspulse/blob/main/INSTALL.md 보고 SysPulse 설치해줘"라고 하면 됩니다. 절차와 막히는 곳은 [INSTALL.md](INSTALL.md) 에 있습니다.

## 빌드 · 설치 — swiftc 단일 스크립트

Xcode 프로젝트 없이 `swiftc` 로 바로 `.app` 을 만듭니다 (macOS 14 이상, Xcode Command Line Tools 필요). 애플 실리콘·인텔 공용(universal) 바이너리로 묶습니다.

```bash
./build.sh                  # build/SysPulse.app
./build.sh install          # ~/Applications 로 복사 후 실행
ARCHS=arm64 ./build.sh      # 한 아키텍처만 (개발 중 빠른 빌드)

# 화면을 PNG 로 저장 (화면 녹화 권한 없이 UI 확인용)
build/SysPulse.app/Contents/MacOS/SysPulse --snapshot out.png [--tab agents|strays|apps] [--width 250] [--light]

# 에이전트 줄 클릭과 같은 이동을 한 번 해 보기 (pid = claude·codex 프로세스)
build/SysPulse.app/Contents/MacOS/SysPulse --jump <pid>

# 아이콘 다시 그리기
swift scripts/make-icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
```

Dock 아이콘 없이 메뉴 막대에만 상주합니다(`LSUIElement`). 2초마다 갱신하며 상주 비용은 CPU 0% 안팎, 메모리 80~100 MB 정도입니다. 직접 빌드한 앱은 다운로드 격리 속성이 없어 Gatekeeper 경고 없이 실행됩니다.

## 화면 구성 — 메뉴 막대 · 팝오버 · 고정 창

- 메뉴 막대: 두 줄(위 CPU %, 아래 가용 GB). 경고 중에는 주황, 메모리 압박이 「위험」이면 빨강으로 바뀝니다.
- 팝오버: CPU·메모리(가용 / 총량)·구독 사용량 아래에 탭 세 개(에이전트 · 세션 밖 · 앱)를 둡니다. 탭 오른쪽에서 메모리순·CPU순을 바꿉니다.
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

`claude`·`codex` 프로세스마다 한 줄씩, 그 세션이 띄운 프로세스까지 합쳐 메모리·CPU 를 보여 줍니다. 이름은 작업 폴더에서 정합니다(`sonix_docs · ml-3426` 처럼 worktree 이름까지). 에이전트 프로세스 자체가 최근 10분 동안 50 MB 넘게 늘거나 줄면 `▲320 MB/10분` 처럼 붙이고, 200 MB 넘게 늘면 주황으로 바꿉니다(2분 넘게 쌓여야 나옵니다).

1. 부모를 따라 올라가 닿는 에이전트가 주인입니다. MCP 서버, Bash 로 띄운 vite·vitest 가 여기에 들어갑니다.
2. 부모가 launchd 로 바뀐(백그라운드로 띄운) node·python 등은 작업 폴더가 세션 폴더 안이거나, 인자에 그 세션의 Claude 스크래치패드 경로(`/tmp/claude-<uid>/<프로젝트 슬러그>/`)가 있으면 그 세션의 「분리」 프로세스로 붙입니다.
3. 끝까지 주인을 못 찾은 것만 「세션 밖」 탭에 남깁니다. 끝난 세션이 남긴 dev 서버일 수도, 직접 띄운 서비스일 수도 있어서 「종료 → 확인」 두 번을 눌러야 끕니다.

Orca 의 터미널은 Orca 앱이 아니라 별도 데몬(`Orca Terminal Host`)에 붙어 있습니다. 그래서 Orca 앱을 꺼도 에이전트는 살아 있습니다.

## 세션 줄 클릭 — 창·탭으로 이동

줄을 누르면 그 세션이 도는 곳으로 갑니다. 누를 때 그 프로세스의 환경 변수에서 아래 키만 읽고, 나머지(토큰 등)는 읽는 즉시 버립니다.

| 띄운 곳 | 읽는 키 | 동작 |
|---|---|---|
| Orca | `ORCA_TERMINAL_HANDLE`, `ORCA_AGENT_PANE`, `ORCA_CLI_BIN_DIR` | `orca terminal switch` 로 그 탭을 앞으로 가져오고 Orca 를 띄웁니다. Orca 를 다시 켜서 핸들이 바뀌었으면 탭·패인 id 로 찾아 다시 시도합니다 |
| VS Code · Cursor · Windsurf · Zed | `__CFBundleIdentifier` | 작업 폴더를 열어 그 폴더의 창으로 갑니다 |
| Terminal · iTerm 등 그 밖 | `__CFBundleIdentifier` | 앱만 앞으로 옵니다. 탭 선택은 Apple 이벤트 권한이 필요해 넣지 않았습니다 |

## 구독 사용량 — claude-hud 스냅샷 · Codex 세션 로그

Orca 상태 줄처럼 5시간 세션 · 주간 한도를 `세션 ▬ 18% 2h 12m · 주간 ▬ 82% 3d 2h` 로 보여 줍니다. 토큰이나 비공개 API 를 쓰지 않고, 각 CLI 가 로컬에 남긴 값만 30초마다 읽습니다.

| 대상 | 출처 | 준비 |
|---|---|---|
| Claude | `~/.claude/plugins/claude-hud/usage-snapshot.json` — Claude Code 가 상태 줄에 넘기는 `rate_limits` 를 claude-hud 가 저장한 파일 | claude-hud 설정(`~/.claude/plugins/claude-hud/config.json`)에 `"display": { "externalUsageWritePath": "~/.claude/plugins/claude-hud/usage-snapshot.json" }`. 경로를 바꿨으면 `defaults write lab.gook.syspulse claudeUsagePath <경로>` |
| Codex | 세션 로그 `rollout-*.jsonl` 의 마지막 `rate_limits` (오늘·어제 폴더) | 없음. `~/.codex/sessions` 와 Orca 의 Codex 홈(`~/Library/Application Support/orca/codex-accounts/*/home/sessions`)을 함께 봅니다 |

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

## 노치 있는 맥 — 메뉴 막대 자리

메뉴 막대 오른쪽이 노치까지 차 있으면, macOS 는 새로 붙은 항목을 노치 뒤·왼쪽으로 밀어 그리지 않습니다. 실행 2초 뒤 어느 화면 메뉴 막대에서도 SysPulse 가 보이지 않으면 안내 창을 띄웁니다(외장 모니터 메뉴 막대에 보이면 띄우지 않습니다). 안내 창에서 바로 고정 창으로 열 수 있습니다.

- 시스템 설정 → 메뉴 막대 → 「메뉴 막대에 허용」에서 SysPulse 를 켜고, 안 쓰는 앱을 끕니다.
- 또는 ⌘ 를 누른 채 다른 아이콘을 메뉴 막대 밖으로 끌어냅니다.

보이게 되면 ⌘-드래그로 SysPulse 를 원하는 자리로 옮길 수 있습니다.
