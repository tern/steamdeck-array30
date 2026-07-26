#!/usr/bin/env bash
# ============================================================================
# array30-setup.sh — 行列30輸入法安裝工具 (fcitx5-array)
# https://github.com/tern/steamdeck-array30
#
# 支援平台:
#   - SteamOS (Steam Deck Desktop Mode)
#   - Ubuntu 24.04 / 22.04 Desktop
#   - Pop!_OS 24.04（Ubuntu noble 系，走 Ubuntu 安裝路徑）
#   - CachyOS / Arch Linux（本機編譯，無需容器）
#
# 透過容器（Podman 或 Docker）編譯 fcitx5-array（SteamOS/Ubuntu），
# 或直接在 Arch-based 系統上本機 makepkg 編譯，
# 自動匹配 host ABI（fcitx5 + fmt 版本），取代功能陽春的 table-based array30。
#
# 用法:
#   ./array30-setup.sh install             # 首次安裝（編譯 + 安裝）
#   ./array30-setup.sh update-table        # 線上更新行列30字根表
#   ./array30-setup.sh diagnose            # 診斷目前安裝狀態
#   ./array30-setup.sh migrate-from-table  # 移除 table 版行列，只留原生 array
#   ./array30-setup.sh uninstall           # 移除 fcitx5-array
#   ./array30-setup.sh backup              # 手動備份目前的 array.db
#   ./array30-setup.sh restore             # 從備份還原 array.db
#
# 授權: GPL-2.0-or-later
# ============================================================================

set -euo pipefail

# ── 常數 ────────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.5.1"
CONTAINER_NAME="array30-builder"
CONTAINER_IMAGE="docker.io/library/archlinux:latest"
ARCHIVE_BASE="https://archive.archlinux.org/packages"

# 上游來源
FCITX5_ARRAY_AUR="https://aur.archlinux.org/fcitx5-array.git"
FCITX5_ARRAY_GITHUB="https://github.com/ray2501/fcitx5-array"
FCITX5_ARRAY_VER="1.0.1"
FCITX5_ARRAY_SHA256="8e8eb20db2aa47011a187e18c90c02fbf0e6785bb0de7ac497f141173c154c34"

# SteamOS 版本支援矩陣（從 SteamOS repo DB 查出，Arch Archive 均已確認有對應套件）
# SteamOS 3.7: fcitx5 5.1.11-2, fmt 11.1.1-2  ← 最低支援版本
# SteamOS 3.8: fcitx5 5.1.14-1, fmt 11.2.0-1  ← 目前測試版本
# SteamOS 3.5/3.6: fcitx5 5.0.x/5.1.7（舊 API，未測試，不支援）
STEAMOS_MIN_SUPPORTED="3.7"
ARRAY30_CIN_REPO="https://github.com/gontera/array30"
ARRAY30_GITHUB_RAW_BASE="https://raw.githubusercontent.com/gontera/array30"
ARRAY30_GITHUB_API_BASE="https://api.github.com/repos/gontera/array30/contents"
ARRAY30_OPENVANILLA_DIR="OpenVanilla"
ARRAY30_PHRASE_DIR="array30_spec"

# Host 路徑（ARRAY_SO 在 OS 偵測後動態設定）
ARRAY_DB="/usr/share/fcitx5/array/array.db"
ARRAY_SO=""  # 由下方 detect_os 後設定
BACKUP_DIR="$HOME/.local/share/fcitx5-array-backup"
FCITX5_PROFILE="$HOME/.config/fcitx5/profile"
FCITX5_WRAPPER="$HOME/.local/bin/fcitx5-start-array.sh"
FCITX5_AUTOSTART="$HOME/.config/autostart/org.fcitx.Fcitx5.desktop"

# ── OS / 容器工具偵測（早期執行）──────────────────────────────────────────

detect_os() {
    if [[ -f /etc/os-release ]]; then
        local id
        id=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
        local id_like
        id_like=$(grep -oP '^ID_LIKE=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || true)
        case "$id" in
            steamos) echo "steamos" ;;
            # Pop!_OS is Ubuntu-based (noble etc.); use the ubuntu install path
            ubuntu|pop) echo "ubuntu" ;;
            debian)  echo "debian" ;;
            *)
                if echo "$id_like" | grep -q "ubuntu\|debian"; then
                    # Prefer ubuntu path for Ubuntu derivatives (e.g. some spins)
                    if echo "$id_like" | grep -q "ubuntu"; then
                        echo "ubuntu"
                    else
                        echo "debian"
                    fi
                elif echo "$id_like" | grep -q "arch"; then
                    echo "arch"
                else
                    echo "unknown"
                fi
                ;;
        esac
    else
        echo "unknown"
    fi
}

detect_container_runtime() {
    if command -v podman &>/dev/null; then
        echo "podman"
    elif command -v docker &>/dev/null; then
        echo "docker"
    else
        echo ""
    fi
}

detect_steamos_version() {
    grep -oP '^VERSION_ID=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || echo ""
}

OS_TYPE=$(detect_os)
CONTAINER_RUNTIME=$(detect_container_runtime)
STEAMOS_VERSION=$(detect_steamos_version)

# OS-dependent 路徑
case "$OS_TYPE" in
    ubuntu|debian)
        ARRAY_SO="/usr/lib/x86_64-linux-gnu/fcitx5/array.so"
        ASSOC_SO="/usr/lib/x86_64-linux-gnu/fcitx5/libassociation.so"
        ;;
    *)
        ARRAY_SO="/usr/lib/fcitx5/array.so"
        ASSOC_SO="/usr/lib/fcitx5/libassociation.so"
        ;;
esac

# Flatpak fcitx5 偵測（在 command -v 之前執行，因 Flatpak 不在 PATH）
detect_fcitx5_type() {
    if command -v fcitx5 &>/dev/null; then
        echo "native"
    elif flatpak list 2>/dev/null | awk -F'\t' '{print $2}' | grep -q "^org\.fcitx\.Fcitx5$"; then
        echo "flatpak"
    else
        echo "none"
    fi
}
FCITX5_INSTALL_TYPE=$(detect_fcitx5_type)

# Flatpak 模式：覆蓋 host 路徑（安裝到 user XDG 路徑，不需 sudo）
if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
    _FP_DATA="$HOME/.var/app/org.fcitx.Fcitx5/data"
    _FP_CFG="$HOME/.var/app/org.fcitx.Fcitx5/config"
    # Flatpak sandbox 的 XDG_DATA_HOME = _FP_DATA，addon loader 搜尋 $XDG_DATA_HOME/fcitx5/lib/
    # addonloader.cpp 搜尋 "{Library}.so" 即 array.so，不加 lib 前綴（與 Ubuntu 一致）
    ARRAY_SO="${_FP_DATA}/fcitx5/lib/array.so"
    ASSOC_SO="${_FP_DATA}/fcitx5/lib/libassociation.so"
    ARRAY_DB="$_FP_DATA/fcitx5/array/array.db"
    FCITX5_PROFILE="$_FP_CFG/fcitx5/profile"
    # Wrapper script 放在 Flatpak XDG_DATA_HOME 內，讓 sandbox 可存取；
    # 功能：在啟動 fcitx5-bin 前將 user addon lib 加入 FCITX_ADDON_DIRS
    _FP_WRAPPER="${_FP_DATA}/fcitx5/bin/fcitx5-array-wrapper.sh"
fi

# 顏色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ── 工具函式 ──────────────────────────────────────────────────────────────

info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*" >&2; }
step()  { echo -e "\n${CYAN}── $* ──${NC}"; }

confirm() {
    local prompt="${1:-Continue?}"
    read -rp "$(echo -e "${YELLOW}$prompt [y/N]${NC} ")" ans
    [[ "$ans" =~ ^[Yy]$ ]]
}

need_sudo() {
    if ! sudo -n true 2>/dev/null; then
        info "需要 sudo 權限來安裝套件到系統目錄"
    fi
}

# 若 SteamOS 版本低於最低支援版本，顯示警告並詢問是否繼續
warn_steamos_version() {
    [[ "$OS_TYPE" != "steamos" ]] && return 0
    [[ -z "$STEAMOS_VERSION" ]] && return 0
    local major minor
    major=$(echo "$STEAMOS_VERSION" | cut -d. -f1)
    minor=$(echo "$STEAMOS_VERSION" | cut -d. -f2)
    local min_major min_minor
    min_major=$(echo "$STEAMOS_MIN_SUPPORTED" | cut -d. -f1)
    min_minor=$(echo "$STEAMOS_MIN_SUPPORTED" | cut -d. -f2)
    if (( major < min_major )) || (( major == min_major && minor < min_minor )); then
        echo ""
        warn "你的 SteamOS 版本 ($STEAMOS_VERSION) 低於最低測試版本 ($STEAMOS_MIN_SUPPORTED)"
        warn "SteamOS 3.5/3.6 使用舊版 fcitx5 API，fcitx5-array 1.0.0 可能無法正常運作"
        warn "建議先更新 SteamOS 至 3.7 以上版本"
        if ! confirm "仍要繼續安裝？"; then
            exit 0
        fi
        echo ""
    fi
}

# ── 套件管理抽象層 ────────────────────────────────────────────────────────

# 取得 host 上指定套件的版本字串（跨 OS）
pkg_get_version() {
    local pkg="$1"
    case "$OS_TYPE" in
        steamos|arch)
            pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
            ;;
        ubuntu|debian)
            dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' | head -1 || true
            ;;
    esac
}

# Ubuntu: 從 dpkg 版本字串提取純 semver（去掉 Ubuntu/Debian 後綴）
# e.g. "9.1.0+ds1-2" → "9.1.0" / "5.1.7-1build3" → "5.1.7"
strip_semver() {
    echo "$1" | sed 's/+.*//' | sed 's/-[0-9]*build.*//' | sed 's/-[0-9]*$//'
}

# 檢查遠端 URL 是否存在（支援 curl 或 wget）
url_exists() {
    local url="$1"
    if command -v curl &>/dev/null; then
        curl -fsI "$url" &>/dev/null
    elif command -v wget &>/dev/null; then
        wget -q --spider "$url" 2>/dev/null
    else
        err "需要 curl 或 wget"
        exit 1
    fi
}

resolve_latest_array30_sources() {
    local ref="${1:-master}"
    local ov_url="${ARRAY30_GITHUB_API_BASE}/${ARRAY30_OPENVANILLA_DIR}?ref=${ref}"
    local phrase_api_url="${ARRAY30_GITHUB_API_BASE}/${ARRAY30_PHRASE_DIR}?ref=${ref}"
    local ov_json phrase_json
    ov_json=$(mktemp)
    phrase_json=$(mktemp)

    if ! curl -fsL "$ov_url" -o "$ov_json"; then
        rm -f "$ov_json" "$phrase_json"
        return 1
    fi
    # 詞組目錄失敗時仍可解析主表；Python 端會再 fallback
    curl -fsL "$phrase_api_url" -o "$phrase_json" 2>/dev/null || echo '[]' > "$phrase_json"

    if ! python3 - "$ov_json" "$phrase_json" "$ARRAY30_GITHUB_RAW_BASE" "$ref" "$ARRAY30_PHRASE_DIR" <<'PY'; then
import json
import re
import shlex
import sys

ov_path, phrase_path, raw_base, ref, phrase_dir = sys.argv[1:6]

with open(ov_path, "r", encoding="utf-8") as f:
    items = json.load(f)

try:
    with open(phrase_path, "r", encoding="utf-8") as f:
        phrase_items = json.load(f)
except Exception:
    phrase_items = []
if not isinstance(phrase_items, list):
    phrase_items = []

main_candidates = []
simple_candidates = []
phrase_candidates = []

versioned_main = re.compile(r"^array30-OpenVanilla-big-v(\d{4})-(\d+)\.(\d+)-(\d{8})\.cin$")
dated_simple = re.compile(r"^array-shortcode-(\d{8})\.cin$")
dated_phrase = re.compile(r"^array30-phrase-(\d{8})\.txt$")

for item in items:
    if item.get("type") != "file":
        continue
    name = item["name"]
    main_match = versioned_main.match(name)
    if main_match:
        year, major, minor, stamp = main_match.groups()
        main_candidates.append(((int(year), int(major), int(minor), int(stamp)), name))
        continue

    simple_match = dated_simple.match(name)
    if simple_match:
        simple_candidates.append((int(simple_match.group(1)), name))

for item in phrase_items:
    if item.get("type") != "file":
        continue
    name = item["name"]
    phrase_match = dated_phrase.match(name)
    if phrase_match:
        phrase_candidates.append((int(phrase_match.group(1)), name))

if not main_candidates:
    raise SystemExit("no versioned array30 main CIN file found")
if not simple_candidates:
    raise SystemExit("no shortcode CIN file found")

main_candidates.sort(reverse=True)
simple_candidates.sort(reverse=True)
phrase_candidates.sort(reverse=True)

main_name = main_candidates[0][1]
simple_name = simple_candidates[0][1]

main_url = f"{raw_base}/{ref}/OpenVanilla/{main_name}"
simple_url = f"{raw_base}/{ref}/OpenVanilla/{simple_name}"

if phrase_candidates:
    phrase_name = phrase_candidates[0][1]
    phrase_rel = f"{phrase_dir}/{phrase_name}"
    phrase_url = f"{raw_base}/{ref}/{phrase_rel}"
else:
    # 相容舊路徑（上游已遷移至 array30_spec/ 後多半 404）
    phrase_name = "array30-phrase-20210725.txt"
    phrase_rel = phrase_name
    phrase_url = f"{raw_base}/{ref}/{phrase_name}"

for key, value in (
    ("ARRAY30_SOURCE_REF", ref),
    ("ARRAY30_MAIN_NAME", main_name),
    ("ARRAY30_MAIN_URL", main_url),
    ("ARRAY30_SIMPLE_NAME", simple_name),
    ("ARRAY30_SIMPLE_URL", simple_url),
    ("ARRAY30_PHRASE_NAME", phrase_name),
    ("ARRAY30_PHRASE_PATH", phrase_rel),
    ("ARRAY30_PHRASE_URL", phrase_url),
):
    print(f"{key}={shlex.quote(value)}")
PY
        rm -f "$ov_json" "$phrase_json"
        return 1
    fi

    rm -f "$ov_json" "$phrase_json"
}

# Ubuntu: 在 Arch Linux Archive 搜尋與指定 semver 匹配的套件版本
# 嘗試 release -1 ~ -4，回傳第一個找到的完整版本字串
find_arch_pkg_version() {
    local pkg="$1"
    local semver="$2"
    local first_char="${pkg:0:1}"
    for rel in 1 2 3 4; do
        local ver="${semver}-${rel}"
        local url="$ARCHIVE_BASE/$first_char/$pkg/$pkg-$ver-x86_64.pkg.tar.zst"
        if url_exists "$url"; then
            echo "$ver"
            return 0
        fi
    done
    return 1
}

# 安裝編譯好的 .so / 資料檔到 host（跨 OS）
pkg_install_array() {
    case "$OS_TYPE" in
        steamos|arch)
            # SteamOS/Arch: 直接 pacman -U 安裝整個 .pkg.tar.zst
            local pkg_file="$1"
            sudo pacman -U --noconfirm "$pkg_file"
            ;;
        ubuntu|debian)
            # Ubuntu/Debian: 從容器提取特定檔案並手動複製
            ubuntu_install_files
            ;;
    esac
}

# 移除 fcitx5-array（跨 OS）
pkg_remove_array() {
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        info "移除 Flatpak user 路徑的 fcitx5-array 檔案..."
        rm -f "$ARRAY_SO" "$ASSOC_SO" "$ARRAY_DB"
        rm -f "${_FP_DATA}/fcitx5/addon/array.conf"
        rm -f "${_FP_DATA}/fcitx5/inputmethod/array.conf"
        ok "已移除 fcitx5-array 相關檔案（Flatpak 模式）"
        return
    fi
    case "$OS_TYPE" in
        steamos|arch)
            sudo pacman -R --noconfirm fcitx5-array
            ;;
        ubuntu|debian)
            info "移除手動安裝的 fcitx5-array 檔案..."
            sudo rm -f "$ARRAY_SO"
            sudo rm -f "$(dirname "$ARRAY_SO")/libarray.so"
            sudo rm -f "$ARRAY_DB"
            sudo rm -f /usr/share/fcitx5/addon/array.conf
            sudo rm -f /usr/share/fcitx5/inputmethod/array.conf
            sudo rm -f "$ASSOC_SO" 2>/dev/null || true
            ok "已移除 fcitx5-array 相關檔案"
            ;;
    esac
}

# ── 前置檢查 ──────────────────────────────────────────────────────────────

# /etc/os-release ID（用於顯示，例如 pop vs ubuntu）
_os_release_id() {
    grep -oP '^ID=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || echo ""
}

check_platform() {
    case "$OS_TYPE" in
        steamos)
            ok "偵測到 SteamOS (Steam Deck)"
            ;;
        arch)
            ok "偵測到 Arch-based 系統 (CachyOS/Arch Linux)"
            ;;
        ubuntu)
            if [[ "$(_os_release_id)" == "pop" ]]; then
                ok "偵測到 Pop!_OS（Ubuntu 相容路徑）"
            else
                ok "偵測到 Ubuntu Desktop"
            fi
            ;;
        debian)
            warn "偵測到 Debian-based 系統（實驗性支援）"
            confirm "繼續安裝？" || exit 1
            ;;
        unknown)
            warn "無法識別的作業系統"
            confirm "仍要繼續嗎？" || exit 1
            ;;
    esac
}

check_container_runtime() {
    # Arch/CachyOS builds natively — no container needed
    [[ "$OS_TYPE" == "arch" ]] && return 0
    if [[ -z "$CONTAINER_RUNTIME" ]]; then
        err "找不到容器工具（Podman 或 Docker）"
        case "$OS_TYPE" in
            steamos)
                err "請確認你在 Desktop Mode 下執行（SteamOS 應已內建 Podman）"
                ;;
            arch)
                err "請先安裝容器工具："
                err "  sudo pacman -S podman"
                ;;
            ubuntu|debian)
                err "請先安裝容器工具："
                err "  sudo apt install podman"
                err "  或參考 https://docs.docker.com/engine/install/ubuntu/"
                ;;
        esac
        exit 1
    fi
    ok "容器工具: $CONTAINER_RUNTIME"
}

check_chinese_locale() {
    # 只有 Ubuntu/Debian 需要檢查中文語系
    [[ "$OS_TYPE" != "ubuntu" && "$OS_TYPE" != "debian" ]] && return 0

    # 檢查 zh_TW.UTF-8 locale 是否已產生
    if locale -a 2>/dev/null | grep -qi 'zh_TW\.utf-\?8'; then
        ok "繁體中文語系 (zh_TW.UTF-8) 已安裝"
        return 0
    fi

    warn "未偵測到繁體中文語系 (zh_TW.UTF-8)"
    info "安裝繁體中文語言套件..."
    need_sudo
    sudo apt-get install -y language-pack-zh-hant language-pack-gnome-zh-hant fonts-noto-cjk 2>&1 | tail -3
    sudo locale-gen zh_TW.UTF-8 2>&1 | tail -1
    ok "繁體中文語系已安裝"
    info "如需將系統語言切換為中文，可至 Settings > Region & Language 設定"
}

check_fcitx5() {
    if [[ "$FCITX5_INSTALL_TYPE" == "none" ]]; then
        err "找不到 fcitx5，請先安裝 fcitx5 輸入法框架"
        case "$OS_TYPE" in
            ubuntu|debian)
                err "  sudo apt install fcitx5 fcitx5-chinese-addons"
                ;;
            steamos)
                err "  Flatpak: flatpak install flathub org.fcitx.Fcitx5"
                ;;
            arch)
                err "  sudo pacman -S fcitx5 fcitx5-chinese-addons"
                ;;
        esac
        exit 1
    fi

    # Ubuntu/Debian: 確保 libfmt runtime 存在（fcitx5-array .so 需要動態連結）
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        if ! dpkg -l 'libfmt[0-9]*' 2>/dev/null | grep -q '^ii'; then
            info "安裝 libfmt runtime（fcitx5-array 編譯產物需要）..."
            need_sudo
            sudo apt-get install -y libfmt9 2>&1 | tail -2
            ok "libfmt9 已安裝"
        fi
    fi
}

check_readonly() {
    # 只有 SteamOS native 安裝需要解除唯讀
    [[ "$OS_TYPE" != "steamos" ]] && return 0
    [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]] && return 0

    if ! touch /usr/lib/.steamos_writable_test 2>/dev/null; then
        warn "SteamOS 檔案系統目前為唯讀模式"
        info "需要暫時解除唯讀才能安裝"
        if confirm "要執行 sudo steamos-readonly disable 嗎？"; then
            sudo steamos-readonly disable
            ok "已解除唯讀模式（安裝完成後建議重新啟用）"
        else
            err "無法在唯讀模式下安裝，中止"
            exit 1
        fi
    else
        rm -f /usr/lib/.steamos_writable_test 2>/dev/null
    fi
}

get_host_versions() {
    # Flatpak 模式：直接從 metadata 和 runtime 目錄取得版本，跳過 native 套件查詢
    # （pacman -Q fcitx5 在 Flatpak 模式下找不到包會 exit 1，觸發 set -e 靜默退出）
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        HOST_FCITX5_VER=$(LANG=C flatpak info org.fcitx.Fcitx5 2>/dev/null \
            | awk '/Version:/{print $NF}')
        # 從 KDE Platform runtime 目錄掃 libfmt，避免啟動沙箱（flatpak run 會 hang）
        local _fp_rt _fp_rt_id _fp_rt_branch _fp_rt_base _fp_rt_dir
        _fp_rt=$(LANG=C flatpak info org.fcitx.Fcitx5 2>/dev/null | awk '/Runtime:/{print $NF}')
        _fp_rt_id="${_fp_rt%%/*}"      # org.kde.Platform
        _fp_rt_branch="${_fp_rt##*/}"  # 6.10（相容 "id//branch" 和 "id/arch/branch"）
        _fp_rt_base=""
        for _fp_rt_dir in "/var/lib/flatpak/runtime" "$HOME/.local/share/flatpak/runtime"; do
            local _candidate="${_fp_rt_dir}/${_fp_rt_id}/x86_64/${_fp_rt_branch}/active/files"
            if [[ -d "$_candidate" ]]; then
                _fp_rt_base="$_candidate"
                break
            fi
        done
        if [[ -n "$_fp_rt_base" ]]; then
            HOST_FMT_VER=$(find "$_fp_rt_base/lib" -name "libfmt.so.*.*.*" 2>/dev/null \
                | head -1 | grep -oP 'libfmt\.so\.\K[0-9]+\.[0-9]+\.[0-9]+')
        fi
    else
        case "$OS_TYPE" in
            steamos)
                HOST_FCITX5_VER=$(pkg_get_version fcitx5)
                HOST_FMT_VER=$(pkg_get_version fmt)
                ;;
            arch)
                local fcitx5_raw fmt_raw
                fcitx5_raw=$(pkg_get_version fcitx5)
                fmt_raw=$(pkg_get_version fmt)
                # Strip CachyOS/distro dist suffix (e.g., 5.1.19-1.1 → 5.1.19-1)
                HOST_FCITX5_VER=$(echo "$fcitx5_raw" | sed 's/-\([0-9]*\)\.[0-9]*$/-\1/')
                HOST_FMT_VER=$(echo "$fmt_raw" | sed 's/-\([0-9]*\)\.[0-9]*$/-\1/')
                ;;
            ubuntu|debian)
                local fcitx5_raw fmt_raw
                fcitx5_raw=$(pkg_get_version fcitx5)
                # Ubuntu fmt 套件名稱含版本號（libfmt9、libfmt10…）
                fmt_raw=$(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii[[:space:]]+libfmt[0-9]/{print $3}' | head -1)
                HOST_FCITX5_VER=$(strip_semver "$fcitx5_raw")
                HOST_FMT_VER=$(strip_semver "$fmt_raw")
                ;;
        esac
    fi

    if [[ -z "$HOST_FCITX5_VER" ]]; then
        err "找不到 fcitx5 版本，請確認 fcitx5 已安裝"
        exit 1
    fi
    if [[ -z "$HOST_FMT_VER" ]]; then
        err "找不到 libfmt 版本，請確認 fcitx5 相依套件已安裝"
        case "$OS_TYPE" in
            ubuntu|debian) err "  sudo apt install libfmt-dev" ;;
            arch) err "  sudo pacman -S fmt" ;;
        esac
        exit 1
    fi

    info "Host fcitx5 版本: $HOST_FCITX5_VER"
    info "Host fmt 版本:    $HOST_FMT_VER"
}

# ── 容器管理 ──────────────────────────────────────────────────────────────

container_exists() {
    $CONTAINER_RUNTIME container exists "$CONTAINER_NAME" 2>/dev/null
}

container_running() {
    [[ "$($CONTAINER_RUNTIME inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

ensure_container() {
    if container_exists; then
        if ! container_running; then
            info "啟動現有容器 $CONTAINER_NAME ..."
            $CONTAINER_RUNTIME start "$CONTAINER_NAME" >/dev/null
        fi
    else
        info "建立 Arch Linux 編譯容器 ..."
        $CONTAINER_RUNTIME run -dit --name "$CONTAINER_NAME" "$CONTAINER_IMAGE" >/dev/null
    fi
    ok "容器 $CONTAINER_NAME 就緒（$CONTAINER_RUNTIME）"
}

container_exec() {
    $CONTAINER_RUNTIME exec "$CONTAINER_NAME" bash -c "$1"
}

cleanup_container() {
    if container_exists; then
        info "清理容器 ..."
        $CONTAINER_RUNTIME stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
        $CONTAINER_RUNTIME rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
        ok "容器已清理"
    fi
}

# Ubuntu/Debian 專用：從容器內的 .pkg.tar.zst 提取檔案並安裝到 host
ubuntu_install_files() {
    step "提取並安裝 fcitx5-array 檔案（Ubuntu 模式）"

    # 在容器內解壓縮 .pkg.tar.zst（排除 debug package）
    container_exec "
        mkdir -p /tmp/pkg-extract
        cd /tmp/pkg-extract
        PKG=\$(ls /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst 2>/dev/null | grep -v debug | head -1)
        [[ -z \$PKG ]] && { echo 'ERROR: no package found'; exit 1; }
        echo \"Extracting: \$PKG\"
        tar -I zstd -xf \$PKG 2>/dev/null \
            || tar --use-compress-program=zstd -xf \$PKG
    "

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # 從容器複製需要的檔案到本地暫存（用不同檔名避免同名覆蓋）
    local files_ok=0
    local -A file_map=(
        ["usr/lib/fcitx5/array.so"]="array.so"
        ["usr/share/fcitx5/array/array.db"]="array.db"
        ["usr/share/fcitx5/addon/array.conf"]="addon-array.conf"
        ["usr/share/fcitx5/inputmethod/array.conf"]="inputmethod-array.conf"
        ["usr/lib/fcitx5/libassociation.so"]="libassociation.so"
    )
    for src_path in "${!file_map[@]}"; do
        local dest_name="${file_map[$src_path]}"
        $CONTAINER_RUNTIME cp "$CONTAINER_NAME:/tmp/pkg-extract/$src_path" "$tmpdir/$dest_name" 2>/dev/null && \
            files_ok=$((files_ok+1)) || true
    done

    if [[ $files_ok -lt 3 ]]; then
        err "從容器提取檔案失敗（只取得 $files_ok 個檔案）"
        exit 1
    fi
    info "已從容器提取 $files_ok 個檔案"

    # 建立目標目錄
    sudo mkdir -p "$(dirname $ARRAY_SO)"
    sudo mkdir -p "$(dirname $ARRAY_DB)"
    sudo mkdir -p /usr/share/fcitx5/addon
    sudo mkdir -p /usr/share/fcitx5/inputmethod

    # 複製到 host 系統目錄
    [[ -f "$tmpdir/array.so" ]]                  && sudo cp "$tmpdir/array.so"                  "$ARRAY_SO"
    [[ -f "$tmpdir/array.db" ]]                  && sudo cp "$tmpdir/array.db"                  "$ARRAY_DB"
    [[ -f "$tmpdir/addon-array.conf" ]]          && sudo cp "$tmpdir/addon-array.conf"          /usr/share/fcitx5/addon/array.conf
    [[ -f "$tmpdir/inputmethod-array.conf" ]]    && sudo cp "$tmpdir/inputmethod-array.conf"    /usr/share/fcitx5/inputmethod/array.conf
    [[ -f "$tmpdir/libassociation.so" ]]         && sudo cp "$tmpdir/libassociation.so"         "$ASSOC_SO"

    # Ubuntu/Debian: fcitx5 的 addon loader 會加 "lib" 前綴尋找 .so
    # Library=array → 找 libarray.so，需建立 symlink
    if [[ "$OS_TYPE" == "ubuntu" || "$OS_TYPE" == "debian" ]]; then
        local so_dir
        so_dir=$(dirname "$ARRAY_SO")
        if [[ -f "$ARRAY_SO" ]] && [[ ! -f "$so_dir/libarray.so" ]]; then
            sudo ln -sf "$ARRAY_SO" "$so_dir/libarray.so"
            ok "建立 libarray.so symlink"
        fi
    fi

    ok "fcitx5-array 檔案已安裝到 host"
}

flatpak_install_files() {
    step "提取並安裝 fcitx5-array 檔案（Flatpak 模式）"

    container_exec "
        mkdir -p /tmp/pkg-extract
        cd /tmp/pkg-extract
        PKG=\$(ls /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst 2>/dev/null | grep -v debug | head -1)
        [[ -z \$PKG ]] && { echo 'ERROR: no package found'; exit 1; }
        echo \"Extracting: \$PKG\"
        tar -I zstd -xf \$PKG 2>/dev/null \
            || tar --use-compress-program=zstd -xf \$PKG
    "

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    local files_ok=0
    local -A file_map=(
        ["usr/lib/fcitx5/array.so"]="array.so"
        ["usr/share/fcitx5/array/array.db"]="array.db"
        ["usr/share/fcitx5/addon/array.conf"]="addon-array.conf"
        ["usr/share/fcitx5/inputmethod/array.conf"]="inputmethod-array.conf"
        ["usr/lib/fcitx5/libassociation.so"]="libassociation.so"
    )
    for src_path in "${!file_map[@]}"; do
        local dest_name="${file_map[$src_path]}"
        $CONTAINER_RUNTIME cp "$CONTAINER_NAME:/tmp/pkg-extract/$src_path" "$tmpdir/$dest_name" 2>/dev/null && \
            files_ok=$((files_ok+1)) || true
    done

    if [[ $files_ok -lt 3 ]]; then
        err "從容器提取檔案失敗（只取得 $files_ok 個檔案）"
        exit 1
    fi
    info "已從容器提取 $files_ok 個檔案"

    # 建立目標目錄（不需 sudo）
    mkdir -p "$(dirname "$ARRAY_SO")"
    mkdir -p "$(dirname "$ARRAY_DB")"
    mkdir -p "${_FP_DATA}/fcitx5/addon"
    mkdir -p "${_FP_DATA}/fcitx5/inputmethod"

    # 安裝 array.so → libarray.so（Library=array 時 fcitx5 查找 libarray.so）
    [[ -f "$tmpdir/array.so" ]]               && cp "$tmpdir/array.so"             "$ARRAY_SO"
    [[ -f "$tmpdir/array.db" ]]               && cp "$tmpdir/array.db"             "$ARRAY_DB"
    [[ -f "$tmpdir/addon-array.conf" ]]       && cp "$tmpdir/addon-array.conf"     "${_FP_DATA}/fcitx5/addon/array.conf"
    [[ -f "$tmpdir/inputmethod-array.conf" ]] && cp "$tmpdir/inputmethod-array.conf" "${_FP_DATA}/fcitx5/inputmethod/array.conf"
    [[ -f "$tmpdir/libassociation.so" ]]      && cp "$tmpdir/libassociation.so"    "$ASSOC_SO"

    ok "fcitx5-array 檔案已安裝到 Flatpak user 路徑"

    # 建立 FCITX_ADDON_DIRS wrapper：/app/bin/fcitx5 會覆蓋 FCITX_ADDON_DIRS，
    # 此 wrapper 在 exec fcitx5-bin 前重新插入 user addon lib 路徑
    local fp_bin_dir="${_FP_DATA}/fcitx5/bin"
    mkdir -p "$fp_bin_dir"
    cat > "$_FP_WRAPPER" << 'FPWRAP'
#!/bin/sh
# Prepend user addon lib so fcitx5's addonloader can find array.so
USER_ADDON_LIB="$HOME/.var/app/org.fcitx.Fcitx5/data/fcitx5/lib"
export FCITX_ADDON_DIRS="$USER_ADDON_LIB:/app/lib/fcitx5"
for dir in $(ls /app/addons/); do
    export FCITX_ADDON_DIRS="/app/addons/$dir/lib/fcitx5:$FCITX_ADDON_DIRS"
    export XDG_DATA_DIRS="/app/addons/$dir/share:${XDG_DATA_DIRS}"
    export PATH="/app/addons/$dir/bin:$PATH"
done
for dir in $(ls /app/addons/); do
    if [ -d "/app/addons/$dir/lib/libime" ]; then
        export LIBIME_MODEL_DIRS="/app/addons/$dir/lib/libime:$LIBIME_MODEL_DIRS"
    fi
done
exec fcitx5-bin "$@"
FPWRAP
    chmod +x "$_FP_WRAPPER"
    ok "已建立 Flatpak addon wrapper: $_FP_WRAPPER"
}

# ── 備份/還原 ─────────────────────────────────────────────────────────────

do_backup() {
    step "備份目前的 fcitx5-array 檔案"
    mkdir -p "$BACKUP_DIR"
    local ts
    ts=$(date +%Y%m%d-%H%M%S)
    local bak="$BACKUP_DIR/$ts"
    mkdir -p "$bak"

    if [[ -f "$ARRAY_DB" ]]; then
        cp "$ARRAY_DB" "$bak/array.db"
        ok "已備份 array.db"
    fi
    if [[ -f "$ARRAY_SO" ]]; then
        cp "$ARRAY_SO" "$bak/array.so"
        ok "已備份 array.so"
    fi

    # 記錄目前套件版本
    case "$OS_TYPE" in
        steamos|arch)
            if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
                LANG=C flatpak info org.fcitx.Fcitx5 2>/dev/null \
                    | awk '/Version:/{print "fcitx5 (flatpak): "$NF}' > "$bak/pkg-version.txt" || true
                echo "mode: flatpak" >> "$bak/pkg-version.txt"
            else
                pacman -Q fcitx5-array 2>/dev/null > "$bak/pkg-version.txt" || echo "not installed" > "$bak/pkg-version.txt"
                pacman -Q fcitx5 fmt 2>/dev/null >> "$bak/pkg-version.txt"
            fi
            ;;
        ubuntu|debian)
            echo "fcitx5: $(pkg_get_version fcitx5)" > "$bak/pkg-version.txt"
            echo "libfmt: $(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii[[:space:]]+libfmt[0-9]/{print $3}' | head -1)" >> "$bak/pkg-version.txt"
            echo "array.so: $([ -f "$ARRAY_SO" ] && echo "installed" || echo "not installed")" >> "$bak/pkg-version.txt"
            ;;
    esac

    ok "備份完成: $bak"
    echo "$ts" > "$BACKUP_DIR/latest"
}

do_restore() {
    warn_steamos_version
    step "從備份還原"

    if [[ ! -d "$BACKUP_DIR" ]]; then
        err "找不到備份目錄 $BACKUP_DIR"
        exit 1
    fi

    # 列出可用備份
    echo "可用的備份:"
    local backups=()
    while IFS= read -r -d '' dir; do
        local name
        name=$(basename "$dir")
        if [[ -f "$dir/array.db" ]] || [[ -f "$dir/array.so" ]]; then
            backups+=("$name")
            local ver
            ver=$(cat "$dir/pkg-version.txt" 2>/dev/null || echo "unknown")
            echo "  $((${#backups[@]}))) $name — $ver"
        fi
    done < <(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -print0 | sort -z)

    if [[ ${#backups[@]} -eq 0 ]]; then
        err "沒有找到可用的備份"
        exit 1
    fi

    read -rp "選擇要還原的備份編號 [1-${#backups[@]}]: " choice
    if [[ "$choice" -lt 1 ]] || [[ "$choice" -gt ${#backups[@]} ]]; then
        err "無效的選擇"
        exit 1
    fi

    local selected="${backups[$((choice-1))]}"
    local src="$BACKUP_DIR/$selected"

    need_sudo
    if [[ -f "$src/array.db" ]]; then
        sudo cp "$src/array.db" "$ARRAY_DB"
        ok "已還原 array.db"
    fi
    if [[ -f "$src/array.so" ]]; then
        sudo cp "$src/array.so" "$ARRAY_SO"
        ok "已還原 array.so"
    fi

    restart_fcitx5
    ok "還原完成"
}

# ── 核心: 安裝 ────────────────────────────────────────────────────────────

do_install() {
    warn_steamos_version
    step "行列30 (fcitx5-array) 安裝程序"
    echo ""
    info "此腳本將:"
    if [[ "$OS_TYPE" == "arch" ]]; then
        info "  1. 在本機編譯 fcitx5-array（Arch-based 系統，無需容器）"
    else
        info "  1. 在容器（$CONTAINER_RUNTIME）中編譯 fcitx5-array"
        info "  2. 確保 ABI 相容性（降級容器內依賴以匹配 host）"
    fi
    info "  3. 安裝編譯成果到 host"
    info "  4. 設定 fcitx5 使用原生行列30引擎"
    echo ""

    # 前置檢查
    check_platform
    check_chinese_locale
    check_container_runtime
    check_fcitx5
    get_host_versions

    # 將 host 版本對應到 Arch Archive 版本（含 release suffix，如 5.1.19-1）
    local ARCH_FCITX5_VER ARCH_FMT_VER
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        # Flatpak 模式：host 版本無 release suffix（來自 flatpak info / libfmt.so 檔名）
        # 需透過 find_arch_pkg_version 找到含 release 的正確 Arch 套件
        info "搜尋對應的 Arch Linux 套件版本（Flatpak ABI 匹配）..."
        ARCH_FCITX5_VER=$(find_arch_pkg_version "fcitx5" "$HOST_FCITX5_VER") || {
            err "找不到 Arch Archive 中對應 fcitx5 $HOST_FCITX5_VER 的套件"
            err "請回報此問題至 https://github.com/tern/steamdeck-array30/issues"
            exit 1
        }
        ARCH_FMT_VER=$(find_arch_pkg_version "fmt" "$HOST_FMT_VER") || {
            err "找不到 Arch Archive 中對應 fmt $HOST_FMT_VER 的套件"
            err "請回報此問題至 https://github.com/tern/steamdeck-array30/issues"
            exit 1
        }
        info "Arch 套件版本: fcitx5=$ARCH_FCITX5_VER  fmt=$ARCH_FMT_VER"
    else
        case "$OS_TYPE" in
            steamos|arch)
                # native 模式：pacman -Q 已含 release suffix（如 5.1.19-1）
                # arch 模式下 CachyOS dist suffix 已在 get_host_versions() 中去除
                ARCH_FCITX5_VER="$HOST_FCITX5_VER"
                ARCH_FMT_VER="$HOST_FMT_VER"
                ;;
            ubuntu|debian)
                info "搜尋對應的 Arch Linux 套件版本..."
                ARCH_FCITX5_VER=$(find_arch_pkg_version "fcitx5" "$HOST_FCITX5_VER") || {
                    err "找不到 Arch Archive 中對應 fcitx5 $HOST_FCITX5_VER 的套件"
                    err "請回報此問題至 https://github.com/tern/steamdeck-array30/issues"
                    exit 1
                }
                ARCH_FMT_VER=$(find_arch_pkg_version "fmt" "$HOST_FMT_VER") || {
                    err "找不到 Arch Archive 中對應 fmt $HOST_FMT_VER 的套件"
                    err "請回報此問題至 https://github.com/tern/steamdeck-array30/issues"
                    exit 1
                }
                info "Arch 套件版本: fcitx5=$ARCH_FCITX5_VER  fmt=$ARCH_FMT_VER"
                ;;
        esac
    fi

    echo ""
    confirm "開始安裝？" || exit 0

    # 備份現有安裝
    if [[ -f "$ARRAY_SO" ]] || [[ -f "$ARRAY_DB" ]]; then
        do_backup
    fi

    # 準備 fmt::runtime() patch 腳本（native 和 container 路徑共用）
    cat > /tmp/patch_fmt_runtime.py << 'PYEOF'
import re, sys
fname = sys.argv[1]
c = open(fname).read()
# Replace: fmt::format(_("..."), args) -> fmt::format(fmt::runtime(_("...")), args)
c = re.sub(r'fmt::format\(_\((".*?")\),', r'fmt::format(fmt::runtime(_(\1)),', c)
open(fname, 'w').write(c)
PYEOF

    local _native_build_dir=""

    if [[ "$OS_TYPE" == "arch" ]]; then
        # ── Arch/CachyOS 本機編譯（無需容器，host 已有相符 ABI）──────────────
        step "本機編譯 fcitx5-array"
        _native_build_dir=/tmp/fcitx5-array-native
        rm -rf "$_native_build_dir"
        mkdir -p "$_native_build_dir"

        info "從 AUR 取得 PKGBUILD ..."
        git clone "$FCITX5_ARRAY_AUR" "$_native_build_dir/fcitx5-array" 2>&1 | tail -1
        sed -i "s/^pkgver=.*/pkgver=$FCITX5_ARRAY_VER/" "$_native_build_dir/fcitx5-array/PKGBUILD"
        sed -i "s/^sha256sums=.*/sha256sums=('$FCITX5_ARRAY_SHA256')/" "$_native_build_dir/fcitx5-array/PKGBUILD"

        # GCC 14 對 fcitx5 5.x 舊 header 的 uint32_t 不再隱式 include <cstdint>
        local _hdr=/usr/include/Fcitx5/Utils/fcitx-utils/inputbuffer.h
        if [[ -f "$_hdr" ]] && ! grep -q '<cstdint>' "$_hdr"; then
            sudo sed -i '/#include <cstring>/a #include <cstdint>' "$_hdr"
        fi

        info "執行 makepkg ..."
        # 步驟一：僅解壓源碼（不編譯）
        (cd "$_native_build_dir/fcitx5-array" && makepkg -of --noconfirm 2>&1 | tail -3)
        # 步驟二：fmt::runtime() patch
        local _engine
        _engine=$(find "$_native_build_dir/fcitx5-array/src" -name engine.cpp 2>/dev/null | head -1)
        if [[ -n "$_engine" ]]; then
            python3 /tmp/patch_fmt_runtime.py "$_engine"
        fi
        # 步驟三：使用已解壓的源碼編譯（--noextract 跳過重新解壓）
        (cd "$_native_build_dir/fcitx5-array" && makepkg -ef --noconfirm 2>&1 | tail -5)
        ok "本機編譯完成"
    else
        # ── 容器編譯路徑（SteamOS / Ubuntu / Debian）────────────────────────
        step "準備編譯容器"
        ensure_container

        info "安裝編譯工具 ..."
        container_exec "pacman -Syu --noconfirm 2>&1 | tail -3"
        container_exec "pacman -S --noconfirm --needed base-devel git cmake extra-cmake-modules sqlite gettext fmt fcitx5 2>&1 | tail -3"
        ok "編譯工具就緒"

        step "降級容器依賴以匹配 host ABI"
        downgrade_container_pkg "fcitx5" "$ARCH_FCITX5_VER"
        downgrade_container_pkg "fmt" "$ARCH_FMT_VER"

        step "編譯 fcitx5-array"
        info "從 AUR 取得 PKGBUILD ..."
        container_exec "
            cd /tmp
            rm -rf fcitx5-array
            git clone $FCITX5_ARRAY_AUR 2>&1 | tail -1
            sed -i \"s/^pkgver=.*/pkgver=$FCITX5_ARRAY_VER/\" /tmp/fcitx5-array/PKGBUILD
            sed -i \"s/^sha256sums=.*/sha256sums=('$FCITX5_ARRAY_SHA256')/\" /tmp/fcitx5-array/PKGBUILD
        "

        info "執行 makepkg ..."
        $CONTAINER_RUNTIME cp /tmp/patch_fmt_runtime.py "$CONTAINER_NAME:/tmp/patch_fmt_runtime.py"

        container_exec "
            cd /tmp/fcitx5-array
            useradd -m builder 2>/dev/null || true
            chown -R builder:builder /tmp/fcitx5-array
            HDR=/usr/include/Fcitx5/Utils/fcitx-utils/inputbuffer.h
            if [[ -f \$HDR ]] && ! grep -q '<cstdint>' \$HDR; then
                sed -i '/#include <cstring>/a #include <cstdint>' \$HDR
            fi
            su - builder -c 'cd /tmp/fcitx5-array && makepkg -of --noconfirm 2>&1 | tail -3'
            ENGINE=\$(find /tmp/fcitx5-array/src -name engine.cpp 2>/dev/null | head -1)
            if [[ -n \$ENGINE ]]; then
                python3 /tmp/patch_fmt_runtime.py \"\$ENGINE\"
            fi
            su - builder -c 'cd /tmp/fcitx5-array && makepkg -ef --noconfirm 2>&1 | tail -5'
        "
    fi

    # ABI 驗證：用 ldd 做實際載入測試
    step "驗證 ABI 相容性"
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        info "Flatpak 模式：ABI 驗證由安裝後載入測試確認"
    elif [[ "$OS_TYPE" == "arch" ]]; then
        local _abi_so
        _abi_so=$(find "$_native_build_dir/fcitx5-array/pkg" -name "array.so" 2>/dev/null | head -1)
        if [[ -n "$_abi_so" && -s "$_abi_so" ]]; then
            local missing
            missing=$(ldd "$_abi_so" 2>&1 | grep "not found" || true)
            if [[ -n "$missing" ]]; then
                err "ABI 不相容: array.so 缺少以下動態庫:"
                echo "$missing" | sed 's/^/  /'
                exit 1
            fi
            ok "ABI 驗證通過"
        else
            warn "無法找到 array.so 進行 ABI 驗證，跳過（繼續安裝）"
        fi
    else
        local tmp_so
        tmp_so=$(mktemp /tmp/array-abi-test-XXXXXX.so)
        $CONTAINER_RUNTIME cp "$CONTAINER_NAME:/tmp/fcitx5-array/pkg/fcitx5-array/usr/lib/fcitx5/array.so" "$tmp_so" 2>/dev/null || true

        if [[ -s "$tmp_so" ]]; then
            local missing
            missing=$(ldd "$tmp_so" 2>&1 | grep "not found" || true)
            rm -f "$tmp_so"
            if [[ -n "$missing" ]]; then
                err "ABI 不相容: array.so 缺少以下動態庫（host 與容器版本不匹配）:"
                echo "$missing" | sed 's/^/  /'
                err "請重新執行 install；若問題持續請回報至 GitHub Issues"
                exit 1
            fi
            ok "ABI 驗證通過"
        else
            rm -f "$tmp_so"
            warn "無法提取 array.so 進行 ABI 驗證，跳過（繼續安裝）"
        fi
    fi

    # 安裝到 host
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        step "安裝到 Flatpak user 路徑"
        flatpak_install_files
    else
        step "安裝到 host"
        check_readonly
        need_sudo

        local pkg_file
        if [[ "$OS_TYPE" == "arch" ]]; then
            pkg_file=$(ls "$_native_build_dir/fcitx5-array/"fcitx5-array-*-any.pkg.tar.zst 2>/dev/null | grep -v debug | head -1)
        else
            pkg_file=$(container_exec "ls /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst 2>/dev/null | grep -v debug | head -1")
        fi
        if [[ -z "$pkg_file" ]]; then
            err "找不到編譯產出的 .pkg.tar.zst 檔案"
            exit 1
        fi

        case "$OS_TYPE" in
            steamos)
                $CONTAINER_RUNTIME cp "$CONTAINER_NAME:$pkg_file" /tmp/fcitx5-array-latest.pkg.tar.zst
                # --overwrite '*' 處理系統更新後殘留的同名檔案衝突
                sudo pacman -U --noconfirm --overwrite '*' /tmp/fcitx5-array-latest.pkg.tar.zst
                ok "套件已安裝（pacman）"
                ;;
            arch)
                # 本機編譯：pkg_file 已在 host 上，直接安裝
                sudo pacman -U --noconfirm --overwrite '*' "$pkg_file"
                ok "套件已安裝（pacman）"
                ;;
            ubuntu|debian)
                ubuntu_install_files
                ;;
        esac
    fi

    # 可選：安裝新酷音 (fcitx5-chewing) 以便與行列30共用
    _maybe_install_chewing

    # 設定 fcitx5 profile
    setup_profile

    # 設定 autostart wrapper
    setup_autostart

    # 重啟 fcitx5
    restart_fcitx5

    # 驗證
    step "驗證安裝結果"
    sleep 2
    if verify_array_loaded; then
        echo ""
        ok "================================================"
        ok "  行列30 (fcitx5-array) 安裝成功！"
        ok "  按 Ctrl+Space 切換輸入法"
        ok "  支援 W+數字 符號輸入、簡碼、萬用字元"
        ok "================================================"
    else
        err "安裝完成但 array addon 載入失敗"
        err "請執行 ./array30-setup.sh diagnose 檢查問題"
        exit 1
    fi

    # 若仍有 table-based 行列，詢問是否遷移移除
    if _table_array30_present; then
        echo ""
        info "偵測到 table-based 行列30（array30 / array30-large）仍在系統中"
        info "原生 array 功能更完整，建議移除 table 版以避免清單重複"
        if confirm "要移除 table-based 行列並只保留原生 array 嗎？"; then
            do_migrate_from_table auto
        else
            info "已保留 table 版；之後可執行: ./array30-setup.sh migrate-from-table"
        fi
    fi

    # 清理
    echo ""
    if [[ "$OS_TYPE" == "arch" ]]; then
        if confirm "要清理本機編譯暫存目錄嗎？"; then
            rm -rf /tmp/fcitx5-array-native
            ok "暫存目錄已清理"
        fi
    else
        if confirm "要清理編譯容器嗎？（保留可加速未來重建）"; then
            cleanup_container
        fi
    fi
}

downgrade_container_pkg() {
    local pkg="$1"
    local target_ver="$2"
    local first_char="${pkg:0:1}"

    local current_ver
    current_ver=$(container_exec "pacman -Q $pkg 2>/dev/null | awk '{print \$2}'" || true)

    if [[ "$current_ver" == "$target_ver" ]]; then
        ok "$pkg 版本已匹配: $target_ver"
        return
    fi

    info "降級 $pkg: $current_ver -> $target_ver"
    local url="$ARCHIVE_BASE/$first_char/$pkg/$pkg-$target_ver-x86_64.pkg.tar.zst"

    container_exec "
        cd /tmp
        curl -fLO '$url' 2>&1 | tail -1
        pacman -U --noconfirm $pkg-$target_ver-x86_64.pkg.tar.zst 2>&1 | tail -3
    "
    ok "$pkg 已降級到 $target_ver"
}

# ── 核心: 更新字根表 ──────────────────────────────────────────────────────

do_update_table() {
    warn_steamos_version
    step "線上更新行列30字根表"

    check_fcitx5

    if [[ ! -f "$ARRAY_DB" ]]; then
        err "找不到 array.db — 請先執行 install"
        exit 1
    fi

    if ! command -v python3 &>/dev/null; then
        err "需要 python3 來轉換字根表"
        exit 1
    fi

    if ! command -v sqlite3 &>/dev/null; then
        err "需要 sqlite3"
        exit 1
    fi

    # 顯示目前狀態
    local current_count
    current_count=$(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM main;" 2>/dev/null)
    info "目前 array.db 主表筆數: $current_count"

    local ARRAY30_SOURCE_REF ARRAY30_MAIN_NAME ARRAY30_MAIN_URL
    local ARRAY30_SIMPLE_NAME ARRAY30_SIMPLE_URL
    local ARRAY30_PHRASE_NAME ARRAY30_PHRASE_PATH ARRAY30_PHRASE_URL

    info "解析官方字根表來源 ..."
    if ! eval "$(resolve_latest_array30_sources master)"; then
        err "無法取得 gontera/array30 的最新版 OpenVanilla 字根表清單"
        exit 1
    fi

    echo ""
    info "字根表來源: gontera/array30 (${ARRAY30_SOURCE_REF})"
    info "主表版本:   ${ARRAY30_MAIN_NAME}"
    info "簡碼版本:   ${ARRAY30_SIMPLE_NAME}"
    info "詞組來源:   ${ARRAY30_PHRASE_PATH}"
    echo ""

    # 取得最新 CIN
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    info "下載最新字根表 ..."
    if ! curl -fL "$ARRAY30_MAIN_URL" -o "$tmpdir/array30.cin" 2>/dev/null; then
        err "下載字根表失敗"
        exit 1
    fi
    ok "已下載 ${ARRAY30_MAIN_NAME}"

    info "下載簡碼表 ..."
    if ! curl -fL "$ARRAY30_SIMPLE_URL" -o "$tmpdir/simplecode.cin" 2>/dev/null; then
        warn "下載簡碼表失敗，跳過簡碼更新"
    else
        ok "已下載 ${ARRAY30_SIMPLE_NAME}"
    fi

    info "下載詞組表 ..."
    if ! curl -fL "$ARRAY30_PHRASE_URL" -o "$tmpdir/phrase.txt" 2>/dev/null; then
        warn "下載詞組表失敗（${ARRAY30_PHRASE_PATH}），跳過詞組更新"
    else
        ok "已下載 ${ARRAY30_PHRASE_NAME}"
    fi

    # 備份
    do_backup

    # 產生更新用的 Python 腳本
    cat > "$tmpdir/update_db.py" << 'PYEOF'
#!/usr/bin/env python3
"""Update array.db from CIN table files."""
import sqlite3
import sys
import os

# Region codes 對齊 ray2501/fcitx5-array data/cin2sqlite.py
# gontera OpenVanilla 標記名偶有變動（有/無 "Base"、Ext H/I/J），未知區段仍納入以免丟字。
REGION_MAP = {
    "CJK Unified Ideographs": 1,
    "CJK Unified Ideographs Base": 1,
    "Special Codes": 2,
    "Compatible Input Codes": 3,
    "CJK Unified Ideographs Extension A": 4,
    "CJK Unified Ideographs Extension B": 5,
    "CJK Unified Ideographs Extension C": 6,
    "CJK Unified Ideographs Extension D": 7,
    "CJK Unified Ideographs Extension E": 8,
    "CJK Unified Ideographs Extension F": 9,
    "CJK Unified Ideographs Extension G": 10,
    "CJK Unified Ideographs Extension H": 11,
    "CJK Unified Ideographs Extension I": 12,
    "CJK Unified Ideographs Extension J": 13,
    "CJK Symbols & Punctuation": 14,
    "CJK Symbols & Punctuation (w+0~9)": 14,
}

def update_main_table(db_path, cin_file):
    """Rebuild main table from CIN file."""
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM main;")

    region_stack = []
    count = 0
    next_unknown_cat = 100

    with open(cin_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            if line.startswith("# Begin of "):
                name = line[len("# Begin of "):]
                if name in REGION_MAP:
                    region_stack.append(REGION_MAP[name])
                else:
                    # 未知區段仍推進 stack，避免整段被跳過
                    region_stack.append(next_unknown_cat)
                    next_unknown_cat += 1
                continue

            if line.startswith("# End of "):
                if region_stack:
                    region_stack.pop()
                continue

            if line.startswith("#") or line.startswith("%"):
                continue

            parts = line.split()
            if len(parts) >= 2:
                keys, ch = parts[0], parts[1]
                # 上游偶有缺 Begin 標記（如 Ext J），區段外的對應列仍寫入，避免丟字
                cat = region_stack[-1] if region_stack else 1
                cur.execute(
                    "INSERT INTO main (keys, ch, cat, cnt) VALUES (?, ?, ?, 0)",
                    (keys, ch, cat),
                )
                count += 1

    con.commit()
    con.close()
    return count

def update_simple_table(db_path, cin_file):
    """Rebuild simple code table."""
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM simple;")

    count = 0
    with open(cin_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or line.startswith("%"):
                continue
            parts = line.split("\t") if "\t" in line else line.split()
            if len(parts) >= 2:
                cur.execute(
                    "INSERT INTO simple (keys, ch) VALUES (?, ?)",
                    (parts[0].lower(), parts[1].strip()),
                )
                count += 1

    con.commit()
    con.close()
    return count

def update_phrase_table(db_path, phrase_file):
    """Rebuild phrase table."""
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM phrase;")

    count = 0
    with open(phrase_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("|"):
                continue
            parts = line.split("\t")
            if len(parts) >= 2:
                cur.execute(
                    "INSERT INTO phrase (keys, ph) VALUES (?, ?)",
                    (parts[0].lower(), parts[1].strip()),
                )
                count += 1

    con.commit()
    con.close()
    return count

if __name__ == "__main__":
    db_path = sys.argv[1]
    cin_file = sys.argv[2] if len(sys.argv) > 2 else None
    simple_file = sys.argv[3] if len(sys.argv) > 3 else None
    phrase_file = sys.argv[4] if len(sys.argv) > 4 else None

    if cin_file and os.path.exists(cin_file):
        n = update_main_table(db_path, cin_file)
        print(f"main: {n} entries updated")

    if simple_file and os.path.exists(simple_file):
        n = update_simple_table(db_path, simple_file)
        print(f"simple: {n} entries updated")

    if phrase_file and os.path.exists(phrase_file):
        n = update_phrase_table(db_path, phrase_file)
        print(f"phrase: {n} entries updated")
PYEOF

    # 更新
    info "重建 array.db ..."
    cp "$ARRAY_DB" "$tmpdir/array.db"

    python3 "$tmpdir/update_db.py" \
        "$tmpdir/array.db" \
        "$tmpdir/array30.cin" \
        "$tmpdir/simplecode.cin" \
        "$tmpdir/phrase.txt"

    local new_count
    new_count=$(sqlite3 "$tmpdir/array.db" "SELECT count(*) FROM main;" 2>/dev/null)

    echo ""
    info "更新前主表筆數: $current_count"
    info "更新後主表筆數: $new_count"

    if [[ "$new_count" -lt 10000 ]]; then
        err "更新後資料筆數異常偏少 ($new_count)，中止安裝"
        err "原始 array.db 未被修改"
        exit 1
    fi

    # 主表明顯縮水時警告（常見原因：上游 CIN 區段標記變更導致解析漏字）
    if [[ -n "$current_count" && "$current_count" -gt 0 && "$new_count" -lt $((current_count * 95 / 100)) ]]; then
        warn "更新後主表筆數從 $current_count 降到 $new_count（少於 95%）"
        warn "若非預期，請選 N 取消，或之後執行 restore 還原備份"
        if ! confirm "仍要套用？"; then
            info "已取消（原始 array.db 未被修改）"
            return 0
        fi
    fi

    echo ""
    if confirm "確認要套用新的字根表嗎？"; then
        need_sudo
        check_readonly
        sudo cp "$tmpdir/array.db" "$ARRAY_DB"
        ok "字根表已更新"
        info "主表 $new_count / 簡碼 $(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM simple;" 2>/dev/null) / 詞組 $(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM phrase;" 2>/dev/null)"
        restart_fcitx5
    else
        info "已取消"
    fi
}

# ── 核心: 診斷 ────────────────────────────────────────────────────────────

do_diagnose() {
    step "fcitx5-array 診斷報告"
    echo ""

    # 系統資訊
    echo "【系統資訊】"
    local os_display
    if [[ "$OS_TYPE" == "steamos" ]] && [[ -n "$STEAMOS_VERSION" ]]; then
        os_display="SteamOS $STEAMOS_VERSION"
    else
        os_display="$(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    fi
    local fcitx5_ver_display
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        fcitx5_ver_display="$(LANG=C flatpak info org.fcitx.Fcitx5 2>/dev/null | awk '/Version:/{print $NF}' || echo 'not found') (Flatpak)"
    else
        fcitx5_ver_display="$(fcitx5 --version 2>/dev/null || echo 'not found')"
    fi
    echo "  OS:          $os_display"
    echo "  Kernel:      $(uname -r)"
    echo "  fcitx5:      $fcitx5_ver_display"
    echo "  array30工具: v$SCRIPT_VERSION (fcitx5-array $FCITX5_ARRAY_VER)"
    echo ""

    # 套件狀態
    echo "【套件狀態】"
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        echo "  fcitx5: $(flatpak list 2>/dev/null | awk '/^org\.fcitx\.Fcitx5[[:space:]]/{print $2" "$3}')"
        for addon in Chewing ChineseAddons McBopomofo Rime Array30; do
            if flatpak list 2>/dev/null | grep -q "org\.fcitx\.Fcitx5\.Addon\.$addon"; then
                echo "  Addon.$addon: 已安裝"
            fi
        done
        echo "  fcitx5-array (user): $([ -f "$ARRAY_SO" ] && echo "已安裝" || echo "未安裝")"
    else
        case "$OS_TYPE" in
            steamos|arch)
                for p in fcitx5 fcitx5-array fcitx5-table-extra fmt; do
                    local v
                    v=$(pacman -Q "$p" 2>/dev/null || echo "$p: 未安裝")
                    echo "  $v"
                done
                ;;
            ubuntu|debian)
                for p in fcitx5 fcitx5-table-array30 fcitx5-table-array30-large fcitx5-chewing; do
                    local v
                    v=$(pkg_get_version "$p")
                    echo "  $p: ${v:-未安裝}"
                done
                echo "  fcitx5-array (files): $([ -f "$ARRAY_SO" ] && echo "已安裝 ($ARRAY_SO)" || echo "未安裝")"
                local fmt_v
                fmt_v=$(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii[[:space:]]+libfmt[0-9]/{print $2" "$3}' | head -1)
                echo "  libfmt: ${fmt_v:-未安裝}"
                echo "  fcitx5-array (手動): $([ -f "$ARRAY_SO" ] && echo "已安裝" || echo "未安裝")"
                ;;
        esac
    fi
    echo ""

    # 檔案檢查
    echo "【關鍵檔案】"
    local addon_conf inputmethod_conf
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        addon_conf="${_FP_DATA}/fcitx5/addon/array.conf"
        inputmethod_conf="${_FP_DATA}/fcitx5/inputmethod/array.conf"
    else
        addon_conf="/usr/share/fcitx5/addon/array.conf"
        inputmethod_conf="/usr/share/fcitx5/inputmethod/array.conf"
    fi
    local files=("$ARRAY_SO" "$ARRAY_DB"
        "$ASSOC_SO"
        "$addon_conf"
        "$inputmethod_conf")
    for f in "${files[@]}"; do
        if [[ -f "$f" ]]; then
            echo -e "  ${GREEN}OK${NC}  $f ($(stat -c%s "$f" 2>/dev/null) bytes)"
        else
            echo -e "  ${RED}MISSING${NC}  $f"
        fi
    done
    echo ""

    # ABI 檢查
    echo "【ABI 相容性】"
    if [[ -f "$ARRAY_SO" ]]; then
        if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
            # Flatpak 模式：在 sandbox 內執行 ldd，因為 host 看不到 Flatpak runtime libs
            local missing
            missing=$(flatpak run --command=sh org.fcitx.Fcitx5 -c \
                "ldd \"$ARRAY_SO\" 2>&1 | grep 'not found'" 2>/dev/null || true)
            if [[ -n "$missing" ]]; then
                echo -e "  ${RED}FAIL${NC}  有缺失的動態連結庫（Flatpak sandbox）:"
                echo "$missing" | sed 's/^/    /'
            else
                echo -e "  ${GREEN}OK${NC}  所有動態連結庫都已找到（Flatpak sandbox）"
            fi
        else
            local missing
            missing=$(ldd "$ARRAY_SO" 2>&1 | grep "not found" || true)
            if [[ -n "$missing" ]]; then
                echo -e "  ${RED}FAIL${NC}  有缺失的動態連結庫:"
                echo "$missing" | sed 's/^/    /'
            else
                echo -e "  ${GREEN}OK${NC}  所有動態連結庫都已找到"
            fi

            # fmt 版本匹配：先 c++filt 解 mangle，再抓 fmt::vNN 的 NN
            local so_fmt_ver host_fmt_ver
            so_fmt_ver=$(nm -D "$ARRAY_SO" 2>/dev/null | c++filt | grep -oP 'fmt::v\K[0-9]+' | head -1 || true)
            # host libfmt.so 版本：從 soname 後綴取主版本號（libfmt.so.11.2.0 → 11）
            host_fmt_ver=$(ls /usr/lib/libfmt.so.*.*.* 2>/dev/null | grep -oE '\.([0-9]+)\.' | head -1 | tr -d '.' || true)
            if [[ -n "$so_fmt_ver" ]] && [[ -n "$host_fmt_ver" ]]; then
                if [[ "$so_fmt_ver" == "$host_fmt_ver" ]]; then
                    echo -e "  ${GREEN}OK${NC}  fmt 版本匹配: v$so_fmt_ver"
                else
                    echo -e "  ${RED}FAIL${NC}  fmt 版本不匹配: array.so 用 v$so_fmt_ver, host libfmt.so 主版本 $host_fmt_ver"
                    echo -e "  ${YELLOW}提示${NC}  執行 ./array30-setup.sh install 重新編譯"
                fi
            fi

            # fcitx5 API 版本資訊（僅供參考，不阻擋）
            # 注意：不能用 grep -q（set -o pipefail + grep -q 提前退出 → nm SIGPIPE → exit 141 → if 條件假）
            #       改用 grep "..." > /dev/null，讓 grep 讀完所有輸入才退出
            local host_uses_new_api="舊 API (StandardPath)"
            if nm -D /usr/lib/libFcitx5Utils.so 2>/dev/null | grep "_ZN5fcitx13StandardPaths6globalEv" > /dev/null; then
                host_uses_new_api="新 API (StandardPaths, fcitx5 ≥5.1.13)"
            fi
            local so_uses_api="舊 API (StandardPath)"
            if nm -D "$ARRAY_SO" 2>/dev/null | grep "_ZN5fcitx13StandardPaths" > /dev/null; then
                so_uses_api="新 API (StandardPaths)"
            fi
            echo -e "  ${BLUE}INFO${NC}  host fcitx5: $host_uses_new_api"
            echo -e "  ${BLUE}INFO${NC}  array.so:    $so_uses_api"
        fi
    else
        echo -e "  ${YELLOW}SKIP${NC}  array.so 不存在，跳過 ABI 檢查"
    fi
    echo ""

    # 字根表統計
    echo "【字根表統計】"
    if [[ -f "$ARRAY_DB" ]]; then
        echo "  主表 (main):   $(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM main;" 2>/dev/null) 筆"
        echo "  簡碼 (simple): $(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM simple;" 2>/dev/null) 筆"
        echo "  詞組 (phrase): $(sqlite3 "$ARRAY_DB" "SELECT count(*) FROM phrase;" 2>/dev/null) 筆"
    else
        echo -e "  ${YELLOW}SKIP${NC}  array.db 不存在"
    fi
    echo ""

    # Profile 檢查
    echo "【fcitx5 Profile】"
    if [[ -f "$FCITX5_PROFILE" ]]; then
        if grep -q "Name=array$" "$FCITX5_PROFILE"; then
            echo -e "  ${GREEN}OK${NC}  原生 array 已在 profile 中"
        else
            echo -e "  ${YELLOW}WARN${NC}  原生 array 不在 profile 中"
            echo "  提示: 用 fcitx5-configtool 或手動編輯 $FCITX5_PROFILE"
        fi
        if grep -q "Name=array30$" "$FCITX5_PROFILE"; then
            echo -e "  ${BLUE}INFO${NC}  table-based array30 也在 profile 中（可共存）"
        fi
    else
        echo -e "  ${YELLOW}WARN${NC}  找不到 fcitx5 profile"
    fi
    echo ""

    # 載入測試
    echo "【Addon 載入測試】"
    if verify_array_loaded_quiet; then
        echo -e "  ${GREEN}OK${NC}  array addon 載入成功"
    else
        echo -e "  ${RED}FAIL${NC}  array addon 載入失敗"
        echo "  最近的錯誤訊息:"
        grep -i "array\|Error\|Failed" /tmp/fcitx5-array-diag.log 2>/dev/null | grep -v wayland | sed 's/^/    /' | head -5
    fi
    echo ""

    # 備份狀態
    echo "【備份】"
    if [[ -d "$BACKUP_DIR" ]]; then
        local count
        count=$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "  備份數量: $count"
        echo "  備份位置: $BACKUP_DIR"
    else
        echo "  尚無備份"
    fi
}

# ── 核心: 移除 ────────────────────────────────────────────────────────────

do_uninstall() {
    step "移除 fcitx5-array"

    # 檢查是否已安裝
    local is_installed=false
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        [[ -f "$ARRAY_SO" ]] && is_installed=true
    else
        case "$OS_TYPE" in
            steamos|arch)
                pacman -Q fcitx5-array &>/dev/null && is_installed=true
                ;;
            ubuntu|debian)
                [[ -f "$ARRAY_SO" ]] && is_installed=true
                ;;
        esac
    fi

    if [[ "$is_installed" == "false" ]]; then
        warn "fcitx5-array 未安裝"
        exit 0
    fi

    info "將移除 fcitx5-array"
    info "table-based array30 不受影響"
    echo ""
    confirm "確認移除？" || exit 0

    do_backup
    check_readonly
    need_sudo
    pkg_remove_array

    # 將 profile 切回 array30
    if [[ -f "$FCITX5_PROFILE" ]]; then
        if grep -q "Name=array$" "$FCITX5_PROFILE"; then
            sed -i 's/^Name=array$/Name=array30/' "$FCITX5_PROFILE"
            info "已將 profile 中的 array 切換回 array30"
        fi
        if grep -q "DefaultIM=array$" "$FCITX5_PROFILE"; then
            sed -i 's/^DefaultIM=array$/DefaultIM=array30/' "$FCITX5_PROFILE"
        fi
    fi

    restart_fcitx5
    ok "fcitx5-array 已移除"
}

# ── 輔助 ──────────────────────────────────────────────────────────────────

# 偵測 host 是否仍裝有 table-based 行列套件 / profile 項目
_table_array30_present() {
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        return 1
    fi
    case "$OS_TYPE" in
        ubuntu|debian)
            dpkg -l fcitx5-table-array30 2>/dev/null | grep -q "^ii" && return 0
            dpkg -l fcitx5-table-array30-large 2>/dev/null | grep -q "^ii" && return 0
            ;;
        steamos|arch)
            pacman -Q fcitx5-table-extra &>/dev/null && return 0
            ;;
    esac
    if [[ -f "$FCITX5_PROFILE" ]] && grep -qE '^Name=array30(-large)?$' "$FCITX5_PROFILE"; then
        return 0
    fi
    return 1
}

# 移除 table-based 行列（套件 + profile），改由原生 array 承接
# $1 = "auto" 時略過 confirm（已在 install 成功後詢問過）
do_migrate_from_table() {
    step "從 table-based 行列遷移到原生 fcitx5-array"

    if [[ ! -f "$ARRAY_SO" ]]; then
        err "尚未安裝原生 array.so，請先執行 ./array30-setup.sh install"
        exit 1
    fi

    if ! _table_array30_present; then
        ok "未偵測到 table-based array30，無需遷移"
        return 0
    fi

    info "將會："
    info "  1. 從 fcitx5 profile 移除 array30 / array30-large"
    info "  2. 解除安裝 table 套件（保留原生 array 與 chewing）"
    info "  3. 重啟 fcitx5"
    echo ""
    if [[ "${1:-}" != "auto" ]]; then
        confirm "確認移除 table-based 行列？" || exit 0
    fi

    # profile 清理（先停 fcitx5，避免結束時回寫舊 profile）
    _stop_fcitx5
    if [[ -f "$FCITX5_PROFILE" ]]; then
        cp "$FCITX5_PROFILE" "$FCITX5_PROFILE.bak.migrate.$(date +%s)"
        _profile_remove_ims array30 array30-large
        if ! grep -q "^Name=array$" "$FCITX5_PROFILE"; then
            _profile_add_im "array"
        fi
        if grep -q "^DefaultIM=" "$FCITX5_PROFILE"; then
            sed -i 's/^DefaultIM=.*/DefaultIM=array/' "$FCITX5_PROFILE"
        fi
        ok "已自 profile 移除 table-based array30 / array30-large"
    fi

    # 套件移除
    case "$OS_TYPE" in
        ubuntu|debian)
            need_sudo
            local pkgs=()
            dpkg -l fcitx5-table-array30 2>/dev/null | grep -q "^ii" && pkgs+=(fcitx5-table-array30)
            dpkg -l fcitx5-table-array30-large 2>/dev/null | grep -q "^ii" && pkgs+=(fcitx5-table-array30-large)
            if [[ ${#pkgs[@]} -gt 0 ]]; then
                sudo apt-get remove -y "${pkgs[@]}" 2>&1 | tail -5
                ok "已移除套件: ${pkgs[*]}"
            fi
            ;;
        steamos|arch)
            warn "Arch/SteamOS 的 table 行列通常在 fcitx5-table-extra 內，不自動卸載整個套件"
            warn "請用 fcitx5-configtool 手動從清單移除 table 版行列（若仍顯示）"
            ;;
        *)
            warn "此平台未自動卸載 table 套件，請手動移除"
            ;;
    esac

    restart_fcitx5
    ok "table-based 行列已移除；預設輸入法為原生 array"
}

# 可選：提示使用者是否同時安裝新酷音（fcitx5-chewing）
_maybe_install_chewing() {
    local already_installed=false
    _has_chewing_installed && already_installed=true

    if $already_installed; then
        ok "新酷音 (fcitx5-chewing) 已安裝，將加入 profile"
        return
    fi

    echo ""
    info "偵測到新酷音 (fcitx5-chewing) 尚未安裝"
    if confirm "是否同時安裝新酷音？（可與行列30共用，按 Ctrl+Space 切換）"; then
        if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
            flatpak install -y flathub org.fcitx.Fcitx5.Addon.Chewing 2>&1 | tail -3
        else
            case "$OS_TYPE" in
                steamos|arch)
                    sudo pacman -S --noconfirm fcitx5-chewing
                    ;;
                ubuntu|debian)
                    sudo apt-get install -y fcitx5-chewing 2>&1 | tail -3
                    ;;
            esac
        fi
        ok "已安裝 fcitx5-chewing"
    fi
}

# 是否已安裝新酷音
_has_chewing_installed() {
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        flatpak list 2>/dev/null | grep -q "org\.fcitx\.Fcitx5\.Addon\.Chewing"
        return $?
    fi
    case "$OS_TYPE" in
        steamos|arch)
            pacman -Q fcitx5-chewing &>/dev/null
            ;;
        ubuntu|debian)
            dpkg -l fcitx5-chewing 2>/dev/null | grep -q "^ii"
            ;;
        *)
            return 1
            ;;
    esac
}

# 停止 fcitx5（結束時會回寫 profile，改 profile 前必須先停）
_stop_fcitx5() {
    # -x：只殺同名程序；先 TERM 再 KILL，避免殘留程序回寫舊 profile
    pkill -x fcitx5 2>/dev/null || true
    pkill -x fcitx5-bin 2>/dev/null || true
    pkill -f "fcitx5-array-wrapper.sh" 2>/dev/null || true
    sleep 1
    if pgrep -x fcitx5 >/dev/null 2>&1 || pgrep -x fcitx5-bin >/dev/null 2>&1; then
        pkill -9 -x fcitx5 2>/dev/null || true
        pkill -9 -x fcitx5-bin 2>/dev/null || true
        sleep 1
    fi
}

setup_profile() {
    step "設定 fcitx5 Profile"

    # fcitx5 結束時會把記憶體中的 profile 寫回磁碟；若在執行中改檔會被覆蓋
    _stop_fcitx5

    local has_chewing=false
    _has_chewing_installed && has_chewing=true

    # 如果 profile 不存在，直接建立
    if [[ ! -f "$FCITX5_PROFILE" ]]; then
        info "建立 fcitx5 profile（含 keyboard-us + array）"
        mkdir -p "$(dirname "$FCITX5_PROFILE")"
        _write_profile "$has_chewing"
        ok "已建立 profile 並加入 array"
        return
    fi

    # 備份 profile
    cp "$FCITX5_PROFILE" "$FCITX5_PROFILE.bak.$(date +%s)"

    # 確保 DefaultIM=array
    if grep -q "^DefaultIM=" "$FCITX5_PROFILE"; then
        sed -i 's/^DefaultIM=.*/DefaultIM=array/' "$FCITX5_PROFILE"
    else
        # 若 profile 裡沒有 DefaultIM（SteamOS 升級後可能遺失），補在 [Groups/0] section 下
        sed -i '/^\[Groups\/0\]/a # Default Input Method\nDefaultIM=array' "$FCITX5_PROFILE"
        info "補入 DefaultIM=array 到 profile"
    fi

    # 加入 array（若尚未存在）
    if ! grep -q "^Name=array$" "$FCITX5_PROFILE"; then
        _profile_add_im "array"
        ok "已將原生 array 加入 profile"
    else
        ok "原生 array 已在 profile 中"
    fi

    # 加入 chewing（若已安裝且尚未存在）
    if $has_chewing; then
        if ! grep -q "^Name=chewing$" "$FCITX5_PROFILE"; then
            _profile_add_im "chewing"
            ok "已將新酷音 (chewing) 加入 profile"
        else
            ok "chewing 已在 profile 中"
        fi
    fi
}

# 將指定輸入法名稱追加到 profile 的 Groups/0
_profile_add_im() {
    local im_name="$1"
    local max_idx
    max_idx=$(grep -oP 'Groups/0/Items/\K[0-9]+' "$FCITX5_PROFILE" | sort -n | tail -1)
    if [[ -n "$max_idx" ]]; then
        local new_idx=$((max_idx + 1))
        sed -i "/^\[GroupOrder\]/i\\
[Groups/0/Items/$new_idx]\\
# Name\\
Name=$im_name\\
# Layout\\
Layout=\\
" "$FCITX5_PROFILE"
    else
        warn "無法自動修改 profile，請用 fcitx5-configtool 手動新增 $im_name"
    fi
}

# 從 profile 移除指定 IM 名稱（可傳多個），並重編號 Groups/0/Items
# 用法: _profile_remove_ims array30 array30-large
_profile_remove_ims() {
    [[ ! -f "$FCITX5_PROFILE" ]] && return 0
    [[ $# -eq 0 ]] && return 0

    python3 - "$FCITX5_PROFILE" "$@" <<'PY'
import re, sys
path = sys.argv[1]
remove = set(sys.argv[2:])
text = open(path, encoding="utf-8").read()

# Split into sections preserving order. Item sections match [Groups/0/Items/N]
parts = re.split(r'(?=^\[)', text, flags=re.M)
kept = []
items = []  # list of full item section texts we keep
other_after_items = []
seen_item = False
finished_items = False

for p in parts:
    if not p.strip():
        continue
    if re.match(r'^\[Groups/0/Items/\d+\]', p):
        seen_item = True
        m = re.search(r'^Name=(.+)$', p, re.M)
        name = m.group(1).strip() if m else ""
        if name not in remove:
            items.append(p if p.endswith("\n") else p + "\n")
        continue
    if seen_item and not finished_items:
        # first non-item section after items (e.g. [GroupOrder])
        finished_items = True
        other_after_items.append(p if p.endswith("\n") else p + "\n")
        continue
    if finished_items:
        other_after_items.append(p if p.endswith("\n") else p + "\n")
    else:
        kept.append(p if p.endswith("\n") else p + "\n")

# Reindex kept items
reindexed = []
for i, sec in enumerate(items):
    sec = re.sub(r'^\[Groups/0/Items/\d+\]', f'[Groups/0/Items/{i}]', sec, count=1, flags=re.M)
    if not sec.endswith("\n"):
        sec += "\n"
    if not sec.endswith("\n\n") and not sec.rstrip("\n").endswith("Layout="):
        pass
    # ensure trailing blank line between items
    if not sec.endswith("\n\n"):
        sec = sec.rstrip("\n") + "\n\n"
    reindexed.append(sec)

out = "".join(kept) + "".join(reindexed) + "".join(other_after_items)
# Normalize DefaultIM if it pointed at a removed IM
for name in remove:
    out = re.sub(rf'^DefaultIM={re.escape(name)}\s*$', 'DefaultIM=array', out, flags=re.M)
open(path, "w", encoding="utf-8").write(out)
PY
}

# 從頭寫出完整 profile
_write_profile() {
    local has_chewing="$1"
    local chewing_block=""
    if $has_chewing; then
        chewing_block=$'\n[Groups/0/Items/2]\n# Name\nName=chewing\n# Layout\nLayout=\n'
    fi
    cat > "$FCITX5_PROFILE" << PROFEOF
[Groups/0]
# Group Name
Name=預設
# Layout
Default Layout=us
# Default Input Method
DefaultIM=array

[Groups/0/Items/0]
# Name
Name=keyboard-us
# Layout
Layout=

[Groups/0/Items/1]
# Name
Name=array
# Layout
Layout=
${chewing_block}
[GroupOrder]
0=預設
PROFEOF
}

setup_autostart() {
    step "設定開機自動啟動"

    # 建立 wrapper 腳本：啟動 fcitx5 後等待 array addon 載入再切換
    mkdir -p "$(dirname "$FCITX5_WRAPPER")"
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        local fp_wrapper_path="${_FP_DATA}/fcitx5/bin/fcitx5-array-wrapper.sh"
        cat > "$FCITX5_WRAPPER" << WRAPEOF
#!/bin/bash
# 啟動 Flatpak fcitx5（透過 addon wrapper 確保 array.so 可被找到）並切換到行列30
flatpak run --command=${fp_wrapper_path} org.fcitx.Fcitx5 -rd &

# 等待 array addon 載入（最多 10 秒）
for i in \$(seq 1 50); do
    if flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -s array 2>/dev/null && \\
       [ "\$(flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -n 2>/dev/null)" = "array" ]; then
        break
    fi
    sleep 0.2
done
WRAPEOF
    else
        cat > "$FCITX5_WRAPPER" << 'WRAPEOF'
#!/bin/bash
# 啟動 fcitx5 並確保切換到行列30輸入法
fcitx5 -rd

# 等待 array addon 載入（最多 10 秒）
for i in $(seq 1 50); do
    if fcitx5-remote -s array 2>/dev/null && [ "$(fcitx5-remote -n 2>/dev/null)" = "array" ]; then
        break
    fi
    sleep 0.2
done
WRAPEOF
    fi
    chmod +x "$FCITX5_WRAPPER"
    ok "已建立 $FCITX5_WRAPPER"

    # 建立或更新 autostart .desktop
    mkdir -p "$(dirname "$FCITX5_AUTOSTART")"
    if [[ -f "$FCITX5_AUTOSTART" ]]; then
        # 只更新 Exec 行
        sed -i "s|^Exec=.*|Exec=$FCITX5_WRAPPER|" "$FCITX5_AUTOSTART"
        ok "已更新 autostart Exec -> $FCITX5_WRAPPER"
    else
        cat > "$FCITX5_AUTOSTART" << DESKTOPEOF
[Desktop Entry]
Name=Fcitx 5
GenericName=Input Method
Comment=Start Input Method
Exec=$FCITX5_WRAPPER
Icon=fcitx5
Terminal=false
Type=Application
Categories=System;Utility;
StartupNotify=false
X-KDE-autostart-after=panel
Hidden=false
DESKTOPEOF
        ok "已建立 autostart .desktop"
    fi
}

restart_fcitx5() {
    step "重啟 fcitx5"
    # 用 _stop_fcitx5 徹底停止，避免殘留行程在我們改完 profile 後又回寫舊設定
    _stop_fcitx5
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        flatpak run --command="$_FP_WRAPPER" org.fcitx.Fcitx5 -rd &>/dev/null &
    elif [[ -x "$FCITX5_WRAPPER" ]]; then
        bash "$FCITX5_WRAPPER" &>/dev/null &
    else
        fcitx5 -rd &>/dev/null &
    fi
    disown
    sleep 2
    ok "fcitx5 已重啟"
}

verify_array_loaded() {
    # 不在此處 pkill：避免把已寫好的 profile 用舊狀態蓋掉。
    # 若 fcitx5 未在跑則啟動；已在跑則只做切換與 log 檢查。
    if ! pgrep -x fcitx5 >/dev/null 2>&1 && ! pgrep -x fcitx5-bin >/dev/null 2>&1; then
        if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
            flatpak run --command="$_FP_WRAPPER" --env=FCITX_LOG=default=5 org.fcitx.Fcitx5 -rd &>/tmp/fcitx5-array-verify.log &
        else
            FCITX_LOG=default=5 fcitx5 -rd &>/tmp/fcitx5-array-verify.log &
        fi
        disown
        sleep 2
    else
        # 已在跑：用 remote 觸發 OnDemand 載入；日誌可能不完整，輔以 fcitx5-remote -n
        : > /tmp/fcitx5-array-verify.log
    fi
    # array 是 OnDemand addon，必須切換到它才會觸發載入
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -s array 2>/dev/null || true
    else
        fcitx5-remote -s array 2>/dev/null || true
    fi
    sleep 2

    if grep "Loaded addon array" /tmp/fcitx5-array-verify.log > /dev/null 2>&1; then
        ok "array addon 載入成功"
        if grep "found array.db" /tmp/fcitx5-array-verify.log > /dev/null 2>&1; then
            ok "array.db 讀取正常"
        fi
        return 0
    fi

    # 後備：若 log 無「Loaded」（例如先前已載入、或未用 FCITX_LOG 啟動），用 remote 確認
    local cur
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        cur=$(flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -n 2>/dev/null || true)
    else
        cur=$(fcitx5-remote -n 2>/dev/null || true)
    fi
    if [[ "$cur" == "array" ]]; then
        ok "array addon 載入成功（fcitx5-remote -n = array）"
        return 0
    fi

    local error
    error=$(grep -i "Failed.*array\|Could not load addon array\|undefined symbol" /tmp/fcitx5-array-verify.log 2>/dev/null || true)
    if [[ -n "$error" ]]; then
        err "$error"
    fi
    return 1
}

verify_array_loaded_quiet() {
    if ! pgrep -x fcitx5 >/dev/null 2>&1 && ! pgrep -x fcitx5-bin >/dev/null 2>&1; then
        if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
            flatpak run --command="$_FP_WRAPPER" --env=FCITX_LOG=default=5 org.fcitx.Fcitx5 -rd &>/tmp/fcitx5-array-diag.log &
        else
            FCITX_LOG=default=5 fcitx5 -rd &>/tmp/fcitx5-array-diag.log &
        fi
        disown
        sleep 2
    fi
    # array 是 OnDemand addon，必須切換到它才會觸發載入
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -s array 2>/dev/null || true
    else
        fcitx5-remote -s array 2>/dev/null || true
    fi
    sleep 2
    if grep "Loaded addon array" /tmp/fcitx5-array-diag.log > /dev/null 2>&1; then
        return 0
    fi
    local cur
    if [[ "$FCITX5_INSTALL_TYPE" == "flatpak" ]]; then
        cur=$(flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -n 2>/dev/null || true)
    else
        cur=$(fcitx5-remote -n 2>/dev/null || true)
    fi
    [[ "$cur" == "array" ]]
}

# ── 主程式 ────────────────────────────────────────────────────────────────

show_help() {
    cat << EOF
行列30輸入法安裝工具 (fcitx5-array)
支援平台: SteamOS (Steam Deck) / Ubuntu 24.04 / 22.04 / Pop!_OS 24.04 / CachyOS / Arch

用法: ./array30-setup.sh <command>

Commands:
  install             首次安裝或重建 fcitx5-array
                      在 Podman/Docker 容器中編譯（Arch 則本機 makepkg），自動匹配 host ABI
                      成功後可選擇移除 table-based array30

  update-table        線上更新行列30字根表
                      從 gontera/array30 自動解析最新版 v2026 OpenVanilla CIN 並重建 array.db
                      支援主表、簡碼、詞組三合一更新

  diagnose            診斷目前安裝狀態
                      檢查套件、檔案、ABI、字根表、Profile 及 addon 載入

  migrate-from-table  移除 table-based array30 / array30-large，只保留原生 array
                      （需已完成 install 且 addon 可載入）

  uninstall           移除 fcitx5-array 並切回 table-based array30

  backup              手動備份目前的 array.db 和 array.so

  restore             從備份還原 array.db 和 array.so

  help                顯示此說明

行列30 vs table-based array30:
  原生 fcitx5-array 支援：
    - W+數字鍵 符號輸入（接近 Windows 行列體驗）
    - 一級/二級簡碼
    - 萬用字元查詢（? 和 *）
    - 詞組輸入
    - 聯想詞
    - 反查碼（Ctrl+Alt+E）

  table-based array30 (fcitx5-table-array30):
    - 基本行列輸入
    - 不支援上述進階功能

Version: v${SCRIPT_VERSION}
License: GPL-2.0-or-later
EOF
}

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        install)             do_install ;;
        update-table)        do_update_table ;;
        diagnose)            do_diagnose ;;
        migrate-from-table)  do_migrate_from_table ;;
        uninstall)           do_uninstall ;;
        backup)              do_backup ;;
        restore)             do_restore ;;
        help|--help|-h)      show_help ;;
        *)
            err "未知的命令: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
