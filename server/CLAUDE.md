# server/（splat-server 負責）

## 環境

- Windows 11 Home、NVIDIA RTX 4060 8GB VRAM
- Anaconda（conda 環境名稱：待 M1 決定）
- Python + FastAPI + [apple/ml-sharp](https://github.com/apple/ml-sharp)（PyTorch CUDA 版）
- 第三方原始碼放 `server/third_party/`（不 commit）
- 生成的 splat 放 `server/splats/`（不 commit）

## 啟動方式

（待 M2 補上）

## 注意事項

- shell 有 PowerShell 與 Git Bash 兩種；指令範例請標明用哪一種。
- 8GB VRAM：模型只在啟動時載入一次；輸入圖片過大時先縮圖。
- 下載任意網址有 SSRF 與大檔風險：要限制大小、逾時、只允許 http/https。
- 座標系以 ml-sharp 原始輸出為準，不在 server 端轉換（轉換由 vision 端處理）。
