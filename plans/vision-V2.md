# vision V2：接上真實 server、座標確認、第一代機效能

## 目標

1. 收到 splat-server「server 已可連線」（或 STATUS.md 的 M3 完成）後，用真實 server 生成與顯示。
2. 用真實 ml-sharp PLY 確認座標系（上下、前後、左右是否顛倒或鏡像）並修正。
3. 記憶體與 FPS 在第一代 Vision Pro 上順跑（實機數字要等 V4 裝機時量，這裡先把量測與調整手段做好）。
4. fp32／fp16 樣本視覺比對，結果寫在 NOTES.md「給 server」。

## 分兩段

**A. 不需要 server 的部分（M3 之前先做）**

### A1. SHARP 專用快速讀檔器（`SharpPLYLoader`，也解決 V0 延後的「讀檔不能取消」）

- 動機：SplatIO 會為 118 萬點逐一建立 `SplatPoint`（每點的 SH 是一個 heap 陣列），慢、吃記憶體，而且底層 producer Task
  不能取消。SHARP 的格式是固定的，直接轉成 MetalSplatter 的 `EncodedSplatPoint` 寫進 `MetalBuffer` 即可。
- 解析 ASCII header 到 `end_header`（header 最多 64 KB）；只在以下條件成立時走快速路徑，否則退回 SplatIO：
  `format binary_little_endian 1.0`、第一個 element 是 `vertex`、vertex 的屬性都是固定大小的純量、
  含 `x y z f_dc_0..2 opacity scale_0..2 rot_0..3` 且這 14 個都是 float32（其他屬性依型別大小跳過）、
  **沒有任何 `f_rest_*`**（有高階 SH 時交給 SplatIO，才不會丟掉方向性顏色；Codex #1）。
- 檔案用 memory-map 讀；點數必須 ≥ 0，`點數 × stride` 與 header 長度相加用**可偵測溢位**的運算，
  總長超過檔案就**直接報錯**（格式損壞不交給 fallback）。每個欄位用未對齊安全的方式讀（`loadUnaligned`）。（Codex #2）
- 轉換：`colorSH0 = f_dc`（MetalSplatter 要原始 SH0 係數）、`opacity = sigmoid(logit)`、`scale = exp(log)`、
  `rotation = quat(w = rot_0, x = rot_1, y = rot_2, z = rot_3).normalized`；公式與 SplatIO 相同。
- 有效性（Codex #3）：輸入任一欄位非有限值、四元數長度 < 1e-6、`exp(scale)` 非有限或最大軸 > 100 m
  （協方差超出 Float16 可表示範圍）的點都略過並計數；**全部被略過就報錯**，不回報「載入成功」。
- 平行轉換（Codex #4）：以 64K 點為一批，批內 `concurrentPerform` 讓每個 worker 寫互不重疊的區間
  （原索引位置）並在旗標陣列記錄有效與否；全部完成後**依序壓縮**成連續陣列，最後一次設定 `count`。
  測試在首、中、尾混入壞點。
- 取消（Codex #5）：每一批之間、以及 header 解析、篩選、建立 chunk、`addChunk` 前後都檢查取消；
  取消時釋放 buffer。退回 SplatIO 的路徑仍無法取消、`addChunk` 內建的 locality 排序也無法中斷，
  所以 **V1 的「載入中不切換」互斥照舊保留**。
- 驗證：同一個 mock PLY，快速讀檔器產出的每個 `EncodedSplatPoint` 和 SplatIO 路徑（`EncodedSplatPoint(SplatPoint)`）
  逐欄位比對（float16 容許誤差）；header 異常（截斷檔、非 little endian、缺欄位、型別不符）會退回或報錯；
  118 萬點的大 mock 在模擬器量讀取時間（目標：比 SplatIO 路徑快數倍）；取消測試。

### A2. 效能量測（主視窗的「效能」區塊）

- renderer 每秒回報（名稱照實際量到的東西，Codex #7）：**提交幀率**（每秒送出的 frame 數）、
  **GPU 時間**（command buffer `gpuEndTime − gpuStartTime` 的平均與最大，> 11 ms 表示跟不上 90 Hz）、
  成功渲染數與跳過／失敗幀數、splat 數。不宣稱是「實際呈現 FPS」。
- App 記憶體：`task_vm_info.phys_footprint`（Xcode 記憶體量表同一個數字）與 `os_proc_available_memory()`。
- 讀檔時間拆成：解析、建立 chunk、加入 renderer、**第一次排序完成**（用 MetalSplatter 的 `afterNextSort`）；
  排序耗時用 `onSortComplete`。都經 V0 的 request id 隔離。

### A3. splat 數量上限（設定頁「顯示品質」）

- 選項：全部（118 萬）／80 萬／50 萬／30 萬。超過上限時（Codex #6，不用未經驗證的重要度公式）：
  1. 先丟掉幾乎透明（opacity < 1/255）的點——畫面上本來就看不到；
  2. 仍超過就**固定 seed 的均勻隨機抽樣**到 N 個，保持空間覆蓋均勻（不會集中刪掉近景或薄表面）。
  在模擬器用大 mock 與 teaser 各截一張「全部」與「30 萬」比較。
- 預設「全部」；V4 在實機量到 FPS 後再決定預設值（例如 FPS 低於 60 就預設 50 萬）。
- 改設定後，下次開啟 splat 才生效（不即時重建）。

**B. 需要 server 的部分（M3 之後）**

### B1. 接上真實 server

- 設定填 STATUS.md 的 Base URL（預計 `http://192.168.0.32:8000`），「測試連線」看到 GPU 名稱。
- 用一張網路圖片跑完整流程；確認 503（忙碌）、404（被淘汰）等錯誤訊息合理。

### B2. 座標確認

- 下載 NOTES.md 提供的 teaser 樣本（fp16／fp32），在模擬器截圖：畫面要跟原圖同方向（不上下顛倒、不左右鏡像），
  場景在使用者前方約 1 m（teaser 的 z 中位數約 1.1 m）。
- 再用一張有明顯文字／左右不對稱的照片生成，確認沒有鏡像。
- 若有問題，修改 `SceneTransforms.openCVToVisionOS` 並更新單元測試（目前依 ml-sharp README 的 OpenCV 慣例推導）。

### B3. fp32／fp16 比對

- 同一個位置、同樣的視角各截一張，並排比較；寫在 NOTES.md「給 server」：看得出差異的區域、是否可接受。

## 不在 V2 範圍

照片上傳（V3）；實機安裝與實機 FPS 量測（V4，屆時依 A2 的數字調整 A3 的預設）。

## Codex 審查

### Plan review（2026-11-21）

1. P2 快速路徑會靜默丟掉高階 SH → **採納**：有 `f_rest_*` 就退回 SplatIO；測試。
2. P2 長度檢查的溢位與未對齊讀取 → **採納**：header 上限、溢位檢查、`loadUnaligned`；損壞直接報錯。
3. P2 只排除 NaN／Inf 不夠 → **採納**：檢查四元數長度、尺度與協方差範圍；全部無效就報錯。
4. P2 平行轉換的輸出壓縮 → **採納**：各 worker 寫不重疊區間＋旗標，最後依序壓縮；測試首中尾壞點。
5. P2 取消只涵蓋轉換批次 → **採納**：全流程檢查取消；fallback 與 locality 排序無法中斷，所以保留 V1 互斥。
6. P2 重要度公式可能刪掉清晰表面 → **採納**：改成「先丟透明點，再均勻隨機抽樣」，並截圖比較。
7. P2 量測事件定義 → **採納**：分開提交幀率、GPU 時間、成功／跳過幀、排序耗時與第一次排序完成；不稱「實際呈現 FPS」。

### Code review：A 段（2026-11-21）

第一輪 4 點：
1. P2 `end_header` 用子字串搜尋，註解含該字會提早結束 header → **採納**：逐行比對整行；CRLF 退回 SplatIO；測試。
2. P2 SplatIO fallback 忽略顯示上限 → **採納**：fallback 套同樣規則（先丟透明、共用固定 seed 抽樣）並回報；測試。
3. P2 首次排序事件早於 `.loaded` 時遺失 → **採納**：暫存並在 `.loaded` 時合併；測試兩種順序。
4. P3 成功／跳過以 drawable 計、提交以 frame 計 → **採納**：統一以 frame 計。

第二輪：沒有仍成立或新引入的 P1／P2。

## A 段驗證結果（模擬器）

- 67 個測試全過：快速讀檔器與 SplatIO 路徑逐欄位比對 mock 18,903 點一致；header 變體退回、損壞報錯；
  首中尾壞點略過且保持順序；全部無效報錯；上限抽樣固定且不含透明點；取消。
- Release、118 萬點大 mock（經區網 mock server）：解析 0.1 秒、加入 0.2 秒、首次排序完成 0.4 秒（V1 的 SplatIO 路徑整體約 0.5 秒）。
  模擬器的 GPU／幀率數字（全部：提交 33 幀/秒、GPU 平均 18 ms；30 萬：60 幀/秒）只供參考，實機在 V4 量。
- 觀察：30 萬點抽樣時，mock 裡點數少的紅球會變得透光；真實 SHARP 是每像素都有點，要用真實資料再評估。
