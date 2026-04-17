# Steam Deck 行列30安裝工具

在 **Steam Deck (SteamOS)** 或 **Ubuntu Desktop** 上一鍵安裝原生 **fcitx5-array** 行列30輸入法引擎。

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

本工具透過容器編譯 [fcitx5-array](https://github.com/ray2501/fcitx5-array) `1.0.0`，自動處理各平台的 ABI 版本差異問題，安裝到 host 上。

## 支援平台

| 平台 | 狀態 | 容器工具 |
|------|------|----------|
| SteamOS 3.8 (Steam Deck) | ✅ 已測試 | Podman（內建） |
| SteamOS 3.7 (Steam Deck) | ✅ 已確認相容 | Podman（內建） |
| SteamOS 3.6 及以下 | ⚠️ 未測試 | — |
| Ubuntu 24.04 Desktop | ✅ 已測試 | Podman 或 Docker |
| Ubuntu 22.04 Desktop | ✅ 已測試 | Podman 或 Docker |
| 其他 Debian-based | ⚠️ 實驗性 | Podman 或 Docker |

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

# 安裝（自動偵測平台）
./array30-setup.sh install

# 安裝完成後，重啟 fcitx5 或登出重登
# 按 Ctrl+Space 切換輸入法
```

### Ubuntu 前置需求

Ubuntu 上需先安裝 fcitx5 和容器工具：

```bash
# 安裝 fcitx5
sudo apt install fcitx5 fcitx5-chinese-addons

# 安裝容器工具（擇一）
sudo apt install podman   # 推薦
# 或
sudo apt install docker.io && sudo systemctl start docker
```

## 指令一覽

| 指令 | 說明 |
|------|------|
| `./array30-setup.sh install` | 首次安裝或重建 fcitx5-array（含新酷音安裝詢問） |
| `./array30-setup.sh update-table` | 線上更新行列30字根表（自動抓官方 `v2026` OpenVanilla CIN 重建 `array.db`） |
| `./array30-setup.sh diagnose` | 診斷安裝狀態（檢查 ABI、檔案、載入、字根表） |
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
- `fcitx5` 已安裝（`sudo apt install fcitx5`）
- Podman 或 Docker（見上方前置需求）
- sudo 權限
- 網路連線

## 安裝流程說明

`install` 指令自動完成以下步驟：

1. **偵測平台** — 自動識別 SteamOS / Ubuntu / Debian
2. **盤點 host 版本** — 記錄 `fcitx5` 和 `fmt` 的精確版本
3. **建立 Arch 容器** — 用 Podman/Docker 拉一個乾淨的 `archlinux:latest`
4. **降級容器依賴** — 從 [Arch Linux Archive](https://archive.archlinux.org/) 下載並降級 `fcitx5` 和 `fmt` 到跟 host 一致的版本，確保 ABI 相容
5. **編譯** — 在容器內用 `makepkg` 編譯 AUR 的 `fcitx5-array`
6. **ABI 驗證** — 自動檢查產出的 `.so` 不會引用 host 沒有的 symbol
7. **安裝** —
   - SteamOS：複製 `.pkg.tar.zst` 到 host，用 `pacman -U` 安裝
   - Ubuntu：從容器解包 `.so` 和 `array.db`，直接複製到 host 路徑
8. **設定 Profile** — 自動將原生 `array` 加入 fcitx5 輸入法列表
9. **驗證** — 重啟 fcitx5 並確認 addon 載入成功

## 為什麼要用容器編譯？

`fcitx5-array` 只在 AUR 提供，Ubuntu apt 沒有原生套件（apt 只有 `fcitx5-table-array30`，即 table-based 版本）。SteamOS 亦無法直接安裝 AUR 工具。

在最新的 Arch 容器裡直接編譯會產生 **ABI 不相容**（`undefined symbol`），因為：

- `fcitx5` 5.1.11 的 class 叫 `StandardPath`，5.1.17+ 改名為 `StandardPaths`
- `fmt` 11.x 的 inline namespace 是 `v11`，12.x 是 `v12`
- Ubuntu 24.04 的 `fmt` 版本號格式為 `9.1.0+ds1-2`（需去後綴對應 Arch 版本）

本腳本自動偵測 host 版本並在容器內降級，確保編出來的 `.so` 可以載入。

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
- **詞組表**: 同上倉庫的 `array30-phrase-20210725.txt`

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
