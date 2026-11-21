# vision V0：骨架 + mock 顯示

## 目標

在 `vision/` 建立 visionOS App（SwiftUI），用 SPM 加入 MetalSplatter。mock 模式讀取 App bundle 內的範例 `.ply`，
在 ImmersiveSpace 裡顯示在使用者正前方，並以 **SHARP 的原始相機位置 = 使用者開啟當下的眼睛位置** 為原點
（SHARP 只在原始視角附近好看）。

## 環境與前提

- 目標：第一代 Vision Pro、**部署目標 visionOS 26.0**，不使用 visionOS 27 API。
- 這台 Mac 目前只有 Xcode 16.1（Swift 6.0、visionOS 2.1 SDK），**無法建置**：MetalSplatter 1.0.x 的
  `swift-tools-version: 6.1`，Swift 6.0 讀不了。已請使用者安裝 Xcode 26.6（含 visionOS 26.5 SDK，macOS 26.5.1 可裝；
  Xcode 27.2 需要 macOS 26.6）。指令一律用 `DEVELOPER_DIR=/Applications/Xcode-26.6.app/...`，不動 `xcode-select`。
- 在 Xcode 26 裝好之前：先寫程式、產生器腳本、XcodeGen 專案；Xcode 裝好之後再建置、跑測試、在模擬器驗證。

## 專案結構（全部在 `vision/`）

```
vision/
  project.yml                 XcodeGen 規格（專案的唯一來源）
  SplatVision.xcodeproj/      由 xcodegen 產生，也 commit（使用者不必安裝 xcodegen 就能開）
  SplatVision/
    App/        SplatVisionApp.swift（WindowGroup + ImmersiveSpace）、AppModel.swift（@Observable 狀態）
    Views/      ContentView.swift（V0：「顯示範例」「關閉」按鈕、狀態文字）
    Rendering/  ContentStageConfiguration.swift、SplatSceneRenderer.swift、RendererTaskExecutor.swift
    Rendering/  SceneTransforms.swift（純數學：座標轉換、只取 yaw 的擺放矩陣）
    Resources/  Assets.xcassets、Info.plist
  SplatVisionTests/           單元測試（座標數學、讀取 mock PLY）
  tools/make_mock_ply.py      產生 mock PLY（只用 Python 標準函式庫）
```

- **專案產生方式**：用 XcodeGen（Homebrew）。`project.yml` 可讀、可 review；產生的 `.xcodeproj` 一起 commit。
  之後要加檔案就改資料夾並重跑 `xcodegen`（README 會寫）。
- **MetalSplatter**：SPM `https://github.com/scier/MetalSplatter` `from: 1.0.1`，用 `MetalSplatter`、`SplatIO` 兩個 product。
  渲染迴圈改寫自 MetalSplatter SampleApp 的 `VisionSceneRenderer`（MIT，檔頭保留出處與授權聲明）。

## 渲染

- `ImmersiveSpace(id: "splat", for: SplatSource.self)` + `CompositorLayer`（Metal 直接畫），immersion style `.mixed`
  （看得到周圍環境；之後可加 `.full` 選項）。
- `SplatSource`：`Codable, Hashable` enum，V0 只有 `.bundledMock`；V1 會加 `.file(URL)`（下載後的 PLY）。
- 讀檔：`AutodetectSceneReader(url).readAll()` → `SplatChunk` → `SplatRenderer.addChunk`。
  MetalSplatter 1.0.1 的 PLY reader 會略過 `vertex` 以外的元素（ml-sharp 有 `intrinsic`、`extrinsic`、`image_size`…）。
- 讀檔中、讀檔失敗都要讓主視窗看得到狀態（AppModel 的 `loadState`）。

## 座標系與擺放（這個里程碑的重點）

- ml-sharp 輸出是 **OpenCV 慣例**：x 右、y 下、z 往前；相機在原點、看向 +z；單位是公尺（metric）。
- visionOS（ARKit / ImmersiveSpace）：右手系，x 右、y 上、使用者面向 −z。
- 轉換：繞 X 軸轉 180°，`(x, y, z) → (x, −y, −z)`。這是剛體旋轉（det = +1），所以不用改每顆 gaussian 的四元數，
  直接放在 model 矩陣裡即可。`openCVToVisionOS = diag(1, −1, −1, 1)`。
- 擺放：開啟 ImmersiveSpace 後，等 `WorldTrackingProvider` 拿到第一個 tracked 的 device anchor，
  取 **頭部位置 + 只取水平朝向（yaw）**，組成 `placement = T(頭部位置) · R_y(yaw)`，只算一次並固定在世界座標
  （不跟著頭動，才能左右移動頭看到視差）。
- yaw 的計算：device 的前方是 −Z 欄向量，投影到水平面；**投影長度 < 0.2（抬頭或低頭超過約 78°）時不擺放**，
  等下一幀（避免場景被固定到任意方向）。
- 最終：`viewMatrix = (head · view.transform)⁻¹ · placement · openCVToVisionOS`。
- 1:1 公尺比例，不縮放。
- 擺放邏輯抽成純值型別 `PlacementController`（輸入：每幀的頭部姿勢與「是否為模擬」；輸出：placement），
  方便單元測試世界固定、重新置中、重開。

### 頭部姿勢來源與後備（Codex #1、#2）

- 三種狀態：
  1. **追蹤中**：用真實 device anchor，相機和擺放都用它。
  2. **模擬頭部**：`WorldTrackingProvider.isSupported == false` 或 `arSession.run` 拋錯（不 `fatalError`），
     或已啟動但 2 秒內都沒有 tracked anchor。此時**相機和擺放共用同一個模擬頭部姿勢** `T(0, 1.6, 0)`，
     不會出現模型比眼睛高 1.6 m 的錯位；主視窗顯示「頭部追蹤無法使用，使用模擬視角」。
  3. 模擬中**之後才拿到真實 anchor**：用模擬姿勢算出的 placement 標記為「暫時」，第一個真實 anchor 到達時重新擺放一次。
- 追蹤中途短暫丟失：相機沿用最後一個有效姿勢，placement 不變。

### 生命週期（Codex #5）

- 每次開啟都建立新的 `SplatRequest { id: UUID, source }`，作為 ImmersiveSpace 的值；renderer 回報狀態時帶 id，
  AppModel 只接受目前 id 的回報，舊場次的結果一律丟掉。
- `LayerRenderer` 變成 `.invalidated`（使用者關閉、系統關閉）時：取消讀檔 Task、停止 `ARSession`、跳出 render loop，
  並回報「已關閉」，讓主視窗按鈕狀態恢復。
- 讀檔完成時先檢查 Task 是否已取消、layer 是否還有效，才加入 chunk。
- `openImmersiveSpace` 回傳 `.error` / `.userCancelled` 時，狀態回到「已關閉」並顯示原因。

## mock PLY

- `tools/make_mock_ply.py` 產生 **跟 ml-sharp 格式一樣** 的 binary little-endian PLY：
  `vertex`（x, y, z, f_dc_0..2, opacity, scale_0..2, rot_0..3，全部 float32），再加上 `image_size`、`intrinsic`、
  `extrinsic`、`frame`、`disparity`、`color_space`、`version` 這些 metadata 元素，確認 reader 會正確略過。
- 數值編碼跟 ml-sharp `save_ply` 一致（Codex #3）：`f_dc = (sRGB − 0.5) / C0`（C0 = 0.28209479），
  `opacity = logit(α)`，`scale = ln(σ 公尺)`，`rot_0..3 = (w, x, y, z)`，背景板用單位四元數。
- 內容用 OpenCV 座標，模擬一張 60° 水平視角、4:3 照片的 SHARP 輸出，而且**上下左右不對稱**，方便肉眼檢查座標轉換：
  - z = 4 m 的背景板：上半部天藍、下半部草綠，中間一個白色往上的箭頭（OpenCV 的「上」是 −y）。
  - 左邊 z = 2 m 一顆紅球、右邊 z = 2.5 m 一個黃色方塊。
  - 約 3 萬顆 gaussian，約 1.7 MB。
- **不 commit `.ply`**（CLAUDE.md 第 7 節）：用 Xcode 的 Run Script build phase 在建置時執行腳本，
  輸出到 App bundle（宣告 input/output 檔，相容 User Script Sandboxing）。Xcode 內附 `python3`。
  產生器固定 random seed，每次輸出相同。

## 驗證

1. `python3 tools/make_mock_ply.py out.ply` 產出檔案，header 和大小正確。
2. 單元測試（visionOS 模擬器，`xcodebuild test`）：
   - `SceneTransforms`：OpenCV 的 (0, −1, 4)（相機前方 4 m、偏上 1 m）轉換並擺放後，
     在使用者面向 −z、頭在 (0, 1.6, 0) 時，落在 (0, 2.6, −4)；頭向左轉 90° 時落在使用者左手邊 4 m；
     pitch/roll 不影響 yaw；**正上方、正下方的姿勢回傳 nil**（Codex #4）。
   - `PlacementController`（Codex #6）：擺放後頭部移動或轉向，placement 不變；重新置中只在下一個有效姿勢更新一次；
     模擬姿勢的 placement 在第一個真實姿勢到達時被取代、之後不再變；新場次（新 controller）用新姿勢。
   - 讀取 bundle 內的 mock PLY：splat 數量等於產生器寫的數量；metadata 元素被略過；
     **抽樣解碼**：第一顆 gaussian 的位置、sRGB 顏色、線性 opacity、公尺 scale 等於產生器寫入的值（Codex #3）。
3. 模擬器手動檢查（截圖 `xcrun simctl io booted screenshot`）：天空在上、紅球在左、箭頭朝上。
4. Debug 讀大檔很慢（MetalSplatter README 說差一個數量級以上），scheme 的 Run 預設用 Release。

## 不在 V0 範圍

UI 輸入網址、API client、設定頁（V1）；真實 server、效能調校（V2）；照片上傳（V3）；實機部署（V4）。

## Codex 審查

### Plan review（2026-11-21）

1. P2 後備 placement 與相機姿態不一致 → **採納**：模擬模式下相機與擺放共用同一個模擬頭部姿勢；暫時 placement 在真實 anchor 到達時重新擺放。
2. P2 `arSession.run` 失敗會 `fatalError` → **採納**：區分「不支援／啟動失敗」與「尚無 anchor」，前者進入模擬模式並在 UI 顯示，不終止 App。
3. P2 mock 缺數值編碼規格與解碼驗證 → **採納**：明訂 f_dc／logit／ln／wxyz，測試抽樣比對解碼後數值。
4. P2 只取 yaw 在垂直視線時退化 → **採納**：水平投影長度 < 0.2 不擺放、等下一幀；測試加入正上、正下姿勢。
5. P2 開關與載入的生命週期 → **採納**：每次開啟用 request id 隔離回報；invalidated 時取消讀檔、停止 ARSession、回報關閉。
6. P2 驗收無法證明世界固定與重新置中 → **採納**：擺放邏輯抽成 `PlacementController` 純值型別並寫狀態測試。

### Code review（2026-11-21，第一輪 5 點）

1. P2 關閉後 MetalSplatter sorter 背景迴圈與 GPU buffer 不會釋放（有 chunk 時 `sortLoop` 不結束且保留自己）→ **採納**：已查原始碼確認；`shutdown()` 改 async，先標記 `isShutDown` 再 `await removeAllChunks()`；載入完成時在鎖內檢查是否已關閉／取消，沒發布就立刻 `removeAllChunks()`。
2. P2 `render()` 回傳 false／拋錯仍提交未定義畫面 → **採納**：未完成渲染時在同一 command buffer 先清除再 present。
3. P2 先檢查 `isReadyToRender` 會把 GPU 背壓當成「未載入」而閃成透明 → **採納**：已載入就先等 in-flight semaphore 再畫。
4. P2 追蹤中斷時，重新置中被舊姿勢消耗 → **採納**：`Pose.kind`（tracked／held／simulated），`held` 不擺放、不消耗 recenter；新增測試。
5. P2 取消外層 Task 不會停止 `PLYReader` 底層讀取 → **部分採納，延到 V2**：這是 MetalSplatter 1.0.1 的限制（producer Task 沒接取消），App 端改不了；V0 的 mock 只有 1 MB、讀取 0.02 秒，影響可忽略。V2 要處理 63 MB／118 萬點的真實檔案，屆時針對 SHARP 固定格式寫可取消的快速讀檔器（同時避免逐點配置 `SplatPoint` 的效能問題），其他格式仍走 SplatIO。

第二輪（只審修正與受影響範圍）：沒有仍成立或新引入的 P1／P2。

## 驗證結果

- visionOS 26.5 模擬器：Debug／Release 建置成功，App 程式碼無警告；20 個單元測試全過（座標、擺放、追蹤後備、mock 讀取與解碼）。
- 模擬器截圖：天空在上、草地在下、箭頭朝上、紅球在左、黃方塊在右；「已載入 18,903 個 splat（0.02 秒）」「頭部追蹤中」（模擬器的 WorldTrackingProvider 可用）。
- 自動化：啟動參數 `-autoOpenMock YES` 會在開啟 App 時自動顯示範例，方便 `xcrun simctl io booted screenshot`。
