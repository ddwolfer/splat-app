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
- **本機 mock server**（照 API.md 回應，不需要 Windows PC）：
  ```
  python3 vision/tools/mock_server.py --host <Mac 區網 IP> --port 8765 [--count 1179648]   # --count：產生跟 SHARP 一樣大的 63 MB 檔
  ```
  App 的設定填 `http://<Mac 區網 IP>:8765`。`image_url` 含 `error`／`busy`／`slow` 會回 400／503／延遲 10 秒；
  multipart 上傳只收 JPEG／PNG／HEIC／WebP（看檔頭），上限 20 MiB（同真實 server）。
  整合測試：`TEST_RUNNER_SPLAT_MOCK_SERVER=http://<Mac 區網 IP>:8765 xcodebuild test ...`（沒設就跳過）。
  用區網 IP 而不是 127.0.0.1，才會測到 ATS 的區網例外。
- 模擬器相簿加照片：`xcrun simctl addmedia booted <圖片>`。
- 其他啟動參數：`-autoOpenFile <PLY 路徑>` 直接開 Mac 上的 PLY、`-hideWindow YES` 開啟後收起主視窗（截圖用）、
  `-autoGenerateURL <圖片網址>` 自動生成、`-autoUploadPath <Mac 上的圖片路徑>` 走照片上傳流程、
  `-showPhotoPicker YES` 開照片選擇器、`-showSettings YES` 開設定頁、`-splatBudget 300000` 顯示品質上限、
  `-serverBaseURL <url> -useMockService NO` 暫時指定 server（不寫入設定）。
- App 的 Mock 模式（設定頁開關，預設開到第一次儲存 Base URL 為止）：不連網路，回傳內建範例。

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
