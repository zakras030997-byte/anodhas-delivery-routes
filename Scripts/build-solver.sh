#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$PROJECT_ROOT/Vendor"
SOURCE="$VENDOR/vroom"
COMMIT="43dd7d0b8b560431eb555bf335cf4797eb7343c4"
SDK="${FREIGHT_SDK:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
DEPLOYMENT="${FREIGHT_MIN_MACOS:-13.3}"
BUILD_ARCHS="${FREIGHT_SOLVER_ARCHS:-arm64 x86_64}"
JOBS="${FREIGHT_BUILD_JOBS:-2}"
mkdir -p "$VENDOR/bin" "$PROJECT_ROOT/Verification"
test -d "$SDK"
if [ ! -d "$SOURCE/.git" ]; then
  git clone --branch v1.15.0 --depth 1 https://github.com/VROOM-Project/vroom.git "$SOURCE"
  git -C "$SOURCE" submodule update --init --depth 1
fi
test "$(git -C "$SOURCE" rev-parse HEAD)" = "$COMMIT"
git -C "$SOURCE" diff --quiet
git -C "$SOURCE" submodule status > "$PROJECT_ROOT/Verification/solver-submodules.txt"
python3 - "$PROJECT_ROOT/Verification/solver-submodules.txt" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
if len(lines) != 3 or any(not line.startswith(' ') for line in lines):
    raise SystemExit('VROOM submodule state does not match pinned source')
PY
BINARIES=()
for ARCH in $BUILD_ARCHS; do
  case "$ARCH" in arm64|x86_64) ;; *) echo 'Unsupported architecture' >&2; exit 1;; esac
  BUILD="$VENDOR/builds/$ARCH-macos$DEPLOYMENT"
  mkdir -p "$BUILD"
  rsync -a --exclude '.git' --exclude '*.o' --exclude '*.d' --exclude bin --exclude lib "$SOURCE/" "$BUILD/"
  make -C "$BUILD/src" -j "$JOBS" USE_ROUTING=false \
    CXX="$(xcrun --find clang++) -arch $ARCH -isysroot $SDK -mmacosx-version-min=$DEPLOYMENT -include semaphore" \
    > "$PROJECT_ROOT/Verification/solver-build-$ARCH.log" 2>&1
  BINARIES+=("$BUILD/bin/vroom")
done
xcrun lipo -create "${BINARIES[@]}" -output "$VENDOR/bin/vroom"
codesign --force --sign - "$VENDOR/bin/vroom"
codesign --verify --strict "$VENDOR/bin/vroom"
xcrun lipo -archs "$VENDOR/bin/vroom"
otool -L "$VENDOR/bin/vroom" > "$PROJECT_ROOT/Verification/solver-linked-libraries.txt"
"$VENDOR/bin/vroom" --version
echo "$VENDOR/bin/vroom"
