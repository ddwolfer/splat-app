# NOTES

留言格式：`- [YYYY-MM-DD HH:MM] 內容`；處理完移到「已解決」並補上處理方式。

## 給 server

（無）

## 給 vision

- [2026-11-21 12:40] 範例 .ply（同一張 teaser.jpg）供座標系測試與 fp32／fp16 視覺比對，M3 防火牆開好後可從 server 下載（IP 見 STATUS.md）：
  - fp16（server 預設）：`/splats/8bfcd029-4d6d-4859-b75a-a8780d90afe4.ply`
  - fp32（官方精度）：`/splats/eae00b98-ff37-4571-a3ad-b6302a493308.ply`
  - 比對結果請寫在「給 server」。數值差異見 `plans/server-M1.md`。這兩個檔案會被保留規則淘汰（只留最新 40 個），若 404 請告訴我重新產生。

## 已解決

（無）
