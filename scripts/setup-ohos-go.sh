#!/bin/bash
# Download Go 1.27.3 source, apply patches/ohos-go-1.27.3.patch, and bootstrap
# the OpenHarmony Go cross-compiler into $HOME/.ohos-go-build/ohos-go-1.27.3.
set -euo pipefail

MIHOMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PATCH_FILE="$MIHOMO_ROOT/patches/ohos-go-1.27.3.patch"
BUILD_DIR="${OHOS_GO_BUILD_DIR:-$HOME/.ohos-go-build}"
GO_ROOT="${OHOS_GO_ROOT:-$BUILD_DIR/ohos-go-1.27.3}"
ARCHIVE="$BUILD_DIR/go1.27.3.src.tar.gz"
GO_SRC_URL="${GO_SRC_URL:-https://go.dev/dl/go1.27.3.src.tar.gz}"
EXPECTED_SHA256="6e7749035cf360f06b2575d162ea79df9fda8ef671889e5c375f8e50777f26bb"

[[ -f "$PATCH_FILE" ]] || {
  echo "FATAL: missing patch file at $PATCH_FILE" >&2
  exit 1
}

if [[ -x "$GO_ROOT/bin/go" && "${FORCE_REBUILD:-0}" != "1" ]]; then
  echo "==> OpenHarmony Go toolchain already installed at $GO_ROOT"
  "$GO_ROOT/bin/go" version
  echo "Set FORCE_REBUILD=1 to rebuild from source."
  exit 0
fi

compute_sha256() {
  local file="$1"
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print tolower($1)}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print tolower($1)}'
  else
    echo "FATAL: neither sha256sum nor shasum found" >&2
    exit 1
  fi
}

mkdir -p "$BUILD_DIR"

if [[ ! -f "$ARCHIVE" ]]; then
  echo "==> Downloading $GO_SRC_URL ..."
  curl -fL --retry 3 --output "$ARCHIVE.tmp" "$GO_SRC_URL"
  mv -f "$ARCHIVE.tmp" "$ARCHIVE"
fi

ACTUAL_SHA256="$(compute_sha256 "$ARCHIVE")"
if [[ "$ACTUAL_SHA256" != "$EXPECTED_SHA256" ]]; then
  echo "FATAL: SHA-256 mismatch for $ARCHIVE" >&2
  echo "  expected: $EXPECTED_SHA256" >&2
  echo "  actual:   $ACTUAL_SHA256" >&2
  exit 1
fi
echo "==> Verified go1.27.3.src.tar.gz SHA-256: $ACTUAL_SHA256"

if [[ -z "${GOROOT_BOOTSTRAP:-}" ]]; then
  if command -v go >/dev/null 2>&1; then
    GOROOT_BOOTSTRAP="$(go env GOROOT)"
  else
    echo "FATAL: host Go compiler (>= 1.24) is required in PATH or set GOROOT_BOOTSTRAP" >&2
    exit 1
  fi
fi
export GOROOT_BOOTSTRAP
echo "==> Using GOROOT_BOOTSTRAP=$GOROOT_BOOTSTRAP"

STAGE_DIR="$BUILD_DIR/.go-src-stage.$$"
rm -rf "$STAGE_DIR" "$GO_ROOT"
mkdir -p "$STAGE_DIR"
tar -C "$STAGE_DIR" -xzf "$ARCHIVE"
mv "$STAGE_DIR/go" "$GO_ROOT"
rmdir "$STAGE_DIR"

echo "==> Applying $PATCH_FILE ..."
git apply --directory="$GO_ROOT" -p1 "$PATCH_FILE"

echo "==> Building OpenHarmony Go 1.27.3 toolchain in $GO_ROOT/src ..."
(
  unset GOROOT GOENV GOFLAGS GOEXPERIMENT
  cd "$GO_ROOT/src"
  ./make.bash
)

echo "==> Toolchain ready: $GO_ROOT/bin/go"
"$GO_ROOT/bin/go" version
