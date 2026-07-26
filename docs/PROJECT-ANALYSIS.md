# 專案分析：`steamdeck-array30`

> 分析日期：2026-07-26  
> 腳本版本常數：`SCRIPT_VERSION="1.4.0"`  
> 授權：GPL-2.0-or-later

這是一個**以單一 Bash 腳本為核心**的工具專案，目標是在多種 Linux 桌面環境上，安裝「功能完整」的原生 **fcitx5-array（行列 30）** 輸入法引擎，而不是系統預設較陽春的 table-based 版本。

---

## 解決什麼問題？

| 面向 | 說明 |
|------|------|
| **使用者痛點** | table-based array30 缺 W+數字、簡碼、萬用字元、詞組、聯想詞、反查碼等 |
| **技術痛點** | `fcitx5-array` 只在 AUR；SteamOS / Ubuntu 不能直接裝，且對 `fcitx5`、`fmt` **ABI 極敏感** |
| **本專案做法** | 自動偵測平台與 host 版本 → 在匹配 ABI 的環境編譯 → 安裝並設定 profile / autostart |

核心 ABI 風險：

- `fcitx5` 5.1.11 的 `StandardPath` vs 新版 `StandardPaths`
- `fmt` 11.x (`v11`) vs 12.x (`v12`) 的 inline namespace
- Ubuntu 版本字串含 `+ds1-2` 等後綴，需 `strip_semver` 後才能對應 Arch Archive

---

## 專案結構

```
steamdeck-array30/
├── array30-setup.sh      # 主程式 ~1951 行，幾乎全部邏輯
├── fix-profile.sh        # 獨立修復：profile 沒有 array 時可 curl|bash
├── wayland-input-check.sh # 唯讀診斷：Wayland/fcitx5 打字問題，產出報告
├── README.md
├── CLAUDE.md             # AI agent 導讀
├── LICENSE
└── docs/
    ├── PROJECT-ANALYSIS.md   # 本檔
    └── superpowers/specs/
        └── 2026-03-16-ubuntu-vm-skill-design.md  # Steam Deck 上建 Ubuntu VM 的 skill 設計
```

沒有傳統建置系統 / 測試套件。執行時只需要 **Bash + Python 3**；SteamOS/Ubuntu 另需 **Podman 或 Docker**，Arch 系另需 **base-devel / git / cmake**。

---

## 主腳本架構（`array30-setup.sh`）

```
常數 → OS/容器/fcitx5 偵測 → 套件抽象層 → 前置檢查
  → 容器管理 / 各平台安裝檔案
  → backup/restore
  → do_install / do_update_table / do_diagnose / do_uninstall
  → profile、autostart、chewing、驗證
  → main 分派
```

### 入口指令

| 指令 | 作用 |
|------|------|
| `install` | 編譯 + 安裝 + 設 profile + 驗證 |
| `update-table` | 從 `gontera/array30` 抓最新 CIN，重建 `array.db` |
| `diagnose` | 查套件、檔案、ABI symbol、profile、即時載入 |
| `uninstall` | 移除原生 array，退回 table-based |
| `backup` / `restore` | 備份/還原 `array.db`、`array.so` 等到 `~/.local/share/fcitx5-array-backup/` |

### 執行期狀態（腳本啟動就定好）

- `OS_TYPE`: `steamos` | `ubuntu` | `debian` | `arch` | `unknown`
- `CONTAINER_RUNTIME`: podman / docker
- `FCITX5_INSTALL_TYPE`: `native` | `flatpak` | `none`
- 路徑依 **先 OS、再 Flatpak 覆蓋** 決定（`ARRAY_SO`、`ARRAY_DB`、`FCITX5_PROFILE` 等）

平台分支順序：

1. 先看 `FCITX5_INSTALL_TYPE`（抓 Flatpak，與底層 OS 無關）
2. 再看 `OS_TYPE`

---

## 多平台策略

| 平台 | 編譯 | 安裝 | 路徑特點 |
|------|------|------|----------|
| **SteamOS** | Arch 容器 + 降級 fcitx5/fmt | `pacman -U` | `/usr/lib/fcitx5/`；可能要 `steamos-readonly disable` |
| **Ubuntu/Debian** | 同上容器降級 | 容器解包後手動 copy | multiarch 路徑；需 **`libarray.so` symlink**（loader 會加 `lib` 前綴） |
| **Flatpak** | 同上容器 | copy 到 `~/.var/app/org.fcitx.Fcitx5/...`，通常免 sudo | wrapper 注入 `FCITX_ADDON_DIRS` |
| **CachyOS/Arch** | **本機 makepkg**（無容器） | `pacman -U` | 與 SteamOS 同系統路徑；CachyOS 版本後綴會被 strip |

### `install` 流程（簡化）

1. 平台 / 中文 locale（Ubuntu）/ 容器 / fcitx5 檢查
2. `get_host_versions` → 對應 Arch Archive 套件版號
3. **Arch**：本機 clone AUR → patch → makepkg  
   **其他**：起 `archlinux:latest` 容器 → 降級依賴 → 同流程編譯
4. 編譯前兩個常見 patch：
   - `engine.cpp`：`fmt::format(_("..."), …)` → `fmt::runtime(_(...))`
   - fcitx5 header：補 `#include <cstdint>`（GCC 14）
5. `ldd` 做 ABI 粗檢（Flatpak 較鬆，靠載入驗證）
6. 依平台安裝 → 可選新酷音 → `setup_profile` / `setup_autostart` → 重啟 fcitx5 → `verify_array_loaded`

---

## 附屬腳本

1. **`fix-profile.sh`**  
   檔案已裝好、但 profile 沒有 `array` 時的獨立修復（可一鍵 curl）。會先停 fcitx5 再改 profile，避免程序結束時回寫覆蓋。

2. **`wayland-input-check.sh`**  
   純診斷：session type、IM 環境變數、fcitx5 native/flatpak、array 是否載入、Chrome Flatpak 等，輸出 `~/array30-wayland-report.txt`。反映實際使用上常卡在 **Wayland / Flatpak 輸入法整合**，不只是「.so 有沒有裝上」。

3. **`docs/.../ubuntu-vm-skill-design.md`**  
   在 Steam Deck 上用 KVM 建 Ubuntu VM 的 AI skill 設計稿——偏開發/測試基礎設施，不是 runtime 安裝流程的一部分。

---

## 設計取捨與特色

**優點**

- 單一可執行腳本，clone 就能跑，維運面單純
- 明確處理跨 distro ABI（Archive 降級 + version strip + ldd）
- 有 backup/restore、diagnose、update-table，偏「可長期維護的系統工具」
- Flatpak 路徑與 native 路徑分開處理，符合 Steam Deck 實況

**限制 / 技術債跡象**

- 幾乎全部邏輯在 ~2000 行 Bash，單元測試缺席
- 上游 AUR 版本、SHA256 是腳本內**寫死**的（`FCITX5_ARRAY_VER=1.0.0`）
- help 文字裡還寫「Version: v1.0.0」，與常數 `SCRIPT_VERSION="1.4.0"` 不一致
- 平台矩陣靠 case 分支撐起，新增 distro 要動多處路徑/安裝邏輯
- 依賴外部：Arch Archive 是否有對應歷史套件、GitHub API（字根表）、AUR git

---

## 資料流總覽

```text
使用者
  └─ array30-setup.sh install
        ├─ 偵測 OS / fcitx5 native|flatpak / podman|docker
        ├─ host fcitx5 + fmt 版本
        ├─ [非 Arch] Podman/Docker 容器
        │     └─ 對齊 archive.archlinux.org 套件 → makepkg fcitx5-array
        ├─ [Arch] 本機 makepkg
        ├─ 安裝 array.so / array.db / conf /（Ubuntu）libarray.so
        ├─ profile + autostart wrapper（GTK/QT IM_MODULE 等）
        └─ 驗證 addon 載入

字根更新 update-table
  └─ GitHub API 找 gontera/array30 最新 v2026 CIN
        └─ fcitx5-array-tools 重建 array.db → 替換 host
```

---

## 一句話總結

這是一個**面向 Steam Deck / Ubuntu / Arch 使用者的「原生行列 30 安裝器」**：本質不是新輸入法引擎，而是把 AUR 的 `fcitx5-array` 在 **ABI 受限環境** 裡安全編出、裝上、設好、能診斷與回滾的完整運維腳本。
