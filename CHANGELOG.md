# CHANGELOG（API）

| 日期 | 內容 | 原因 |
|---|---|---|
| 2026-11-21 | API v1 建立：`/health`、`/generate`、`/splats/<id>.ply`、`/list` | 專案初始化 |
| 2026-11-21 | 補充說明（不改端點與欄位）：同步行為與建議逾時、排隊上限與 503、斷線行為、圖片與 URL 限制、保留 40 個、`/list` 回應格式、`.ply` 欄位說明、錯誤狀態碼表、座標系細節 | M2 實作完成，把 server 行為寫清楚給 vision 端 |
| 2026-11-21 | 明確寫出上傳限制的精確數值：20 MiB（20,971,520 bytes）、40,000,000 像素、multipart body 上限 20 MiB + 64 KiB（行為不變） | vision V3 依 server/config.py 取值；規格應以 API.md 為準，原本的「20MB／40MP」有歧義 |
