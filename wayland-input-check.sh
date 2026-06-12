#!/bin/bash
# wayland-input-check.sh — 行列30 / fcitx5 Wayland 輸入問題診斷腳本
#
# 用途：在無法打字的機器上執行，自動收集診斷資訊並產生報告。
# 用法：
#   bash wayland-input-check.sh
# 執行後把 ~/array30-wayland-report.txt 傳回給協助者即可。
#
# 本腳本只讀取系統狀態，不做任何修改。

REPORT="$HOME/array30-wayland-report.txt"

# 顏色（報告檔不含色碼）
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  [OK]${NC} $1";   echo "  [OK] $1"   >> "$REPORT"; }
warn() { echo -e "${YELLOW}  [警告]${NC} $1"; echo "  [警告] $1" >> "$REPORT"; }
bad()  { echo -e "${RED}  [問題]${NC} $1";   echo "  [問題] $1" >> "$REPORT"; }
info() { echo "  $1";                        echo "  $1"        >> "$REPORT"; }
section() {
    echo -e "\n${CYAN}── $1 ──${NC}"
    echo -e "\n── $1 ──" >> "$REPORT"
}

# 收集到的關鍵狀態，最後用來下判斷
FCITX5_TYPE="none"        # native / flatpak / none
FCITX5_RUNNING=0
CURRENT_IM=""
ARRAY_LOADED=0
SESSION_TYPE="${XDG_SESSION_TYPE:-unknown}"
VK_SET_TO_FCITX=0
ENV_GTK="${GTK_IM_MODULE:-}"
ENV_QT="${QT_IM_MODULE:-}"
ENV_XMOD="${XMODIFIERS:-}"
HAS_CHROME_FLATPAK=0

# 開新報告
{
    echo "行列30 / fcitx5 Wayland 輸入診斷報告"
    echo "產生時間: $(date '+%Y-%m-%d %H:%M:%S')"
} > "$REPORT"

echo "=== 行列30 / fcitx5 輸入診斷 ==="
echo "（過程約 10 秒，結束後請把 $REPORT 傳回）"

# ── 1. 系統資訊 ──────────────────────────────────────────────────────────
section "1. 系統資訊"
if [[ -f /etc/os-release ]]; then
    info "OS: $(grep -oP '^PRETTY_NAME=\K.*' /etc/os-release | tr -d '"')"
    info "VERSION_ID: $(grep -oP '^VERSION_ID=\K.*' /etc/os-release | tr -d '"')"
else
    warn "找不到 /etc/os-release"
fi
info "Session 類型: $SESSION_TYPE"
info "桌面環境: ${XDG_CURRENT_DESKTOP:-unknown}"
if [[ "$SESSION_TYPE" == "wayland" ]]; then
    ok "目前是 Wayland session"
elif [[ "$SESSION_TYPE" == "x11" ]]; then
    info "目前是 X11 session（Wayland 相關檢查將跳過）"
else
    warn "無法判斷 session 類型（可能在 SSH / Game Mode 下執行，請在桌面模式的 Konsole 內執行）"
fi

# ── 2. fcitx5 安裝與執行狀態 ──────────────────────────────────────────────
section "2. fcitx5 安裝與執行狀態"
if command -v fcitx5 &>/dev/null; then
    FCITX5_TYPE="native"
    info "fcitx5 安裝方式: native ($(command -v fcitx5))"
elif flatpak list 2>/dev/null | awk -F'\t' '{print $2}' | grep -q "^org\.fcitx\.Fcitx5$"; then
    FCITX5_TYPE="flatpak"
    info "fcitx5 安裝方式: Flatpak (org.fcitx.Fcitx5)"
else
    bad "找不到 fcitx5（native 與 Flatpak 都沒有）"
fi

# fcitx5-remote 指令（依安裝方式選擇）
fc_remote() {
    if [[ "$FCITX5_TYPE" == "flatpak" ]]; then
        flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 "$@" 2>/dev/null
    else
        fcitx5-remote "$@" 2>/dev/null
    fi
}

if pgrep -x fcitx5 >/dev/null 2>&1 || pgrep -f "org.fcitx.Fcitx5" >/dev/null 2>&1; then
    FCITX5_RUNNING=1
    ok "fcitx5 程序正在執行"
    info "程序: $(pgrep -af 'fcitx5' | head -3)"
else
    bad "fcitx5 程序沒有在執行"
fi

if [[ "$FCITX5_TYPE" != "none" && "$FCITX5_RUNNING" == "1" ]]; then
    remote_state=$(fc_remote)
    CURRENT_IM=$(fc_remote -n)
    info "fcitx5-remote 狀態碼: ${remote_state:-無回應}（1=非啟用 2=啟用中）"
    if [[ -n "$CURRENT_IM" ]]; then
        info "目前輸入法: $CURRENT_IM"
        if [[ "$CURRENT_IM" == "array" ]]; then
            ARRAY_LOADED=1
            ok "行列30 (array) 是目前的輸入法"
        else
            warn "目前輸入法不是 array，請按 Ctrl+Space 切換後再測"
        fi
    else
        bad "fcitx5-remote 無回應 — fcitx5 D-Bus 介面異常"
    fi
fi

# ── 3. array addon 檔案 ──────────────────────────────────────────────────
section "3. array addon 檔案"
check_file() {
    if [[ -f "$1" ]]; then
        ok "$1 ($(stat -c '%s bytes' "$1" 2>/dev/null))"
        return 0
    fi
    return 1
}
ARRAY_FILE_FOUND=0
for so in /usr/lib/fcitx5/array.so \
          /usr/lib/x86_64-linux-gnu/fcitx5/array.so \
          "$HOME/.var/app/org.fcitx.Fcitx5/data/fcitx5/lib/array.so"; do
    check_file "$so" && ARRAY_FILE_FOUND=1
done
[[ "$ARRAY_FILE_FOUND" == "0" ]] && bad "找不到 array.so — 行列30 引擎未安裝"

DB_FOUND=0
for db in /usr/share/fcitx5/array/array.db \
          "$HOME/.var/app/org.fcitx.Fcitx5/data/fcitx5/array/array.db"; do
    check_file "$db" && DB_FOUND=1
done
[[ "$DB_FOUND" == "0" ]] && bad "找不到 array.db — 字碼表未安裝"

for prof in "$HOME/.config/fcitx5/profile" \
            "$HOME/.var/app/org.fcitx.Fcitx5/config/fcitx5/profile"; do
    if [[ -f "$prof" ]]; then
        if grep -q "Name=array$" "$prof"; then
            ok "profile 已含 array: $prof"
        else
            warn "profile 存在但未含 array: $prof"
        fi
    fi
done

# ── 4. 輸入法環境變數與來源 ───────────────────────────────────────────────
section "4. 輸入法環境變數"
info "GTK_IM_MODULE = ${ENV_GTK:-（未設定）}"
info "QT_IM_MODULE  = ${ENV_QT:-（未設定）}"
info "XMODIFIERS    = ${ENV_XMOD:-（未設定）}"
info "SDL_IM_MODULE = ${SDL_IM_MODULE:-（未設定）}"

if [[ "$SESSION_TYPE" == "wayland" && ( -n "$ENV_GTK" || -n "$ENV_QT" ) ]]; then
    warn "Wayland 下設定了 GTK/QT_IM_MODULE — 與 Wayland 輸入法前端並存（即 fcitx 彈窗警告的來源）"
fi

info ""
info "變數定義位置搜尋:"
found_src=0
for f in /etc/environment "$HOME/.pam_environment" "$HOME/.xprofile" \
         "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" \
         "$HOME"/.config/environment.d/*.conf "$HOME/.config/plasma-workspace/env"/*.sh; do
    [[ -f "$f" ]] || continue
    hits=$(grep -n "IM_MODULE\|XMODIFIERS" "$f" 2>/dev/null | grep -v "^\s*#" || true)
    if [[ -n "$hits" ]]; then
        found_src=1
        info "  $f:"
        while IFS= read -r line; do info "    $line"; done <<< "$hits"
    fi
done
[[ "$found_src" == "0" ]] && info "  （常見設定檔中都沒找到 — 可能由桌面整合元件自動設定）"

# ── 5. Plasma Wayland 虛擬鍵盤設定 ────────────────────────────────────────
section "5. Plasma 虛擬鍵盤（Wayland 輸入法通道）"
KREAD=""
command -v kreadconfig6 &>/dev/null && KREAD="kreadconfig6"
[[ -z "$KREAD" ]] && command -v kreadconfig5 &>/dev/null && KREAD="kreadconfig5"
if [[ -n "$KREAD" ]]; then
    vk=$($KREAD --file kwinrc --group Wayland --key InputMethod 2>/dev/null)
    info "kwinrc [Wayland] InputMethod = ${vk:-（未設定）}"
    if [[ "${vk,,}" == *fcitx5* ]]; then
        VK_SET_TO_FCITX=1
        ok "Plasma 虛擬鍵盤已設為 Fcitx 5"
    elif [[ "$SESSION_TYPE" == "wayland" ]]; then
        warn "Plasma 虛擬鍵盤未設為 Fcitx 5 — Wayland 原生應用可能收不到輸入法"
        info "  修正: 系統設定 → 鍵盤 → 虛擬鍵盤 → 選 Fcitx 5"
    fi
else
    warn "找不到 kreadconfig5/6，無法讀取 kwinrc（手動檢查: 系統設定 → 鍵盤 → 虛擬鍵盤）"
fi

# ── 6. 瀏覽器（Chrome / Chromium）────────────────────────────────────────
section "6. 瀏覽器設定"
if command -v flatpak &>/dev/null; then
    chrome_apps=$(flatpak list --app --columns=application 2>/dev/null | grep -iE "chrome|chromium" || true)
    if [[ -n "$chrome_apps" ]]; then
        HAS_CHROME_FLATPAK=1
        info "偵測到 Flatpak 瀏覽器:"
        while IFS= read -r app; do
            info "  $app"
            ov=$(flatpak override --user --show "$app" 2>/dev/null | grep -i "IM_MODULE\|XMODIFIERS" || true)
            [[ -n "$ov" ]] && info "    override: $ov" || info "    （無輸入法相關 override）"
        done <<< "$chrome_apps"
    else
        info "沒有 Flatpak 版 Chrome/Chromium"
    fi
fi
command -v google-chrome-stable &>/dev/null && info "偵測到 native Chrome: $(command -v google-chrome-stable)"
for fc in "$HOME/.config/chrome-flags.conf" "$HOME/.config/chromium-flags.conf" \
          "$HOME/.var/app/com.google.Chrome/config/chrome-flags.conf"; do
    if [[ -f "$fc" ]]; then
        info "$fc 內容:"
        while IFS= read -r line; do info "  $line"; done < "$fc"
    fi
done

# ── 7. 自動判斷 ──────────────────────────────────────────────────────────
section "7. 自動判斷與建議"
if [[ "$FCITX5_TYPE" == "none" ]]; then
    bad "fcitx5 未安裝 → 請先執行 array30-setup.sh install"
elif [[ "$FCITX5_RUNNING" == "0" ]]; then
    bad "fcitx5 沒在執行 → 在 Konsole 執行: fcitx5 -rd  然後重新測試打字"
elif [[ -z "$CURRENT_IM" ]]; then
    bad "fcitx5 在跑但 D-Bus 無回應 → 執行: pkill fcitx5; fcitx5 -rd  後重測"
elif [[ "$ARRAY_FILE_FOUND" == "0" || "$DB_FOUND" == "0" ]]; then
    bad "行列30 引擎或字碼表缺檔 → 請執行 array30-setup.sh diagnose 取得詳細資訊"
elif [[ "$SESSION_TYPE" == "wayland" && "$VK_SET_TO_FCITX" == "0" ]]; then
    bad "最可能原因: Plasma 虛擬鍵盤未設為 Fcitx 5"
    info "  → 系統設定 → 鍵盤 → 虛擬鍵盤 → 選 Fcitx 5 → 套用，然後用 Kate 測試"
else
    ok "fcitx5 與行列30 基礎狀態正常"
    info "若仍無法打字，請依下列順序測試並回報結果："
    info "  1. 開 Kate（或 KWrite），按 Ctrl+Space，測試能否打出中文"
    info "  2. Kate 可以但 Chrome 不行 → Chrome 網址列開 chrome://flags，"
    info "     搜尋 text-input，啟用 Wayland text-input-v3 後重啟 Chrome"
    info "  3. Kate 也不行 → 把本報告檔傳回，並註明測試的應用程式名稱"
fi

echo ""
echo -e "${CYAN}報告已儲存到: $REPORT${NC}"
echo "請把這個檔案傳回給協助者（或直接截圖第 7 節的判斷結果）。"
