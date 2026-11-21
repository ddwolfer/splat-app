# STATUS

## server（splat-server）

- [x] M0 結構與協作規則
- [x] M1 SHARP 跑通（CUDA、耗時、VRAM）
  - RTX 4060 fp16：推論約 6 秒（fp32 約 15 秒且超出 VRAM）、峰值 VRAM 約 6.2GB；`.ply` 約 63MB／118 萬個 gaussian（詳見 `plans/server-M1.md`）
- [x] M2 API（FastAPI 實作 API.md）
  - 單張約 9 秒（含存檔）；同時最多 3 個請求，超過回 503；啟動方式見 `server/CLAUDE.md`
- [x] M3 區網可連線
  - **Base URL：`http://192.168.0.32:8000`**（IP 192.168.0.32，port 8000）
  - 防火牆規則「splat-server 8000 (LAN)」已建立：只允許 192.168.0.0/24 經「乙太網路」連到 sharp env 的 python.exe（Private 設定檔）
  - 已驗證：PC 端經 192.168.0.32（/health、上傳生成 9.4 秒、下載 63MB）；**跨機（Mac → server）由 splat-vision 實測通過**（上傳 8.7 秒、下載 66,061,086 bytes 一致，見 NOTES.md 已解決 13:28）
  - fp16 經 vision 視覺比對定案為預設（與 fp32 每像素平均差 0.76/255，肉眼看不出）
  - server 需手動啟動（`.\server\run_server.ps1 -Lan`），PC 關機或 server 停止時連不到；IP 由 DHCP 分配，若改變會更新這裡

## vision（splat-vision）

- [x] V0 骨架 + mock 顯示
  - Xcode 26.6（visionOS 26.5 SDK）、MetalSplatter 1.0.1；mock 為 SHARP 格式 PLY（建置時產生）；OpenCV→visionOS 座標轉換、以開啟當下頭部位置為原點；模擬器 20 個測試全過（見 `plans/vision-V0.md`）
- [x] V1 UI + API client
  - 網址生成、進度與耗時、歷史（最多 10 筆，存在 App 內）、設定頁（Base URL／Mock 模式）、ATS 區網例外；本機 `vision/tools/mock_server.py` 照 API.md 模擬 server；模擬器 52 個測試全過（含 63MB／118 萬點的區網整合測試）
- [x] V2 接上真實 server 並修正座標
  - 跨機實測通過（上傳／網址生成約 10 秒含下載）；真實 ml-sharp PLY 方向正確，座標轉換不需修改；fp16 可接受；SHARP 快速讀檔器、效能量測、顯示品質上限（預設全部）。實機 FPS／記憶體在 V4 量測
- [x] V3 照片上傳
  - 系統照片選擇器（不需權限）、原檔直送保留 EXIF 焦距（超過 20 MiB／40 MP 或非 JPEG/PNG/HEIC/WebP 才在本機轉 JPEG，白底、保留 EXIF）、multipart 暫存檔上傳與進度、歷史縮圖；以 mock server 驗證，真實 server 於 M3 後與 V2 一起驗
- [ ] V4 安裝到實機

## 整合

- [ ] E2E 測試通過
