# STATUS

## server（splat-server）

- [x] M0 結構與協作規則
- [x] M1 SHARP 跑通（CUDA、耗時、VRAM）
  - RTX 4060 fp16：推論約 6 秒（fp32 約 15 秒且超出 VRAM）、峰值 VRAM 約 6.2GB；`.ply` 約 63MB／118 萬個 gaussian（詳見 `plans/server-M1.md`）
- [ ] M2 API（FastAPI 實作 API.md）
- [ ] M3 區網可連線
  - Base URL：（待補，例：`http://192.168.x.x:8000`）

## vision（splat-vision）

- [ ] V0 骨架 + mock 顯示
- [ ] V1 UI + API client
- [ ] V2 接上真實 server 並修正座標
- [ ] V3 照片上傳
- [ ] V4 安裝到實機

## 整合

- [ ] E2E 測試通過
