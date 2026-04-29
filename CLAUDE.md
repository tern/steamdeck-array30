# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo is a single Bash script (`array30-setup.sh`) that installs the native `fcitx5-array` input method engine (行列30) on Steam Deck (SteamOS) or Ubuntu Desktop. The central problem it solves is ABI incompatibility: `fcitx5-array` is AUR-only, so it must be compiled inside an Arch Linux container that is pinned to the same `fcitx5` and `fmt` library versions as the host.

## Usage

```bash
./array30-setup.sh install        # compile + install (detects platform automatically)
./array30-setup.sh update-table   # update array30 character tables from gontera/array30
./array30-setup.sh diagnose       # inspect install state, ABI, profile, addon loading
./array30-setup.sh uninstall      # remove fcitx5-array, fall back to table-based
./array30-setup.sh backup         # manually back up array.db + array.so
./array30-setup.sh restore        # restore from a previous backup
```

No build step, no tests, no dependencies beyond Bash + Podman/Docker + Python 3.

## Architecture

All logic lives in `array30-setup.sh` (~1500 lines). Key sections in order:

1. **Constants** — AUR/GitHub upstream URLs, host paths (`ARRAY_SO`, `ARRAY_DB`, `FCITX5_PROFILE`).
2. **`detect_os` / `detect_container_runtime`** — run at script start; results stored in `OS_TYPE` and `CONTAINER_RUNTIME`. `ARRAY_SO` and `ASSOC_SO` are set here because Ubuntu and SteamOS use different lib paths (`x86_64-linux-gnu/fcitx5/` vs `fcitx5/`).
3. **`pkg_*` helpers** — abstract over `pacman` (SteamOS) vs `dpkg` (Ubuntu/Debian) for version queries and install/remove.
4. **`strip_semver`** — trims Ubuntu version suffixes like `+ds1-2build3` before matching against Arch Archive filenames.
5. **`find_arch_pkg_version`** — probes `archive.archlinux.org` for a matching `fcitx5`/`fmt` package. Tries release suffixes `-1` through `-4`.
6. **`resolve_latest_array30_sources`** — calls the GitHub API to discover the latest versioned `v2026-*` CIN filename under `gontera/array30/OpenVanilla/`, then emits shell variable assignments consumed by `do_update_table`.
7. **`do_install`** — main install flow: checks → resolve Arch version → spin up container → downgrade container deps → compile via `makepkg` → ABI verify → install (`pacman -U` on SteamOS; manual file copy on Ubuntu) → configure profile → verify addon loads.
8. **`ubuntu_install_files`** — unpacks the `.pkg.tar.zst` inside the container, copies `array.so`, `array.db`, `addon/array.conf`, `inputmethod/array.conf`, and `libassociation.so` to the host. Creates a `libarray.so` symlink because fcitx5's addon loader prepends `lib` to the `Library=` name.
9. **`do_update_table`** — downloads new CIN files into a temp dir, runs `fcitx5-array-tools` inside the container to rebuild `array.db`, then replaces `/usr/share/fcitx5/array/array.db` on the host.
10. **`do_diagnose`** — checks package state, file presence, `nm`-based ABI symbol inspection, array.db size, profile entry, and live `FCITX_LOG=default=5 fcitx5 -rd` output.
11. **`setup_autostart`** — writes `~/.config/autostart/org.fcitx.Fcitx5.desktop` so fcitx5 starts with the desktop session. Also writes `~/.local/bin/fcitx5-start-array.sh` to handle `GTK_IM_MODULE`/`QT_IM_MODULE`/`DefaultIM` env vars.

## Platform differences to keep in mind

| Concern | SteamOS | Ubuntu/Debian |
|---------|---------|---------------|
| `.so` path | `/usr/lib/fcitx5/` | `/usr/lib/x86_64-linux-gnu/fcitx5/` |
| Install method | `pacman -U *.pkg.tar.zst` | manual file copy from container |
| Version source | `pacman -Q` | `dpkg -l` (raw ver needs `strip_semver`) |
| `libarray.so` symlink | not needed | required (fcitx5 addon loader adds `lib` prefix) |
| Read-only filesystem | needs `steamos-readonly disable` | n/a |
| Chewing support | n/a | `XMODIFIERS=@im=fcitx` in wrapper |
