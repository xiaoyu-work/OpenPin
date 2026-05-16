# Install OpenPin

Installs OpenPin on the Pin for the first time. Disables the stock Humane
apps, installs the OpenPin primary app, grants required runtime
permissions, pushes the daemon binaries, and starts the daemon.

If a step fails with `Broken pipe` or `Can't find service: package`, the
script automatically waits for Android's `PackageManagerService` to recover
and retries (up to `PM_RETRIES`, default 5). In rare cases you may still
need to reboot the Pin (`adb reboot`) and re-run the script.
