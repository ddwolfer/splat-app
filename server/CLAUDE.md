# server/（splat-server 負責）

## 環境

- Windows 11 Home、NVIDIA GeForce RTX 4060 8GB VRAM（driver 610.88）
- Anaconda，conda 環境 **`sharp`**（`C:\Users\91006\anaconda3\envs\sharp`，Python 3.13）
- PyTorch `2.8.0+cu128`、torchvision `0.23.0+cu128`；完整套件版本見 `server/requirements-lock.txt`
- [apple/ml-sharp](https://github.com/apple/ml-sharp) clone 在 `server/third_party/ml-sharp`（commit `aed6527499ef91cba3b54c18d49a870f25947190`，不 commit），以 `pip install -e` 安裝
- Checkpoint：`%USERPROFILE%\.cache\torch\hub\checkpoints\sharp_2572gikvuh.pt`（2.8GB，SHA256 `94211a75198c47f61fca7d739ba08a215418d8d398d48fddf023baccc24f073d`），首次執行自動下載
- 生成的 splat 放 `server/splats/`（不 commit）

### ⚠️ 一定要設 `PYTHONNOUSERSITE=1`

這台機器的 `%APPDATA%\Python\Python313\site-packages` 裝了很多套件，會被 conda env 讀到並**優先**於 env 自己的套件。所有指令都要設：

```bash
# Git Bash
export PYTHONNOUSERSITE=1
PY=/c/Users/91006/anaconda3/envs/sharp/python.exe
```
```powershell
# PowerShell
$env:PYTHONNOUSERSITE = "1"
$PY = "C:\Users\91006\anaconda3\envs\sharp\python.exe"
```

### 從零重建環境

```bash
export PYTHONNOUSERSITE=1
conda create -n sharp python=3.13 -y
PY=/c/Users/91006/anaconda3/envs/sharp/python.exe
git clone https://github.com/apple/ml-sharp server/third_party/ml-sharp
git -C server/third_party/ml-sharp checkout aed6527499ef91cba3b54c18d49a870f25947190
$PY -m pip install torch==2.8.0 torchvision==0.23.0 --index-url https://download.pytorch.org/whl/cu128
cd server/third_party/ml-sharp && $PY -m pip install -r requirements.txt --extra-index-url https://download.pytorch.org/whl/cu128 && cd -
$PY -m pip install fastapi==0.165.0 uvicorn==0.54.0 httpx==0.28.1 httpcore==1.0.9 python-multipart==0.0.34 pytest==9.2.0
$PY -c "import torch; print(torch.cuda.is_available())"   # 必須是 True
```

## 檔案

- `app.py`：FastAPI（API.md v1）；`config.py` 設定；`fetch.py` 安全下載（SSRF 防護在連線當下驗證 IP）；`imaging.py` 圖片解碼／轉正／縮圖／焦距；`storage.py` 檔案儲存（`<id>.json` 是完成標記）
- `sharp_runner.py`：載入模型、推論（官方 `predict_image` 的鏡像版，加上只作用在網路 forward 的 fp16 autocast）。M2 的 API server 重用它。
- `scripts/bench_sharp.py`：M1 benchmark（計時、VRAM、PLY 檢查）。
  ```bash
  $PY server/scripts/bench_sharp.py -i server/third_party/ml-sharp/data/teaser.jpg -o server/splats/m1 -n 3 --amp fp16
  ```

## 啟動方式

```powershell
# PowerShell（在 repo 根目錄）
.\server\run_server.ps1          # 只有本機：127.0.0.1:8000
.\server\run_server.ps1 -Lan     # 區網：0.0.0.0:8000（需要防火牆規則，見 STATUS.md / M3）
```
```bash
# Git Bash
server/run_server.sh              # 127.0.0.1:8000
server/run_server.sh --lan        # 0.0.0.0:8000
```

啟動約 13 秒（載入模型）後才開始 listen。單一 process、不開 reload（GPU 串行化依賴這點）。

設定（環境變數，見 `config.py`）：`SHARP_AMP`（fp16／none）、`MAX_UPLOAD_BYTES`、`MAX_PIXELS`、`MAX_SIDE`、`MAX_INFLIGHT`、`MAX_SPLATS`、`ALLOWED_PRIVATE_NETS`（允許下載的私有網段 CIDR，逗號分隔，預設空）等。

### 測試

```bash
cd server && PYTHONNOUSERSITE=1 $PY -m pytest tests -q -p no:cacheprovider   # 假模型，不需要 GPU
```

curl（server 啟動後）：
```bash
curl -s http://127.0.0.1:8000/health
curl -s -X POST http://127.0.0.1:8000/generate -F "file=@server/third_party/ml-sharp/data/teaser.jpg"
curl -s -X POST http://127.0.0.1:8000/generate -H "Content-Type: application/json" \
     -d '{"image_url":"https://upload.wikimedia.org/wikipedia/commons/4/47/PNG_transparency_demonstration_1.png"}'
curl -s -o out.ply http://127.0.0.1:8000/splats/<id>.ply
curl -s http://127.0.0.1:8000/list
```

把離線產生的 .ply 交給 server 提供：`$PY server/scripts/register_ply.py <file.ply> --source "sample:..." --amp none`

## 區網（M3）

PC 區網 IP：192.168.0.32（網卡「乙太網路」，Private 設定檔；建議在路由器設 DHCP 保留）。
防火牆規則（**系統管理員** PowerShell，只需執行一次）：

```powershell
New-NetFirewallRule -DisplayName "splat-server 8000 (LAN)" `
  -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8000 `
  -Profile Private -InterfaceAlias "乙太網路" -RemoteAddress 192.168.0.0/24 `
  -Program "C:\Users\91006\anaconda3\envs\sharp\python.exe"
# 移除：Remove-NetFirewallRule -DisplayName "splat-server 8000 (LAN)"
```

規則寫死 port 8000 與 `envs\sharp\python.exe`；改 port 或換 Python 要另外加規則。先建規則再用 `-Lan` 啟動，避免 Windows 自動跳出較寬鬆的允許視窗。

## 注意事項

- shell 有 PowerShell 與 Git Bash 兩種；指令範例請標明用哪一種。
- **8GB VRAM**：fp32 推論峰值 reserved 約 10.9GB，超過顯卡容量（推斷會溢出到共享記憶體，約 14–18 秒）；**fp16 autocast** 峰值約 6.2GB，約 6 秒。`sharp_runner.DEFAULT_AMP = "fp16"`；位置／顏色誤差很小，少數 gaussian 形狀差異較大，待 vision 端視覺比對後定案（數據見 `plans/server-M1.md`）。bf16 誤差太大，不使用。
- 比較兩個 .ply：`$PY server/scripts/compare_ply.py ref.ply cand.ply`
- `torch.linalg.inv`（後處理）不支援 fp16，所以 autocast 只包住 model forward。
- 模型只在啟動時載入一次（載入約 9 秒，常駐約 2.7GB VRAM）。
- 推論內部固定縮放到 1536×1536；原圖會先以 float32 上 GPU，超大圖要先在 CPU 縮圖。
- 下載任意網址有 SSRF 與大檔風險：要限制大小、逾時、只允許 http/https。
- 座標系以 ml-sharp 原始輸出為準（OpenCV：x 右、y 下、z 前），不在 server 端轉換（由 vision 端處理）。
