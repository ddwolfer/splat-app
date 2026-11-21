# API 規格 v1

> 唯一的 API 規格。只有 splat-server 可以修改；修改時同步更新 `CHANGELOG.md`。

**Base URL**：預設 `http://<PC 區網 IP>:8000`（實際 IP 見 `STATUS.md`）

## GET /health

```json
{"ok": true, "gpu": "<顯卡名稱>"}
```

## POST /generate

兩種輸入方式擇一：

1. JSON：`Content-Type: application/json`
   ```json
   {"image_url": "https://example.com/photo.jpg"}
   ```
2. multipart/form-data：欄位名稱 `file`（圖片檔）

成功回應（200）：

```json
{"id": "<uuid>", "ply_url": "/splats/<id>.ply", "seconds": 12.3}
```

- `ply_url` 是相對路徑，接在 Base URL 後面下載。
- `seconds`：server 端生成耗時（秒，浮點數）。

## GET /splats/<id>.ply

下載生成的 Gaussian splat（`.ply`，binary）。

## GET /list（除錯用）

列出 server 上已生成的 splat。

## 錯誤

HTTP 4xx / 5xx，body：

```json
{"error": "<說明>"}
```

## 座標系

以 ml-sharp 原始輸出為準，server 不做轉換；轉換由 vision 端處理。
