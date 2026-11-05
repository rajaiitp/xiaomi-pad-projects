# Android projects

- `tablet-playback.sh`: playback, display launches, task moves and panel policy; installed as a Termux dispatcher and `/data/adb/tablet-playback`.
- `apps/hdmi-control-tile`: Move HDMI and Caffeinate Quick Settings tiles.
- `apps/tv-touch-controller`: external-display preview and touch injection.
- `apps/reading-mode` and `reading-mode.sh`: standalone Reading Mode tile and durable root state controller.
- `charge-threshold.sh`: Magisk charging policy; pauses at 80%, resumes at 75%, and releases only its own pause.
- `pad6-idle-saver/`: inactivity-based Battery Saver and Doze service.
- `termux-boot/start-sshd`: key-only SSH startup with a Termux wake lock.
- `legacy-notification/`: event-driven compatibility notification and shortcuts.
- `../display/hdmi-panel-backlight.sh`: HDMI/backlight coordinator.

Run from the repository root with authorized ADB and the original APK signing keys available:

```sh
./android/set-hdmi-mirror-default.sh --serial YOUR_ADB_SERIAL
./android/install-tablet-stack.sh --serial YOUR_ADB_SERIAL --apps
```

`tablet sync --serial YOUR_ADB_SERIAL` invokes the same stack installer after loading `host/tablet.zsh`. Existing notification compatibility is preserved until explicitly retired:

```sh
./android/install-tablet-stack.sh --serial YOUR_ADB_SERIAL \
  --retire-notification --retire-hook
```

This removes the duplicate notification and obsolete HDMI LSPosed app, not LSPosed itself. Verify the replacement tile first.

Reading Mode is installed separately and left off:

```sh
./android/install-reading-mode.sh --serial YOUR_ADB_SERIAL --ssh YOUR_SSH_ALIAS
```

Approve its Magisk access and add its Quick Settings tile in the setup app. Do not activate the offline preset over the only remote connection; verify on/off restoration locally with USB available.
