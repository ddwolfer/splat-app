# vision/（splat-vision 負責）

## 環境

- M2 MacBook、Xcode（支援 visionOS 26 SDK 的版本）
- 目標裝置：第一代 Apple Vision Pro、visionOS 26
  - **不能使用 visionOS 27 才有的 API**
- 渲染：[MetalSplatter](https://github.com/scier/MetalSplatter)（Swift Package）

## 啟動方式

- Xcode：**`/Applications/Xcode-26.6.app`**（含 visionOS 26.5 SDK 與模擬器）。舊的 `Xcode.app` 是 16.1，不能用
  （MetalSplatter 1.0.x 需要 Swift 6.1+）。指令列用 `DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer`，
  不必改 `xcode-select`。
- 開專案：`open vision/SplatVision.xcodeproj`，scheme `SplatVision`，目的地選 Apple Vision Pro 模擬器 → Run。
  - Run 預設用 **Release**（Debug 讀大檔慢十倍以上）；Test 用 Debug。
- 專案由 XcodeGen 產生：**改 `project.yml` 或增刪檔案後**執行 `cd vision && xcodegen`，`project.yml` 與
  `SplatVision.xcodeproj` 一起 commit。（安裝：`brew install xcodegen`）
- 測試（指令列）：
  ```
  DEVELOPER_DIR=/Applications/Xcode-26.6.app/Contents/Developer xcodebuild test \
    -project vision/SplatVision.xcodeproj -scheme SplatVision \
    -destination 'platform=visionOS Simulator,name=Apple Vision Pro'
  ```
- mock 資料：建置時由 `tools/make_mock_ply.py` 產生 `mock_sharp.ply` 放進 App（不 commit `.ply`）。
  主視窗按「顯示範例」即可看到：天空在上、草地在下、白色箭頭朝上、紅球在左、黃方塊在右。
- 模擬器自動化：`xcrun simctl launch booted io.github.ddwolfer.SplatVision -autoOpenMock YES` 會自動開啟範例，
  再用 `xcrun simctl io booted screenshot out.png` 截圖。
- Xcode 26 首次建置若出現 missing Metal Toolchain：`xcodebuild -downloadComponent MetalToolchain`。

## 座標系（重要）

- ml-sharp PLY 是 OpenCV 慣例（x 右、y 下、z 前，相機在原點，單位公尺）；visionOS 是 y 上、−z 前。
- 轉換在 `SplatVision/Rendering/SceneTransforms.swift`：model 矩陣 = `placement · diag(1, −1, −1, 1)`。
- `placement` = 開啟當下的頭部位置 + 水平朝向（只取 yaw），之後固定在世界座標；「重新置中」會重算。

## 注意事項

- API 規格見根目錄 `API.md`；需要改規格請在 `NOTES.md`「給 server」提出或傳訊息。
- server 回傳的 `.ply` 座標系是 ml-sharp 原始輸出，轉換由 vision 端處理。
- Server Base URL 預設 `http://<PC 區網 IP>:8000`，實際 IP 見 `STATUS.md`。
- visionOS 要連區網 HTTP（非 HTTPS）需要在 Info.plist 設定 ATS 例外（`NSAllowsLocalNetworking`）及本地網路權限說明。
- 不要 commit `xcuserdata`、`*.xcuserstate`、`DerivedData`、`.build`。
