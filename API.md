# API 規格 v1

> 唯一的 API 規格。只有 splat-server 可以修改；修改時同步更新 `CHANGELOG.md`。

**Base URL**：預設 `http://<PC 區網 IP>:8000`（實際 IP 見 `STATUS.md`）。純 HTTP（區網），visionOS 需要 ATS 例外。

## GET /health

```json
{"ok": true, "gpu": "<顯卡名稱>"}
```

server 在模型載入完成後才開始接受連線，所以只要 `/health` 有回應就代表可以生成。

## POST /generate

兩種輸入方式擇一：

1. JSON：`Content-Type: application/json`（body ≤ 4KB）
   ```json
   {"image_url": "https://example.com/photo.jpg"}
   ```
2. multipart/form-data：欄位名稱 `file`（圖片檔）

成功回應（200）：

```json
{"id": "<uuid>", "ply_url": "/splats/<id>.ply", "seconds": 12.3}
```

- `ply_url` 是相對路徑，接在 Base URL 後面下載。
- `seconds`：server 端從收到請求到 `.ply` 寫完的總耗時（秒，浮點數；包含下載與排隊）。

### 行為說明

- **同步**：請求會等到生成完成才回應。單張約 9 秒（RTX 4060，fp16）；前面有排隊時最多約 30 秒。**client 逾時請設 ≥ 120 秒**。
- **排隊**：同時最多 3 個請求（1 個生成中 + 2 個等待），超過立刻回 `503 {"error": "server busy, try again later"}`，請稍後重試。
- **斷線**：client 斷線不會取消生成；完成後會出現在 `/list`。
- **圖片限制**：檔案 ≤ 20MB、≤ 40MP；格式 JPEG／PNG／HEIC／WebP 等 Pillow 能解的格式；依 EXIF 轉正；長邊 > 2048 會先縮圖；透明區域以白色填底。
- **焦距**：取自 EXIF（35mm 等效焦距，或 FocalLength），沒有就假設 30mm（與 ml-sharp 相同）。網路圖片常沒有 EXIF。
- **`image_url` 限制**：只允許 http/https、公開網路位址（私有／區網／loopback 位址會被拒絕）；最多 3 次 redirect；下載總時限 20 秒。
- **保留**：server 只保留最新 40 個 splat，舊的會被刪除（之後 `/splats/<id>.ply` 回 404）。

## GET /splats/<id>.ply

下載生成的 Gaussian splat（`application/octet-stream`）。

- 約 63MB、固定 1,179,648 個 gaussian（與輸入解析度無關）。
- binary little-endian PLY，`vertex` 欄位：`x y z f_dc_0 f_dc_1 f_dc_2 opacity scale_0 scale_1 scale_2 rot_0 rot_1 rot_2 rot_3`（皆 float32）
  - `f_dc_*`：SH DC 係數，已轉成 sRGB；`opacity`：logit；`scale_*`：log；`rot_*`：四元數 (w, x, y, z)
- 另有額外 element：`extrinsic`、`intrinsic`、`image_size`、`frame`、`disparity`、`color_space`、`version`（reader 應忽略不認得的 element）。

## GET /list（除錯用）

```json
{"splats": [
  {"id": "<uuid>", "ply_url": "/splats/<id>.ply", "seconds": 8.6,
   "created": "2026-11-21T04:30:00+00:00", "source": "https://host/path.jpg 或 upload:<檔名>",
   "width": 1635, "height": 748, "amp": "fp16", "size_bytes": 66061086}
]}
```

依建立時間新到舊。`source` 不含 query string 與帳密。`width`／`height` 是送進模型的尺寸（縮圖後）。

## 錯誤

HTTP 4xx / 5xx，body 一律：

```json
{"error": "<說明>"}
```

| 狀態 | 情況 |
|---|---|
| 400 | JSON 格式錯、缺 `image_url`／`file`、不是圖片、URL 不合法或指向私有位址 |
| 404 | 找不到 splat（或已被淘汰） |
| 413 | 圖片或 body 太大、像素超過上限 |
| 415 | Content-Type 不是 JSON 或 multipart |
| 502 | 圖片網址回傳錯誤或連線失敗 |
| 503 | server 忙碌（排隊已滿）或 GPU 記憶體不足 → 稍後重試 |
| 504 | 下載圖片逾時 |
| 507 | server 磁碟空間不足 |
| 500 | 未預期的錯誤 |

## 座標系

以 ml-sharp 原始輸出為準，server 不做轉換；轉換由 vision 端處理。

- OpenCV 慣例：**x 右、y 下、z 前**（相機在原點、看向 +z）。
- 場景中心約在 (0, 0, +z)；單位為公尺（metric scale）。範例 teaser：z 中位數約 1.1，範圍 0.66–19.4。
