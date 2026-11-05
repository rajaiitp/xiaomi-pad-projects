# Xiaomi Pad projects

Source projects for a rooted Xiaomi Pad 6 (`pipa`) running LineageOS.

| Directory | Projects |
| --- | --- |
| `android/` | HDMI and Caffeinate tiles, TV touch controller, Reading Mode, charging policy, idle saver, Termux startup and installers |
| `display/` | HDMI/internal-panel backlight coordinator |
| `host/` | Zsh `tablet` command |
| `books/` | Tolstoy/Orwell and philosophy-of-love collection tools |
| `kernel/` | Pinned kernel upstreams and the local UFS patch |

Signing keys, SSH credentials, downloaded books, runtime state and build outputs are not versioned.

## Host setup

Clone to `~/xiaomi-pad-projects`, or set `XIAOMI_PROJECTS_ROOT` to another checkout. Load the host command in Zsh:

```zsh
source "${XIAOMI_PROJECTS_ROOT:-$HOME/xiaomi-pad-projects}/host/tablet.zsh"
```

Configure your own SSH alias. The `tablet` command defaults to `xiaomi`; ebook transfer and Reading Mode installation default to `xiaomi-tail`. Set `XIAOMI_SSH_HOST` for the host command and ebook transfer, or pass `--ssh` to the Reading Mode installer. Keep SSH keys and device addresses outside this repository.

Android builds require JDK 21, Android platforms 36 and 37.0, build-tools 36.0.0, and platform-tools. Export `JAVA_HOME` and `ANDROID_HOME`, and put `$ANDROID_HOME/platform-tools` on `PATH`.

```sh
./android/build-hdmi-control-tile.sh
./android/build-tv-touch-controller.sh
./android/build-reading-mode.sh
```

Signing configuration stays in `~/.android/*.properties` and adjacent keystores. Preserve existing keys to update installed apps. `HDMI_TILE_SIGNING_PROPERTIES` and `TV_TOUCH_SIGNING_PROPERTIES` can select separate build/test signing configurations. Builds do not install apps.

See [Android setup](android/README.md) before deploying. Installers use authorized ADB and root access; review them before use. Reading Mode disables radios: test activation and restoration with USB available, not over the sole remote connection.

## Checks

Install shfmt, ShellCheck, Ruff, Android command-line lint, and Google Java Format 1.28.0. Set `JAVA_FORMAT_JAR` to its executable JAR. Tool paths can be supplied with `SHFMT`, `SHELLCHECK`, and `RUFF`.

```sh
./check.sh
```

Checks lint sources, test the Reading Mode controller and EPUB utilities, and build/validate Reading Mode. The other APK builds can be run separately as above. No check installs software or changes tablet settings.

## Ebook tools

```sh
python3 -m venv ~/.cache/book-collections/philosophy-of-love/.venv
~/.cache/book-collections/philosophy-of-love/.venv/bin/pip install -r books/requirements.txt
python3 books/classics/download-xiaomi-classics.py
~/.cache/book-collections/philosophy-of-love/.venv/bin/python books/philosophy-of-love/download_books.py
```

Data defaults to `~/.cache/book-collections`; override the base with `XIAOMI_BOOKS_CACHE`. The philosophy collection uses its frozen 50-title Goodreads snapshot, includes six authorized English editions, and provides purchase/library-search links for the rest. The download command assembles Russell's 21 chapters, normalizes EPUB packaging without rewriting prose, and builds the catalog. `parse_shelf.py` is a separate research tool for saved shelf HTML, not an automatic expansion of the rights-checked snapshot.

Transfer is a separate, explicit action:

```sh
python3 books/philosophy-of-love/transfer_collection.py
python3 books/classics/verify-xiaomi-classics.py --serial YOUR_ADB_SERIAL
```

The philosophy transfer refuses to overwrite an existing destination. Classics verification expects those books to have already been copied to `/sdcard/Books`. Source permissions are edition-specific and were selected for US use; recheck them before use in another jurisdiction or redistribution. Rilke's selected translation permits noncommercial use, not unrestricted reuse.

## Kernel patch

`kernel/upstreams.json` records both upstream URLs and exact revisions. The UFS patch is for the recorded MagicTime revision; existing kernel checkouts are managed separately.

```sh
git -C /path/to/magictime apply --check "$PWD/kernel/patches/pipa-ufs.patch"
git -C /path/to/magictime apply "$PWD/kernel/patches/pipa-ufs.patch"
```

The upstream kernel's GPL-2.0 licensing applies to the kernel patch. This repository does not build or flash a kernel automatically.
