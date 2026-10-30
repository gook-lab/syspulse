#!/usr/bin/env bash
# 사용법: ./build.sh            → build/SysPulse.app (애플 실리콘 + 인텔 공용)
#         ./build.sh install    → ~/Applications 로 복사 후 실행
#         ARCHS=arm64 ./build.sh → 한 아키텍처만 (개발 중 빠른 빌드)
set -euo pipefail
cd "$(dirname "$0")"

APP=build/SysPulse.app
ARCHS="${ARCHS:-arm64 x86_64}"
rm -rf "$APP" build/obj
mkdir -p "$APP/Contents/MacOS" build/obj

slices=()
for arch in $ARCHS; do
  swiftc -O -parse-as-library -swift-version 5 \
    -target "$arch-apple-macos14.0" \
    Sources/*.swift -o "build/obj/SysPulse-$arch"
  slices+=("build/obj/SysPulse-$arch")
done
lipo -create "${slices[@]}" -output "$APP/Contents/MacOS/SysPulse"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP" >/dev/null
echo "built $APP ($(lipo -archs "$APP/Contents/MacOS/SysPulse"))"

if [[ "${1:-}" == "install" ]]; then
  pkill -x SysPulse 2>/dev/null || true
  mkdir -p ~/Applications
  rm -rf ~/Applications/SysPulse.app
  cp -R "$APP" ~/Applications/
  open ~/Applications/SysPulse.app
  echo "installed ~/Applications/SysPulse.app"
fi
