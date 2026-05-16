# OpenPin installer scripts

This directory holds the installer scripts that are uploaded as assets to
each GitHub Release of OpenPin. They are the same scripts that the
[OpenPin.org](https://openpin.org) Hub executes through WebUSB/WebADB, but
you can also run them yourself with a local `adb`.

## Files

| File                  | Purpose                                                       |
| --------------------- | ------------------------------------------------------------- |
| `install.sh`          | First-time install (disable Humane apps, push app + daemon).  |
| `relaunch.sh`         | Restart the daemon after a Pin reboot.                        |
| `installer-info.json` | Manifest the Hub reads to discover the available actions.     |
| `install.md`          | Per-action description shown in the Hub.                      |
| `relaunch.md`         | Per-action description shown in the Hub.                      |

## Running locally

1. Install Android **platform-tools** so `adb` is on your `PATH`.
2. Download the release assets that go with the version you want to
   install, into this directory:
   - `primaryapp-debug.apk`
   - `openpin-daemon.kexe`
   - `pty_exec`

   Either via `gh`:

   ```sh
   gh release download v1.0.2 -R MaxMaeder/OpenPin \
       -p primaryapp-debug.apk -p openpin-daemon.kexe -p pty_exec \
       -D installer/
   ```

   …or with `curl`:

   ```sh
   for f in primaryapp-debug.apk openpin-daemon.kexe pty_exec; do
     curl -L -o "installer/$f" \
       "https://github.com/MaxMaeder/OpenPin/releases/download/v1.0.2/$f"
   done
   ```

3. Connect the Pin via the interposer and confirm `adb` sees it:

   ```sh
   adb devices
   ```

4. Run the script:

   ```sh
   cd installer
   bash install.sh
   ```

After a Pin reboot, run `bash relaunch.sh` instead — it just restarts the
daemon.

## Why these scripts have retry logic

The Pin's package manager (`system_server` / `PackageManagerService`) is
fragile under bursts of `pm` calls and can fail with either of:

- `Failure calling service package: Broken pipe (32)` — single call dropped
- `cmd: Can't find service: package` — PMS itself temporarily gone

Both are transient. `install.sh` wraps every `pm`/`appops` call in a
`retry_pm` helper that waits for PMS to come back (`pm path android`) and
retries up to `PM_RETRIES` times (default 5), with a `PMS_SETTLE_SECS`
(default 2s) pause between consecutive calls.

Tunable via env vars:

```sh
PMS_SETTLE_SECS=4 PM_RETRIES=10 bash install.sh
```

If `PackageManagerService` is wedged hard enough that even the wait loop
times out (60s by default, configurable via `PMS_WAIT_TIMEOUT_SECS`), reboot
the Pin and re-run:

```sh
adb reboot
adb wait-for-device
sleep 30   # let PMS finish scanning packages
bash install.sh
```

## Releasing

When cutting a new release, attach these five files plus the built
artifacts (`primaryapp-debug.apk`, `openpin-daemon.kexe`, `pty_exec`) to
the GitHub Release. The Hub picks them up automatically from the latest
release.
