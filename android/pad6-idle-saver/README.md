# Xiaomi Pad 6 idle saver

A Magisk service for the rooted Xiaomi Pad 6 (`pipa`). Every 10 seconds it checks Android's last user-activity timestamp. After **five minutes** of inactivity, it enables Android Battery Saver and forces deep Doze only when:

- AC, USB, and wireless charging are all off; and
- no active HDMI/DisplayPort external display is reported by Android; and
- no live SSH session and no authorized connected ADB host are reported.

An active external display, SSH session, or ADB connection counts as use. User interaction, charging, or any of those active connections immediately releases forced Doze; Battery Saver is disabled only if this service enabled it.

## Install/update

```bash
./android/pad6-idle-saver/install.sh YOUR_ADB_SERIAL
```

The service is placed in Magisk's `/data/adb/service.d`, starts immediately, and starts again after every boot.

## Inspect

```bash
adb -s YOUR_ADB_SERIAL shell su -c '/data/adb/service.d/99-pad6-idle-saver.sh --status'
adb -s YOUR_ADB_SERIAL shell su -c 'tail -n 50 /data/adb/pad6-idle-saver/service.log'
```

## Remove

```bash
./android/pad6-idle-saver/uninstall.sh YOUR_ADB_SERIAL
```

The removal script releases forced Doze and turns Battery Saver off only if this service had turned it on.
