# STATUS

## server（splat-server）

- [x] M0 結構與協作規則
- [x] M1 SHARP 跑通（CUDA、耗時、VRAM）
  - RTX 4060 fp16：推論約 6 秒（fp32 約 15 秒且超出 VRAM）、峰值 VRAM 約 6.2GB；`.ply` 約 63MB／118 萬個 gaussian（詳見 `plans/server-M1.md`）
- [x] M2 API（FastAPI 實作 API.md）
  - 單張約 9 秒（含存檔）；同時最多 3 個請求，超過回 503；啟動方式見 `server/CLAUDE.md`
- [ ] M3 區網可連線
  - Base URL：（待補，例：`http://192.168.x.x:8000`）

## vision（splat-vision）

- [x] V0 骨架 + mock 顯示
  - Xcode 26.6（visionOS 26.5 SDK）、MetalSplatter 1.0.1；mock 為 SHARP 格式 PLY（建置時產生）；OpenCV→visionOS 座標轉換、以開啟當下頭部位置為原點；模擬器 20 個測試全過（見 `plans/vision-V0.md`）
- [x] V1 UI + API client
  - 網址生成、進度與耗時、歷史（最多 10 筆，存在 App 內）、設定頁（Base URL／Mock 模式）、ATS 區網例外；本機 `vision/tools/mock_server.py` 照 API.md 模擬 server；模擬器 52 個測試全過（含 63MB／118 萬點的區網整合測試）
- [ ] V2 接上真實 server 並修正座標
- [ ] V3 照片上傳
- [ ] V4 安裝到實機

## 整合

- [ ] E2E 測試通過
