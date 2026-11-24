#!/bin/bash
# Build unified Mihomo + Patched Tailscale HarmonyOS Debug HAP (API 23, arm64-v8a).
set -euo pipefail

MIHOMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$MIHOMO_ROOT/app"
BRIDGE_DIR="$MIHOMO_ROOT/go_bridge"

if [[ -f "$HOME/.harmony_env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.harmony_env"
fi

OHOS_SDK_ROOT="${OHOS_SDK_ROOT:-$HOME/ohos-sdk-6.1.0.830/command-line-tools}"
DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$OHOS_SDK_ROOT/sdk}"
export OHOS_SDK_ROOT DEVECO_SDK_HOME
export OHOS_SDK_HOME="$DEVECO_SDK_HOME"
export PATH="$OHOS_SDK_ROOT/bin:$DEVECO_SDK_HOME/default/openharmony/toolchains:$PATH"

NATIVE_SDK="$DEVECO_SDK_HOME/default/openharmony/native"
CLANG="$NATIVE_SDK/llvm/bin/clang"
SYSROOT="$NATIVE_SDK/sysroot"
[[ -x "$CLANG" && -d "$SYSROOT" ]] || {
  echo "Missing OpenHarmony native SDK at $NATIVE_SDK" >&2
  exit 1
}

GO_ROOT="${OHOS_GO_ROOT:-$HOME/.ohos-go-build/ohos-go-1.27.3}"
[[ -x "$GO_ROOT/bin/go" ]] || {
  echo "Missing OpenHarmony Go 1.27.3 toolchain at $GO_ROOT/bin/go" >&2
  exit 1
}

OUT_SO="$APP_DIR/entry/src/main/cpp/prebuilt/arm64-v8a/libmihomo_ohos.so"
mkdir -p "$(dirname "$OUT_SO")"

echo "==> Building libmihomo_ohos.so (GOOS=openharmony GOARCH=arm64, with_gvisor + patched tailscale)..."
(
  export GOROOT="$GO_ROOT"
  export PATH="$GO_ROOT/bin:$PATH"
  export GOOS=openharmony
  export GOARCH=arm64
  export CGO_ENABLED=1
  export GOTOOLCHAIN=local
  export GOENV=off
  export GOWORK=off
  export GOFLAGS=
  export GOEXPERIMENT=
  export GOCACHE="${GOCACHE:-$HOME/.ohos-go-build/gocache-ohos-1.27.3}"
  export GOMODCACHE="${GOMODCACHE:-$HOME/.ohos-go-build/gomodcache}"
  export GOPATH="${GOPATH:-$HOME/.ohos-go-build/gopath}"
  export GOPROXY="${GOPROXY:-https://goproxy.cn,https://proxy.golang.org,direct}"
  export CC="$CLANG --target=aarch64-linux-ohos --sysroot=$SYSROOT -D__MUSL__ -fstack-protector-strong"

  cd "$BRIDGE_DIR"
  go build -p 2 -tags with_gvisor -buildmode=c-shared -trimpath -buildvcs=false \
    -ldflags="-checklinkname=0 -extldflags=-Wl,-soname,libmihomo_ohos.so,--build-id=sha1,-z,relro,-z,now,-z,noexecstack" \
    -o "$OUT_SO" .
)
ls -lh "$OUT_SO"

cd "$APP_DIR"
echo "==> Installing ohpm dependencies..."
ohpm install --all

echo "==> Building Debug HAP with hvigorw..."
export HVIGOR_USER_HOME="$MIHOMO_ROOT/.hvigor-user"
hvigorw --mode module -p module=entry@default -p product=default \
  -p buildMode=debug -p debuggable=true assembleHap --no-daemon

OUT_HAP="$APP_DIR/entry/build/default/outputs/default/entry-default-unsigned.hap"
echo "==> Unsigned HAP built: $OUT_HAP"
ls -lh "$OUT_HAP"
