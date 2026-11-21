# vision V1：UI + API client

## 目標

主視窗：網址輸入欄、生成按鈕、進度與耗時顯示、歷史清單；設定頁：修改 server Base URL（UserDefaults）。
依 `API.md` 實作 API client；Info.plist 加 ATS 例外，允許區網 HTTP。server 還沒好，先用 mock 推進。

## API client（`SplatVision/Networking/`）

- `SplatService` protocol：`health()`、`generate(imageURL:)`、`downloadPLY(path:to:progress:)`。兩個實作：
  - `HTTPSplatService`：照 `API.md`。
    - `GET /health` → `{ok, gpu}`。
    - `POST /generate`，`Content-Type: application/json`，body `{"image_url": "..."}` → `{id, ply_url, seconds}`。
      逾時 300 秒（首次推論、排隊都可能拉長）；其他請求 15 秒。
    - `GET /splats/<id>.ply`：`ply_url` 是相對路徑，用 Base URL 組合（Base URL 有無結尾 `/`、有路徑前綴都要正確）。
      用 `URLSessionDownloadTask`，觀察 `task.progress` 回報下載進度（約 63 MB），完成後移到 App 的儲存位置。
    - 錯誤：非 2xx 時解析 `{"error": "..."}` 顯示給使用者；不是 JSON 時顯示 HTTP 狀態碼；連線失敗、逾時、
      區網權限被拒（`NSURLErrorNotConnectedToInternet`／local network denied）轉成中文提示。
    - 支援取消（Swift Task 取消 → 取消 URLSession task）。
  - `MockSplatService`：不連網路，模擬延遲後回傳 App 內的 `mock_sharp.ply`。設定頁有「Mock 模式」開關（預設開，
    直到設定 Base URL 為止），讓沒有 server 也能操作整個流程。
- V3 的 multipart 上傳之後加在同一個 protocol（`generate(imageData:)`）。

## 設定（`Settings`）

- `UserDefaults`：`serverBaseURL`（字串）、`useMockService`（布林）。
- 驗證：去掉空白；必須是 `http`／`https` 且有 host；去掉結尾 `/`。不合法時不儲存並顯示原因。
- 「測試連線」按鈕：呼叫 `/health`，顯示 GPU 名稱或錯誤。
- 預設 Base URL 空白（server 的實際 IP 等 STATUS.md 的 M3 填入後，使用者自己輸入）。

## 生成流程（`GenerationController`，@MainActor @Observable）

```
idle → generating(開始時間) → downloading(進度) → 加入歷史 → 開啟沉浸空間顯示 → idle
                     ↘ failed(訊息)      ↘ failed / cancelled
```

- 輸入：去掉空白，必須是 `http`／`https` 網址（server 會自己下載這張圖）。生成中停用按鈕，避免重複送出；提供「取消」。
- 進度：POST 是同步的，server 端沒有進度可讀，所以顯示「server 生成中… 已等 N 秒」（每 0.1 秒更新）；
  下載時顯示百分比與 MB；完成後顯示「server 生成 X 秒｜下載 Y 秒｜總計 Z 秒」，載入 splat 的秒數沿用 V0 的狀態列。
- **每次生成有自己的 generation id**（Codex #1）：進度回報、檔案發布、寫歷史、自動顯示之前都檢查 id 仍是目前這次；
  取消會讓 id 失效，所以「取消 A 後立刻開始 B」時，A 的任何結果都不會寫進歷史或被顯示。
- **開始時固定 service 快照**（Codex #2）：生成途中改設定不影響這一次（POST 與下載都打同一個 server）。
- 完成後自動顯示：交給下面的「顯示切換」統一處理。

## 顯示切換（`ImmersiveController`，Codex #3、#4）

- 所有「顯示某個 splat／關閉」都走同一個序列化入口，**後到的請求取代還沒執行的請求**（最後一次選擇為準）。
- 依序執行：等目前的 splat 讀檔結束（載入中不切換，避免兩份 118 萬點的解析同時進行）→ 關閉舊空間並等 renderer
  回報 `.closed`（V0 的 shutdown 會釋放 sorter）→ 用新的 request id 開啟。
- `.opening`／`.closing`／載入中時 UI 顯示「切換中」，按鈕可以按但只會更新待執行的請求。
- V0 延後的「PLYReader 無法取消」：上面的序列化保證 App 主動切換不會讓兩份解析重疊；只剩「系統在載入中關閉空間」時
  舊解析會跑完才結束，V2 的可取消讀檔器會徹底解決。
- 驗收要有大檔：`make_mock_ply.py --count 1179648` 產生跟 SHARP 一樣點數、約 63 MB 的 mock，透過 mock server 下載與載入。

## 歷史（`HistoryStore`）

- 每筆：server `id`、`imageURL`、建立時間、server 秒數、總秒數、檔名、檔案大小，以及**來源**（Codex #2）：
  `mock` 或 `server(baseURL, plyPath)`。重新下載一律用紀錄裡的來源，不用目前設定；mock 紀錄從 App 內重建。
- 存放：`Application Support/history.json` + `Application Support/splats/<id>.ply`，資料夾設 `isExcludedFromBackup`
  （每個檔約 63 MB，不該進 iCloud 備份）。
- 上限 10 筆（約 630 MB），超過時刪最舊的檔案與紀錄；清單顯示總容量；可滑動刪除、可「全部清除」。
- **提交順序與失敗回復**（Codex #5）：下載到暫存檔 → 搬到 `splats/<id>.ply` → 以原子寫入更新 `history.json`；
  JSON 寫入失敗就刪掉剛搬入的檔案並回報錯誤。**新的一筆完整保存後才淘汰舊筆**（先寫 JSON 再刪檔）。
  啟動時對帳：刪掉不在紀錄裡的孤兒檔，紀錄裡缺檔的標示「檔案不存在」。測試注入寫入失敗。
- **保護顯示中的檔案**（Codex #6）：目前顯示（含讀取中）的那一筆不能滑動刪除，自動淘汰時跳過它；
  「全部清除」先關閉沉浸空間、等 `.closed`，再刪除。
- 點一筆 → 顯示該 splat；檔案不見（例如被手動刪除）時標示「檔案不存在」並提供用 id 重新下載。
- 清單顯示原圖縮圖（`AsyncImage(url: imageURL)`，失敗時顯示圖示）。
- `SplatSource` 新增 `.localFile(URL)`。

## Info.plist

- `NSAppTransportSecurity` → `NSAllowsLocalNetworking = YES`（允許區網 HTTP，不開 `NSAllowsArbitraryLoads`）。
- `NSLocalNetworkUsageDescription`：「連線到同一個區網內的 splat server，用照片生成 3D 場景」。
- 實際驗證：模擬器連 **Mac 的區網 IP**（不是 127.0.0.1）上的 mock server，確認 ATS 允許。

## mock server（`vision/tools/mock_server.py`）

- Python 標準函式庫，照 `API.md` 回應 `/health`、`/generate`（JSON；之後加 multipart）、`/splats/<id>.ply`、`/list`；
  `/generate` 延遲 2 秒後回傳用 `make_mock_ply.py` 產生的檔案；`image_url` 含 `error` 時回 4xx `{"error": ...}`。
- 只在本機開發用，預設綁 `0.0.0.0:8765`（測 ATS 需要區網 IP），README 註明。

## 驗證

1. 單元測試（`URLProtocol` stub，不需要網路）：
   - `/health`、`/generate` 解碼；`/generate` 的 method、header、JSON body 正確；
   - `ply_url` 與 Base URL 組合（有無結尾 `/`、有路徑前綴）；
   - 4xx/5xx 的 `{"error"}` 轉成訊息；非 JSON 錯誤 body；
   - 下載寫入檔案、回報進度、取消會停止。
   - Base URL 驗證；`HistoryStore` 新增／持久化重讀／刪除會刪檔／超過上限刪最舊。
2. 整合測試（有設定環境變數才跑）：模擬器內的測試連 Mac 區網 IP 上的 `mock_server.py`，跑完整的 health → generate → download。
3. 模擬器截圖：主視窗（輸入、進度、歷史）、設定頁。

## 不在 V1 範圍

真實 server 與座標／效能調校、可取消的快速 PLY 讀檔器（V2）；照片上傳（V3）；實機部署（V4）。

## Codex 審查

### Plan review（2026-11-21）

1. P2 取消要隔離整次生成流程 → **採納**：generation id，所有副作用前檢查；測試「取消 A 後立刻開始 B」。
2. P2 歷史缺來源 server、生成途中改設定 → **採納**：開始時固定 service 快照；歷史記錄來源（mock／baseURL + plyPath）。
3. P2 自動顯示與歷史點選要共用切換控制 → **採納**：`ImmersiveController` 序列化入口，最後一次請求為準。
4. P2 V0 延後的讀檔取消問題在大檔會出現 → **部分採納**：V1 用「載入中不切換、等 `.closed` 再開新的」保證 App 主動切換不重疊；
   可取消的快速讀檔器仍在 V2（系統在載入中關閉空間的情況屆時解決）。驗收加入 118 萬點、約 63 MB 的大 mock。
5. P2 檔案與 `history.json` 的提交與失敗回復 → **採納**：暫存 → 搬檔 → 原子寫 JSON，失敗清理；新筆保存後才淘汰；啟動對帳；注入失敗測試。
6. P2 刪除／淘汰可能刪到讀取中的檔案 → **採納**：顯示中的一筆不可刪、淘汰時跳過；全部清除先關閉空間。

### Code review（2026-11-21）

第一輪 6 點（全部 P2，全部採納）：
1. 索引讀取失敗會把所有 PLY 當孤兒刪光 → 已修（見第三輪的最終做法）。
2. 切換途中目標檔失去刪除保護 → `activeTarget` 從取出到開啟／失敗／被取代前都在 `protectedFiles`；測試。
3. 關閉期間收到新命令仍先開過時場景 → 關閉後若有更新命令就跳過、重新迴圈；測試（切換中按關閉不開 B；A→B→C 只開 A、C）。
4. 逾時被當成完成 → `waitUntil` 回傳成敗；載入或關閉逾時就中止佇列並顯示錯誤；`resourcesPending` 在 renderer 確認 `.closed` 前禁止開新的；測試。
5. 全部清除可能在場景開著時刪檔 → `closeForMaintenance`：鎖住期間拒絕 `show()`，確認真的關閉才刪；測試。
6. 提交失敗留下 63 MB 暫存檔 → 下載後 `defer` 清理；測試。

第二輪 1 點（P2，採納）：索引改名保留後，下次啟動仍會把舊 PLY 當孤兒刪除 → 先改成移到 `recovered-*` 資料夾。
第三輪 2 點（P2，採納，改用更簡單的策略）：搬移失敗仍可能刪檔；只有復原檔時無法清除 →
**App 永遠不自動刪除不在索引裡的檔案**，只計數並在 UI 顯示；檔案只會因刪除／淘汰已知紀錄或「全部清除」而刪除。
讀不到的 `history.json` 改名為 `history.unreadable-<時間>.json` 保留；「全部清除」在有未索引檔時也會出現。
第四輪：沒有仍成立或新引入的 P1／P2。

另外自己在測試中抓到並修正：`start()` 在 Task 裡才設「生成中」，連點會重複送出 → 改為同步設定；
`URLSessionTask.progress` 的單位不一定是位元組 → 改觀察 `countOfBytesReceived`；Base URL 沒寫 `http://` 時自動補上。

## 驗證結果

- visionOS 26.5 模擬器：52 個測試全過，包含對 **Mac 區網 IP（192.168.0.18）上 `mock_server.py`** 的整合測試：
  health → generate → 下載 63 MB → 解析 1,179,648 點（HTTP 走區網 IP，ATS 設定可用）。
- 模擬器 Release 端對端（`-autoGenerateURL`）：生成中計時、下載、寫入歷史、自動開啟沉浸空間；
  118 萬點在模擬器載入約 0.5 秒（M2；實機第一代 Vision Pro 的數字在 V2 量）。
- 設定頁：Base URL、測試連線、Mock 開關。
