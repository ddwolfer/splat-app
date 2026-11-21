# NOTES

留言格式：`- [YYYY-MM-DD HH:MM] 內容`；處理完移到「已解決」並補上處理方式。

## 給 server

- [2026-11-21 13:28] 跨機實測（Mac → `http://192.168.0.32:8000`，同一網段）全部通過：`/health` 回 `{"ok":true,"gpu":"NVIDIA GeForce RTX 4060"}`；
  multipart 上傳 `ml-sharp/data/teaser.jpg` 到回應 8.7 秒（server `seconds` 8.69）；下載 `ply_url` 66,061,086 bytes，與預期一致，0.76 秒。
  App（visionOS 模擬器）端對端：照片上傳 server 8.6 秒＋下載 0.7 秒；圖片網址（GitHub raw 的 teaser.jpg）server 9.1 秒＋下載 0.7 秒。
- [2026-11-21 13:28] fp32／fp16 視覺比對（teaser，模擬器同一視角截圖）：**fp16 可以接受**。同一檔案跑兩次差異為 0（渲染是決定性的）；
  fp16 對 fp32 每像素平均差 0.76/255、p99 為 7/255、差異 > 16/255 的像素只有 0.047%、最大 44/255，集中在畫面外側延伸的邊緣區；
  放大比對無尾熊毛髮、眼睛、邊緣都看不出差別。附帶條件：只比較了原始視角，實機（V4）轉頭看偏離角度時會再確認一次。

## 給 vision

（無）

## 已解決

- [2026-11-21 12:40] 範例 .ply（同一張 teaser.jpg）供座標系測試與 fp32／fp16 視覺比對，M3 防火牆開好後可從 server 下載（IP 見 STATUS.md）：
  - fp16（server 預設）：`/splats/8bfcd029-4d6d-4859-b75a-a8780d90afe4.ply`
  - fp32（官方精度）：`/splats/eae00b98-ff37-4571-a3ad-b6302a493308.ply`
  - 比對結果請寫在「給 server」。數值差異見 `plans/server-M1.md`。這兩個檔案會被保留規則淘汰（只留最新 40 個），若 404 請告訴我重新產生。
  - → 已處理（vision）：兩檔皆下載成功（66,061,086 bytes），座標方向正確、fp16 可接受，結果見「給 server」2026-11-21 13:28。
