#!/bin/bash
# Sign the unsigned Mihomo-OHOS Debug HAP using $CERT_DIR, ./certs/debug/, or ../certs/debug/.
set -euo pipefail

MIHOMO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TS_ROOT="$(cd "$MIHOMO_ROOT/.." && pwd)"

if [[ -z "${CERT_DIR:-}" ]]; then
  if [[ -d "$MIHOMO_ROOT/certs/debug" ]]; then
    CERT_DIR="$MIHOMO_ROOT/certs/debug"
  elif [[ -d "$TS_ROOT/certs/debug" ]]; then
    CERT_DIR="$TS_ROOT/certs/debug"
  else
    CERT_DIR="$MIHOMO_ROOT/certs/debug"
  fi
fi

if [[ -f "$HOME/.harmony_env" ]]; then
  # shellcheck disable=SC1091
  source "$HOME/.harmony_env"
fi

OHOS_SDK_ROOT="${OHOS_SDK_ROOT:-$HOME/ohos-sdk-6.1.0.830/command-line-tools}"
SIGN_JAR="$OHOS_SDK_ROOT/sdk/default/openharmony/toolchains/lib/hap-sign-tool.jar"

[[ -f "$SIGN_JAR" ]] || { echo "FATAL: hap-sign-tool.jar not found at $SIGN_JAR" >&2; exit 1; }
[[ -f "$CERT_DIR/password.txt" ]] || { echo "FATAL: missing $CERT_DIR/password.txt" >&2; exit 1; }
[[ -f "$CERT_DIR/tailscale-debug.p12" ]] || { echo "FATAL: missing $CERT_DIR/tailscale-debug.p12" >&2; exit 1; }
[[ -f "$CERT_DIR/tailscale-debug.cer" ]] || { echo "FATAL: missing $CERT_DIR/tailscale-debug.cer" >&2; exit 1; }
[[ -f "$CERT_DIR/tailscale-debug-profileDebug.p7b" ]] || { echo "FATAL: missing $CERT_DIR/tailscale-debug-profileDebug.p7b" >&2; exit 1; }

OUT_DIR="$MIHOMO_ROOT/app/entry/build/default/outputs/default"
UNSIGNED="$OUT_DIR/entry-default-unsigned.hap"
SIGNED="$OUT_DIR/entry-default-signed.hap"
[[ -f "$UNSIGNED" ]] || { echo "FATAL: unsigned hap missing at $UNSIGNED" >&2; exit 1; }

PW="$(tr -d '\r\n' < "$CERT_DIR/password.txt")"

java -jar "$SIGN_JAR" sign-app \
  -mode localSign \
  -keyAlias "tailscale-debug" \
  -keyPwd "$PW" \
  -appCertFile "$CERT_DIR/tailscale-debug.cer" \
  -profileFile "$CERT_DIR/tailscale-debug-profileDebug.p7b" \
  -inFile "$UNSIGNED" \
  -signAlg "SHA256withECDSA" \
  -keystoreFile "$CERT_DIR/tailscale-debug.p12" \
  -keystorePwd "$PW" \
  -outFile "$SIGNED" \
  -compatibleVersion 23 \
  -signCode 1

ls -lh "$SIGNED"
