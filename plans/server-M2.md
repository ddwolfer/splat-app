# server M2：FastAPI 實作 API.md

## 目標

依 `API.md` v1 實作 `/health`、`/generate`、`/splats/<id>.ply`、`/list`；模型啟動時只載入一次；下載圖片有大小上限與逾時；大圖先縮圖；輸出存在 `server/splats/`。附 curl 測試指令，並準備 fp32／fp16 範例 .ply 給 vision 端比對。

## 設計

### 檔案

- `server/app.py`：FastAPI app（lifespan 載入模型）
- `server/fetch.py`：安全下載圖片（SSRF 防護、大小／逾時限制）
- `server/imaging.py`：解碼、EXIF 轉正、焦距、縮圖（重用 ml-sharp `io.load_rgb`）
- `server/config.py`：設定（環境變數覆寫）
- `server/run_server.ps1`、`server/run_server.sh`：設 `PYTHONNOUSERSITE=1` 後啟動 uvicorn
- `server/tests/test_api.py`：pytest，用假模型測 API 邏輯（不需要 GPU）
- 新套件：`fastapi`、`uvicorn`、`httpx`、`python-multipart`、`pytest` → 更新 `requirements-lock.txt`

### 端點

- `GET /health` → `{"ok": true, "gpu": torch.cuda.get_device_name(0)}`；模型還在載入時回 503 `{"error": "model loading"}`。
- `POST /generate`：依 `Content-Type` 分流
  - `application/json` → `{"image_url": "..."}`
  - `multipart/form-data` → 欄位 `file`
  - 其他 → 415
  - 流程：取得圖片 bytes → 寫入暫存檔 → `load_rgb`（處理 EXIF 方向、焦距、HEIC）→ 長邊超過 `MAX_SIDE`（預設 2048）就用 Pillow LANCZOS 在 CPU 縮圖，`f_px` 等比例縮放 → GPU 推論（`asyncio.Lock` 串行化，丟到 threadpool 執行，不阻塞 event loop）→ `save_ply` 到 `splats/<id>.ply.tmp` 再 rename（原子寫入）→ 寫 sidecar `splats/<id>.json`（來源、尺寸、耗時、建立時間、amp）。
  - 回 `{"id", "ply_url": "/splats/<id>.ply", "seconds"}`；`seconds` = server 端從收到請求到 .ply 寫完的總時間。
- `GET /splats/{id}.ply`：`id` 必須是合法 UUID（擋路徑穿越），`FileResponse`，`application/octet-stream`；找不到回 404。
- `GET /list`：讀 sidecar json，依時間新到舊列出 `{id, ply_url, seconds, created, source, size_bytes}`。

### 限制與安全（環境變數可調）

| 項目 | 預設 |
|---|---|
| 下載／上傳大小上限 | 20 MB（串流讀取，超過立即中止 → 413） |
| 下載逾時 | 連線 5 秒、整體 20 秒（→ 504） |
| 協定 | 只允許 http/https（→ 400） |
| Redirect | 手動追蹤最多 3 次，每一跳都重新檢查 |
| SSRF | 解析 DNS，任何 IP 是 private／loopback／link-local／multicast／reserved／unspecified 就拒絕（→ 400）；`ALLOW_PRIVATE_URLS=1` 可放行（例如要抓區網 NAS 的圖） |
| 解碼像素上限 | `Image.MAX_IMAGE_PIXELS = 40MP`（擋 decompression bomb → 400） |
| 內容檢查 | 用 Pillow 實際解碼判斷是否為圖片，不信任 Content-Type |
| 等待佇列 | 正在推論 + 最多 2 個等待；超過回 503 `{"error": "busy"}` |
| 儲存上限 | 保留最新 `MAX_SPLATS`（預設 40 個，約 2.5GB），超過刪最舊的 |
| CUDA OOM | 捕捉 `torch.OutOfMemoryError` → `empty_cache()`，回 503 |

- 錯誤格式統一 `{"error": "..."}`：自訂 `HTTPException`、`RequestValidationError`、未預期例外（500，不洩漏 stack trace）的 handler。
- 已知殘餘風險：DNS rebinding（檢查與實際連線之間 DNS 改變）。這是區網個人工具，記錄下來不處理；若要處理可改成連到已驗證的 IP 並帶 Host header。

### 綁定

M2 開發與測試綁 `127.0.0.1:8000`；M3 改為 `0.0.0.0:8000`（啟動腳本用參數控制）。

### 測試

1. pytest（假模型，不載入 GPU）：health、JSON／multipart 兩種輸入、415、無效 JSON、非圖片、超過大小、SSRF（127.0.0.1、10.x、169.254.169.254、`localhost`、redirect 到私有 IP）、非 http scheme、非法 id／路徑穿越、404、錯誤格式、/list。下載用 `httpx.MockTransport` 或本機測試伺服器。
2. 真實模型 + curl：
   ```bash
   curl -s http://127.0.0.1:8000/health
   curl -s -X POST http://127.0.0.1:8000/generate -H "Content-Type: application/json" -d '{"image_url":"https://..."}'
   curl -s -X POST http://127.0.0.1:8000/generate -F "file=@server/third_party/ml-sharp/data/teaser.jpg"
   curl -s -o out.ply http://127.0.0.1:8000/splats/<id>.ply
   curl -s http://127.0.0.1:8000/list
   ```
   用一張公有領域的網路照片（例如 Wikimedia Commons）測 `image_url` 路徑。
3. 連續送 4 個請求，確認串行化、佇列上限、VRAM 不累積。

### 範例 .ply 給 vision

`server/scripts/make_samples` 產生 `teaser` 的 fp32／fp16 兩份，放在 `server/splats/`，透過 server 的 `/splats/<id>.ply` 提供；id 寫在 NOTES.md「給 vision」。因為這台沒有 `gh`、也不把 63MB 的檔案放進 git，vision 端要等 M3（防火牆打開）後才能下載；M3 緊接在 M2 之後。

## 風險

- 同步 API：一次請求約 6 秒推論 + 2.5 秒存檔 + 下載時間，client 逾時要設 60 秒以上（寫進 API.md 說明，屬於說明補充，不改變規格 → 一樣記 CHANGELOG）。
- `load_rgb` 需要檔案路徑 → 用暫存檔，結束後刪除。
- `.ply` 約 63MB，區網下載數秒；之後如需要可考慮壓縮格式（另外討論）。

## 依 Codex plan review 修訂的設計（優先於上文）

1. **SSRF／DNS rebinding**：下載改用 `httpcore.ConnectionPool(network_backend=SafeBackend())`。`SafeBackend.connect_tcp` 在**實際連線當下**解析 DNS，只要任一個回覆 IP 不允許就拒絕（處理公私混合回覆），然後連到已驗證的 IP；TLS 的 SNI／憑證驗證仍用原 hostname（httpcore 以 origin host 做 `start_tls`）。允許條件：`ip.is_global` 且非 multicast；IPv4-mapped IPv6 以內含的 IPv4 判斷。`ALLOW_PRIVATE_URLS` 改成 CIDR 白名單 `ALLOWED_PRIVATE_NETS`（預設空）。httpcore 不讀環境 proxy。每次 redirect 都重新走同一套。
2. **准入控制**：整條 `/generate`（讀 body、下載、解碼、推論、存檔）共用 3 個名額（1 個執行 + 2 個等待），在讀取 body **之前**取得，額滿立即 503 `busy`。JSON body 上限 4KB；上傳先檢查 `Content-Length`，再以串流讀取並在超過 20MB 時中止（413），之後才交給 Starlette 解析 multipart（`max_files=1, max_fields=1`）。
3. **GPU 串行化**：單一 uvicorn worker、不開 reload；解碼＋推論＋存檔放進**單執行緒** `ThreadPoolExecutor`，所以 GPU 工作不可能重疊。client 斷線時，已送進 executor 的工作照常完成（結果出現在 `/list`），准入名額在工作真正結束時才釋放（`future.add_done_callback`）。
4. **像素上限**：自己解碼，不用 `load_rgb`。`Image.open` 只讀 header，先檢查 `w*h <= 40MP`（HEIC 一樣，透過 `pillow_heif.register_heif_opener()`），並把 `DecompressionBombWarning` 轉成錯誤。
5. **整體期限**：下載建立一個 20 秒的 deadline，DNS／連線／每一塊讀取都用 `min(剩餘時間, 5s)` 當 timeout，每讀一塊就檢查 deadline；`Accept-Encoding: identity`（httpcore 本來就不會解壓）。
6. **影像正規化**：`ImageOps.exif_transpose`（含鏡射）→ `convert("RGB")`（調色盤、CMYK、LA、灰階）→ CPU 縮圖到長邊 ≤ 2048 → `np.uint8`。焦距：沿用 ml-sharp 的 EXIF 規則（35mm 等效 → FocalLength → 預設 30mm）與 `convert_focallength`，用**縮圖後**尺寸計算，並驗證為有限正數。
7. **OOM**：在 worker 內 `except torch.OutOfMemoryError`：刪除區域 tensor 參考、`gc.collect()`、`empty_cache()`，回 503；測試要驗證下一個請求能成功。不自動退回 fp32。fp32 範例在 server 停止時用 bench 腳本離線產生。
8. **檔案一致性**：輸入暫存檔不需要（直接從記憶體 bytes 解碼）。`<id>.ply.tmp` → rename `<id>.ply` → `<id>.json.tmp` → rename `<id>.json`（**json 是完成標記**；`/splats` 與 `/list` 只認有 json 的）。啟動時清掉 `*.tmp` 與沒有 json 的 ply。生成前檢查磁碟剩餘 ≥ 2GB，否則 507。淘汰最舊的（依 json 的 created），刪除失敗（例如 Windows 上檔案正在被下載）就略過、下次再試。
9. **存取控制／隱私**：**部分採納**。不加 token（API.md 規格沒有驗證，加了要同步改 vision；區網個人用途）；M3 防火牆規則限定 Private profile + LocalSubnet。`source` 只存 `scheme://host/path`（去掉帳密與 query），log 也一樣。
10. **啟動與行為定義**：接受「模型載入完才開始 listen」，`/health` 只要能回就是 ready。在 API.md 補充：client 逾時建議 ≥ 120 秒、503 busy 可稍後重試、斷線不取消生成、保留最新 40 個、`/list` 格式。屬於規格補充 → 記 CHANGELOG。
11. **測試**：真的同時送出、慢速串流、超限 multipart、像素炸彈、色彩模式（P、CMYK、LA、I;16、EXIF 方向）、SSRF（IPv6、IPv4-mapped、公私混合 DNS、redirect 到私有 IP、rebinding：第一次解析公有、第二次私有）、取消後不重疊、假模型丟 OOM 後下一個請求成功。

## Codex 審查

### Plan review（2026-11-21）
1. DNS rebinding 要修、私網放行改白名單、停用 proxy → **採納**：SafeBackend 在 connect 時驗證並連到已驗證 IP；CIDR 白名單。
2. 准入限制要在讀 body 前、限制 body/欄位 → **採納**：3 個名額涵蓋整條流程，串流讀取上限。
3. asyncio.Lock 不夠、單 worker、取消不可提早釋放 → **採納**：單執行緒 executor + done callback 釋放名額。
4. 40MP 上限有漏洞（io.py 改成 200MP、Pillow 只警告） → **採納**：解碼前自己檢查尺寸、警告轉錯誤。
5. 整體逾時要自己實作、拒絕壓縮 → **採納**：deadline + identity encoding。
6. load_rgb 不是安全的正規化器 → **採納**：自己解碼，只沿用焦距規則。
7. OOM 恢復、fp32 範例離線產生 → **採納**。
8. 檔案一致性（json 完成標記、孤兒清理、磁碟空間） → **採納**。
9. 加 token、遮蔽 source → **部分採納**：遮蔽 source 採納；token 不加（會改 API 規格與 vision 端，區網個人用途，改以防火牆 LocalSubnet 限制）。
10. 啟動與行為要寫清楚 → **採納**：模型載入後才 listen；API.md 補充行為說明。
11. 測試補邊界 → **採納**：見上方第 11 點；磁碟寫入失敗不做自動化測試（難以穩定模擬），以程式碼審查代替。

### 實作結果（2026-11-21）
- pytest 96 項通過（假模型）。真實模型 + curl：multipart 8.6 秒、image_url（Wikimedia 原始檔）9.0 秒；SSRF（169.254.169.254）400；錯誤 Content-Type 415。
- 同時送 4 個：3 個依序完成（8.5／16.7／25.1 秒），第 4 個立刻 503；VRAM 穩定在 7.2GB。
- server 輸出與 M1 bench 的 fp16 輸出逐點一致。
- 範例：fp16 `8bfcd029-…`（server 產生）、fp32 `eae00b98-…`（M1 bench 輸出，用 `scripts/register_ply.py` 登錄），id 記在 NOTES.md。
- 備註：Wikimedia 的縮圖 URL（`/thumb/.../640px-...`）回 400，是對方限制非標準縮圖尺寸，不是 server 問題。

### Code review（2026-11-21）
1. [P1] 總期限沒涵蓋 DNS、各次連線、慢速回應標頭 → **採納**：`Deadline` + `DeadlineStream` 包住 socket，每次讀寫／TLS／連線都用 `min(剩餘, 5s)`；DNS 在 helper 執行緒解析並以剩餘時間等待。新增慢 DNS、慢標頭測試。
2. [P1] 上傳 body 送不完會一直占名額 → **採納**：讀 body 加 `BODY_READ_TIMEOUT`（30 秒）→ 408 並釋放名額；新增 raw socket 測試。
3. [P2] 新套件沒進 lock 與重建步驟 → **採納**：更新 `requirements-lock.txt` 與 `server/CLAUDE.md`。
4. [P2] 淘汰與下載／列舉的競爭 → **採納**：下載改在 handler 先開檔再串流（Windows 開著的檔案無法刪除，淘汰會記 log 下次重試；來不及開檔就是乾淨的 404）；`/list` 的 stat 容忍檔案消失；`created` 改毫秒精度讓排序穩定。新增競爭測試。
5. [P2] save_ply 階段 OOM 時 `gaussians` 參考未釋放 → **採納**：例外後一律 `gaussians = None` 再 gc／empty_cache。
6. [P2] 不合法 port 會 500 → **採納**：`_validate_url` 讀取 `parts.port`，`ValueError` 一律 400；新增測試。
7. [P2] register_ply 與線上淘汰互相破壞 → **採納**：執行期間只把超過 10 分鐘的無 json `.ply` 視為孤兒（啟動時仍全部清除）；新增測試。
