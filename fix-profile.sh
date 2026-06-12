#!/bin/bash
# fix-profile.sh — 將行列30 (array) 加入 fcitx5 輸入法清單並設為預設
#
# 適用情況：array.so / array.db 已安裝，但 fcitx5 的輸入法清單裡沒有行列30
#（診斷腳本第 3 節出現「profile 存在但未含 array」時用這個修復）。
#
# 用法：
#   curl -fsSL https://raw.githubusercontent.com/tern/steamdeck-array30/main/fix-profile.sh | bash
#
# 會自動備份原 profile 到 profile.bak.<時間戳>。
set -u

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
bad()  { echo -e "${RED}[失敗]${NC} $1"; }
warn() { echo -e "${YELLOW}[注意]${NC} $1"; }

# ── 偵測安裝型態與 profile 路徑（可用環境變數覆蓋，供測試）─────────────────
FCITX5_TYPE="none"
if command -v fcitx5 &>/dev/null; then
    FCITX5_TYPE="native"
    PROFILE="${ARRAY30_PROFILE:-$HOME/.config/fcitx5/profile}"
elif flatpak list 2>/dev/null | awk -F'\t' '{print $2}' | grep -q "^org\.fcitx\.Fcitx5$"; then
    FCITX5_TYPE="flatpak"
    PROFILE="${ARRAY30_PROFILE:-$HOME/.var/app/org.fcitx.Fcitx5/config/fcitx5/profile}"
else
    bad "找不到 fcitx5（native 與 Flatpak 都沒有），請先執行 array30-setup.sh install"
    exit 1
fi
echo "fcitx5 安裝方式: $FCITX5_TYPE"
echo "profile 路徑: $PROFILE"

# ── 先停止 fcitx5（fcitx5 結束時會回寫 profile，必須先停再改）──────────────
if [[ "${ARRAY30_NO_RESTART:-0}" != "1" ]]; then
    # 用 -x 精確比對程序名，避免 -f 誤殺命令列含 "fcitx5" 字樣的其他程序（如執行本腳本的終端）
    killed=0
    pkill -x fcitx5 2>/dev/null && killed=1
    pkill -x fcitx5-bin 2>/dev/null && killed=1          # Flatpak 內的主程序
    pkill -f "fcitx5-array-wrapper.sh" 2>/dev/null && killed=1
    [[ "$killed" == "1" ]] && echo "已停止 fcitx5" || echo "fcitx5 原本就沒在跑"
    sleep 1
fi

mkdir -p "$(dirname "$PROFILE")"

# ── 修改或建立 profile ────────────────────────────────────────────────────
if [[ -f "$PROFILE" ]]; then
    cp "$PROFILE" "$PROFILE.bak.$(date +%s)"
    echo "已備份原 profile"

    if grep -q "^Name=array$" "$PROFILE"; then
        ok "array 已在清單中，不需修改"
    else
        max_idx=$(grep -oP 'Groups/0/Items/\K[0-9]+' "$PROFILE" | sort -n | tail -1)
        if [[ -n "$max_idx" ]] && grep -q "^\[GroupOrder\]" "$PROFILE"; then
            new_idx=$((max_idx + 1))
            sed -i "/^\[GroupOrder\]/i\\
[Groups/0/Items/$new_idx]\\
# Name\\
Name=array\\
# Layout\\
Layout=\\
" "$PROFILE"
            ok "已將 array 加入輸入法清單 (Items/$new_idx)"
        else
            warn "profile 格式異常，改為重建整份 profile"
            rm -f "$PROFILE"
        fi
    fi

    # 設定預設輸入法為 array
    if [[ -f "$PROFILE" ]]; then
        if grep -q "^DefaultIM=" "$PROFILE"; then
            sed -i 's/^DefaultIM=.*/DefaultIM=array/' "$PROFILE"
        else
            sed -i '/^\[Groups\/0\]/a # Default Input Method\nDefaultIM=array' "$PROFILE"
        fi
        ok "已設定 DefaultIM=array"
    fi
fi

# profile 不存在（或上面判定格式異常被刪除）→ 從頭建立
if [[ ! -f "$PROFILE" ]]; then
    cat > "$PROFILE" << 'PROFEOF'
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

[GroupOrder]
0=預設
PROFEOF
    ok "已建立全新 profile（keyboard-us + array）"
fi

# ── 重啟 fcitx5 並驗證 ────────────────────────────────────────────────────
if [[ "${ARRAY30_NO_RESTART:-0}" == "1" ]]; then
    echo "（測試模式：跳過重啟）"
    exit 0
fi

WRAPPER="$HOME/.local/bin/fcitx5-start-array.sh"
if [[ -x "$WRAPPER" ]]; then
    nohup bash "$WRAPPER" &>/dev/null &
elif [[ "$FCITX5_TYPE" == "flatpak" ]]; then
    nohup flatpak run org.fcitx.Fcitx5 -rd &>/dev/null &
else
    nohup fcitx5 -rd &>/dev/null &
fi
echo "fcitx5 重新啟動中…（Flatpak 冷啟動可能需要十幾秒）"

# 輪詢最多 20 秒：取得目前輸入法名稱，或至少確認 D-Bus 服務已註冊
current=""
DBUS_OK=0
for i in $(seq 1 20); do
    sleep 1
    if [[ "$FCITX5_TYPE" == "flatpak" ]]; then
        current=$(flatpak run --command=fcitx5-remote org.fcitx.Fcitx5 -n 2>/dev/null)
    else
        current=$(fcitx5-remote -n 2>/dev/null)
    fi
    [[ -n "$current" ]] && break
    if busctl --user list --no-pager 2>/dev/null | awk '{print $1}' | grep -qx "org.fcitx.Fcitx5"; then
        DBUS_OK=1
        break
    fi
done

echo ""
if [[ "$current" == "array" ]]; then
    ok "修復完成！目前輸入法: array（行列30）"
    echo "請開 Kate 或瀏覽器測試打字，按 Ctrl+Space 可切換中英文。"
elif [[ -n "$current" ]]; then
    warn "fcitx5 已重啟，目前輸入法是: $current"
    echo "請按 Ctrl+Space 切換到行列30 後測試。"
elif [[ "$DBUS_OK" == "1" ]]; then
    # fcitx5-remote 重啟後在尚無視窗取得輸入焦點前會回空值，不代表失敗
    ok "fcitx5 已啟動並註冊到 D-Bus（profile 已含 array）"
    echo "請點一下任何文字輸入框（如 Kate 或瀏覽器網址列），按 Ctrl+Space 切換到行列30 測試。"
else
    bad "fcitx5 重啟後無回應，請重新執行診斷腳本並回傳報告："
    echo "  curl -fsSL https://raw.githubusercontent.com/tern/steamdeck-array30/main/wayland-input-check.sh | bash"
fi
