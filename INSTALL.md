# SysPulse 설치 가이드 — 에이전트에게 링크로 맡기기

Claude Code·Codex 같은 에이전트에게 이 문서 링크를 주고 아래처럼 말하면 설치까지 끝납니다.

> https://github.com/gook-lab/syspulse/blob/main/INSTALL.md 보고 SysPulse 설치해줘

에이전트가 소스를 받아 이 맥에서 직접 빌드한 뒤 `~/Applications` 에 넣고 실행합니다. 직접 빌드한 앱이라 Gatekeeper 경고가 뜨지 않고, 관리자 권한도 필요 없습니다. 빌드는 15초 안팎, 전체는 1분 정도 걸립니다. 새 버전이 올라오면 팝오버 머리 줄의 「업데이트 N」과 알림으로 알려 주고, 누르면 다시 빌드해 설치합니다. 에이전트에게 "SysPulse 업데이트해줘"라고 해도 됩니다. v1.11 이전 버전에는 업데이트 기능이 없으니 이 문서 링크로 한 번 다시 설치해 주세요. 버전별 변경 내용은 [CHANGELOG.md](CHANGELOG.md) 에 있습니다.

## 설치 뒤 사람이 할 일 — 메뉴 막대 확인 · 로그인 시 실행

- 메뉴 막대 오른쪽에 두 줄 숫자(위 CPU %, 아래 가용 GB)가 보이는지 확인해 주세요. 노치 때문에 가려지면 앱이 안내 창을 띄우고, 거기서 「고정 창으로 보기」로 바로 쓸 수 있습니다.
- 맥을 켤 때마다 띄우려면 팝오버 아래 「로그인 시 실행」을 켜 주세요.

## 에이전트 설치 절차 — 순서대로 실행

이 절은 에이전트가 읽고 실행하는 지시문입니다.

지킬 것:

- `sudo` 를 쓰지 않는다. 시스템 설정이나 다른 앱 설정은 사용자에게 묻기 전에 바꾸지 않는다.
- 토큰·자격 증명 파일(`auth.json`, `.credentials*`, 키체인 등)을 읽거나 출력하지 않는다.
- 단계가 실패하면 거기서 멈추고, 명령과 출력을 그대로 사용자에게 보여 준다. 우회 설치를 시도하지 않는다.

### 1. 사전 확인 — macOS 14 이상 · Command Line Tools

```bash
sw_vers -productVersion   # 14.0 이상
xcode-select -p           # 경로가 나와야 한다
swiftc --version
```

- macOS 가 14 미만이면 중단하고 사용자에게 알린다.
- `xcode-select -p` 가 실패하면 `xcode-select --install` 을 실행한다. 설치 창이 뜨므로 사용자에게 「설치」를 눌러 달라고 하고, 끝났다고 하면 위 확인을 다시 한다.

### 2. 소스 받기 — 이미 있으면 갱신

```bash
DIR="${SYSPULSE_DIR:-$HOME/Developer/syspulse}"
if [ -d "$DIR/.git" ]; then
  git -C "$DIR" pull --ff-only
elif command -v gh >/dev/null; then
  gh repo clone gook-lab/syspulse "$DIR"
else
  git clone https://github.com/gook-lab/syspulse.git "$DIR"
fi
```

- `Repository not found`·404 가 나오면 이 레포에 접근 권한이 없는 것이다. 사용자에게 알리고 중단한다.
- `pull --ff-only` 가 실패하면(로컬 수정이 있음) 덮어쓰지 말고 사용자에게 알린다.

### 3. 빌드 · 설치 — 이 맥 아키텍처만

```bash
cd "$DIR" && ARCHS="$(uname -m)" ./build.sh install
```

- 마지막 줄이 `installed ~/Applications/SysPulse.app` 이면 성공이다. 앱은 바로 실행된다.
- 이미 실행 중인 SysPulse 는 스크립트가 끄고 새 빌드로 바꾼다.

### 4. 동작 확인 — 프로세스 · 화면 스냅샷

```bash
pgrep -lf "Applications/SysPulse.app"
~/Applications/SysPulse.app/Contents/MacOS/SysPulse --snapshot "${TMPDIR:-/tmp}/syspulse-check.png"
```

- 프로세스가 하나 보여야 한다.
- 스냅샷 명령은 화면을 PNG 로 저장하고 경로를 출력한다(화면 녹화 권한 불필요). 이미지를 볼 수 있으면 CPU·메모리·에이전트 목록이 그려졌는지 확인한다.
- 사용자에게 메뉴 막대 아이콘이 보이는지 물어본다.

### 5. 구독 사용량 출처 — Orca 또는 claude-hud

- Orca 가 설치돼 있으면(`ls -d /Applications/Orca*.app`) 할 일이 없다. Orca 에 로그인된 에이전트(Claude·Codex·Cursor 등)가 자동으로 보인다.
- Orca 가 없고 Claude Code 에 claude-hud 플러그인을 쓰면, `~/.claude/plugins/claude-hud/config.json` 에 아래 설정이 있어야 Claude 사용량이 보인다. 없으면 **사용자에게 추가해도 되는지 먼저 묻고**, 허락하면 기존 `display` 객체에 키 하나만 더한다(다른 키는 건드리지 않는다).

  ```json
  "display": { "externalUsageWritePath": "~/.claude/plugins/claude-hud/usage-snapshot.json" }
  ```

  설정 뒤 Claude Code 상태 줄이 한 번 그려지면 파일이 생긴다.
- Codex 는 할 일이 없다(`~/.codex/sessions` 로그를 읽는다).

### 6. 결과 보고

설치 경로, 소스 버전(`git -C "$DIR" log --oneline -1`), 4단계 확인 결과, 「설치 뒤 사람이 할 일」 두 가지를 짧게 알린다.

## 삭제 — 앱 · 설정

```bash
pkill -x SysPulse
rm -rf ~/Applications/SysPulse.app
defaults delete lab.gook.syspulse
```

「로그인 시 실행」을 켰다면 지우기 전에 끄거나, 지운 뒤 시스템 설정 → 일반 → 로그인 항목에서 빼 주세요. 소스 폴더(`~/Developer/syspulse`)는 따로 지우면 됩니다.

## 자주 막히는 곳 — 증상별 원인 · 해결

| 증상 | 원인 | 해결 |
|---|---|---|
| 메뉴 막대에 아이콘이 없음 | 메뉴 막대가 노치까지 차서 새 아이콘이 가려짐 | 안내 창의 「고정 창으로 보기」, 또는 ⌘ 를 누른 채 안 쓰는 아이콘을 메뉴 막대 밖으로 끌어내기 |
| `xcrun: error: invalid active developer path` | Command Line Tools 없음 | 1단계의 `xcode-select --install` |
| 구독 사용량 칸이 비어 있음 | Orca 없음, claude-hud 설정 없음 | 5단계 |
| 경고 알림이 「스크립트 편집기」 이름으로 옴 | ad-hoc 서명 빌드는 알림 센터 권한이 거절되어 `osascript` 로 대신 띄움 | 정상 동작. 아예 안 오면 시스템 설정 → 알림 → 스크립트 편집기 켜기 |
| Terminal·iTerm 세션 줄을 눌러도 탭이 안 바뀜 | 「자동화」 권한 거절 | 시스템 설정 → 개인정보 보호 및 보안 → 자동화 → SysPulse 에서 Terminal·iTerm 켜기 |
| 업데이트를 눌렀는데 그대로임 | 소스 폴더에 로컬 수정이 있어 `git pull --ff-only` 실패 | 머리 줄 아래 빨간 실패 이유와 `~/Library/Logs/SysPulse-update.log` 확인 |
| 「업데이트 실패 (종료 코드 0)」 | 설치는 끝났는데 옛 앱이 안 꺼짐 (v1.14 이전 `build.sh`) | 「업데이트」를 한 번 더 누르면 고친 `build.sh` 로 다시 켜짐. 또는 `pkill -x SysPulse; open ~/Applications/SysPulse.app` |
