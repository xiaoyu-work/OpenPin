#!/usr/bin/env bash
#
# Install OpenPin on a Humane Ai Pin.
#
# Run locally with platform-tools (`adb`) and the Pin connected via interposer.
# Required files in the same directory:
#   - primaryapp-debug.apk
#   - openpin-daemon.kexe
#   - pty_exec
#
# Usage:
#   cd installer
#   bash install.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PMS_SETTLE_SECS="${PMS_SETTLE_SECS:-2}"
PMS_WAIT_TIMEOUT_SECS="${PMS_WAIT_TIMEOUT_SECS:-60}"
PM_RETRIES="${PM_RETRIES:-5}"

log()  { printf '\n==> %s\n' "$*"; }
warn() { printf '!! %s\n' "$*" >&2; }

require() {
  command -v "$1" >/dev/null 2>&1 || {
    warn "'$1' not found in PATH. Install Android platform-tools first."
    exit 1
  }
}

require_file() {
  [ -f "$1" ] || {
    warn "Missing required file: $1"
    warn "Download the v1.0.x release assets into this directory."
    exit 1
  }
}

# Verify exactly one Pin is reachable over adb and print a one-line summary.
# Exits non-zero with an actionable message if the connection isn't usable.
verify_pin_connection() {
  local devices_raw count line serial state model manufacturer

  # Make sure the adb daemon is up (it auto-starts, but we want a clean state).
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
    warn "  ANDROID_SERIAL=<serial> bash install.sh"
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
      warn "  The Pin has no screen, so you usually can't tap 'Allow' — confirm"
      warn "  the device was provisioned for ADB before the Hub install."
      exit 1
      ;;
    offline)
      warn "Device '$serial' is offline. Try:"
      warn "  adb kill-server && adb start-server && adb devices"
      exit 1
      ;;
    "no"|"no permissions"*)
      warn "adb cannot open the USB device ('no permissions'). On Linux this"
      warn "usually means missing udev rules; on macOS try a different USB port."
      exit 1
      ;;
    *)
      warn "Device '$serial' is in unexpected state: '$state'"
      exit 1
      ;;
  esac

  # adb shell here uses the selected serial via ANDROID_SERIAL (if set) or
  # the single attached device.
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
      warn "Continuing anyway — set ANDROID_SERIAL to be safe if you have"
      warn "multiple devices attached."
      ;;
  esac
}

# Wait until PackageManagerService is registered and answering.
# On the Pin this can briefly disappear after a burst of `pm` calls.
wait_for_pm() {
  local i=0
  while ! adb shell 'pm path android' >/dev/null 2>&1; do
    i=$((i + 1))
    if [ "$i" -ge "$PMS_WAIT_TIMEOUT_SECS" ]; then
      warn "PackageManagerService never came back after ${PMS_WAIT_TIMEOUT_SECS}s"
      return 1
    fi
    sleep 1
  done
}

# Run an adb command, retrying on transient PMS failures
# ("Broken pipe", "Can't find service: package", etc.). Between retries we
# pause and wait for PMS to be healthy again.
retry_pm() {
  local n=0
  local out rc
  while :; do
    if out="$("$@" 2>&1)"; then
      [ -n "$out" ] && printf '%s\n' "$out"
      return 0
    fi
    rc=$?
    n=$((n + 1))
    printf '%s\n' "$out" >&2
    if [ "$n" -ge "$PM_RETRIES" ]; then
      warn "Command failed after $n attempts: $*"
      return "$rc"
    fi
    warn "Transient pm failure (attempt $n/$PM_RETRIES); waiting for package service..."
    sleep "$PMS_SETTLE_SECS"
    wait_for_pm || true
  done
}

require adb

require_file primaryapp-debug.apk
require_file openpin-daemon.kexe
require_file pty_exec

log "Verifying Pin connection"
verify_pin_connection

log "Stopping any running openpin-daemon"
adb shell 'pkill -f openpin-daemon || true'

log "Waiting for PackageManagerService"
wait_for_pm

log "Disabling Humane apps"
# Small sleep between calls keeps PMS from being overloaded on the Pin's
# limited hardware (this is what causes the original Broken pipe failures).
for pkg in \
    hu.ma.ne.ironman \
    humane.experience.onboarding \
    humane.ota \
    hu.ma.ne.bort.ota
do
  retry_pm adb shell pm disable-user --user 0 "$pkg"
  sleep "$PMS_SETTLE_SECS"
done

log "Installing primary app"
wait_for_pm
retry_pm adb install -r -t primaryapp-debug.apk

log "Granting runtime permissions"
retry_pm adb shell appops set org.openpin.primaryapp MANAGE_EXTERNAL_STORAGE allow
retry_pm adb shell pm grant org.openpin.primaryapp android.permission.CAMERA
retry_pm adb shell pm grant org.openpin.primaryapp android.permission.RECORD_AUDIO

log "Pushing daemon binaries"
adb push openpin-daemon.kexe /data/local/tmp/openpin-daemon
adb push pty_exec /data/local/tmp/pty_exec
adb shell chmod +x /data/local/tmp/openpin-daemon /data/local/tmp/pty_exec

log "Launching daemon"
# Background on the *device*, fully detached, so the adb session can exit
# cleanly without taking the daemon with it.
adb shell 'nohup /data/local/tmp/openpin-daemon >/dev/null 2>&1 </dev/null &'

log "Done. OpenPin is installed and running."
