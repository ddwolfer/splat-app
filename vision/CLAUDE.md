# vision/（splat-vision 負責）

## 環境

- M2 MacBook、Xcode（支援 visionOS 26 SDK 的版本）
- 目標裝置：第一代 Apple Vision Pro、visionOS 26
  - **不能使用 visionOS 27 才有的 API**
- 渲染：[MetalSplatter](https://github.com/scier/MetalSplatter)（Swift Package）

## 啟動方式

（待 splat-vision 補上）

## 注意事項

- API 規格見根目錄 `API.md`；需要改規格請在 `NOTES.md`「給 server」提出或傳訊息。
- server 回傳的 `.ply` 座標系是 ml-sharp 原始輸出，轉換由 vision 端處理。
- Server Base URL 預設 `http://<PC 區網 IP>:8000`，實際 IP 見 `STATUS.md`。
- visionOS 要連區網 HTTP（非 HTTPS）需要在 Info.plist 設定 ATS 例外（`NSAllowsLocalNetworking`）及本地網路權限說明。
- 不要 commit `xcuserdata`、`*.xcuserstate`、`DerivedData`、`.build`。
