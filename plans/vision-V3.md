# vision V3：從照片 App 選圖，multipart 上傳

## 目標

主視窗可以從照片 App 選一張圖，用 `POST /generate` 的 multipart（欄位 `file`，見 API.md）上傳生成，
其餘流程（下載、歷史、自動顯示）沿用 V1。

## 做法

### 選圖

- SwiftUI `PhotosPicker(selection:matching: .images, preferredItemEncoding: .current)`：系統在 App 外執行，
  **不需要相簿權限**，也不用 Info.plist 說明。`.current` 保留原始格式（HEIC／JPEG／PNG）。
- 用**檔案型** Transferable（`FileRepresentation`）把原檔複製到 App 暫存資料夾，不把整張圖讀進記憶體（Codex #4）。
  上傳原始檔案（含 EXIF），不先轉成 `UIImage` 再壓縮：server 用 EXIF 的焦距算公制尺度（API.md「焦距」），
  重新編碼會丟掉 EXIF，場景比例就會錯。
- **從選圖開始就有 generation id**（Codex #1）：phase 多一個 `preparing`（從相簿／iCloud 取檔、檢查、縮圖）；
  改選另一張或按取消，舊的取檔結果一律丟棄；`loadTransferable` 回傳 nil 或失敗要顯示錯誤。

### 上傳前檢查（對齊 API.md 的圖片限制，全部在背景執行，不佔 MainActor）

- 用 `CGImageSource` 從檔案讀**實際格式**（不是副檔名）與尺寸，不解碼整張圖。
- 原檔直接上傳的條件：格式是 JPEG／PNG／HEIC／WebP（server 的 Pillow 確定能解，Codex #2）、≤ 20 MB、≤ 40 MP。
- 其他情況（其他格式、超過大小或像素）：用 ImageIO 縮圖（長邊 4096、≤ 40 MP，直接從檔案降採樣），
  **先合成到白底**（透明 PNG 不會變黑，Codex #3），輸出 JPEG（品質 0.9），**複製原檔 metadata（含 EXIF 焦距）**，
  方向在縮圖時套用並把 Orientation 設為 1。縮完仍 > 20 MB 就報錯。
- 副檔名與 MIME **依最後輸出的資料**決定（原檔沿用其格式；轉換後一律 `image/jpeg`、`.jpg`）。
- ImageIO 讀不出來（不是圖片）就在本機報錯，不上傳。

### API client

- `SplatService` 新增 `generate(imageData:filename:mimeType:progress:)`：
  - multipart/form-data，隨機 boundary（確認不出現在資料中）；`Content-Disposition: form-data; name="file"; filename="..."`，
    檔名只留安全字元（去掉引號、換行、路徑），`Content-Type` 用上面的 MIME。
  - multipart body **寫成暫存檔**（串流複製圖片檔），用 `URLSession.uploadTask(with:fromFile:)` 上傳，
    觀察 `countOfBytesSent` 回報進度；逾時同 V1 的 generate（300 秒）；結束後刪除暫存檔。
  - 錯誤處理、取消與 V1 相同（413／415／400 會顯示 server 的 `{"error"}`）。
- `MockSplatService` 與 `tools/mock_server.py` 都支援 multipart（mock server 用標準函式庫 `email` 解析，檢查 `file` 欄位與 20 MB 上限）。

### 生成流程

- `GenerationController.start(upload:)`：phase 多一個 `uploading(進度)`，上傳完成後轉成 `generating`（等 server 回應），
  之後同 V1（generation id、server 快照、下載、提交歷史、自動顯示）。
- 歷史：`imageURL` 存 `upload:<檔名>`（與 server `/list` 的 `source` 格式一致）；另外存一張**本機縮圖**
  （長邊 256 的 JPEG，`thumbs/<id>.jpg`），清單用它顯示。舊紀錄沒有縮圖欄位仍可讀（欄位可選）。
- 縮圖完全套用 V1 的歷史規則（Codex #5）：與 PLY 一起提交（JSON 寫入失敗兩者都回滾）、刪除、淘汰；
  `thumbs/` 裡沒被紀錄引用的檔案計入「未列入紀錄」的數量與容量，「全部清除」會清掉，按鈕條件也包含它們；
  重新下載 PLY 時保留原本的縮圖。

## 驗證

1. 單元測試：multipart body 的格式（boundary、header、內容完整、檔名淨化）；MIME／副檔名對應；
   上傳進度與取消；超過上限的縮圖保留 EXIF 焦距、套用方向、像素 ≤ 40 MP；非圖片報錯；
   歷史縮圖的提交／刪除／全部清除；舊格式紀錄可讀。
2. 整合測試：模擬器內的測試對 Mac 區網 IP 上的 `mock_server.py` 做 multipart 上傳 → 下載 → 解析。
3. 模擬器：`xcrun simctl addmedia` 放一張照片進相簿，截圖確認 PhotosPicker 出現；上傳流程用啟動參數自動跑一次並截圖。
4. 真實 server（M3 之後）：用一張有 EXIF 焦距的照片上傳，確認比例合理（與 V2 的座標檢查一起）。

## 不在 V3 範圍

相機拍照、一次選多張、批次生成。

## Codex 審查

### Plan review（2026-11-21）

1. P2 取消與隔離要從選圖載入開始 → **採納**：`preparing` 階段納入 generation id；nil／失敗顯示錯誤。
2. P2 ImageIO 可解不等於 server 可解；MIME 要依輸出 → **採納**：只有 JPEG／PNG／HEIC／WebP 原檔上傳，其他轉 JPEG；MIME 依輸出資料。
3. P2 轉 JPEG 前要白底合成 → **採納**：測試半透明邊緣。
4. P2 原圖整個載入記憶體 → **採納**：檔案型 Transferable、從檔案降採樣、背景執行、multipart 寫暫存檔上傳。
5. P2 縮圖要納入歷史規則 → **採納**：提交回滾、淘汰、未索引統計、全部清除、重新下載保留縮圖。

### Code review（2026-11-21）

第一輪 4 點：
1. P2 取消準備後仍會繼續完整轉檔 → **採納**：縮圖後、轉檔前後都檢查取消；產生的暫存檔在失敗／取消時以 `defer` 刪除；測試。
2. P3 縮圖編碼失敗留下暫存檔 → **採納**：finalize 失敗時刪除輸出。
3. P3 大小上限與 server 不一致（20,000,000 vs 20 MiB）→ **採納**：改為 20 × 1024 × 1024（與 API.md 一致：20,971,520 bytes），mock server 同步；測試。
4. P3 總容量沒算縮圖 → **採納**：`totalBytes` 納入已索引縮圖；測試。

第二輪：沒有仍成立或新引入的 P1／P2。

## 驗證結果

- 模擬器 89 個測試全過：原檔直送（JPEG／PNG／HEIC 保留原始位元組）、TIFF 轉 JPEG 保留 EXIF 焦距、超過像素上限縮圖、
  方向套用（Orientation 6 → 直立、Orientation 欄位為 1）、透明區變白、非圖片報錯、檔名淨化、multipart 位元組完整、
  上傳與錯誤訊息、歷史縮圖（提交、回滾、刪除、重新下載保留、未索引統計、舊紀錄可讀）、選圖被取消不會上傳、
  對 Mac 區網 IP 上 mock server 的 multipart 整合測試（含非圖片回 400）。
- Release 模擬器：`-autoUploadPath` 端對端（上傳 139 KB JPEG → 生成 → 下載 → 自動顯示，歷史顯示本機縮圖）；
  `-showPhotoPicker` 確認系統照片選擇器出現（顯示「私密取用照片」，不需要相簿權限）。
- 真實 server 的上傳（含 HEIC 與 EXIF 焦距比例）與 V2 B 段一起在 M3 之後驗證。
