# Steam Deck 行列30輸入法安裝工具

在 Steam Deck (SteamOS Desktop Mode) 上一鍵安裝原生 **fcitx5-array** 行列30輸入法引擎。

## 為什麼需要這個？

Steam Deck 預設可透過 `fcitx5-table-extra` 使用 table-based 的行列30，但這個版本功能較陽春：

| 功能 | table-based array30 | 原生 fcitx5-array |
|------|:---:|:---:|
| 基本行列輸入 | O | O |
| W+數字鍵 符號輸入 | X | O |
| 一級/二級簡碼 | X | O |
| 萬用字元查詢 (?, *) | X | O |
| 詞組輸入 | X | O |
| 聯想詞 | X | O |
| 反查碼 (Ctrl+Alt+E) | X | O |
| 接近 Windows 行列體驗 | X | O |

本工具透過 Podman 容器編譯 [fcitx5-array](https://github.com/ray2501/fcitx5-array)（AUR），自動處理 SteamOS 特有的 ABI 版本差異問題，安裝到 host 上。

## 快速開始

```bash
git clone https://github.com/tern/steamdeck-array30.git
cd steamdeck-array30
chmod +x array30-setup.sh

# 安裝
./array30-setup.sh install

# 安裝完成後，按 Ctrl+Space 切換輸入法
```

## 指令一覽

| 指令 | 說明 |
|------|------|
| `./array30-setup.sh install` | 首次安裝或重建 fcitx5-array |
| `./array30-setup.sh update-table` | 線上更新行列30字根表（從官方 CIN 表重建 array.db） |
| `./array30-setup.sh diagnose` | 診斷安裝狀態（檢查 ABI、檔案、載入、字根表） |
| `./array30-setup.sh uninstall` | 移除 fcitx5-array，切回 table-based |
| `./array30-setup.sh backup` | 手動備份 |
| `./array30-setup.sh restore` | 從備份還原 |

## 安裝需求

- Steam Deck (SteamOS Desktop Mode)
- Podman（SteamOS 內建）
- sudo 權限（安裝套件到系統目錄需要）
- 網路連線（下載容器映像、AUR 來源碼、字根表）

## 安裝流程說明

`install` 指令自動完成以下步驟：

1. **盤點 host 版本** — 記錄 `fcitx5` 和 `fmt` 的精確版本
2. **建立 Arch 容器** — 用 Podman 拉一個乾淨的 `archlinux:latest`
3. **降級容器依賴** — 從 [Arch Linux Archive](https://archive.archlinux.org/) 下載並降級 `fcitx5` 和 `fmt` 到跟 host 一致的版本，確保 ABI 相容
4. **編譯** — 在容器內用 `makepkg` 編譯 AUR 的 `fcitx5-array`
5. **ABI 驗證** — 自動檢查產出的 `.so` 不會引用 host 沒有的 symbol
6. **安裝** — 複製 `.pkg.tar.zst` 到 host，用 `pacman -U` 安裝
7. **設定 Profile** — 自動將原生 `array` 加入 fcitx5 輸入法列表
8. **驗證** — 重啟 fcitx5 並確認 addon 載入成功

## 為什麼要用容器編譯？

SteamOS 是基於 Arch 的 immutable 系統，有以下限制：

- **rootfs 可能唯讀** — 需要 `steamos-readonly disable`
- **套件版本落後** — SteamOS 的 `fcitx5` 和 `fmt` 通常比 Arch 官方庫舊
- **不該安裝編譯工具到 host** — 避免污染系統

直接在最新的 Arch 容器裡編譯會產生 **ABI 不相容**（`undefined symbol`），因為：

- `fcitx5` 5.1.11 的 class 叫 `StandardPath`，5.1.17+ 改名為 `StandardPaths`
- `fmt` 11.x 的 inline namespace 是 `v11`，12.x 是 `v12`

本腳本自動偵測 host 版本並在容器內降級，確保編出來的 `.so` 可以載入。

## 字根表更新

`update-table` 指令從官方來源下載最新字根表：

- **主字根表**: [gontera/array30](https://github.com/gontera/array30) — 官方行列30鍵碼表
- **簡碼表**: 同上倉庫的 `array30_simplecode.cin`
- **詞組表**: [ray2501/fcitx5-array](https://github.com/ray2501/fcitx5-array) 內附

更新前會自動備份，更新後顯示筆數對照，異常時自動中止。

## SteamOS 更新後

SteamOS 系統更新可能改變 `fcitx5` 或 `fmt` 版本。如果更新後行列30無法使用：

```bash
# 診斷問題
./array30-setup.sh diagnose

# 重建（會自動匹配新的 host 版本）
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
