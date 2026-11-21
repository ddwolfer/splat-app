# splat-app

在 Apple Vision Pro 上觀看「單張照片生成的 3D Gaussian Splat」。

貼上一個網路圖片網址（或從相簿選一張照片）→ 區網內的 Windows PC 用 Apple 的
[ml-sharp](https://github.com/apple/ml-sharp)（CUDA）生成 3D Gaussian splat（`.ply`）→
Vision Pro App 下載後用 [MetalSplatter](https://github.com/scier/MetalSplatter) 渲染。

## 架構

```
 ┌──────────────────────────────┐          區網 (LAN)          ┌──────────────────────────────────┐
 │  Apple Vision Pro (gen 1)    │                               │  Windows 11 PC (RTX 4060 8GB)     │
 │  visionOS 26                 │   POST /generate              │  server/  (Python + FastAPI)      │
 │                              │   {image_url} 或 file ───────►│                                   │
 │  vision/  (SwiftUI App)      │                               │   ┌─────────────┐   ┌──────────┐  │
 │   ├─ UI：輸入網址 / 選照片   │◄─── {id, ply_url, seconds} ───│   │  FastAPI    │──►│ ml-sharp │  │
 │   ├─ API client              │                               │   │  (0.0.0.0:  │   │ (CUDA)   │  │
 │   └─ MetalSplatter 渲染      │   GET /splats/<id>.ply ──────►│   │   8000)     │◄──│          │  │
 │      (座標轉換在此處理)      │◄────────── .ply ──────────────│   └─────────────┘   └──────────┘  │
 └──────────────────────────────┘                               │        server/splats/<id>.ply     │
                                                                └──────────────────────────────────┘
```

## 目錄

| 路徑 | 說明 | 負責 |
|---|---|---|
| `server/` | FastAPI + ml-sharp 推論服務 | splat-server（Windows） |
| `vision/` | visionOS App（SwiftUI + MetalSplatter） | splat-vision（Mac） |
| `plans/` | 各里程碑的計畫與 Codex 審查紀錄 | 各自的里程碑檔 |
| `API.md` | 唯一的 API 規格 | 只有 splat-server 可改 |
| `STATUS.md` | 里程碑勾選表 | 各自勾自己的部分 |
| `NOTES.md` | 兩邊互相留言 | 兩邊 |
| `CHANGELOG.md` | API 變更紀錄 | splat-server |
| `CLAUDE.md` | 協作規則（兩邊的 Claude Code 都會讀） | 兩邊（需共識） |

## 兩台機器分工

- **Windows PC（splat-server）**：Windows 11、RTX 4060 8GB、Anaconda。負責 `server/`、`API.md`、`CHANGELOG.md`。
- **M2 MacBook（splat-vision）**：Xcode、visionOS 26 SDK。負責 `vision/`，目標是第一代 Vision Pro（不使用 visionOS 27 API）。

## 快速開始

### Server（Windows）

環境建立見 `server/CLAUDE.md`。啟動（PowerShell，repo 根目錄）：

```powershell
.\server\run_server.ps1 -Lan
```

約 13 秒後可用：`curl http://<PC IP>:8000/health`。API 見 `API.md`。

### Vision App（Mac）

（待補，見 `vision/CLAUDE.md`）

### 端對端測試

（待補）
