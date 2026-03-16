#!/usr/bin/env bash
# ============================================================================
# array30-setup.sh — 行列30輸入法安裝工具 (fcitx5-array)
# https://github.com/tern/steamdeck-array30
#
# 支援平台:
#   - SteamOS (Steam Deck Desktop Mode)
#   - Ubuntu 24.04 / 22.04 Desktop
#
# 透過容器（Podman 或 Docker）編譯 fcitx5-array，
# 自動匹配 host ABI（fcitx5 + fmt 版本），取代功能陽春的 table-based array30。
#
# 用法:
#   ./array30-setup.sh install        # 首次安裝（編譯 + 安裝）
#   ./array30-setup.sh update-table   # 線上更新行列30字根表
#   ./array30-setup.sh diagnose       # 診斷目前安裝狀態
#   ./array30-setup.sh uninstall      # 移除 fcitx5-array
#   ./array30-setup.sh backup         # 手動備份目前的 array.db
#   ./array30-setup.sh restore        # 從備份還原 array.db
#
# 授權: GPL-2.0-or-later
# ============================================================================

set -euo pipefail

# ── 常數 ────────────────────────────────────────────────────────────────────
SCRIPT_VERSION="1.0.0"
CONTAINER_NAME="array30-builder"
CONTAINER_IMAGE="docker.io/library/archlinux:latest"
ARCHIVE_BASE="https://archive.archlinux.org/packages"

# 上游來源
FCITX5_ARRAY_AUR="https://aur.archlinux.org/fcitx5-array.git"
FCITX5_ARRAY_GITHUB="https://github.com/ray2501/fcitx5-array"
ARRAY30_CIN_REPO="https://github.com/gontera/array30"
ARRAY30_CIN_RAW="https://raw.githubusercontent.com/gontera/array30/master"

# Host 路徑
ARRAY_DB="/usr/share/fcitx5/array/array.db"
ARRAY_SO="/usr/lib/fcitx5/array.so"
BACKUP_DIR="$HOME/.local/share/fcitx5-array-backup"
FCITX5_PROFILE="$HOME/.config/fcitx5/profile"

# ── OS / 容器工具偵測（早期執行）──────────────────────────────────────────

detect_os() {
    if [[ -f /etc/os-release ]]; then
        local id
        id=$(grep -oP '^ID=\K.*' /etc/os-release | tr -d '"')
        local id_like
        id_like=$(grep -oP '^ID_LIKE=\K.*' /etc/os-release 2>/dev/null | tr -d '"' || true)
        case "$id" in
            steamos) echo "steamos" ;;
            ubuntu)  echo "ubuntu" ;;
            debian)  echo "debian" ;;
            *)
                if echo "$id_like" | grep -q "ubuntu\|debian"; then
                    echo "debian"
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

OS_TYPE=$(detect_os)
CONTAINER_RUNTIME=$(detect_container_runtime)

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

# ── 套件管理抽象層 ────────────────────────────────────────────────────────

# 取得 host 上指定套件的版本字串（跨 OS）
pkg_get_version() {
    local pkg="$1"
    case "$OS_TYPE" in
        steamos)
            pacman -Q "$pkg" 2>/dev/null | awk '{print $2}'
            ;;
        ubuntu|debian)
            dpkg -l "$pkg" 2>/dev/null | awk '/^ii/{print $3}' | head -1
            ;;
    esac
}

# Ubuntu: 從 dpkg 版本字串提取純 semver（去掉 Ubuntu/Debian 後綴）
# e.g. "9.1.0+ds1-2" → "9.1.0" / "5.1.7-1build3" → "5.1.7"
strip_semver() {
    echo "$1" | sed 's/+.*//' | sed 's/-[0-9]*build.*//' | sed 's/-[0-9]*$//'
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
        if curl -fsI "$url" &>/dev/null; then
            echo "$ver"
            return 0
        fi
    done
    return 1
}

# 安裝編譯好的 .so / 資料檔到 host（跨 OS）
pkg_install_array() {
    case "$OS_TYPE" in
        steamos)
            # SteamOS: 直接 pacman -U 安裝整個 .pkg.tar.zst
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
    case "$OS_TYPE" in
        steamos)
            sudo pacman -R --noconfirm fcitx5-array
            ;;
        ubuntu|debian)
            info "移除手動安裝的 fcitx5-array 檔案..."
            sudo rm -f "$ARRAY_SO"
            sudo rm -f "$ARRAY_DB"
            sudo rm -f /usr/share/fcitx5/addon/array.conf
            sudo rm -f /usr/share/fcitx5/inputmethod/array.conf
            sudo rm -f /usr/lib/fcitx5/libassociation.so 2>/dev/null || true
            ok "已移除 fcitx5-array 相關檔案"
            ;;
    esac
}

# ── 前置檢查 ──────────────────────────────────────────────────────────────

check_platform() {
    case "$OS_TYPE" in
        steamos)
            ok "偵測到 SteamOS (Steam Deck)"
            ;;
        ubuntu)
            ok "偵測到 Ubuntu Desktop"
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
    if [[ -z "$CONTAINER_RUNTIME" ]]; then
        err "找不到容器工具（Podman 或 Docker）"
        case "$OS_TYPE" in
            steamos)
                err "請確認你在 Desktop Mode 下執行（SteamOS 應已內建 Podman）"
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

check_fcitx5() {
    if ! command -v fcitx5 &>/dev/null; then
        err "找不到 fcitx5，請先安裝 fcitx5 輸入法框架"
        case "$OS_TYPE" in
            ubuntu|debian)
                err "  sudo apt install fcitx5 fcitx5-chinese-addons"
                ;;
        esac
        exit 1
    fi
}

check_readonly() {
    # 只有 SteamOS 需要解除唯讀
    [[ "$OS_TYPE" != "steamos" ]] && return 0

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
    case "$OS_TYPE" in
        steamos)
            HOST_FCITX5_VER=$(pkg_get_version fcitx5)
            HOST_FMT_VER=$(pkg_get_version fmt)
            ;;
        ubuntu|debian)
            local fcitx5_raw fmt_raw
            fcitx5_raw=$(pkg_get_version fcitx5)
            # Ubuntu fmt 套件名稱含版本號（libfmt9、libfmt10…）
            fmt_raw=$(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii\s+libfmt[0-9]/{print $3}' | head -1)
            HOST_FCITX5_VER=$(strip_semver "$fcitx5_raw")
            HOST_FMT_VER=$(strip_semver "$fmt_raw")
            ;;
    esac

    if [[ -z "$HOST_FCITX5_VER" ]]; then
        err "找不到 fcitx5 版本，請確認 fcitx5 已安裝"
        exit 1
    fi
    if [[ -z "$HOST_FMT_VER" ]]; then
        err "找不到 libfmt 版本，請確認 fcitx5 相依套件已安裝"
        case "$OS_TYPE" in
            ubuntu|debian) err "  sudo apt install libfmt-dev" ;;
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

    # 在容器內解壓縮 .pkg.tar.zst
    container_exec "
        mkdir -p /tmp/pkg-extract
        cd /tmp/pkg-extract
        tar -I zstd -xf /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst 2>/dev/null \
            || tar --use-compress-program=zstd -xf /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst
    "

    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" RETURN

    # 從容器複製需要的檔案到本地暫存
    local files_ok=0
    for src_path in \
        "usr/lib/fcitx5/array.so" \
        "usr/share/fcitx5/array/array.db" \
        "usr/share/fcitx5/addon/array.conf" \
        "usr/share/fcitx5/inputmethod/array.conf" \
        "usr/lib/fcitx5/libassociation.so"
    do
        $CONTAINER_RUNTIME cp "$CONTAINER_NAME:/tmp/pkg-extract/$src_path" "$tmpdir/$(basename $src_path)" 2>/dev/null && \
            files_ok=$((files_ok+1)) || true
    done

    if [[ $files_ok -lt 2 ]]; then
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
    [[ -f "$tmpdir/array.so" ]]          && sudo cp "$tmpdir/array.so"          "$ARRAY_SO"
    [[ -f "$tmpdir/array.db" ]]          && sudo cp "$tmpdir/array.db"          "$ARRAY_DB"
    [[ -f "$tmpdir/array.conf" ]]        && sudo cp "$tmpdir/array.conf"        /usr/share/fcitx5/addon/array.conf
    [[ -f "$tmpdir/libassociation.so" ]] && sudo cp "$tmpdir/libassociation.so" /usr/lib/fcitx5/libassociation.so

    # inputmethod/array.conf 可能跟 addon/array.conf 同名，特別處理
    container_exec "ls /tmp/pkg-extract/usr/share/fcitx5/inputmethod/ 2>/dev/null" | grep -q "array" && \
        $CONTAINER_RUNTIME cp "$CONTAINER_NAME:/tmp/pkg-extract/usr/share/fcitx5/inputmethod/array.conf" \
            "$tmpdir/inputmethod-array.conf" 2>/dev/null && \
        sudo cp "$tmpdir/inputmethod-array.conf" /usr/share/fcitx5/inputmethod/array.conf || true

    ok "fcitx5-array 檔案已安裝到 host"
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
        steamos)
            pacman -Q fcitx5-array 2>/dev/null > "$bak/pkg-version.txt" || echo "not installed" > "$bak/pkg-version.txt"
            pacman -Q fcitx5 fmt 2>/dev/null >> "$bak/pkg-version.txt"
            ;;
        ubuntu|debian)
            echo "fcitx5: $(pkg_get_version fcitx5)" > "$bak/pkg-version.txt"
            echo "libfmt: $(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii\s+libfmt[0-9]/{print $3}' | head -1)" >> "$bak/pkg-version.txt"
            echo "array.so: $([ -f "$ARRAY_SO" ] && echo "installed" || echo "not installed")" >> "$bak/pkg-version.txt"
            ;;
    esac

    ok "備份完成: $bak"
    echo "$ts" > "$BACKUP_DIR/latest"
}

do_restore() {
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
    step "行列30 (fcitx5-array) 安裝程序"
    echo ""
    info "此腳本將:"
    info "  1. 在容器（$CONTAINER_RUNTIME）中編譯 fcitx5-array"
    info "  2. 確保 ABI 相容性（降級容器內依賴以匹配 host）"
    info "  3. 安裝編譯成果到 host"
    info "  4. 設定 fcitx5 使用原生行列30引擎"
    echo ""

    # 前置檢查
    check_platform
    check_container_runtime
    check_fcitx5
    get_host_versions

    # Ubuntu: 將 host 版本對應到 Arch Archive 版本
    local ARCH_FCITX5_VER ARCH_FMT_VER
    case "$OS_TYPE" in
        steamos)
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

    echo ""
    confirm "開始安裝？" || exit 0

    # 備份現有安裝
    if [[ -f "$ARRAY_SO" ]] || [[ -f "$ARRAY_DB" ]]; then
        do_backup
    fi

    # 建立容器
    step "準備編譯容器"
    ensure_container

    info "安裝編譯工具 ..."
    container_exec "pacman -Syu --noconfirm 2>&1 | tail -3"
    container_exec "pacman -S --noconfirm --needed base-devel git cmake extra-cmake-modules sqlite gettext fmt fcitx5 2>&1 | tail -3"
    ok "編譯工具就緒"

    # 降級容器依賴
    step "降級容器依賴以匹配 host ABI"
    downgrade_container_pkg "fcitx5" "$ARCH_FCITX5_VER"
    downgrade_container_pkg "fmt" "$ARCH_FMT_VER"

    # 編譯
    step "編譯 fcitx5-array"
    info "從 AUR 取得 PKGBUILD ..."
    container_exec "
        cd /tmp
        rm -rf fcitx5-array
        git clone $FCITX5_ARRAY_AUR 2>&1 | tail -1
    "

    info "執行 makepkg ..."
    container_exec "
        cd /tmp/fcitx5-array
        useradd -m builder 2>/dev/null || true
        chown -R builder:builder /tmp/fcitx5-array
        su - builder -c 'cd /tmp/fcitx5-array && makepkg -sf --noconfirm' 2>&1 | tail -5
    "

    # ABI 驗證
    step "驗證 ABI 相容性"
    local symbols
    symbols=$(container_exec "nm -D /tmp/fcitx5-array/pkg/fcitx5-array/usr/lib/fcitx5/array.so 2>/dev/null | grep ' U ' | grep -E 'StandardPath|vformat'" || true)

    if echo "$symbols" | grep -q "StandardPaths"; then
        err "ABI 不相容: array.so 引用了 StandardPaths (複數)"
        err "host 的 fcitx5 使用 StandardPath (單數)"
        err "請回報此問題"
        exit 1
    fi
    ok "ABI 驗證通過"

    # 安裝到 host
    step "安裝到 host"
    check_readonly
    need_sudo

    local pkg_file
    pkg_file=$(container_exec "ls /tmp/fcitx5-array/fcitx5-array-*-any.pkg.tar.zst 2>/dev/null | head -1")
    if [[ -z "$pkg_file" ]]; then
        err "找不到編譯產出的 .pkg.tar.zst 檔案"
        exit 1
    fi

    case "$OS_TYPE" in
        steamos)
            $CONTAINER_RUNTIME cp "$CONTAINER_NAME:$pkg_file" /tmp/fcitx5-array-latest.pkg.tar.zst
            sudo pacman -U --noconfirm /tmp/fcitx5-array-latest.pkg.tar.zst
            ok "套件已安裝（pacman）"
            ;;
        ubuntu|debian)
            ubuntu_install_files
            ;;
    esac

    # 設定 fcitx5 profile
    setup_profile

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

    # 清理
    echo ""
    if confirm "要清理編譯容器嗎？（保留可加速未來重建）"; then
        cleanup_container
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

    echo ""
    info "字根表來源: gontera/array30 (官方行列30字根表)"
    info "引擎來源:   ray2501/fcitx5-array"
    echo ""

    # 取得最新 CIN
    local tmpdir
    tmpdir=$(mktemp -d)
    trap "rm -rf $tmpdir" EXIT

    info "下載最新字根表 ..."
    if ! curl -fL "$ARRAY30_CIN_RAW/array30-OpenVanilla-big.cin" -o "$tmpdir/array30.cin" 2>/dev/null; then
        err "下載字根表失敗"
        exit 1
    fi
    ok "已下載 array30-OpenVanilla-big.cin"

    info "下載簡碼表 ..."
    if ! curl -fL "$ARRAY30_CIN_RAW/array30_simplecode.cin" -o "$tmpdir/simplecode.cin" 2>/dev/null; then
        warn "下載簡碼表失敗，跳過簡碼更新"
    else
        ok "已下載 array30_simplecode.cin"
    fi

    info "下載詞組表 ..."
    if ! curl -fL "${FCITX5_ARRAY_GITHUB}/raw/master/data/array30-phrase-20210725.txt" -o "$tmpdir/phrase.txt" 2>/dev/null; then
        warn "下載詞組表失敗，跳過詞組更新"
    else
        ok "已下載 array30-phrase.txt"
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

REGION_MAP = {
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
    "CJK Symbols & Punctuation (w+0~9)": 11,
}

def update_main_table(db_path, cin_file):
    """Rebuild main table from CIN file."""
    con = sqlite3.connect(db_path)
    cur = con.cursor()
    cur.execute("DELETE FROM main;")

    region_stack = []
    count = 0

    with open(cin_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue

            # Check region markers
            matched = False
            for name, code in REGION_MAP.items():
                if line == f"# Begin of {name}":
                    region_stack.append(code)
                    matched = True
                    break
                elif line == f"# End of {name}":
                    if region_stack:
                        region_stack.pop()
                    matched = True
                    break

            if matched or not region_stack:
                continue

            if line.startswith("#") or line.startswith("%"):
                continue

            parts = line.split()
            if len(parts) >= 2:
                keys, ch = parts[0], parts[1]
                cat = region_stack[-1]
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

    echo ""
    if confirm "確認要套用新的字根表嗎？"; then
        need_sudo
        check_readonly
        sudo cp "$tmpdir/array.db" "$ARRAY_DB"
        ok "字根表已更新"
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
    echo "  OS:       $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"')"
    echo "  Kernel:   $(uname -r)"
    echo "  fcitx5:   $(fcitx5 --version 2>/dev/null || echo 'not found')"
    echo ""

    # 套件狀態
    echo "【套件狀態】"
    case "$OS_TYPE" in
        steamos)
            for p in fcitx5 fcitx5-array fcitx5-table-extra fmt; do
                local v
                v=$(pacman -Q "$p" 2>/dev/null || echo "$p: 未安裝")
                echo "  $v"
            done
            ;;
        ubuntu|debian)
            for p in fcitx5 fcitx5-table-array30; do
                local v
                v=$(pkg_get_version "$p")
                echo "  $p: ${v:-未安裝}"
            done
            local fmt_v
            fmt_v=$(dpkg -l 'libfmt*' 2>/dev/null | awk '/^ii\s+libfmt[0-9]/{print $2" "$3}' | head -1)
            echo "  libfmt: ${fmt_v:-未安裝}"
            echo "  fcitx5-array (手動): $([ -f "$ARRAY_SO" ] && echo "已安裝" || echo "未安裝")"
            ;;
    esac
    echo ""

    # 檔案檢查
    echo "【關鍵檔案】"
    local files=("$ARRAY_SO" "$ARRAY_DB"
        "/usr/lib/fcitx5/libassociation.so"
        "/usr/share/fcitx5/addon/array.conf"
        "/usr/share/fcitx5/inputmethod/array.conf")
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
        local missing
        missing=$(ldd "$ARRAY_SO" 2>&1 | grep "not found" || true)
        if [[ -n "$missing" ]]; then
            echo -e "  ${RED}FAIL${NC}  有缺失的動態連結庫:"
            echo "$missing" | sed 's/^/    /'
        else
            echo -e "  ${GREEN}OK${NC}  所有動態連結庫都已找到"
        fi

        # Symbol 檢查
        local undef
        undef=$(nm -D "$ARRAY_SO" 2>/dev/null | grep " U " | grep -E "StandardPaths|fmt::v[0-9]" || true)
        if echo "$undef" | grep -q "StandardPaths"; then
            echo -e "  ${RED}FAIL${NC}  引用了 StandardPaths (host 使用 StandardPath)"
        fi

        # 檢查 fmt 版本匹配
        local so_fmt_ver host_fmt_ver
        so_fmt_ver=$(nm -D "$ARRAY_SO" 2>/dev/null | grep -oP 'fmt::v\K[0-9]+' | head -1 || true)
        host_fmt_ver=$(nm -D /usr/lib/libfmt.so 2>/dev/null | grep -oP 'fmt::v\K[0-9]+' | head -1 || true)
        if [[ -n "$so_fmt_ver" ]] && [[ -n "$host_fmt_ver" ]]; then
            if [[ "$so_fmt_ver" == "$host_fmt_ver" ]]; then
                echo -e "  ${GREEN}OK${NC}  fmt 版本匹配: v$so_fmt_ver"
            else
                echo -e "  ${RED}FAIL${NC}  fmt 版本不匹配: array.so 用 v$so_fmt_ver, host 有 v$host_fmt_ver"
            fi
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
    case "$OS_TYPE" in
        steamos)
            pacman -Q fcitx5-array &>/dev/null && is_installed=true
            ;;
        ubuntu|debian)
            [[ -f "$ARRAY_SO" ]] && is_installed=true
            ;;
    esac

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

setup_profile() {
    step "設定 fcitx5 Profile"

    if [[ ! -f "$FCITX5_PROFILE" ]]; then
        warn "找不到 fcitx5 profile，請用 fcitx5-configtool 手動新增 Array 輸入法"
        return
    fi

    # 備份 profile
    cp "$FCITX5_PROFILE" "$FCITX5_PROFILE.bak.$(date +%s)"

    # 檢查是否已有 array (native)
    if grep -q "Name=array$" "$FCITX5_PROFILE"; then
        ok "原生 array 已在 profile 中"
        return
    fi

    # 在 profile 中加入 array
    # 找到最後一個 Items 編號並加 1
    local max_idx
    max_idx=$(grep -oP 'Groups/0/Items/\K[0-9]+' "$FCITX5_PROFILE" | sort -n | tail -1)

    if [[ -n "$max_idx" ]]; then
        local new_idx=$((max_idx + 1))
        # 在 [GroupOrder] 前插入
        sed -i "/^\[GroupOrder\]/i\\
[Groups/0/Items/$new_idx]\\
# Name\\
Name=array\\
# Layout\\
Layout=\\
" "$FCITX5_PROFILE"
        ok "已將原生 array 加入 profile (Items/$new_idx)"
    else
        warn "無法自動修改 profile，請用 fcitx5-configtool 手動新增"
    fi
}

restart_fcitx5() {
    step "重啟 fcitx5"
    pkill fcitx5 2>/dev/null || true
    sleep 1
    fcitx5 -rd &>/dev/null &
    disown
    sleep 2
    ok "fcitx5 已重啟"
}

verify_array_loaded() {
    pkill fcitx5 2>/dev/null || true
    sleep 1
    FCITX_LOG=default=5 fcitx5 -rd &>/tmp/fcitx5-array-verify.log &
    disown
    sleep 3

    if grep -q "Loaded addon array" /tmp/fcitx5-array-verify.log 2>/dev/null; then
        ok "array addon 載入成功"
        if grep -q "found array.db" /tmp/fcitx5-array-verify.log 2>/dev/null; then
            ok "array.db 讀取正常"
        fi
        return 0
    else
        local error
        error=$(grep -i "Failed.*array\|Could not load addon array" /tmp/fcitx5-array-verify.log 2>/dev/null || true)
        if [[ -n "$error" ]]; then
            err "$error"
        fi
        return 1
    fi
}

verify_array_loaded_quiet() {
    pkill fcitx5 2>/dev/null || true
    sleep 1
    FCITX_LOG=default=5 fcitx5 -rd &>/tmp/fcitx5-array-diag.log &
    disown
    sleep 3
    grep -q "Loaded addon array" /tmp/fcitx5-array-diag.log 2>/dev/null
}

# ── 主程式 ────────────────────────────────────────────────────────────────

show_help() {
    cat << 'EOF'
行列30輸入法安裝工具 (fcitx5-array)
支援平台: SteamOS (Steam Deck) / Ubuntu 24.04 / Ubuntu 22.04

用法: ./array30-setup.sh <command>

Commands:
  install        首次安裝或重建 fcitx5-array
                 在 Podman 容器中編譯，自動匹配 host ABI

  update-table   線上更新行列30字根表
                 從 gontera/array30 下載最新 CIN 字根表並重建 array.db
                 支援主表、簡碼、詞組三合一更新

  diagnose       診斷目前安裝狀態
                 檢查套件、檔案、ABI、字根表、Profile 及 addon 載入

  uninstall      移除 fcitx5-array 並切回 table-based array30

  backup         手動備份目前的 array.db 和 array.so

  restore        從備份還原 array.db 和 array.so

  help           顯示此說明

行列30 vs table-based array30:
  原生 fcitx5-array 支援：
    - W+數字鍵 符號輸入（接近 Windows 行列體驗）
    - 一級/二級簡碼
    - 萬用字元查詢（? 和 *）
    - 詞組輸入
    - 聯想詞
    - 反查碼（Ctrl+Alt+E）

  table-based array30 (fcitx5-table-extra):
    - 基本行列輸入
    - 不支援上述進階功能

Version: v1.0.0
License: GPL-2.0-or-later
EOF
}

main() {
    local cmd="${1:-help}"
    case "$cmd" in
        install)       do_install ;;
        update-table)  do_update_table ;;
        diagnose)      do_diagnose ;;
        uninstall)     do_uninstall ;;
        backup)        do_backup ;;
        restore)       do_restore ;;
        help|--help|-h) show_help ;;
        *)
            err "未知的命令: $cmd"
            echo ""
            show_help
            exit 1
            ;;
    esac
}

main "$@"
