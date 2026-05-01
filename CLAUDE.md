# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This repo is a single Bash script (`array30-setup.sh`) that installs the native `fcitx5-array` input method engine (行列30) on Steam Deck (SteamOS), Ubuntu Desktop, or CachyOS/Arch Linux. The central problem it solves is ABI incompatibility: `fcitx5-array` is AUR-only, so it must either be compiled inside an Arch Linux container pinned to the host's `fcitx5` and `fmt` versions (SteamOS/Ubuntu), or built natively via `makepkg` on Arch-based systems where the host already has matching ABI.

## Usage

```bash
./array30-setup.sh install        # compile + install (detects platform automatically)
./array30-setup.sh update-table   # update array30 character tables from gontera/array30
./array30-setup.sh diagnose       # inspect install state, ABI, profile, addon loading
./array30-setup.sh uninstall      # remove fcitx5-array, fall back to table-based
./array30-setup.sh backup         # manually back up array.db + array.so
./array30-setup.sh restore        # restore from a previous backup
```

No build step, no tests, no dependencies beyond Bash + Python 3. SteamOS/Ubuntu also need Podman/Docker; Arch-based systems need only `base-devel` and `git`.

## Architecture

All logic lives in `array30-setup.sh` (~1866 lines). Key sections in order:

1. **Constants** — AUR/GitHub upstream URLs, host paths (`ARRAY_SO`, `ARRAY_DB`, `FCITX5_PROFILE`).
2. **`detect_os` / `detect_container_runtime` / `detect_fcitx5_type`** — run at script start; results stored in `OS_TYPE`, `CONTAINER_RUNTIME`, and `FCITX5_INSTALL_TYPE` ("native"/"flatpak"/"none"). `ARRAY_SO` and `ASSOC_SO` are set based on `OS_TYPE` first, then overridden if `FCITX5_INSTALL_TYPE == "flatpak"` to point into `~/.var/app/org.fcitx.Fcitx5/data/fcitx5/lib/`.
3. **`pkg_*` helpers** — abstract over `pacman` (SteamOS) vs `dpkg` (Ubuntu/Debian) for version queries and install/remove.
4. **`strip_semver`** — trims Ubuntu version suffixes like `+ds1-2build3` before matching against Arch Archive filenames.
5. **`check_*` functions** — run early in `do_install`: platform, container runtime, Chinese locale (Ubuntu only), fcitx5 presence, read-only filesystem (SteamOS only).
6. **`get_host_versions`** — detects `HOST_FCITX5_VER` / `HOST_FMT_VER`. Flatpak mode reads the Fcitx5 app metadata and scans the KDE Platform runtime files to avoid launching the sandbox.
7. **`find_arch_pkg_version`** — probes `archive.archlinux.org` for a matching `fcitx5`/`fmt` package. Tries release suffixes `-1` through `-4`.
8. **`resolve_latest_array30_sources`** — calls the GitHub API to discover the latest versioned `v2026-*` CIN filename under `gontera/array30/OpenVanilla/`, then emits shell variable assignments consumed by `do_update_table`. Contains an inline Python 3 heredoc for JSON parsing.
9. **`do_install`** — main install flow: checks → resolve Arch version → spin up container → downgrade container deps → compile via `makepkg` → ABI verify → install (`pacman -U` on SteamOS; manual file copy on Ubuntu/Flatpak) → configure profile → verify addon loads.
10. **`ubuntu_install_files`** — unpacks the `.pkg.tar.zst` inside the container, copies `array.so`, `array.db`, `addon/array.conf`, `inputmethod/array.conf`, and `libassociation.so` to the host. Creates a `libarray.so` symlink because fcitx5's addon loader prepends `lib` to the `Library=` name.
11. **`do_update_table`** — downloads new CIN files into a temp dir, runs `fcitx5-array-tools` inside the container to rebuild `array.db`, then replaces the host `array.db`.
12. **`do_diagnose`** — checks package state, file presence, `nm`-based ABI symbol inspection, array.db size, profile entry, and live `FCITX_LOG=default=5 fcitx5 -rd` output.
13. **`setup_autostart`** — writes `~/.config/autostart/org.fcitx.Fcitx5.desktop` so fcitx5 starts with the desktop session. Also writes `~/.local/bin/fcitx5-start-array.sh` to handle `GTK_IM_MODULE`/`QT_IM_MODULE`/`DefaultIM` env vars.

## Platform differences to keep in mind

| Concern | SteamOS (native) | Ubuntu/Debian | Flatpak (SteamOS) | CachyOS/Arch |
|---------|---------|---------------|-------------------|--------------|
| `.so` path | `/usr/lib/fcitx5/` | `/usr/lib/x86_64-linux-gnu/fcitx5/` | `~/.var/app/org.fcitx.Fcitx5/data/fcitx5/lib/` | `/usr/lib/fcitx5/` |
| Install method | `pacman -U *.pkg.tar.zst` | manual file copy from container | manual file copy, no sudo needed | `pacman -U` (local build, no container) |
| Build method | container (downgraded) | container (downgraded) | container (downgraded) | native `makepkg` on host |
| Version source | `pacman -Q` | `dpkg -l` (raw ver needs `strip_semver`) | `flatpak info` + runtime lib scan | `pacman -Q` (strip CachyOS dist suffix `x.y-N.M` → `x.y-N`) |
| `libarray.so` symlink | not needed | required (addon loader adds `lib` prefix) | not needed (loader uses exact name) | not needed |
| Read-only filesystem | needs `steamos-readonly disable` | n/a | n/a | n/a |
| Chewing support | n/a | `XMODIFIERS=@im=fcitx` in wrapper | n/a | `pacman -S fcitx5-chewing` |
| Detected by | `OS_TYPE=steamos` + `FCITX5_INSTALL_TYPE=native` | `OS_TYPE=ubuntu\|debian` | `FCITX5_INSTALL_TYPE=flatpak` (overrides OS paths) | `OS_TYPE=arch` (via `ID_LIKE=arch`) |

When adding new platform-specific logic, branch on `FCITX5_INSTALL_TYPE` first (to catch Flatpak regardless of OS), then on `OS_TYPE`.
