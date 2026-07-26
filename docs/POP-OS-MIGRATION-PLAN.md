# Pop!_OS 24.04 — 本機行列30現況分析與遷移計畫

> 分析日期：2026-07-26  
> 目標主機：Pop!_OS 24.04 LTS (`ID=pop`, `ID_LIKE=ubuntu debian`, Ubuntu noble 系)

---

## 1. 本機現況 vs 本專案

### 1.1 本機目前安裝

| 項目 | 現值 |
|------|------|
| OS | Pop!_OS 24.04 LTS |
| fcitx5 | **native** `5.1.7-1build3`（非 Flatpak） |
| 行列引擎 | **table-based** 套件，不是原生 `fcitx5-array` |
| 套件 | `fcitx5-table-array30` 5.1.3-1 |
| | `fcitx5-table-array30-large` 5.1.3-1 |
| 引擎 addon | `Addon=table`（通用表格式引擎） |
| 字根資料 | `/usr/share/fcitx5/table/array30.main.dict`（約 587K） |
| | `/usr/share/fcitx5/table/array30-large.main.dict`（約 1.6M） |
| IM 名稱 | profile 內為 `array30` / `array30-large` |
| DefaultIM | `array30` |
| 其他 IM | `chewing`（新酷音已裝） |
| Session | Wayland；`GTK_IM_MODULE`/`QT_IM_MODULE`/`XMODIFIERS` 已設 fcitx |
| 原生 `array.so` | **不存在** |
| `array.db` | **不存在** |
| libfmt | **未安裝**（原生 array 執行期需要） |
| Podman/Docker | **未安裝**（容器編譯需要） |

### 1.2 本專案會安裝的

| 項目 | 專案目標 |
|------|----------|
| 引擎 | 原生 **fcitx5-array 1.0.0**（AUR / ray2501） |
| 引擎 addon | `Addon=array`（專用引擎，非 table） |
| 二進位 | `/usr/lib/x86_64-linux-gnu/fcitx5/array.so` + `libarray.so` symlink |
| 聯想 | `libassociation.so` |
| 字根庫 | `/usr/share/fcitx5/array/array.db`（可由 `update-table` 用 gontera 官方 CIN 重建） |
| IM 名稱 | profile 內為 **`array`**（不是 `array30`） |
| 編譯方式 | Arch 容器內對齊 host 的 fcitx5 **5.1.7** + fmt **9.1.0** 後 makepkg |

### 1.3 功能差異（使用者能感受到的）

| 功能 | 本機 table (`array30`) | 專案原生 (`array`) |
|------|:---:|:---:|
| 基本行列輸入 | ✓ | ✓ |
| W+數字 符號 | ✗ | ✓ |
| 一級/二級簡碼 | ✗（table 設定有限） | ✓ |
| 萬用字元 `?` `*` | 僅表格式有限支援 | ✓ 引擎級 |
| 詞組 / 聯想詞 | ✗ / 弱 | ✓ |
| 反查碼 Ctrl+Alt+E | ✗ | ✓ |
| 大字集（獨立 IM） | 有 `array30-large` | 合併在原生字根表（可 update-table） |
| 接近 Windows 行列 | ✗ | ✓ |

### 1.4 技術差異一句話

本機是 **fcitx5 通用 table 引擎 + 靜態 dict**；專案是 **專用 C++ addon + SQLite `array.db`**，功能完整度明顯更高，但必須用與 host ABI 匹配的方式編譯。

---

## 2. 現有腳本對這台機器的支援程度

| 檢查項 | 結果 |
|--------|------|
| `detect_os` | `ID=pop` → 經 `ID_LIKE` 落到 **`debian`（實驗性）** |
| 路徑 | debian 路徑正確：`/usr/lib/x86_64-linux-gnu/fcitx5/` |
| 版本對應 | fcitx5 `5.1.7`、fmt `9.1.0` 在 Arch Archive **均有套件**（可 ABI pin） |
| 中文 locale | `zh_TW.utf8` 已存在 |
| 阻塞項 | 無容器 runtime；無 libfmt；debian 會跳出「實驗性」確認 |
| profile | install 會加 `array` 並 `DefaultIM=array`，但**預設不刪** `array30` / `array30-large` |
| uninstall 語意 | 只移除原生 array，**刻意保留** table 套件 |

**結論：** 邏輯上接近 Ubuntu 路徑，**幾乎可跑**，但 Pop 未一等公民化、缺前置套件、且「卸 table 改裝原生」的遷移流程尚未產品化。

---

## 3. 擴充計畫（程式面）

### P1 — Pop!_OS 一等公民（必要）

1. `detect_os`：`ID=pop` 直接對應 **ubuntu 路徑**（與 Ubuntu 24.04 同源 noble）。
2. `check_platform`：顯示「偵測到 Pop!_OS」，不再標實驗性。
3. README / help：列出 Pop!_OS 24.04 為支援平台。
4. diagnose：列出 `fcitx5-table-array30` / `-large` 狀態。

### P2 — 從 table 遷移到原生（必要，對應你的需求）

在 `install` 成功驗證 addon 載入後，可選執行：

1. **profile 清理**：移除 `Name=array30`、`Name=array30-large` 區塊；保留 `keyboard-us` / `array` / `chewing`。
2. **套件移除**：`sudo apt-get remove -y fcitx5-table-array30 fcitx5-table-array30-large`。
3. 重啟 fcitx5 再確認只有原生 `array`。

也可提供獨立指令（可選）：

```bash
./array30-setup.sh migrate-from-table   # 僅在原生 array 已可用時卸 table
```

### P3 — 前置依賴自動化（必要）

`check_container_runtime` 失敗時，對 ubuntu/pop 給出明確指令；install 流程可提示安裝：

```bash
sudo apt install podman libfmt9
```

（`check_fcitx5` 已有安裝 libfmt9 的邏輯，需確保在查 `HOST_FMT_VER` **之前**裝好。）

### P4 — 小修（建議）

- `setup_profile` 偵測 chewing 的一行有錯誤 redirect（`&>/dev/null` 再 pipe 給 grep），應改為與 `_maybe_install_chewing` 相同寫法。
- help 的 Version 字串與 `SCRIPT_VERSION` 對齊。

### P5 — 風險與驗證

| 風險 | 緩解 |
|------|------|
| fcitx5 5.1.7 在 SteamOS 文件標「未測試」 | 此版是 Ubuntu 22.04/noble 系常見版；Arch Archive 有 pin；靠 ldd + 載入驗證 |
| fmt 9 vs 10/11 ABI | 以 host `libfmt9` 9.1.0 為準降級容器 |
| Wayland 打字問題 | 環境變數已設；失敗時跑 `wayland-input-check.sh` |
| 移除 table 後想回滾 | 先 `apt install fcitx5-table-array30` 或 `./array30-setup.sh uninstall` 再裝回 table |

---

## 4. 本機遷移操作順序（執行面）

```text
1. 程式擴充合併（P1–P4）
2. sudo apt install -y podman libfmt9
3. ./array30-setup.sh install
     - 容器編譯 fcitx5-array（pin fcitx5 5.1.7 + fmt 9.1.0）
     - 安裝 array.so / array.db / conf
     - 設定 DefaultIM=array
     - 驗證 addon 載入
4. 確認原生可用後：
     - 自 profile 移除 array30 / array30-large
     - apt remove fcitx5-table-array30 fcitx5-table-array30-large
5. ./array30-setup.sh diagnose
6. （可選）./array30-setup.sh update-table   # 更新到最新 gontera 字根
```

---

## 5. 成功標準

- [ ] `OS_TYPE` 走 ubuntu 路徑，無「實驗性」誤報  
- [ ] `/usr/lib/x86_64-linux-gnu/fcitx5/array.so` 與 `libarray.so` 存在  
- [ ] `/usr/share/fcitx5/array/array.db` 存在  
- [ ] profile `DefaultIM=array`，無 `array30` / `array30-large`  
- [ ] `dpkg -l fcitx5-table-array30` 已移除  
- [ ] `./array30-setup.sh diagnose` 顯示 array addon 載入 OK  
- [ ] Ctrl+Space 可切到行列，W+數字 / 簡碼可用  
