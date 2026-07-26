# 行列30 系統工作列 Icon

給 fcitx5 / 面板狀態列用的小圖示，以 **16–24px 可讀** 為優先（程式繪製，非 AI 糊字）。

## 預覽

見 [`preview-sheet.png`](preview-sheet.png)。

## 變體建議

| 變體 | 風格 | 工作列建議 |
|------|------|------------|
| **classic-blue** | 藍底白「行」 | **預設推薦**（傳統輸入法、高對比） |
| **modern-teal** | 青綠底白「行」 | 想和拼音/其他 IM 區隔 |
| **ink-gold** | 墨黑底金字 | 深色主題桌面 |
| **blue-active** | 藍底 + 綠點 | 強調「啟用中」 |
| **circle-blue** | 圓形藍底 | 現代圓標風格 |
| **geometric-blue / teal** | 3×4 點陣 | **16px 最穩**（不依賴字型） |
| **symbolic-white / dark** | 純「行」透明底 | 跟隨系統 symbolic 主題 |

## 目錄

```
icons/
  preview-sheet.png
  png/<variant>/array30-{16,22,24,32,48,64,128,256}.png
  png/<variant>-tray-24.png      # 工作列常用 24px
  svg/<variant>.svg              # 可縮放（「行」字需系統 CJK 字型）
```

## 安裝到本機 fcitx5 圖示

目前原生 array 的 conf 為 `Icon=fcitx-ibusarray`。可安裝到 user hicolor：

```bash
# 以 classic-blue 為例
ICON_SRC=icons/png/classic-blue
for s in 16 22 24 32 48 64 128; do
  mkdir -p "$HOME/.local/share/icons/hicolor/${s}x${s}/apps"
  cp "$ICON_SRC/array30-${s}.png" \
     "$HOME/.local/share/icons/hicolor/${s}x${s}/apps/fcitx-ibusarray.png"
done
gtk-update-icon-cache -f "$HOME/.local/share/icons/hicolor" 2>/dev/null || true
# 重啟 fcitx5 後生效
fcitx5 -r
```

或改 conf 使用自訂名稱（需 sudo）：

```bash
# Icon=array30-custom 並把 png 裝成 array30-custom.png
```

## 設計原則

1. **高對比**、少細節（面板上常只有 16–22px）
2. 辨識以 **「行」** 為主（與 fcitx Label=行 一致）
3. 幾何點陣作後備，避免極小尺寸字糊
4. 圓角方塊與多數桌面 tray 圖示一致
