#!/usr/bin/env bash
#
# Relaunch the OpenPin daemon on the Pin. Required after a reboot, since the
# daemon is not registered as a persistent Android service.
#
# Usage:
#   bash relaunch.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "'$1' not found in PATH. Install Android platform-tools first."
    exit 1
  }
}

# Verify exactly one Pin is reachable over adb and print a one-line summary.
# Exits non-zero with an actionable message if the connection isn't usable.
verify_pin_connection() {
  local devices_raw count line serial state model manufacturer

  adb start-server >/dev/null 2>&1 || true

  devices_raw="$(adb devices 2>/dev/null | tail -n +2 | sed '/^[[:space:]]*$/d')"

  if [ -z "$devices_raw" ]; then
    warn "No device detected by adb."
    warn "  - Confirm the Pin is seated on the interposer and connected via USB."
    warn "  - Try a different USB cable (must support data, not just charging)."
    warn "  - On macOS check 'system_profiler SPUSBDataType | grep -i humane'."
    warn "  - Then re-run: adb kill-server && adb start-server && adb devices"
    exit 1
  fi

  count="$(printf '%s\n' "$devices_raw" | wc -l | tr -d ' ')"
  if [ "$count" -gt 1 ] && [ -z "${ANDROID_SERIAL:-}" ]; then
    warn "Multiple adb devices attached:"
    printf '%s\n' "$devices_raw" >&2
    warn "Set ANDROID_SERIAL=<serial> to pick the Pin, e.g.:"
    warn "  ANDROID_SERIAL=<serial> bash relaunch.sh"
    exit 1
  fi

  if [ -n "${ANDROID_SERIAL:-}" ]; then
    line="$(printf '%s\n' "$devices_raw" | awk -v s="$ANDROID_SERIAL" '$1==s')"
    if [ -z "$line" ]; then
      warn "ANDROID_SERIAL='$ANDROID_SERIAL' not present in adb devices:"
      printf '%s\n' "$devices_raw" >&2
      exit 1
    fi
  else
    line="$(printf '%s\n' "$devices_raw" | head -n1)"
  fi

  serial="$(printf '%s' "$line" | awk '{print $1}')"
  state="$(printf '%s' "$line" | awk '{print $2}')"

  case "$state" in
    device) ;;
    unauthorized)
      warn "Device '$serial' is unauthorized."
      exit 1
      ;;
    offline)
      warn "Device '$serial' is offline. Try:"
      warn "  adb kill-server && adb start-server && adb devices"
      exit 1
      ;;
    *)
      warn "Device '$serial' is in unexpected state: '$state'"
      exit 1
      ;;
  esac

  model="$(adb shell getprop ro.product.model 2>/dev/null | tr -d '\r')"
  manufacturer="$(adb shell getprop ro.product.manufacturer 2>/dev/null | tr -d '\r')"

  if [ -z "$model" ]; then
    warn "Connected to '$serial' but 'getprop' returned nothing."
    warn "Device may not be fully booted yet. Wait ~30s and retry."
    exit 1
  fi

  printf '   serial=%s  model=%s  manufacturer=%s\n' \
      "$serial" "$model" "${manufacturer:-?}"

  case "$manufacturer" in
    Humane|humane|HUMANE) ;;
    *)
      warn "Manufacturer is '$manufacturer', not 'Humane'."
      warn "Continuing anyway — set ANDROID_SERIAL if you have multiple devices."
      ;;
  esac
}

require adb

log "Verifying Pin connection"
verify_pin_connection

log "Stopping any running openpin-daemon"
adb shell 'pkill -f openpin-daemon || true'

log "Launching daemon"
adb shell 'nohup /data/local/tmp/openpin-daemon >/dev/null 2>&1 </dev/null &'

log "Done."
