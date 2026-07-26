# Steam Deck 行列30安裝工具

在 **Steam Deck (SteamOS)**、**Ubuntu Desktop**、**Pop!_OS** 或 **CachyOS / Arch Linux** 上一鍵安裝原生 **fcitx5-array** 行列30輸入法引擎。

## 為什麼需要這個？

各平台預設的行列30都是 table-based 版本，功能較陽春：

| 功能 | table-based array30 | 原生 fcitx5-array |
|------|:---:|:---:|
| 基本行列輸入 | ✓ | ✓ |
| W+數字鍵 符號輸入 | ✗ | ✓ |
| 一級/二級簡碼 | ✗ | ✓ |
| 萬用字元查詢 (?, *) | ✗ | ✓ |
| 詞組輸入 | ✗ | ✓ |
| 聯想詞 | ✗ | ✓ |
| 反查碼 (Ctrl+Alt+E) | ✗ | ✓ |
| 接近 Windows 行列體驗 | ✗ | ✓ |

本工具自動處理各平台的 ABI 版本差異問題：在 **Ubuntu / Pop!_OS** 上用本機 **cmake** 對 host 的 fcitx5-dev 編譯 [fcitx5-array](https://github.com/ray2501/fcitx5-array) `1.0.1`（不需拉 Arch 映像）；在 **CachyOS/Arch** 上本機 `makepkg`；在 **SteamOS / Flatpak** 上才透過容器編譯並匹配 ABI。

## 支援平台

| 平台 | 狀態 | 編譯方式 |
|------|------|----------|
| SteamOS 3.8 (Steam Deck) | ✅ 已測試 | Podman 容器（內建） |
| SteamOS 3.7 (Steam Deck) | ✅ 已確認相容 | Podman 容器（內建） |
| SteamOS 3.6 及以下 | ⚠️ 未測試 | — |
| Ubuntu 24.04 Desktop | ✅ 已測試 | **本機 cmake**（可選容器） |
| Ubuntu 22.04 Desktop | ✅ 已測試 | **本機 cmake**（可選容器） |
| Pop!_OS 24.04 | ✅ 支援（Ubuntu noble 路徑） | **本機 cmake**（可選容器） |
| 其他 Debian-based | ⚠️ 實驗性 | **本機 cmake**（可選容器） |
| CachyOS | ✅ 已測試 | 本機 makepkg（無需容器） |
| Arch Linux | ✅ 支援 | 本機 makepkg（無需容器） |

### SteamOS 版本套件對照

| SteamOS | fcitx5 | fmt | 支援狀態 |
|---------|--------|-----|---------|
| 3.8 | 5.1.14-1 | 11.2.0-1 | ✅ 已測試 |
| 3.7 | 5.1.11-2 | 11.1.1-2 | ✅ 已確認相容（Arch Archive 有對應套件） |
| 3.6 | 5.1.7-3 | 10.2.0-1 | ⚠️ 未測試 |
| 3.5 | 5.0.23-2 | 9.1.0-4 | ❌ 不支援（fcitx5 5.0.x 舊 API） |

## 快速開始

```bash
git clone https://github.com/tern/steamdeck-array30.git
cd steamdeck-array30
chmod +x array30-setup.sh

# 安裝（自動偵測平台 → 裝必要套件 → 本機或容器編譯）
./array30-setup.sh install

# 安裝完成後，重啟 fcitx5 或登出重登
# 按 Ctrl+Space 切換輸入法
```

`install` 一開始會依系統顯示**安裝計畫**，並自動處理缺少的必要套件：

| 系統 | 編譯方式 | 是否拉 Arch 映像 | 自動安裝的必要套件（若缺少） |
|------|----------|:----------------:|------------------------------|
| **CachyOS / Arch** | 本機 `makepkg` | **否** | fcitx5、base-devel、git、cmake… |
| **Ubuntu / Pop!_OS / Debian**（native fcitx5） | 本機 **cmake** | **否** | fcitx5、cmake、libfcitx5*-dev、libfmt-dev… |
| **SteamOS** | Arch 容器 | **是** | 檢查 fcitx5 / Podman（不擅自 pacman 裝 fcitx5） |
| **Flatpak fcitx5**（任何主機） | Arch 容器 | **是** | 容器工具（ABI 在 runtime，必須容器） |

強制使用容器編譯（例如本機 cmake 失敗時）：

```bash
ARRAY30_FORCE_CONTAINER=1 ./array30-setup.sh install
```

### 可選手動前置（通常不必）

若想先自己裝好環境再跑腳本：

```bash
# Ubuntu / Pop!_OS（本機 cmake，不需要 podman）
sudo apt install fcitx5 fcitx5-chinese-addons libfmt9 \
  build-essential cmake extra-cmake-modules \
  libfcitx5core-dev libfcitx5utils-dev libfcitx5config-dev \
  fcitx5-modules-dev libfmt-dev libsqlite3-dev

# CachyOS / Arch（不需要容器）
sudo pacman -S --needed fcitx5 fcitx5-chinese-addons fcitx5-configtool \
  base-devel git cmake extra-cmake-modules
```

若系統上已是 **table-based** 行列（`fcitx5-table-array30`），`install` 成功後可選擇自動移除；或稍後執行：

```bash
./array30-setup.sh migrate-from-table
```

## 指令一覽

| 指令 | 說明 |
|------|------|
| `./array30-setup.sh install` | 偵測系統 → 裝必要套件 → 本機 cmake/makepkg 或容器編譯（含新酷音詢問；可選移除 table 版） |
| `./array30-setup.sh update-table` | 線上更新行列30字根表（自動抓官方 `v2026` OpenVanilla CIN 重建 `array.db`） |
| `./array30-setup.sh diagnose` | 診斷安裝狀態（檢查 ABI、檔案、載入、字根表） |
| `./array30-setup.sh migrate-from-table` | 移除 table-based array30 / array30-large，只保留原生 array |
| `./array30-setup.sh uninstall` | 移除 fcitx5-array，切回 table-based |
| `./array30-setup.sh backup` | 手動備份 |
| `./array30-setup.sh restore` | 從備份還原 |

## 安裝需求

### SteamOS (Steam Deck)

- Steam Deck，SteamOS **3.7 以上**（Desktop Mode）
- Podman（SteamOS 內建）
- sudo 權限
- 網路連線（下載容器映像、AUR 來源碼、字根表）

### Ubuntu Desktop

- Ubuntu 22.04 / 24.04（或其他 Debian-based）
- `fcitx5` 與編譯用 `-dev` 套件（`install` 可自動安裝缺少項目）
- 預設**不需要** Podman；僅 Flatpak 或 `ARRAY30_FORCE_CONTAINER=1` 時需要
- sudo 權限
- 網路連線

### CachyOS / Arch Linux

- `fcitx5` 已安裝（`sudo pacman -S fcitx5 fcitx5-chinese-addons`）
- `base-devel`、`git`、`cmake`、`extra-cmake-modules`（AUR 編譯標準工具）
- sudo 權限
- 網路連線（下載 AUR 來源碼、字根表）
- 不需要 Podman/Docker

## 安裝流程說明

`install` 指令自動完成以下步驟：

1. **偵測平台** — 自動識別 SteamOS / Ubuntu / Debian / CachyOS / Arch，顯示安裝計畫
2. **安裝缺少的必要套件** — 依平台補 fcitx5、編譯工具或容器 runtime
3. **盤點 host 版本** — 記錄 `fcitx5` 和 `fmt` 的精確版本
4. **編譯** —
   - **Ubuntu / Pop!_OS / Debian**：本機 `cmake` 對 host 的 fcitx5-dev / libfmt-dev 編譯（**不拉 Arch 映像**）
   - **CachyOS / Arch**：本機 `makepkg`
   - **SteamOS / Flatpak**：啟動 `archlinux:latest` 容器，降級 `fcitx5`/`fmt` 匹配 host ABI 後 `makepkg`
5. **ABI 驗證** — 自動檢查產出的 `.so` 不會引用 host 沒有的 symbol
6. **安裝** —
   - SteamOS / Arch：`pacman -U` 安裝 `.pkg.tar.zst`
   - Ubuntu/Pop：`cmake --install` 到系統路徑，並建立 `libarray.so` symlink
7. **設定 Profile** — 自動將原生 `array` 加入 fcitx5 輸入法列表
8. **驗證** — 重啟 fcitx5 並確認 addon 載入成功

## 為什麼有時仍要用容器編譯？

`fcitx5-array` 沒有 Ubuntu/SteamOS 官方套件（apt 只有 table 版 `fcitx5-table-array30`）。

- **Ubuntu / Pop（native fcitx5）**：直接用系統 `-dev` 套件本機 cmake，ABI 天然相符，**不需要容器**。
- **SteamOS / Flatpak**：host 的 fcitx5/fmt 與「隨手編出的二進位」容易 ABI 不合（例如 `StandardPath` vs `StandardPaths`、`fmt::v11` vs `v12`）。腳本在 Arch 容器內把依賴降到與 host 一致再編譯。
- **CachyOS / Arch**：本機 `makepkg` 即可。

若 Ubuntu/Pop 本機 cmake 失敗，可強制容器：`ARRAY30_FORCE_CONTAINER=1 ./array30-setup.sh install`。

## 新酷音輸入法

`install` 過程中會詢問是否同時安裝**新酷音 (fcitx5-chewing)**：

```
是否同時安裝新酷音？（可與行列30共用，按 Ctrl+Space 切換）[y/N]
```

選 `y` 後，腳本會自動安裝 `fcitx5-chewing` 並將其加入 fcitx5 profile，讓行列30與新酷音可以共存、快速切換。若已安裝過，腳本會自動跳過詢問。

## 字根表更新

`update-table` 指令會自動解析官方 `gontera/array30` 倉庫中最新的 `v2026` OpenVanilla 字根表後再下載：

- **主字根表**: [gontera/array30](https://github.com/gontera/array30) `OpenVanilla/array30-OpenVanilla-big-v2026-*.cin`
- **簡碼表**: 同上倉庫的 `OpenVanilla/array-shortcode-*.cin`
- **詞組表**: 同上倉庫的 `array30_spec/array30-phrase-YYYYMMDD.txt`（腳本自動發現最新日期版，如 20260723）

更新前會自動備份，更新後顯示筆數對照，異常時自動中止。若上游釋出新的 `v2026` 小版本，腳本會自動跟上，不需要再手改檔名。

## 系統更新後

### SteamOS

SteamOS 系統更新可能改變 `fcitx5` 或 `fmt` 版本。如果更新後行列30無法使用：

```bash
./array30-setup.sh diagnose  # 診斷問題
./array30-setup.sh install   # 重建（自動匹配新的 host 版本）
```

### Ubuntu

Ubuntu apt 升級後若 `fcitx5` 版本變動，同樣重新執行 install 即可：

```bash
./array30-setup.sh diagnose
./array30-setup.sh install
```

### CachyOS / Arch Linux

`pacman -Syu` 升級後若 `fcitx5` 或 `fmt` 版本變動，重新本機編譯即可：

```bash
./array30-setup.sh diagnose
./array30-setup.sh install
```

## 回滾

```bash
# 方法 1: 從備份還原
./array30-setup.sh restore

# 方法 2: 完全移除，回到 table-based
./array30-setup.sh uninstall
```

## 備份位置

所有備份存放在 `~/.local/share/fcitx5-array-backup/`，每次操作前自動備份。

## 致謝

- [ray2501/fcitx5-array](https://github.com/ray2501/fcitx5-array) — fcitx5 原生行列30引擎
- [gontera/array30](https://github.com/gontera/array30) — 官方行列30字根表
- [OpenVanilla](https://openvanilla.org/) — CIN 格式字根表及聯想詞資料

## 授權

GPL-2.0-or-later
