# server M1：SHARP 在本機 CUDA 跑通

## 目標

在 Windows 11 + RTX 4060 8GB 上，用 apple/ml-sharp 對一張測試圖產生 `.ply`，確認 `torch.cuda.is_available()` 為 True，記錄耗時與 VRAM 峰值。

## 現況（調查結果）

- 已有 conda 環境 `sharp`（`C:\Users\91006\anaconda3\envs\sharp`，Python 3.13，今天建立，與 ml-sharp README 建議一致），內含 `torch 2.8.0+cu128`，其他套件都還沒裝。
- **陷阱**：這台機器的 user site-packages（`%APPDATA%\Python\Python313\site-packages`）裝了大量套件（PIL 等），因為也是 Python 3.13，會被 conda env 讀到並**優先於** env 的 site-packages。目前 torch 能 import 只是因為 `typing_extensions` 等是從 user site 借來的。
  → 所有指令一律設 `PYTHONNOUSERSITE=1`，讓 env 自給自足。
- ml-sharp 已 clone 到 `server/third_party/ml-sharp`（commit `aed6527`，已 gitignore）。
- `requirements.txt` 釘選 `torch==2.8.0`、`torchvision==0.23.0`、`gsplat==1.5.3` 等；`-e .` 安裝 `sharp` CLI。
- gsplat 只用於 `--render`（影片），推論不需要；但 `sharp.cli.predict` 會間接 `import gsplat`，所以仍需安裝（純 Python wheel，CUDA kernel 首次使用時才 JIT 編譯，不渲染就不會觸發）。
- 模型 checkpoint 首次執行時自動下載到 `~/.cache/torch/hub/checkpoints/sharp_2572gikvuh.pt`（不在 repo 內）。
- 輸出 `.ply`：OpenCV 座標（x 右、y 下、z 前），場景中心大約在 (0,0,+z)；顏色已轉成 sRGB 的 SH DC；除了 `vertex` 之外還有 `extrinsic`、`intrinsic`、`image_size`、`frame`、`disparity`、`color_space`、`version` 等額外 element（要告知 vision 端，MetalSplatter 讀取時可能需要忽略它們）。
- 推論內部會縮放到 1536×1536，但縮放前**原圖先以 float32 搬上 GPU**，所以大圖仍會拉高 VRAM 峰值（Codex 指出）。M2 要在 CPU 端先縮圖；`f_px` 由縮放後尺寸重新算（`load_rgb` 用 35mm 等效焦距 × 寬度推算，縮圖時要同比例調整）。

## 步驟（依 Codex 意見修訂）

1. 安裝（皆在 `PYTHONNOUSERSITE=1` 下，用完整路徑 `envs/sharp/python.exe -m pip`）：
   1. `pip install torch==2.8.0 torchvision==0.23.0 --index-url https://download.pytorch.org/whl/cu128`（補齊 torch 相依，確保 torchvision 是 CUDA 版）
   2. 在 ml-sharp 目錄 `pip install -r requirements.txt --extra-index-url https://download.pytorch.org/whl/cu128`
   3. 驗證：`torch.__version__`、`cuda.is_available()`、`get_device_name`、`sys.executable`；`pip check`；`sharp --help`（同時驗證 gsplat 的完整 import 鏈）
   4. 若某個釘選版本沒有 wheel：先記錄是哪一個，再決定替代方案，不直接混用 conda-forge。
2. **先跑官方 CLI**：`sharp predict -i data/teaser.jpg -o <out> --device cuda`，讀回 PLY。
3. 成功後才寫薄層 `server/scripts/bench_sharp.py`，直接重用官方 `load_rgb`／`predict_image`／`save_ply`：
   - 分開計時：模型載入、warm-up、推論 ×3、存檔；每段前後 `torch.cuda.synchronize()`
   - 每輪前 `reset_peak_memory_stats()`，記錄 `max_memory_allocated/reserved`，另用 `nvidia-smi` 看整卡用量
   - 每輪結束 `del` 前次輸出；確認模型與輸出都在 cuda 上
   - 額外測一張大圖（例如 4000×3000，可用 teaser 放大產生）觀察 VRAM 峰值
4. 驗證 `.ply`：vertex 數量、欄位齊全、NaN/Inf、xyz 範圍、scale/opacity 合理範圍、metadata element；和 CLI 輸出比 vertex 數與統計量。
5. 記錄可重現資訊：ml-sharp commit、checkpoint SHA256、`pip freeze` 存到 `server/requirements-lock.txt`；環境步驟寫進 `server/CLAUDE.md`；耗時／VRAM 寫進本文件「結果」與 STATUS.md。
6. Codex code review → commit `[server] M1: ml-sharp runs on CUDA` → push。

## 風險

- 8GB VRAM 可能 OOM（桌面已佔用約 2.5GB）。對策：先關閉其他佔 VRAM 的程式、釋放前次輸出；最後才評估 fp16 autocast，且要另外驗證輸出有限值與品質。
- gsplat import 失敗會連 predict 都擋住（`predict.py` 頂層 import `render.py`）。先驗證完整 import 鏈；真的失敗才做最小、可追蹤的 lazy-import 修補，並記錄在本文件。
- Python 3.13 部分套件可能沒有 Windows wheel（pillow-heif、scipy 等）：若失敗改用 conda-forge 或放寬版本。
- user site-packages 污染：已用 `PYTHONNOUSERSITE=1` 處理；server 啟動腳本也要設定。

## 結果（2026-11-21）

環境：`sharp` env、torch 2.8.0+cu128、`torch.cuda.is_available() == True`、RTX 4060、driver 610.88；`pip check` 通過；gsplat import 鏈正常（未 JIT 編譯，因為沒 render）。

官方 CLI：`sharp predict -i data/teaser.jpg -o server/splats/m1 --device cuda` 成功（首次含 2.8GB checkpoint 下載約 90 秒）。

Benchmark（`server/scripts/bench_sharp.py`，teaser.jpg 1635×748，模型載入約 9 秒、常駐 2.7GB）：

推論時間為 warm-up 之後的穩定值；`smi-after` 是每輪推論結束後的 nvidia-smi 快照（不是峰值）。

| 模式 | 推論時間 | peak allocated | peak reserved | smi-after 整卡 |
|---|---|---|---|---|
| fp32（官方預設） | 14–18 秒 | 7.0 GB | **10.9 GB（超過 8GB 實體顯存）** | 7.8 / 8.2 GB |
| **fp16 autocast** | **約 5.9 秒**（warm-up 6.6 秒） | 4.75 GB | 6.2 GB | 7.2 / 8.2 GB |
| bf16 autocast | 約 5.7 秒 | 4.75 GB | 6.2 GB | 7.3 / 8.2 GB |

fp32 的 allocator reserved 超過實體顯存，**推斷**是 Windows WDDM 的 sysmem fallback（共享 GPU 記憶體）在作用，這也能解釋 fp32 慢 2–3 倍；沒有另外量測共享記憶體用量，因此這是推斷，不是直接量測。

與 fp32 的逐點差異（`server/scripts/compare_ply.py`，指標定義見該檔 docstring）：

| 指標 | fp16 median / p99 | bf16 median / p99 |
|---|---|---|
| xyz 相對誤差 | 0.04% / 0.36% | 0.30% / 4.2% |
| f_dc（SH DC） | 0.001 / 0.023 | 0.006 / 0.134 |
| opacity（sigmoid 後） | 0.004 / 0.082 | 0.035 / 0.437 |
| scale 相對誤差 | 1.2% / 41% | 7.6% / 209% |
| 共變異 Σ 相對誤差 | 3.0% / 85%（opacity 加權平均 11%） | 19% / 1100%（加權平均 80%） |
| 旋轉角 | 0.66° / 158°（接近等向的 gaussian 旋轉無意義，參考用） | 3.9° / 179° |

- 存檔（save_ply）約 2.5 秒；`.ply` 約 63MB、1,179,648 個 gaussian（固定數量，與輸入解析度無關）。
- 大圖 4000×1830：fp32／fp16 峰值與小圖幾乎相同（float 原圖只多約 90MB）；M2 仍會在 CPU 先縮圖以防更大的圖。
- PLY 檢查：14 個 vertex 欄位齊全、全部 finite、四元數已正規化、opacity 平均 0.76、xyz 中位數約 (0, 0, 1.09)、z 範圍 0.66–19.4。
- **決定：M2 預設用 fp16 autocast**（只包 model forward；後處理的 `linalg.inv` 不支援半精度，維持 fp32）。位置、顏色、不透明度的誤差很小；形狀（Σ）有約 1% 的 gaussian 差異較大，數值上無法證明肉眼看不出差異 → M2 保留設定可切回 fp32，並提供 fp32／fp16 兩份樣本給 vision 端做視覺比對，再定案。bf16 不使用。
- 可重現資訊：ml-sharp commit `aed6527`、checkpoint SHA256 `94211a75…f073d`、`server/requirements-lock.txt`，重建步驟見 `server/CLAUDE.md`。

## Codex 審查

### Plan review（2026-11-21）
1. 大圖仍會拉高 VRAM（原圖先上 GPU）→ **採納**：已修正說明，M1 加測大圖，M2 在 CPU 先縮圖並調整 f_px。
2. 計時要 synchronize、重設峰值統計、分段計時 → **採納**：寫入步驟 3。
3. OOM 對策（empty_cache 無效、fp16 要驗證）→ **採納**：修改風險段落。
4. gsplat 失敗會擋 predict，不要用 stub 掩蓋 → **採納**：先驗證完整 import 鏈。
5. 強制 `--device cuda`、記錄 sys.executable 與版本 → **採納**。
6. PLY 驗證要更完整、給 vision 實測樣本 → **部分採納**：加 Inf／範圍／metadata 檢查；不訂嚴格數值容差（同一模型同一輸入，比 vertex 數與統計量即可）；樣本 .ply 在 M2 提供（依原計畫）。
7. 記錄 commit、checkpoint 雜湊、套件版本；缺 wheel 不直接換來源 → **採納**。
8. 先用 teaser.jpg 跑官方 CLI，再寫薄層 benchmark → **採納**：已調整步驟順序，不另外下載測試照片。

### Code review（2026-11-21）
1. benchmark 驗證失敗仍回傳 0 → **採納**：`check_ply` 回傳 problems（欄位、element、finite、scale、四元數、z>0），有問題就 exit 1。
2. fp16 結論缺可重現的比較流程 → **採納**：新增 `server/scripts/compare_ply.py`（含 scale、opacity、旋轉、共變異），結果表與定義寫進本文件；並因共變異 p99 偏大，改為「預設 fp16、保留 fp32 開關、交給 vision 視覺比對」。
3. 文件說預設 fp16、程式預設 fp32 → **採納**：`sharp_runner.DEFAULT_AMP = "fp16"`，bench 也用它當預設。
4. warm-up 未分離 → **採納**：先跑一次 warm-up 單獨報告，再跑 N 次計算穩定值。
5. VRAM 溢出是推論而非量測、smi 是快照 → **採納**：輸出改名 `smi-after`，文件改成「推斷」並說明依據。
6. `--runs` 可為 0 → **採納**：argparse 限制 >= 1。
